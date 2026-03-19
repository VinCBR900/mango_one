CC := gcc
CFLAGS := -O2 -DASM65C02_MAIN

ASM := asm65c02
ASM_SRC := asm65c02.c
BASIC_SRC := uBASIC6502.asm

ROM_BIN := ubasic6502.bin
ROM_HEX := ubasic6502.hex
FULL_BIN := ubasic_full.bin
SHOWCASE_HEX := showcase.hex

SHOWCASE_START := 0x0200
SHOWCASE_END_EXCL := 0x0623

.PHONY: all tools rom showcase clean

all: $(ROM_HEX) $(SHOWCASE_HEX)

tools: $(ASM)

rom: $(ROM_HEX)

showcase: $(SHOWCASE_HEX)

$(ASM): $(ASM_SRC)
	$(CC) $(CFLAGS) -o $@ $<

$(ROM_BIN): $(ASM) $(BASIC_SRC)
	./$(ASM) $(BASIC_SRC) -o $@ -r '$$F800-$$FFFF'

$(ROM_HEX): $(ROM_BIN)
	python3 -c 'from pathlib import Path; b=Path("ubasic6502.bin").read_bytes(); Path("ubasic6502.hex").write_text("".join(f"{x:02x}\n" for x in b))'

$(FULL_BIN): $(ASM) $(BASIC_SRC)
	./$(ASM) $(BASIC_SRC) -o $@

$(SHOWCASE_HEX): $(FULL_BIN)
	python3 -c 'from pathlib import Path; full=Path("ubasic_full.bin").read_bytes(); start=$(SHOWCASE_START); end_excl=$(SHOWCASE_END_EXCL); chunk=full[start:end_excl]; Path("showcase.hex").write_text("".join(f"{x:02x}\n" for x in chunk))'

clean:
	rm -f $(ASM) $(ROM_BIN) $(ROM_HEX) $(FULL_BIN) $(SHOWCASE_HEX)
