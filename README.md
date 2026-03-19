
# Changes Made

This is a fork of [sehugg/mango_one](https://github.com/sehugg/mango_one), which provided the 8bitworkshop 6502 Apple 1 emulator.

Modifications:

- Replaced 256-byte ROM Monitor  with 2 kB uBASIC6502 at $F800
- Modified GETCHAR / PUTCHAR routines to map BASIC I/O to the emulated Hardware
- Modified keyboard handler for key BASIC syntax "*/-=+*%

All other code remains unchanged. Original project copyright (sehugg) retained.

For details on uBASIC Tiny BASIC see

https://github.com/VinCBR900/65c02-Tiny-BASIC 

Mango One
=====

A simple 6502-based computer inspired by the Apple I, implemented in Verilog.

For the 6502 CPU, we use an [open-source model](https://github.com/Arlet/verilog-6502)
created by Arlet Ottens.

The Mango One's memory map is very similar to the Apple I:

Start | End      | Description
------|----------|----------
$0000 | $0FFF    | RAM
$D010 | $D013    | 6821 PIA (keyboard, terminal)
$F800 | $FFFF    | Tiny BASIC, CPU vectors

You can open this project in [8 Bit Workshop](https://8bitworkshop.com/v3.12.1/?repo=VinCBR900%2Fmango_one&platform=verilog&file=mango1.v) and try it Out!

