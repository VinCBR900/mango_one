/*
 * sim65c02.c  v5  --  Cycle-stepping NMOS 6502 simulator for uBASIC6502
 *
 * Copyright (c) 2026 Vincent Crabtree, MIT License
 *
 * Embeds asm65c02.c (included directly, not compiled separately).
 * I/O model: Apple 1 PIA  (matches mango1.v Verilog implementation)
 *
 *   $D010  r  keyboard data  : bit7=key-present, bits6:0=ASCII char
 *   $D011  r  keyboard status: bit7=key-present (same flag, different reg)
 *   $D011  w  (ignored — keystrobe handled by read side)
 *   $D012  r  display status : bit7=0 always (simulator never busy)
 *   $D012  w  display output : write char to stdout
 *   $E007  w  IRQ trigger    : ignored in simulator
 *
 * Build:
 *   gcc -O2 -o sim65c02 sim65c02.c
 *
 * Usage:
 *   sim65c02 <rom.hex> [input_string]
 *
 *   rom.hex   : Intel-style one-byte-per-line hex file (ubasic6502.hex format)
 *   input     : optional string fed to keyboard; simulator exits when exhausted
 *               and program returns to "> " prompt.
 *               Newlines in the string act as CR keypresses.
 *               If omitted, reads from stdin interactively.
 *
 * Simulation limits:
 *   MAX_CYCLES : 50,000,000 instructions before timeout (catches infinite loops)
 *   MAX_OUTPUT : 64KB of output before abort
 *
 * v5  (Mar 2026)  Apple 1 PIA I/O model; input string injection; cycle limit.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <ctype.h>

/* ── embed the assembler (for mem[] array) ─────────────────────────────── */
/* Define mem[] here so asm65c02.c's extern declaration resolves to it.    */
uint8_t mem[65536];
#include "asm65c02.c"   /* provides assemble() — mem[] already defined above */

/* ── simulator limits ──────────────────────────────────────────────────── */
#define MAX_CYCLES  50000000L
#define MAX_OUTPUT  (64*1024)

/* ── Apple 1 PIA addresses ─────────────────────────────────────────────── */
#define PIA_KBD_DATA   0xD010   /* r: key data */
#define PIA_KBD_STAT   0xD011   /* r: key status */
#define PIA_DISP_DATA  0xD012   /* r/w: display */

/* ── I/O state ─────────────────────────────────────────────────────────── */
static const char *kbd_input   = NULL;  /* null-terminated input string     */
static int         kbd_pos     = 0;     /* current position in input        */
static int         kbd_ready   = 0;     /* 1 = a char is waiting            */
static uint8_t     kbd_char    = 0;     /* the waiting char (ASCII, no bit7)*/
static int         interactive = 0;     /* reading from stdin               */

static char   out_buf[MAX_OUTPUT + 1];
static int    out_pos = 0;
static int    output_overflow = 0;

/* feed next character from input into keyboard buffer */
static void kbd_advance(void) {
    kbd_ready = 0;
    if (kbd_input) {
        if (kbd_input[kbd_pos] == '\0') return;
        char c = kbd_input[kbd_pos++];
        if (c == '\n') c = '\r';        /* newline -> CR for BASIC */
        kbd_char  = (uint8_t)(c & 0x7F);
        kbd_ready = 1;
    }
}

static void kbd_init(void) {
    kbd_pos   = 0;
    kbd_ready = 0;
    kbd_advance();
}

/* ── 6502 CPU state ────────────────────────────────────────────────────── */
typedef struct {
    uint16_t PC;
    uint8_t  A, X, Y, S, P;
} CPU;

#define FL_N 0x80
#define FL_V 0x40
#define FL_B 0x10
#define FL_D 0x08
#define FL_I 0x04
#define FL_Z 0x02
#define FL_C 0x01

#define SET_NZ(v)  do { cpu.P = (cpu.P & ~(FL_N|FL_Z)) \
                        | ((v)&0xFF ? 0 : FL_Z)         \
                        | ((v)&0x80 ? FL_N : 0); } while(0)

/* ── memory access ─────────────────────────────────────────────────────── */
static uint8_t cpu_read(uint16_t addr) {
    if (addr == PIA_KBD_DATA) {
        /* return char with bit7 set if key ready, 0 otherwise */
        uint8_t v = kbd_ready ? (kbd_char | 0x80) : 0x00;
        /* reading $D010 consumes the key (advance to next) */
        if (kbd_ready) kbd_advance();
        return v;
    }
    if (addr == PIA_KBD_STAT) {
        /* bit7 = key ready */
        return kbd_ready ? 0x80 : 0x00;
    }
    if (addr == PIA_DISP_DATA) {
        /* display always ready (bit7=0) */
        return 0x00;
    }
    return mem[addr];
}

