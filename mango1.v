`include "hvsync_generator.v"
`include "cpu6502.v"
`include "font_cp437_8x8.v"

/**
; ==========================================
; uBASIC6502 fork of mango_one  v1.7
; Original monitor and emulator by sehugg
; Modifications by Vincent Crabtree, Mar 2026
;
; For Original see
;  https://github.com/sehugg/mango_one
;
; For Tiny BASIC  see
;   https://github.com/VinCBR900/65c02-Tiny-BASIC
;
; The Demo has a Showcase program embedded.
; Type LIST to see it and RUN to, er, RUN it
;
; KEYBOARD CHEAT SHEET (surrogates for shift-lost chars):
;   ` -> "    [ -> (    ] -> )    \ -> *    ' -> +
;   = - , . / work as labelled.  : < > work as labelled.
;   % and ; are unavailable (shift state lost in browser).
;
; v1.7 (Mar 2026) Code review fixes:
;   - .ti no longer strips bit7 (DO is plain ASCII from CPU)
;   - RAM loaded from ram.hex (full 4KB, $0000-$0FFF) instead of
;     showcase_rom intermediate + copy loop; showcase.hex retired
; v1.6 (Mar 2026) Switch from Apple 1 PIA ($D010-$D012) to Kowalski I/O
;   ($E001/$E004). This matches the original uBASIC6502.asm exactly
;   so the ROM needs no changes. Benefits:
;   - PUTCH: STA $E001 + RTS  (was: spin on BIT $D012 / BMI loop)
;   - GETCH: LDA $E004 / BEQ loop (was: poll $D011 + read $D010 + AND #$7F)
;   - tready/keystrobe handshake removed from display path entirely
;   - te fires directly on $E001 write with no timing dependency
; v1.5 (Mar 2026) Rewrote remap_key() with accurate keyCode analysis.
;   8bitworkshop delivers keyCode|0x80, not ASCII. Shift state is lost for
;   digit-row keys. Surrogates assigned for (, ), *, + using unshifted keys
;   that are unused in BASIC ([ ] \ '). Works on both US and UK keyboards.
;   See GitHub issue: https://github.com/sehugg/8bitworkshop/issues/241
; v1.4 (Mar 2026) BS ($08) handling in signetics_term: backspace-overwrite-
;   backspace in one clock.
; v1.3 (Mar 2026) Map backtick ` -> " surrogate.
; v1.2 (Mar 2026) Keyboard remapping: browser keyCode -> correct ASCII.
; v1.1 (Mar 2026) Fix tready timing: hpos==256 -> hpos>=256.
; v1.0 (Mar 2026) Initial port of uBASIC6502 to Mango1.
; ==========================================
*/

// =============================================================================
// signetics_term  --  32x32 character frame buffer + video output
//
// Unchanged from v1.4 except tready is now unused by the I/O handler
// (kept in the module for potential future use, but no longer read by CPU).
// te fires on writes to $E001 (Kowalski IO_OUT) rather than $D012.
// BS support (v1.4): ti==8 -> overwrite previous char with space, dofs--.
// =============================================================================
module signetics_term(clk, reset, hpos, vpos, tready, dot, te, ti);

  input clk,reset;
  input [8:0] hpos;
  input [8:0] vpos;
  input te;       // input enable: fires on CPU write to $E001
  input [7:0] ti; // input data (plain 7-bit ASCII, bit7 already stripped)
  output tready;  // terminal ready (kept for compatibility; not used by Kowalski path)
  output dot;     // terminal video output

  reg [7:0] dshift[1024]; // 32x32 character frame buffer
  reg [9:0] dofs;         // write pointer
  reg [9:0] scroll;       // scroll offset
  reg [9:0] scnt;         // row-clear countdown after CR or right-edge wrap

  always @(posedge clk or posedge reset)
    if (reset) begin
      scnt   <= 0;
      scroll <= 0;
      dofs   <= 28*32;
    end else if (scnt > 0) begin
      dshift[scroll] <= 0;   // clear row during scroll
      scroll <= scroll + 1;
      scnt   <= scnt - 1;
    end else if (te) begin
      if (ti == 13) begin                        // CR: advance to next row
        scnt <= 32;
        dofs <= ((dofs + 32) & ~10'd31);
      end else if (ti == 8) begin                // BS: backspace-overwrite-backspace
        if ((dofs & 10'h01f) != 0) begin         // clamp at left edge of row
          dshift[dofs-1] <= 8'd32;               // overwrite previous char with SPACE
          dofs <= dofs - 1;                      // move cursor back
        end
      end else if (ti >= 32) begin               // printable: store and advance
        dshift[dofs] <= ti;
        if ((dofs & 31) == 31) scnt <= 32;       // right-edge wrap -> scroll
        dofs <= dofs + 1;
      end
    end

  font_cp437_8x8 tile_rom(.addr(char_addr), .data(char_data));
  wire [9:0]  nt_addr   = {vpos[7:3], hpos[7:3]};
  wire [7:0]  cur_char  = dshift[nt_addr + scroll];
  wire [10:0] char_addr = {cur_char, vpos[2:0]};
  wire [7:0]  char_data;
  wire dot = char_data[~hpos[2:0]];

  // tready kept for interface compatibility; not used in Kowalski I/O path.
  // In the old Apple 1 PIA path the CPU polled this before writing $D012.
  // In the Kowalski path PUTCH is simply STA $E001 with no polling.
  assign tready = !reset && !te && scnt == 0 && hpos >= 256;

  initial begin
    integer i;
    for (i = 0; i < 1024; i = i+1) dshift[i] = 0;
  end

endmodule

// =============================================================================
// apple1_top  --  top-level: CPU + RAM + ROM + keyboard + terminal
//
// I/O map (Kowalski layout, matching original uBASIC6502.asm):
//   $E001  w   IO_OUT : write char to signetics_term  (PUTCH: STA $E001)
//   $E004  r   IO_IN  : read char; 0 = no key waiting  (GETCH: LDA $E004 / BEQ)
//   $F800-$FFFF    ROM (ubasic6502.hex, 2048 bytes)
//   $0000-$0FFF    RAM (4 KB; showcase pre-loaded at $0200)
// =============================================================================
module apple1_top(clk, reset, hsync, vsync, rgb, keycode, keystrobe);

  input        clk, reset;
  input  [7:0] keycode;
  output reg   keystrobe;
  output       hsync, vsync;
  output [2:0] rgb;

  wire display_on;
  wire [8:0] hpos, vpos;

  wire [15:0] AB;
  wire [7:0]  DI;
  wire [7:0]  DO;
  wire        WE;

  // IRQ: active HIGH in Arlet's cpu6502. ESC (keycode=0x9B) asserts it.
  // Level-triggered: deasserts when keystrobe clears keycode[7] on next $E004 read.
  // (Spotty in Edge, fine in Chrome — can revisit later.)
  wire IRQ = (keycode == 8'h9B);
  wire NMI = 0;
  wire RDY = 1;

  cpu6502 cpu(clk, reset, AB, DI, DO, WE, IRQ, NMI, RDY);

  // ---------------------------------------------------------------------------
  // remap_key: browser keyCode|0x80 -> ASCII for Kowalski IO_IN
  //
  // 8bitworkshop delivers keyCode|0x80. keyCode is the physical key position,
  // not the character — shift state is lost for digit-row keys.
  //
  //   0xBB = key -> '='   0xBC , -> ','   0xBD - -> '-'
  //   0xBE . -> '.'       0xBF / -> '/'
  //   0xC0 ` -> '"'   0xDB [ -> '('   0xDD ] -> ')'
  //   0xDC \ -> '*'   0xDE ' -> '+'
  // ---------------------------------------------------------------------------
  function [7:0] remap_key;
    input [7:0] kc;
    begin
      case (kc)
        8'hBB: remap_key = 8'h3D; // = key  -> '='
        8'hBC: remap_key = 8'h2C; // , key  -> ','
        8'hBD: remap_key = 8'h2D; // - key  -> '-'
        8'hBE: remap_key = 8'h2E; // . key  -> '.'
        8'hBF: remap_key = 8'h2F; // / key  -> '/'
        8'hC0: remap_key = 8'h22; // ` key  -> '"'
        8'hDB: remap_key = 8'h28; // [ key  -> '('
        8'hDD: remap_key = 8'h29; // ] key  -> ')'
        8'hDC: remap_key = 8'h2A; // \ key  -> '*'
        8'hDE: remap_key = 8'h2B; // ' key  -> '+'
        default: remap_key = kc & 8'h7F;  // strip bit7: 8bitworkshop delivers keyCode|0x80
      endcase
    end
  endfunction

  // ---------------------------------------------------------------------------
  // Read bus (registered, 1-cycle latency matches cpu6502 DI pipeline)
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    casez (AB)
      // RAM
      16'h0zzz: DI <= ram[AB[11:0]];

      // IO_IN ($E004): Kowalski keyboard read
      //   Returns plain ASCII if key present, 0x00 if not.
      //   ESC (0x9B) masked to 0x00 — IRQ handles it, don't put it in IBUF.
      16'hE004: begin
        if (keycode[7] && keycode != 8'h9B)
          DI <= remap_key(keycode);
        else
          DI <= 8'h00;
      end

      // ROM ($F800-$FFFF)
      16'hf8zz, 16'hf9zz, 16'hfazz, 16'hfbzz,
      16'hfczz, 16'hfdzz, 16'hfezz, 16'hffzz:
        DI <= basic_rom[AB[10:0] - 11'h800];

      default: DI <= 8'hFF;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Write bus + keystrobe
  //
  // keystrobe asserts for one cycle when CPU reads $E004 with a key present,
  // acknowledging the keypress and clearing keycode[7] -> deasserts IRQ.
  // $E001 (IO_OUT) is handled entirely by the signetics_term te signal below.
  // ---------------------------------------------------------------------------
  always @(posedge clk) begin
    keystrobe <= 0; // default: deasserted

    if (!WE && AB == 16'hE004 && keycode[7])
      keystrobe <= 1; // CPU reading keyboard -> acknowledge

    if (WE) begin
      casez (AB)
        16'h0zzz: ram[AB[11:0]] <= DO; // RAM write
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------------------
  // Memory and ROM
  //
  // ram.hex: full 4KB image of $0000-$0FFF extracted from the assembled binary.
  // Includes the pre-loaded BASIC showcase program at $0200 and zero-filled
  // zero-page / stack. No SHOWCASE_END trimming needed — load the whole thing.
  // ---------------------------------------------------------------------------
  reg [7:0] ram[4096];
  reg [7:0] basic_rom[2048];

  integer i;
  initial begin
    for (i = 0; i < 4096; i = i+1) ram[i] = 0;
    for (i = 0; i < 2048; i = i+1) basic_rom[i] = 0;
    $readmemh("ram.hex", ram);
    $readmemh("ubasic6502.hex", basic_rom);
  end

  // ---------------------------------------------------------------------------
  // Video
  // ---------------------------------------------------------------------------
  hvsync_generator hvsync_gen(
    .clk(clk), .reset(reset),
    .hsync(hsync), .vsync(vsync),
    .display_on(display_on),
    .hpos(hpos), .vpos(vpos)
  );

  wire tready;
  wire dot;

  // te fires when CPU writes to $E001 (IO_OUT / Kowalski TERMINAL_OUT)
  wire te = WE && (AB == 16'hE001);

  signetics_term terminal(
    .clk(clk), .reset(reset),
    .hpos(hpos), .vpos(vpos),
    .tready(tready), .dot(dot),
    .te(te),
    .ti(DO)  // plain ASCII from CPU STA $E001 — no bit-stripping needed
  );

  wire g = display_on && dot;
  assign rgb = {1'b0, g, 1'b0}; // green-on-black

endmodule
