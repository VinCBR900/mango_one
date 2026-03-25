
# Changes Made

This is a fork of [sehugg/mango_one](https://github.com/sehugg/mango_one), which provided the 8bitworkshop 6502 Apple 1 emulator.

Modifications:

- Replaced 256-byte ROM Monitor with 2 kB uBASIC6502 at $F800
- Modified Verilog to map [Kowalski 6502 Simulator](http://retro.hansotten.nl/6502-sbc/kowalski-assembler-simulator/) addresses for BASIC I/O in the emulated Hardware
- Modified keyboard handler to remap keys for BASIC syntax "*/-=+*%

All other code remains unchanged. Original project copyright (sehugg) retained.

**Note:** Github Actions runs `Makefile` daily, which pulls upstream uBASIC6502.asm and automatically rebuilds if changes.  For details and source for uBASIC Tiny BASIC see

https://github.com/VinCBR900/65c02-Tiny-BASIC 

Mango One
=====

A simple 6502-based computer inspired by the Apple I, implemented in Verilog.

For the 6502 CPU, we use an [open-source model](https://github.com/Arlet/verilog-6502)
created by Arlet Ottens.

The Mango One's memory map is very similar to the Apple I:

Start | End      | Description
------|----------|----------
$0000 | $0FFF    | 4kbyte RAM (512bytes for system)
$E00x | -    | Kowalski Memory Interface: Putchar @ $E001, terminal Getchar at $E004)
$F800 | $FFFF    | Tiny BASIC and CPU vectors

You can open this project in [8 Bit Workshop](http://8bitworkshop.com/v3.12.1/?redir.html?platform=verilog&githubURL=https%3A%2F%2Fgithub.com%2FVinCBR900%2Fmango_one&file=mango1.v) and try it Out!  Type `LIST` to view the embedded BASIC program and `RUN` to execute it - Pressing `ESC` aborts running program.