static void cpu_write(uint16_t addr, uint8_t val) {
    if (addr == PIA_DISP_DATA) {
        uint8_t c = val & 0x7F;
        if (c == '\r') c = '\n';   /* CR -> newline for terminal output */
        if (c >= 0x20 || c == '\n' || c == '\t') {
            if (out_pos < MAX_OUTPUT) {
                out_buf[out_pos++] = (char)c;
                out_buf[out_pos]   = '\0';
            } else {
                output_overflow = 1;
            }
            if (interactive) {
                putchar(c);
                fflush(stdout);
            }
        }
        return;
    }
    if (addr == PIA_KBD_STAT) return;  /* acknowledge write — ignored */
    if (addr == 0xE007)        return;  /* IRQ trigger — ignored */
    mem[addr] = val;
}

/* ── stack helpers ─────────────────────────────────────────────────────── */
static CPU cpu;

static void push(uint8_t v) {
    mem[0x0100 | cpu.S] = v;
    cpu.S--;
}
static uint8_t pull(void) {
    cpu.S++;
    return mem[0x0100 | cpu.S];
}

/* ── ADC / SBC helpers ─────────────────────────────────────────────────── */
static void do_adc(uint8_t m) {
    uint16_t r = (uint16_t)cpu.A + m + (cpu.P & FL_C ? 1 : 0);
    uint8_t  v = (uint8_t)r;
    /* overflow: both operands same sign, result different sign */
    if (!((cpu.A ^ m) & 0x80) && ((cpu.A ^ v) & 0x80))
        cpu.P |= FL_V; else cpu.P &= ~FL_V;
    cpu.P = (cpu.P & ~FL_C) | (r > 0xFF ? FL_C : 0);
    cpu.A = v;
    SET_NZ(cpu.A);
}
static void do_sbc(uint8_t m) { do_adc(~m); }

/* ── comparison ────────────────────────────────────────────────────────── */
static void do_cmp(uint8_t reg, uint8_t m) {
    uint16_t r = (uint16_t)reg - m;
    cpu.P = (cpu.P & ~(FL_N|FL_Z|FL_C))
          | (reg >= m ? FL_C : 0)
          | ((r & 0xFF) == 0 ? FL_Z : 0)
          | (r & 0x80 ? FL_N : 0);
}

/* ── branch helper ─────────────────────────────────────────────────────── */
static void branch(int taken, int8_t off) {
    if (taken) cpu.PC = (uint16_t)(cpu.PC + off);
}

/* ── BIT instruction ───────────────────────────────────────────────────── */
static void do_bit(uint8_t m) {
    cpu.P = (cpu.P & ~(FL_N|FL_V|FL_Z))
          | (m & 0x80 ? FL_N : 0)
          | (m & 0x40 ? FL_V : 0)
          | ((cpu.A & m) == 0 ? FL_Z : 0);
}

/* ── address mode decoders ─────────────────────────────────────────────── */
static uint16_t addr_zp  (void) { return cpu_read(cpu.PC++); }
static uint16_t addr_zpx (void) { return (uint8_t)(cpu_read(cpu.PC++) + cpu.X); }
static uint16_t addr_zpy (void) { return (uint8_t)(cpu_read(cpu.PC++) + cpu.Y); }
static uint16_t addr_abs (void) {
    uint16_t lo = cpu_read(cpu.PC++);
    uint16_t hi = cpu_read(cpu.PC++);
    return lo | (hi << 8);
}
static uint16_t addr_absx(void) { return (uint16_t)(addr_abs() + cpu.X); }
static uint16_t addr_absy(void) { return (uint16_t)(addr_abs() + cpu.Y); }
static uint16_t addr_indx(void) {
    uint8_t  zp = (uint8_t)(cpu_read(cpu.PC++) + cpu.X);
    uint16_t lo = mem[zp]; uint16_t hi = mem[(uint8_t)(zp+1)];
    return lo | (hi<<8);
}
static uint16_t addr_indy(void) {
    uint8_t  zp = cpu_read(cpu.PC++);
    uint16_t lo = mem[zp]; uint16_t hi = mem[(uint8_t)(zp+1)];
    return (uint16_t)((lo|(hi<<8)) + cpu.Y);
}

