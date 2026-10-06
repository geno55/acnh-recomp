# LARecomp build
CC       := clang
SDL      := /opt/homebrew/opt/sdl3
GENFLAGS := -O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -Iruntime
FFMPEG   := /opt/homebrew/opt/ffmpeg
RTFLAGS  := -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Iruntime -Iruntime/nvn -I$(SDL)/include -I$(FFMPEG)/include
LDFLAGS  := -L$(SDL)/lib -lSDL3 -Wl,-rpath,$(SDL)/lib -L$(FFMPEG)/lib -lavformat -lavcodec -lavutil -lswscale -Wl,-rpath,$(FFMPEG)/lib \
            -framework CoreFoundation -framework Foundation -framework Metal -framework QuartzCore -framework AppKit -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers

GEN_SRC  := $(wildcard generated/main/*.c) $(wildcard generated/sdk/*.c)
GEN_OBJ  := $(patsubst generated/%.c,build/obj/%.o,$(GEN_SRC))
RT_SRC   := $(wildcard runtime/*.c) $(wildcard runtime/hle/*.c) $(wildcard runtime/services/*.c) \
            $(wildcard runtime/nvn/*.c) $(wildcard runtime/nvn/maxwell/*.c)
RT_OBJ   := $(patsubst runtime/%.c,build/rt/%.o,$(RT_SRC))
OBJC_SRC := $(wildcard runtime/nvn/*.m)
OBJC_OBJ := $(patsubst runtime/%.m,build/rt/%.o,$(OBJC_SRC))
RT_HDRS  := $(wildcard runtime/*.h) $(wildcard runtime/nvn/*.h) $(wildcard runtime/nvn/maxwell/*.h)

all: build/larecomp

build/obj/%.o: generated/%.c runtime/cpu.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@

build/rt/%.o: runtime/%.c $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

build/rt/%.o: runtime/%.m $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@

build/larecomp: $(GEN_OBJ) $(RT_OBJ) $(OBJC_OBJ)
	$(CC) -o $@ $^ $(LDFLAGS)

gen:
	cd tools && ./venv/bin/python gen.py sdk ../extracted/exefs/sdk 0x7004000000 ../generated/sdk --hle ../runtime/hle/hle_symbols.txt
	cd tools && ./venv/bin/python gen.py main ../extracted/exefs/main 0x7000000000 ../generated/main

gen-objs: $(GEN_OBJ)

.PHONY: all gen gen-objs
