# LARecomp build
CC      := clang
GENFLAGS := -O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -Iruntime
RTFLAGS  := -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Iruntime $(shell pkg-config --cflags sdl3 2>/dev/null)
LDFLAGS  := $(shell pkg-config --libs sdl3 2>/dev/null) -framework CoreFoundation

GEN_SRC := $(wildcard generated/main/*.c) $(wildcard generated/sdk/*.c)
GEN_OBJ := $(patsubst generated/%.c,build/obj/%.o,$(GEN_SRC))
RT_SRC  := $(wildcard runtime/*.c) $(wildcard runtime/hle/*.c)
RT_OBJ  := $(patsubst runtime/%.c,build/rt/%.o,$(RT_SRC))

all: build/larecomp

build/obj/%.o: generated/%.c runtime/cpu.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@

build/rt/%.o: runtime/%.c $(wildcard runtime/*.h)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

build/larecomp: $(GEN_OBJ) $(RT_OBJ)
	$(CC) -o $@ $^ $(LDFLAGS)

gen:
	cd tools && ./venv/bin/python gen.py sdk ../extracted/exefs/sdk 0x7004000000 ../generated/sdk --hle ../runtime/hle/hle_symbols.txt
	cd tools && ./venv/bin/python gen.py main ../extracted/exefs/main 0x7000000000 ../generated/main

gen-objs: $(GEN_OBJ)

.PHONY: all gen gen-objs