/* ── shift/rotate helpers ──────────────────────────────────────────────── */
static uint8_t do_asl(uint8_t v) {
    cpu.P = (cpu.P&~FL_C)|(v&0x80?FL_C:0);
    v <<= 1; SET_NZ(v); return v;
}
static uint8_t do_lsr(uint8_t v) {
    cpu.P = (cpu.P&~FL_C)|(v&0x01?FL_C:0);
    v >>= 1; SET_NZ(v); return v;
}
static uint8_t do_rol(uint8_t v) {
    uint8_t c = cpu.P&FL_C ? 1 : 0;
    cpu.P = (cpu.P&~FL_C)|(v&0x80?FL_C:0);
    v = (v<<1)|c; SET_NZ(v); return v;
}
static uint8_t do_ror(uint8_t v) {
    uint8_t c = cpu.P&FL_C ? 0x80 : 0;
    cpu.P = (cpu.P&~FL_C)|(v&0x01?FL_C:0);
    v = (v>>1)|c; SET_NZ(v); return v;
}

/* ── single-step the CPU ───────────────────────────────────────────────── */
/* Returns 0 on normal execution, 1 on BRK/halt */
static int cpu_step(void) {
    uint8_t  op = cpu_read(cpu.PC++);
    uint16_t ea;
    uint8_t  m, v;
    int8_t   rel;

    switch (op) {

    /* ── LDA ── */
    case 0xA9: cpu.A=cpu_read(cpu.PC++);        SET_NZ(cpu.A); break;
    case 0xA5: cpu.A=cpu_read(addr_zp());       SET_NZ(cpu.A); break;
    case 0xB5: cpu.A=cpu_read(addr_zpx());      SET_NZ(cpu.A); break;
    case 0xAD: cpu.A=cpu_read(addr_abs());      SET_NZ(cpu.A); break;
    case 0xBD: cpu.A=cpu_read(addr_absx());     SET_NZ(cpu.A); break;
    case 0xB9: cpu.A=cpu_read(addr_absy());     SET_NZ(cpu.A); break;
    case 0xA1: cpu.A=cpu_read(addr_indx());     SET_NZ(cpu.A); break;
    case 0xB1: cpu.A=cpu_read(addr_indy());     SET_NZ(cpu.A); break;
    /* CMOS (zp) mode — used by PEEK */
    case 0xB2: ea=cpu_read(cpu.PC++);
               cpu.A=cpu_read(mem[ea]|(mem[(uint8_t)(ea+1)]<<8)); SET_NZ(cpu.A); break;

    /* ── LDX ── */
    case 0xA2: cpu.X=cpu_read(cpu.PC++);        SET_NZ(cpu.X); break;
    case 0xA6: cpu.X=cpu_read(addr_zp());       SET_NZ(cpu.X); break;
    case 0xB6: cpu.X=cpu_read(addr_zpy());      SET_NZ(cpu.X); break;
    case 0xAE: cpu.X=cpu_read(addr_abs());      SET_NZ(cpu.X); break;
    case 0xBE: cpu.X=cpu_read(addr_absy());     SET_NZ(cpu.X); break;

    /* ── LDY ── */
    case 0xA0: cpu.Y=cpu_read(cpu.PC++);        SET_NZ(cpu.Y); break;
    case 0xA4: cpu.Y=cpu_read(addr_zp());       SET_NZ(cpu.Y); break;
    case 0xB4: cpu.Y=cpu_read(addr_zpx());      SET_NZ(cpu.Y); break;
    case 0xAC: cpu.Y=cpu_read(addr_abs());      SET_NZ(cpu.Y); break;
    case 0xBC: cpu.Y=cpu_read(addr_absx());     SET_NZ(cpu.Y); break;

    /* ── STA ── */
    case 0x85: cpu_write(addr_zp(),  cpu.A); break;
    case 0x95: cpu_write(addr_zpx(), cpu.A); break;
    case 0x8D: cpu_write(addr_abs(), cpu.A); break;
    case 0x9D: cpu_write(addr_absx(),cpu.A); break;
    case 0x99: cpu_write(addr_absy(),cpu.A); break;
    case 0x81: cpu_write(addr_indx(),cpu.A); break;
    case 0x91: cpu_write(addr_indy(),cpu.A); break;
    case 0x92: ea=cpu_read(cpu.PC++);
               cpu_write(mem[ea]|(mem[(uint8_t)(ea+1)]<<8), cpu.A); break;

    /* ── STX ── */
    case 0x86: cpu_write(addr_zp(),  cpu.X); break;
    case 0x96: cpu_write(addr_zpy(), cpu.X); break;
    case 0x8E: cpu_write(addr_abs(), cpu.X); break;

    /* ── STY ── */
    case 0x84: cpu_write(addr_zp(),  cpu.Y); break;
    case 0x94: cpu_write(addr_zpx(), cpu.Y); break;
    case 0x8C: cpu_write(addr_abs(), cpu.Y); break;

    /* ── STZ (CMOS) ── */
    case 0x64: cpu_write(addr_zp(),  0); break;
    case 0x74: cpu_write(addr_zpx(), 0); break;
    case 0x9C: cpu_write(addr_abs(), 0); break;

    /* ── transfers ── */
    case 0xAA: cpu.X=cpu.A; SET_NZ(cpu.X); break;
    case 0xA8: cpu.Y=cpu.A; SET_NZ(cpu.Y); break;
    case 0x8A: cpu.A=cpu.X; SET_NZ(cpu.A); break;
    case 0x98: cpu.A=cpu.Y; SET_NZ(cpu.A); break;
    case 0xBA: cpu.X=cpu.S; SET_NZ(cpu.X); break;
    case 0x9A: cpu.S=cpu.X;                break;

    /* ── stack ── */
    case 0x48: push(cpu.A); break;
    case 0x68: cpu.A=pull(); SET_NZ(cpu.A); break;
    case 0x08: push(cpu.P|0x30); break;
    case 0x28: cpu.P=pull();     break;
    case 0xDA: push(cpu.X); break;  /* PHX CMOS */
    case 0xFA: cpu.X=pull(); SET_NZ(cpu.X); break;  /* PLX CMOS */
    case 0x5A: push(cpu.Y); break;  /* PHY CMOS */
    case 0x7A: cpu.Y=pull(); SET_NZ(cpu.Y); break;  /* PLY CMOS */

    /* ── ADC ── */
    case 0x69: do_adc(cpu_read(cpu.PC++)); break;
    case 0x65: do_adc(cpu_read(addr_zp())); break;
    case 0x75: do_adc(cpu_read(addr_zpx())); break;
    case 0x6D: do_adc(cpu_read(addr_abs())); break;
    case 0x7D: do_adc(cpu_read(addr_absx())); break;
    case 0x79: do_adc(cpu_read(addr_absy())); break;
    case 0x61: do_adc(cpu_read(addr_indx())); break;
    case 0x71: do_adc(cpu_read(addr_indy())); break;

    /* ── SBC ── */
    case 0xE9: do_sbc(cpu_read(cpu.PC++)); break;
    case 0xE5: do_sbc(cpu_read(addr_zp())); break;
    case 0xF5: do_sbc(cpu_read(addr_zpx())); break;
    case 0xED: do_sbc(cpu_read(addr_abs())); break;
    case 0xFD: do_sbc(cpu_read(addr_absx())); break;
    case 0xF9: do_sbc(cpu_read(addr_absy())); break;
    case 0xE1: do_sbc(cpu_read(addr_indx())); break;
    case 0xF1: do_sbc(cpu_read(addr_indy())); break;

    /* ── AND ── */
    case 0x29: cpu.A&=cpu_read(cpu.PC++);   SET_NZ(cpu.A); break;
    case 0x25: cpu.A&=cpu_read(addr_zp());  SET_NZ(cpu.A); break;
    case 0x35: cpu.A&=cpu_read(addr_zpx()); SET_NZ(cpu.A); break;
    case 0x2D: cpu.A&=cpu_read(addr_abs()); SET_NZ(cpu.A); break;
    case 0x32: m=cpu_read(cpu.PC++); cpu.A&=cpu_read(mem[m]|(mem[(uint8_t)(m+1)]<<8)); SET_NZ(cpu.A); break;

    /* ── ORA ── */
    case 0x09: cpu.A|=cpu_read(cpu.PC++);   SET_NZ(cpu.A); break;
    case 0x05: cpu.A|=cpu_read(addr_zp());  SET_NZ(cpu.A); break;
    case 0x15: cpu.A|=cpu_read(addr_zpx()); SET_NZ(cpu.A); break;
    case 0x0D: cpu.A|=cpu_read(addr_abs()); SET_NZ(cpu.A); break;
    case 0x11: cpu.A|=cpu_read(addr_indy()); SET_NZ(cpu.A); break;
    case 0x12: m=cpu_read(cpu.PC++); cpu.A|=cpu_read(mem[m]|(mem[(uint8_t)(m+1)]<<8)); SET_NZ(cpu.A); break;

    /* ── EOR ── */
    case 0x49: cpu.A^=cpu_read(cpu.PC++);   SET_NZ(cpu.A); break;
    case 0x45: cpu.A^=cpu_read(addr_zp());  SET_NZ(cpu.A); break;
    case 0x55: cpu.A^=cpu_read(addr_zpx()); SET_NZ(cpu.A); break;
    case 0x4D: cpu.A^=cpu_read(addr_abs()); SET_NZ(cpu.A); break;
    case 0x51: cpu.A^=cpu_read(addr_indy()); SET_NZ(cpu.A); break;
    case 0x52: m=cpu_read(cpu.PC++); cpu.A^=cpu_read(mem[m]|(mem[(uint8_t)(m+1)]<<8)); SET_NZ(cpu.A); break;

    /* ── CMP ── */
    case 0xC9: do_cmp(cpu.A,cpu_read(cpu.PC++)); break;
    case 0xC5: do_cmp(cpu.A,cpu_read(addr_zp())); break;
    case 0xD5: do_cmp(cpu.A,cpu_read(addr_zpx())); break;
    case 0xCD: do_cmp(cpu.A,cpu_read(addr_abs())); break;
    case 0xDD: do_cmp(cpu.A,cpu_read(addr_absx())); break;
    case 0xD9: do_cmp(cpu.A,cpu_read(addr_absy())); break;
    case 0xC1: do_cmp(cpu.A,cpu_read(addr_indx())); break;
    case 0xD1: do_cmp(cpu.A,cpu_read(addr_indy())); break;
    case 0xD2: m=cpu_read(cpu.PC++); do_cmp(cpu.A,cpu_read(mem[m]|(mem[(uint8_t)(m+1)]<<8))); break;

    /* ── CPX / CPY ── */
    case 0xE0: do_cmp(cpu.X,cpu_read(cpu.PC++)); break;
    case 0xE4: do_cmp(cpu.X,cpu_read(addr_zp())); break;
    case 0xEC: do_cmp(cpu.X,cpu_read(addr_abs())); break;
    case 0xC0: do_cmp(cpu.Y,cpu_read(cpu.PC++)); break;
    case 0xC4: do_cmp(cpu.Y,cpu_read(addr_zp())); break;
    case 0xCC: do_cmp(cpu.Y,cpu_read(addr_abs())); break;

    /* ── INC / DEC ── */
    case 0xE6: ea=addr_zp(); v=cpu_read(ea)+1; cpu_write(ea,v); SET_NZ(v); break;
    case 0xF6: ea=addr_zpx();v=cpu_read(ea)+1; cpu_write(ea,v); SET_NZ(v); break;
    case 0xEE: ea=addr_abs();v=cpu_read(ea)+1; cpu_write(ea,v); SET_NZ(v); break;
    case 0xFE: ea=addr_absx();v=cpu_read(ea)+1;cpu_write(ea,v); SET_NZ(v); break;
    case 0x1A: cpu.A++; SET_NZ(cpu.A); break;  /* INC A CMOS */
    case 0xC6: ea=addr_zp(); v=cpu_read(ea)-1; cpu_write(ea,v); SET_NZ(v); break;
    case 0xD6: ea=addr_zpx();v=cpu_read(ea)-1; cpu_write(ea,v); SET_NZ(v); break;
    case 0xCE: ea=addr_abs();v=cpu_read(ea)-1; cpu_write(ea,v); SET_NZ(v); break;
    case 0x3A: cpu.A--; SET_NZ(cpu.A); break;  /* DEC A CMOS */

    /* ── INX/INY/DEX/DEY ── */
    case 0xE8: cpu.X++; SET_NZ(cpu.X); break;
    case 0xC8: cpu.Y++; SET_NZ(cpu.Y); break;
    case 0xCA: cpu.X--; SET_NZ(cpu.X); break;
    case 0x88: cpu.Y--; SET_NZ(cpu.Y); break;

    /* ── ASL ── */
    case 0x0A: cpu.A=do_asl(cpu.A); break;
    case 0x06: ea=addr_zp(); cpu_write(ea,do_asl(cpu_read(ea))); break;
    case 0x16: ea=addr_zpx();cpu_write(ea,do_asl(cpu_read(ea))); break;
    case 0x0E: ea=addr_abs();cpu_write(ea,do_asl(cpu_read(ea))); break;

    /* ── LSR ── */
    case 0x4A: cpu.A=do_lsr(cpu.A); break;
    case 0x46: ea=addr_zp(); cpu_write(ea,do_lsr(cpu_read(ea))); break;
    case 0x56: ea=addr_zpx();cpu_write(ea,do_lsr(cpu_read(ea))); break;
    case 0x4E: ea=addr_abs();cpu_write(ea,do_lsr(cpu_read(ea))); break;

    /* ── ROL ── */
    case 0x2A: cpu.A=do_rol(cpu.A); break;
    case 0x26: ea=addr_zp(); cpu_write(ea,do_rol(cpu_read(ea))); break;
    case 0x36: ea=addr_zpx();cpu_write(ea,do_rol(cpu_read(ea))); break;
    case 0x2E: ea=addr_abs();cpu_write(ea,do_rol(cpu_read(ea))); break;

    /* ── ROR ── */
    case 0x6A: cpu.A=do_ror(cpu.A); break;
    case 0x66: ea=addr_zp(); cpu_write(ea,do_ror(cpu_read(ea))); break;
    case 0x76: ea=addr_zpx();cpu_write(ea,do_ror(cpu_read(ea))); break;
    case 0x6E: ea=addr_abs();cpu_write(ea,do_ror(cpu_read(ea))); break;

    /* ── BIT ── */
    case 0x24: do_bit(cpu_read(addr_zp())); break;
    case 0x2C: do_bit(cpu_read(addr_abs())); break;
    case 0x89: /* BIT imm CMOS — only sets Z */
        m = cpu_read(cpu.PC++);
        cpu.P = (cpu.P & ~FL_Z) | ((cpu.A & m) ? 0 : FL_Z); break;
    case 0x34: do_bit(cpu_read(addr_zpx())); break;
    case 0x3C: do_bit(cpu_read(addr_absx())); break;

    /* ── flag ops ── */
    case 0x18: cpu.P &= ~FL_C; break;
    case 0x38: cpu.P |=  FL_C; break;
    case 0x58: cpu.P &= ~FL_I; break;
    case 0x78: cpu.P |=  FL_I; break;
    case 0xD8: cpu.P &= ~FL_D; break;
    case 0xF8: cpu.P |=  FL_D; break;
    case 0xB8: cpu.P &= ~FL_V; break;

    /* ── branches ── */
    case 0x90: rel=(int8_t)cpu_read(cpu.PC++); branch(!(cpu.P&FL_C),rel); break;
    case 0xB0: rel=(int8_t)cpu_read(cpu.PC++); branch( (cpu.P&FL_C),rel); break;
    case 0xF0: rel=(int8_t)cpu_read(cpu.PC++); branch( (cpu.P&FL_Z),rel); break;
    case 0xD0: rel=(int8_t)cpu_read(cpu.PC++); branch(!(cpu.P&FL_Z),rel); break;
    case 0x30: rel=(int8_t)cpu_read(cpu.PC++); branch( (cpu.P&FL_N),rel); break;
    case 0x10: rel=(int8_t)cpu_read(cpu.PC++); branch(!(cpu.P&FL_N),rel); break;
    case 0x70: rel=(int8_t)cpu_read(cpu.PC++); branch( (cpu.P&FL_V),rel); break;
    case 0x50: rel=(int8_t)cpu_read(cpu.PC++); branch(!(cpu.P&FL_V),rel); break;
    case 0x80: rel=(int8_t)cpu_read(cpu.PC++); cpu.PC=(uint16_t)(cpu.PC+rel); break; /* BRA CMOS */

    /* ── JMP ── */
    case 0x4C: cpu.PC=addr_abs(); break;
    case 0x6C: {   /* JMP indirect — NMOS page-wrap bug preserved */
        uint16_t ptr = addr_abs();
        uint16_t lo  = mem[ptr];
        uint16_t hi  = mem[(ptr & 0xFF00) | ((ptr+1) & 0xFF)]; /* NMOS wrap */
        cpu.PC = lo | (hi<<8);
    } break;
    case 0x7C: { /* JMP (abs,X) CMOS */
        uint16_t ptr = (uint16_t)(addr_abs() + cpu.X);
        cpu.PC = mem[ptr] | (mem[(uint16_t)(ptr+1)] << 8);
    } break;

    /* ── JSR / RTS ── */
    case 0x20: {
        uint16_t target = addr_abs();
        uint16_t ret    = cpu.PC - 1;
        push((ret >> 8) & 0xFF);
        push(ret & 0xFF);
        cpu.PC = target;
    } break;
    case 0x60: {
        uint16_t lo = pull();
        uint16_t hi = pull();
        cpu.PC = (lo | (hi<<8)) + 1;
    } break;

    /* ── RTI ── */
    case 0x40:
        cpu.P  = pull();
        cpu.PC = pull();
        cpu.PC |= (uint16_t)(pull() << 8);
        break;

    /* ── NOP ── */
    case 0xEA: break;

    /* ── BRK ── */
    case 0x00:
        return 1;

    default:
        /* Treat unknown opcodes as NOP (some NMOS "illegal" ops land here) */
        fprintf(stderr, "  [sim] unknown opcode $%02X at $%04X\n", op, cpu.PC-1);
        break;
    }
    return 0;
}

