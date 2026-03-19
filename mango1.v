`include "hvsync_generator.v"
`include "cpu6502.v"
`include "font_cp437_8x8.v"

/**
; ==========================================
; uBASIC6502 fork of mango_one  v1.1
; Original monitor and emulator by sehugg
; Modifications by Vincent Crabtree, Mar 2026
;
; v1.2 (Mar 2026) Fix Keyboard for correct BASIC syntax "=+;*
;   Finagle keyboard handler to convert to ASCII
; v1.1 (Mar 2026) Fix tready timing: hpos==256 -> hpos>=256
;   The original 1-clock tready pulse at hpos=256 was too narrow.
;   DI is registered (1-cycle latency), so the CPU only saw tready
;   for a single clock (hpos=257).  This made each PUTCH wait up to
;   ~20 horizontal lines on average before catching the ready window.
;   Widening to hpos>=256 holds tready high for the entire horizontal
;   blanking period (~52 clocks), giving the CPU a reliable window to
;   exit the PUTCH_W polling loop.  The te=1 signal (CPU writes $D012)
;   immediately clears tready, so no character is double-accepted.
; V1.0 (Mar 2026) Initial Modifications for Tiny BASIC
;   Replaced Monitor ROM with uBASIC6502
;   uBASIC GETCHAR / PUTCHAR modified for verilog interface
;
; For Original see
;  https://github.com/sehugg/mango_one
;
; For Tiny BASIC  see
;   https://github.com/VinCBR900/65c02-Tiny-BASIC
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
  wire IRQ=0;           // interrupt request
  wire NMI=0;           // non-maskable interrupt request
  wire RDY=1;           // Ready signal. Pauses CPU when RDY=0 

  cpu6502 cpu( clk, reset, AB, DI, DO, WE, IRQ, NMI, RDY );

  // FIX 1.2: Keyboard remapping - 8bitworkshop passes browser KeyboardEvent.keyCode
  // values for punctuation keys >= 0x80 (not ASCII). Remap to correct ASCII.
  // Letters/digits/CR/BS/Space have keyCode == ASCII, passed through as-is.
  // Result retains bit7 (= key-pressed signal for Apple 1 protocol).
  // For shifted punctuation, the browser fires a keypress with the shifted
  // charCode (e.g. shift+' sends 0xA2 for '"'), which falls through correctly.
  function [7:0] remap_key;
    input [7:0] kc;
    begin
      case (kc)
        8'hBA: remap_key = 8'hBB; // keyCode 186 ; -> ASCII ';'(0x3B)|0x80
        8'hBB: remap_key = 8'hBD; // keyCode 187 = -> ASCII '='(0x3D)|0x80
        8'hBC: remap_key = 8'hAC; // keyCode 188 , -> ASCII ','(0x2C)|0x80
        8'hBD: remap_key = 8'hAD; // keyCode 189 - -> ASCII '-'(0x2D)|0x80
        8'hBE: remap_key = 8'hAE; // keyCode 190 . -> ASCII '.'(0x2E)|0x80
        8'hBF: remap_key = 8'hAF; // keyCode 191 / -> ASCII '/'(0x2F)|0x80
        8'hC0: remap_key = 8'hE0; // keyCode 192 ` -> ASCII '`'(0x60)|0x80
        8'hDE: remap_key = 8'hA7; // keyCode 222 ' -> ASCII "'"(0x27)|0x80
        default: remap_key = kc;  // ASCII|0x80 correct: digits, letters,
      endcase                     //  CR(0x8D), BS(0x88), shift-chars(0xA2=")
    end
  endfunction

  always @(posedge clk)
    begin
      casez (AB)
        16'h0zzz: DI <= ram[AB[11:0]];
        16'hd010: begin
          begin : kbd_remap
            reg [7:0] mk;
            mk = remap_key(keycode);
            if (mk >= 8'hE1 && mk <= 8'hFA) // a-z with bit7 -> A-Z with bit7
              DI <= mk - 8'd32;
            else
              DI <= mk;
          end
          keystrobe <= (keycode & 8'h80) != 0;
        end
        16'hd011: begin
          DI <= keycode & 8'h80; // keyboard status
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
  reg [7:0] showcase_rom[1059];	// showcase image for RAM $0200-$0622

  integer i;
  initial begin
    for (i=0; i<4096; i=i+1) ram[i] = 0;
    for (i=0; i<2048; i=i+1) basic_rom[i] = 0;
    for (i=0; i<1059; i=i+1) showcase_rom[i] = 0;
    $readmemh("showcase.hex", showcase_rom);
    for (i=0; i<1059; i=i+1) ram[32'h200 + i] = showcase_rom[i];
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
