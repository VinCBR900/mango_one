# =============================================================================
# Makefile  --  mango_one / uBASIC6502  build system
#
# Both source files are fetched from the upstream 65c02-Tiny-BASIC repo so
# the mango_one repo contains no assembler or BASIC source — always builds
# from the upstream tip.
#
# Targets:
#   all    - build ubasic6502.hex and ram.hex  (default)
#   tools  - build asm65c02 assembler only
#   fetch  - force re-download of upstream sources
#   clean  - remove all generated files including fetched sources
#
# Generated files (not committed):
#   asm65c02.c       fetched from upstream
#   uBASIC6502.asm   fetched from upstream
#   asm65c02         assembled assembler binary
#   ubasic_full.bin  full 64KB assembled image
#   ubasic6502.hex   ROM hex  ($F800-$FFFF, one byte per line)
#   ram.hex          RAM hex  ($0000-$0FFF, one byte per line)
#                    Loaded directly into mango1.v ram[] — includes the
#                    pre-loaded BASIC showcase at $0200, zero-page, stack.
# =============================================================================

CC      := gcc
CFLAGS  := -O2 -DASM65C02_MAIN

UPSTREAM := https://raw.githubusercontent.com/VinCBR900/65c02-Tiny-BASIC/refs/heads/main

ASM_SRC   := asm65c02.c
BASIC_SRC := uBASIC6502.asm
ASM       := asm65c02

FULL_BIN    := ubasic_full.bin
ROM_HEX     := ubasic6502.hex
RAM_HEX     := ram.hex

RAM_START   := 0x0000
RAM_END     := 0x0FFF
ROM_START   := 0xF800
ROM_END     := 0xFFFF

.PHONY: all tools fetch clean

all: $(ROM_HEX) $(RAM_HEX)

tools: $(ASM)

# Fetch upstream sources (only if not already present)
$(ASM_SRC):
	curl -fsSL "$(UPSTREAM)/asm65c02.c" -o $@

$(BASIC_SRC):
	curl -fsSL "$(UPSTREAM)/uBASIC6502.asm" -o $@

# Force re-download of both upstream sources
fetch:
	rm -f $(ASM_SRC) $(BASIC_SRC)
	$(MAKE) $(ASM_SRC) $(BASIC_SRC)

# Build assembler from fetched source
$(ASM): $(ASM_SRC)
	$(CC) $(CFLAGS) -o $@ $<

# Assemble full 64KB image
$(FULL_BIN): $(ASM) $(BASIC_SRC)
	./$(ASM) $(BASIC_SRC) -o $@

# ROM hex: $F800-$FFFF (2048 bytes, one byte per line)
$(ROM_HEX): $(FULL_BIN)
	python3 -c "\
from pathlib import Path; \
full = Path('$(FULL_BIN)').read_bytes(); \
chunk = full[$(ROM_START):$(ROM_END)+1]; \
Path('$(ROM_HEX)').write_text(''.join(f'{x:02x}\n' for x in chunk)); \
print(f'$(ROM_HEX): \$$$(shell printf '%04X' $(ROM_START))-\$$$(shell printf '%04X' $(ROM_END)) = {len(chunk)} bytes') \
"

# RAM hex: $0000-$0FFF (4096 bytes, one byte per line)
# Includes showcase program at $0200 and zeroed zero-page/stack.
$(RAM_HEX): $(FULL_BIN)
	python3 -c "\
from pathlib import Path; \
full = Path('$(FULL_BIN)').read_bytes(); \
chunk = full[$(RAM_START):$(RAM_END)+1]; \
Path('$(RAM_HEX)').write_text(''.join(f'{x:02x}\n' for x in chunk)); \
print(f'$(RAM_HEX): \$$0000-\$$0FFF = {len(chunk)} bytes') \
"

clean:
	rm -f $(ASM) $(ASM_SRC) $(BASIC_SRC) $(FULL_BIN) $(ROM_HEX) $(RAM_HEX)