/* ── load hex file into mem[] ───────────────────────────────────────────── */
static int load_hex(const char *filename) {
    FILE *f = fopen(filename, "r");
    if (!f) { perror(filename); return 0; }
    int addr = 0;
    char line[16];
    while (fgets(line, sizeof(line), f)) {
        char *p = line;
        while (*p == ' ' || *p == '\t') p++;
        if (*p == '\n' || *p == '\r' || *p == '\0') continue;
        mem[0xF800 + (addr++)] = (uint8_t)strtol(p, NULL, 16);
        if (addr >= 2048) break;
    }
    fclose(f);
    return addr;
}

/* ── reset CPU ──────────────────────────────────────────────────────────── */
static void cpu_reset(void) {
    memset(mem, 0, 0x1000);   /* clear 4KB RAM */
    cpu.S  = 0xFF;
    cpu.P  = FL_I | 0x20;
    cpu.A  = cpu.X = cpu.Y = 0;
    cpu.PC = mem[0xFFFC] | (mem[0xFFFD] << 8);
}

/* ── run until prompt appears and input exhausted ───────────────────────── */
/*
 * We detect "done" when:
 *   - All input has been consumed (kbd_pos >= strlen(kbd_input))
 *   - The BASIC interpreter is back at the "> " prompt
 *     (last two output chars are "> ")
 * OR a BRK is hit, OR cycle limit exceeded.
 */
