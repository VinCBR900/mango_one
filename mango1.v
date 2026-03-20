`include "hvsync_generator.v"
`include "cpu6502.v"
`include "font_cp437_8x8.v"

/**
; ==========================================
; uBASIC6502 fork of mango_one  v1.5
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
; See below about Keyboard remapping if you actually want to type BASIC
;
; v1.6 (Mar 2026) ESC key triggers BREAK via hardware IRQ.
;   Note: Spotty performance in EDGE, better in Chrome browser.
;   ESC keyCode=27=0x1B, arrives as keycode=0x9B (0x1B|0x80).
;   IRQ (active HIGH here) is asserted while keycode==0x9B; keystrobe
;   clears bit7 -> keycode drops below 0x80 -> IRQ deasserts cleanly.
;   ESC is masked from D010/D011 (returns 0x00) so it never lands in
;   IBUF as a character. BASIC IRQ_HANDLER checks RUN flag: if a program
;   is running it unwinds the stack, prints "BREAK IN <linenum>", and
;   returns to the MAIN prompt.
; v1.5 (Mar 2026) Rewrote remap_key() with accurate keyCode analysis.
;   8bitworkshop delivers keyCode|0x80, not ASCII. Shift state is lost for
;   digit-row keys. Surrogates assigned for (, ), *, + using unshifted keys
;   that are unused in BASIC ([ ] \ '). Removed dead a-z->A-Z conversion
;   (letter keyCodes 65-90 already equal uppercase ASCII). Works on both
;   US and UK keyboards. Irrecoverable: % (shift+5) and ; (conflicts with :).
;   See GitHub issue: https://github.com/sehugg/8bitworkshop/issues/241#issue-4107170707
; v1.4 (Mar 2026) BS ($08) handling in signetics_term: backspace-overwrite-
;   backspace in one clock. Writes SPACE at dofs-1, sets dofs=dofs-1.
;   Clamped at left edge of row (dofs & 31 == 0 -> no-op), matching the
;   Apple 1 Woz monitor behaviour. uBASIC GETLINE guards independently.
; v1.3 (Mar 2026) Map backtick ` key (0xC0, unshifted) to " (0xA2) so
;   PRINT "string" is typeable without shift. ` = keyCode 192 on US keyboard.
; v1.2 (Mar 2026) Keyboard remapping: browser keyCode -> correct ASCII.
;   Punctuation keys >= 0x80 (e.g. '-'=0xBD, '='=0xBB) were arriving as
;   browser keyCodes, not ASCII. Added remap_key() case table to fix
;   - = . , / ; and ' keys. Uppercase a-z range adjusted to 0xE1-0xFA.
; v1.1 (Mar 2026) Fix tready timing: hpos==256 -> hpos>=256
;   The original 1-clock tready pulse at hpos=256 was too narrow.
;   DI is registered (1-cycle latency), so the CPU only saw tready
;   for a single clock (hpos=257).  This made each PUTCH wait up to
;   ~20 horizontal lines on average before catching the ready window.
;   Widening to hpos>=256 holds tready high for the entire horizontal
;   blanking period (~52 clocks), giving the CPU a reliable window to
;   exit the PUTCH_W polling loop.  The te=1 signal (CPU writes $D012)
;   immediately clears tready, so no character is double-accepted.
; v1.0 (Mar 2026) Initial Port of uBASIC6502 to Mango1
;   Replaced ROM with uBASIC6502 binary and demo code
;   uBASIC ASM GETCHAR / PUTCHAR modified for Mango1 verilog address
; ==========================================
 
/**
Mango One
 
A 6502 computer inspired by Steve Wozniak's Apple I design
 
Memory map:
 
$0000	$0FFF	RAM
$A000	$CFFF	Expansion ROM
$D010	$D013	6821 PIA (keyboard, terminal)
$E000	$EFFF	Integer BASIC
$FF00	$FFFF	Woz Monitor, CPU vectors
 
$D010	Read ASCII character from keyboard.
        If high bit is set then a key has been pressed.
        
$D011	Writing to this address clears the high bit of $D010.
        The CPU usually does this after reading a key.
        
$D012	Writes a character to the terminal.
        On read, if high bit is set then the display
        is not ready to receive characters.
 
MangoMon commands:
 
R aaaa    - dump memory at $aaaa
Enter     - dump next 8 bytes
W aaaa bb - write memory $bb at $aaaa
G aaaa    - jump to address $aaaa
 
https://www.applefritter.com/replica/chapter7
https://github.com/mamedev/mame/blob/master/src/mame/drivers/apple1.cpp
https://github.com/jefftranter/6502/blob/master/asm/wozmon/wozmon.s
https://www.applefritter.com/files/signetics2513.pdf
http://retro.hansotten.nl/uploads/6502docs/signetics2504.pdf
http://retro.hansotten.nl/uploads/6502docs/signetics2519.pdf
*/
 
module signetics_term(clk, reset, hpos, vpos, tready, dot, te, ti);
 
  input clk,reset;
  input [8:0] hpos;
  input [8:0] vpos;
  input te;		// input enable
  input [7:0] ti;	// input data
  output tready;	// terminal ready
  output dot;		// terminal video output
  
  reg [7:0] dshift[1024]; // frame buffer offset
  reg [9:0] dofs;	// current offset to write
  reg [9:0] scroll;	// scroll offset
  reg [9:0] scnt;	// row clear counter when scrolling
 
  always @(posedge clk or posedge reset)
    if (reset) begin
      scnt <= 0;
      scroll <= 0;
      dofs <= 28*32;
      scroll <= 0;
    end else if (scnt > 0) begin
      dshift[scroll] <= 0; // clear row when scrolling
      scroll <= scroll + 1;
      scnt <= scnt - 1;
    end else if (te) begin
      if (ti == 13) begin // CR, next row
        scnt <= 32;
        dofs <= ((dofs + 32) & ~31);
      end else if (ti == 8) begin // BS: backspace-overwrite-backspace
        if ((dofs & 10'h01f) != 0) begin // clamp at left edge of row
          dshift[dofs-1] <= 8'd32;       // overwrite previous char with SPACE
          dofs <= dofs - 1;              // move cursor back to that position
        end
      end else if (ti >= 32) begin // display char
        dshift[dofs] <= ti;
        if ((dofs & 31) == 31) scnt <= 32; // wrap around
        dofs <= dofs + 1;
      end
    end
 
  // character generator from ROM
  font_cp437_8x8 tile_rom(
    .addr(char_addr),
    .data(char_data)
  );
  wire [9:0] nt_addr = {vpos[7:3], hpos[7:3]};
  wire [7:0] cur_char = dshift[nt_addr + scroll];
  wire [10:0] char_addr = {cur_char, vpos[2:0]};
  wire [7:0] char_data;
  wire dot = char_data[~hpos[2:0]]; // video output
  
  // terminal ready output
  // FIX v1.1: was (hpos == 256) — only 1 clock wide, too narrow for the
  // registered-DI pipeline (CPU saw ready for just 1 cycle at hpos=257).
  // Changed to (hpos >= 256) so tready holds high across the entire
  // horizontal blanking period (~52 clocks), giving the CPU a reliable
  // window to detect ready via PUTCH_W (BIT $D012 / BMI PUTCH_W).
  // te=1 (CPU writes $D012) immediately forces tready=0 via the !te term,
  // so the terminal will not accept a second character until the next
  // hblank with scnt==0.
  assign tready = !reset && !te && scnt == 0 && hpos >= 256;
  
  initial begin
    integer i;
    for (i=0; i<1024; i=i+1) dshift[i] = 0; // clear buffer
  end
  
endmodule
 
module apple1_top(clk, reset, hsync, vsync, rgb, keycode, keystrobe);
 
  input clk, reset;
  input [7:0] keycode;
  output reg keystrobe;
  output hsync, vsync;
  output [2:0] rgb;
  wire display_on;
  wire [8:0] hpos;
  wire [8:0] vpos;
 
  wire [15:0] AB;   	// address bus
  wire [7:0] DI;        // data in, read bus
  wire [7:0] DO;        // data out, write bus
  wire WE;              // write enable
  // IRQ: active HIGH here. Assert when ESC is pressed (keycode = ESC|0x80 = 0x9B).
  // Async  HIGH while keycode stays 0x9B; keystrobe clears bit7 -> deasserts.
  // BASIC IRQ_HANDLER ($FFFE) checks RUN flag: if running, unwinds stack
  // and prints "BREAK IN <linenum>", then returns to MAIN prompt.
 wire IRQ = (keycode == 8'h9B); //Async active High 
  wire NMI=0;           // non-maskable interrupt request
  wire RDY=1;           // Ready signal. Pauses CPU when RDY=0 
 
  cpu6502 cpu( clk, reset, AB, DI, DO, WE, IRQ, NMI, RDY );
 
  // ---------------------------------------------------------------------------
  // Keyboard remapping  (v1.5)
  //
  // 8bitworkshop delivers keycode = browser KeyboardEvent.keyCode | 0x80.
  // keyCode is the PHYSICAL KEY, not the character: shift state is lost for
  // digit-row keys, and punctuation keyCode values differ from ASCII.
  //
  // This function converts the raw keycode to ASCII|0x80 for the Apple 1 PIA.
  // After GETCH does AND #$7F the result is plain 7-bit ASCII.
  //
  // DIRECT MAPPINGS (keyCode & 0x7F already equals the correct ASCII):
  //   Letters A-Z  (keyCode 65-90  = ASCII, uppercase only — acceptable)
  //   Digits  0-9  (keyCode 48-57  = ASCII ✓)
  //   Space        (keyCode 32     = ASCII ✓)
  //   CR/Enter     (keyCode 13     = ASCII ✓)
  //   BS/Backspace (keyCode 8      = ASCII ✓)
  //   < > : ?      (keyCode 188,190,186,191 & 0x7F = 0x3C,0x3E,0x3A,0x3F ✓)
  //
  // REMAPPED PUNCTUATION (keyCode & 0x7F gives wrong ASCII without this):
  //   0xBB (187 = key) -> 0xBD ('=') // kC&7F=0x3B=';', need 0x3D='='
  //   0xBC (188 , key) -> 0xAC (',') // kC&7F=0x3C='<', need 0x2C=','
  //   0xBD (189 - key) -> 0xAD ('-') // kC&7F=0x3D='=', need 0x2D='-'
  //   0xBE (190 . key) -> 0xAE ('.') // kC&7F=0x3E='>', need 0x2E='.'
  //   0xBF (191 / key) -> 0xAF ('/') // kC&7F=0x3F='?', need 0x2F='/'
  //
  // SURROGATES (shift state lost for digit-row, so these keys are repurposed):
  //   0xC0 (192 ` key)  -> 0xA2 ('"') // ` unshifted; UK: ¬ key same kC
  //   0xDB (219 [ key)  -> 0xA8 ('(') // [ unshifted; both layouts
  //   0xDD (221 ] key)  -> 0xA9 (')') // ] unshifted; both layouts
  //   0xDC (220 \ key)  -> 0xAA ('*') // \ unshifted; UK: # key same kC
  //   0xDE (222 ' key)  -> 0xAB ('+') // ' unshifted; UK: # near Enter same kC
  //
  // IRRECOVERABLE (shift state lost, no usable surrogate):
  //   %  (shift+5)  — use MOD workaround in BASIC if needed
  //   ;  (shift+;)  — keyCode 186 used for ':', ';' unavailable
  // ---------------------------------------------------------------------------
  function [7:0] remap_key;
    input [7:0] kc;
    begin
      case (kc)
        // --- Punctuation: remap keyCode to correct ASCII|0x80 ---
        8'hBB: remap_key = 8'hBD; // = key  -> '=' (0x3D|0x80)
        8'hBC: remap_key = 8'hAC; // , key  -> ',' (0x2C|0x80)
        8'hBD: remap_key = 8'hAD; // - key  -> '-' (0x2D|0x80)
        8'hBE: remap_key = 8'hAE; // . key  -> '.' (0x2E|0x80)
        8'hBF: remap_key = 8'hAF; // / key  -> '/' (0x2F|0x80)
        // --- Surrogates: repurposed keys for chars lost to shift ---
        8'hC0: remap_key = 8'hA2; // ` key  -> '"' (US: backtick; UK: ¬)
        8'hDB: remap_key = 8'hA8; // [ key  -> '(' (both layouts)
        8'hDD: remap_key = 8'hA9; // ] key  -> ')' (both layouts)
        8'hDC: remap_key = 8'hAA; // \ key  -> '*' (US: backslash; UK: # near Enter)
        8'hDE: remap_key = 8'hAB; // ' key  -> '+' (US: apostrophe; UK: same)
        // --- Pass through: letters, digits, CR, BS, space, < > : ? ---
        default: remap_key = kc;
      endcase
    end
  endfunction
 
  always @(posedge clk)
    begin
      casez (AB)
        16'h0zzz: DI <= ram[AB[11:0]];
        16'hd010: begin
          begin : kbd_remap
            reg [7:0] mk;
            // ESC (keycode=0x9B) fires IRQ; do not deliver to IBUF.
            // Return 0x00 (no key) so GETCH sees nothing and doesn't store ESC.
            if (keycode == 8'h9B)
              DI <= 8'h00;
            else begin
              mk = remap_key(keycode);
              // Note: letter keyCodes 65-90 equal uppercase ASCII directly,
              // so no a-z -> A-Z conversion is needed here.
              DI <= mk;
            end
          end
          keystrobe <= (keycode & 8'h80) != 0; // ack ESC too, clears keycode[7]
        end
        16'hd011: begin
          // ESC: report no key (bit7=0) so GETCH doesn't loop back to read D010.
          DI <= (keycode == 8'h9B) ? 8'h00 : (keycode & 8'h80);
          keystrobe <= 0;
        end
        16'hd012: begin
          DI <= {!tready, 7'b0}; // display status
        end
        16'hf8zz, 16'hf9zz, 16'hfazz, 16'hfbzz,
        16'hfczz, 16'hfdzz, 16'hfezz, 16'hffzz:
          DI <= basic_rom[AB[10:0] - 11'h800];
      endcase
    end
 
  always @(posedge clk)
    if (WE) begin
      casez (AB)
        16'hd010: begin end // 
        16'hd011: begin end // 
        16'hd012: begin end // handled by terminal module
        16'hd013: begin end // 
        16'h0zzz: ram[AB[11:0]] <= DO; // write RAM
      endcase
    end
 
  reg [7:0] ram[4096];		// 1K of RAM
  reg [7:0] basic_rom[2048];	// uBASIC ROM ($F800-$FFFF)
  reg [7:0] showcase_rom[1058];	// showcase image for RAM $0200-$0621
 
  integer i;
  initial begin
    for (i=0; i<4096; i=i+1) ram[i] = 0;
    for (i=0; i<2048; i=i+1) basic_rom[i] = 0;
    for (i=0; i<1058; i=i+1) showcase_rom[i] = 0;
    $readmemh("showcase.hex", showcase_rom);
    for (i=0; i<1058; i=i+1) ram[32'h200 + i] = showcase_rom[i];
    $readmemh("ubasic6502.hex", basic_rom);
  end
  
  hvsync_generator hvsync_gen(
    .clk(clk),
    .reset(reset),
    .hsync(hsync),
    .vsync(vsync),
    .display_on(display_on),
    .hpos(hpos),
    .vpos(vpos)
  );
 
  wire tready; // terminal ready
  wire dot; // dot output
  wire te = WE && AB == 16'hd012; // terminal enable (write)
  signetics_term terminal(clk, reset, hpos, vpos,
                          tready, dot,
                          te, .ti(DO & 8'h7f));
  
  wire r = display_on && 0;
  wire g = display_on && dot;
  wire b = display_on && 0;
  assign rgb = {b,g,r};
 
endmodule
 