static int run_until_done(long max_cycles) {
    long cycles = 0;
    int  brk    = 0;

    while (cycles < max_cycles && !output_overflow) {
        brk = cpu_step();
        cycles++;
        if (brk) break;

        /* Check: input exhausted AND we're at the "> " prompt */
        if (!kbd_ready && kbd_input && kbd_input[kbd_pos] == '\0') {
            /* Wait for the prompt to appear */
            if (out_pos >= 2 &&
                out_buf[out_pos-2] == '>' &&
                out_buf[out_pos-1] == ' ')
                break;
        }
    }

    if (cycles >= max_cycles) {
        fprintf(stderr, "  [sim] TIMEOUT after %ld cycles\n", cycles);
        return -1;
    }
    if (output_overflow) {
        fprintf(stderr, "  [sim] OUTPUT OVERFLOW\n");
        return -2;
    }
    return brk ? 1 : 0;
}

/* ── test harness ───────────────────────────────────────────────────────── */
typedef struct {
    const char *name;
    const char *input;       /* lines to feed, \n = CR */
    const char *expect;      /* substring that must appear in output */
    const char *no_expect;   /* substring that must NOT appear (or NULL) */
} Test;

static const Test tests[] = {

    /* --- arithmetic: the EA_DO subtraction fix --- */
    { "subtraction 10-3=7",
      "PRINT 10-3\n",
      "7",  "13" },

    { "addition 3+4=7",
      "PRINT 3+4\n",
      "7",  NULL },

    { "multiplication 6*7=42",
      "PRINT 6*7\n",
      "42", NULL },

    { "division 20/4=5",
      "PRINT 20/4\n",
      "5",  NULL },

    { "modulo 17%5=2",
      "PRINT 17%5\n",
      "2",  NULL },

    { "chained arithmetic (3+4)*2=14",
      "PRINT (3+4)*2\n",
      "14", NULL },

    { "negative number -5",
      "PRINT -5\n",
      "-5", NULL },

    { "negative subtraction -3-2=-5",
      "PRINT -3-2\n",
      "-5", NULL },

    { "subtraction to zero 5-5=0",
      "PRINT 5-5\n",
      "0",  NULL },

    { "large subtraction 1000-999=1",
      "PRINT 1000-999\n",
      "1",  NULL },

    /* --- comparisons --- */
    { "compare 5>3 true",
      "IF 5>3 THEN PRINT 42\n",
      "42", NULL },

    { "compare 3<5 true",
      "IF 3<5 THEN PRINT 99\n",
      "99", NULL },

    { "compare 3=3 true",
      "IF 3=3 THEN PRINT 77\n",
      "77", NULL },

    { "compare 3>=3 true",
      "IF 3>=3 THEN PRINT 55\n",
      "55", NULL },

    { "compare 4<>3 true",
      "IF 4<>3 THEN PRINT 11\n",
      "11", NULL },

    /* --- variables and LET --- */
    { "LET and PRINT variable",
      "A=42\nPRINT A\n",
      "42", NULL },

    { "variable arithmetic",
      "A=10\nB=3\nPRINT A-B\n",
      "7",  "13" },

    { "multiple variables",
      "X=6\nY=7\nPRINT X*Y\n",
      "42", NULL },

    /* --- string print --- */
    { "PRINT string literal",
      "PRINT \"HELLO\"\n",
      "HELLO", NULL },

    { "PRINT CHR$(65)",
      "PRINT CHR$(65)\n",
      "A", NULL },

    /* --- GOTO loop --- */
    { "GOTO loop prints 1 to 3",
      "10 I=1\n20 IF I>3 THEN GOTO 50\n30 PRINT I\n40 I=I+1:GOTO 20\n50 END\nRUN\n",
      "1",  NULL },

    { "GOTO loop result includes 3",
      "10 I=1\n20 IF I>3 THEN GOTO 50\n30 PRINT I\n40 I=I+1:GOTO 20\n50 END\nRUN\n",
      "3",  NULL },

    /* --- NEW and program store --- */
    { "NEW clears program",
      "10 PRINT 99\nNEW\nRUN\n",
      ">", "99" },   /* after NEW+RUN we just get another prompt, not 99 */

    /* --- LIST regression: LP guard --- */
    { "LIST empty program after NEW",
      "NEW\nLIST\n",
      ">", NULL },    /* should complete and return to prompt */

    { "LIST short program",
      "10 PRINT 42\n20 END\nLIST\n",
      "10", NULL },

    { "LIST shows line content",
      "10 PRINT 42\n20 END\nLIST\n",
      "PRINT 42", NULL },

    /* --- multi-statement with colon --- */
    { "colon separator",
      "A=3:B=4:PRINT A+B\n",
      "7", NULL },

    /* --- INPUT (skip: requires interactive, hard to test) --- */

    /* --- PEEK/POKE --- */
    { "POKE and PEEK",
      "POKE 512,123\nPRINT PEEK(512)\n",
      "123", NULL },

    /* --- division by zero error --- */
    { "division by zero gives error",
      "PRINT 1/0\n",
      "?", NULL },

    /* sentinel */
    { NULL, NULL, NULL, NULL }
};

/* ── run one test ───────────────────────────────────────────────────────── */
static int run_test(const char *hex_file, const Test *t) {
    /* reload ROM for each test */
    int n = load_hex(hex_file);
    if (n <= 0) { fprintf(stderr, "  failed to load %s\n", hex_file); return 0; }

    /* clear RAM, reset CPU */
    cpu_reset();

    /* set up I/O */
    kbd_input = t->input;
    kbd_pos   = 0;
    kbd_ready = 0;
    out_pos   = 0;
    out_buf[0]= '\0';
    output_overflow = 0;
    kbd_advance();

    int rc = run_until_done(MAX_CYCLES);

    /* check expectations */
    int pass = 1;
    if (t->expect && !strstr(out_buf, t->expect)) {
        pass = 0;
        fprintf(stderr, "  FAIL [%s]: expected '%s' in output\n", t->name, t->expect);
        fprintf(stderr, "  Output: [%s]\n", out_buf);
    }
    if (pass && t->no_expect && strstr(out_buf, t->no_expect)) {
        pass = 0;
        fprintf(stderr, "  FAIL [%s]: unexpected '%s' in output\n", t->name, t->no_expect);
        fprintf(stderr, "  Output: [%s]\n", out_buf);
    }
    if (rc < 0 && pass) {
        pass = 0;
        fprintf(stderr, "  FAIL [%s]: simulation error (rc=%d)\n", t->name, rc);
    }

    return pass;
}

/* ── main ───────────────────────────────────────────────────────────────── */
int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "Usage: sim65c02 <ubasic6502.hex> [--interactive | test_input]\n");
        return 1;
    }

    const char *hex_file = argv[1];

    /* Interactive mode */
    if (argc == 2 || (argc == 3 && strcmp(argv[2],"--interactive")==0)) {
        interactive = 1;
        int n = load_hex(hex_file);
        if (n <= 0) return 1;
        cpu_reset();
        kbd_input = NULL;
        kbd_ready = 0;
        out_pos   = 0;
        out_buf[0]= '\0';
        fprintf(stderr, "[sim65c02 v5] loaded %d ROM bytes, reset PC=$%04X\n",
                n, cpu.PC);
        /* simple interactive: read stdin char by char */
        while (1) {
            int c = getchar();
            if (c == EOF) break;
            kbd_char  = (uint8_t)(c == '\n' ? '\r' : c & 0x7F);
            kbd_ready = 1;
            /* run until prompt */
            run_until_done(MAX_CYCLES);
        }
        return 0;
    }

    /* Regression test mode */
    if (argc == 3 && strcmp(argv[2], "--test") == 0) {
        int passed = 0, failed = 0, total = 0;
        for (const Test *t = tests; t->name; t++) {
            total++;
            if (run_test(hex_file, t)) {
                printf("  PASS  %s\n", t->name);
                passed++;
            } else {
                failed++;
            }
        }
        printf("\n%d/%d tests passed", passed, total);
        if (failed) printf(", %d FAILED", failed);
        printf("\n");
        return failed ? 1 : 0;
    }

    /* Single input string mode */
    int n = load_hex(hex_file);
    if (n <= 0) return 1;
    cpu_reset();
    kbd_input = argv[2];
    kbd_pos   = 0;
    kbd_ready = 0;
    out_pos   = 0;
    out_buf[0]= '\0';
    output_overflow = 0;
    kbd_advance();
    run_until_done(MAX_CYCLES);
    printf("%s", out_buf);
    return 0;
}
