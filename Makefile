# LAS Recomp build
# macOS: Homebrew clang/SDL3/FFmpeg, Metal renderer.
# Windows: MSYS2 UCRT64 shell (see docs/BUILD-windows.md), clang + Vulkan renderer.
UNAME := $(shell uname -s)
ifneq ($(filter MINGW% MSYS% CYGWIN% Windows_NT,$(UNAME) $(OS)),)
PLATFORM := windows
else
PLATFORM := macos
endif

CC       := clang
CXX      := clang++
IMGUI    := third_party/imgui
GENFLAGS := -O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -Iruntime

GEN_SRC  := $(wildcard generated/main/*.c) $(wildcard generated/sdk/*.c)
# no generated code yet (make gen): link a stub, the start screen works
ifeq ($(strip $(GEN_SRC)),)
GEN_SRC  := tools/nogen_stub.c
endif
GEN_OBJ  := $(patsubst %.c,build/obj/%.o,$(patsubst generated/%,%,$(GEN_SRC)))
RT_SRC   := $(wildcard runtime/*.c) $(wildcard runtime/hle/*.c) $(wildcard runtime/services/*.c) \
            $(wildcard runtime/nvn/*.c) $(wildcard runtime/nvn/maxwell/*.c) runtime/platform/$(PLATFORM).c
RT_HDRS  := $(wildcard runtime/*.h) $(wildcard runtime/platform/*.h) $(wildcard runtime/nvn/*.h) \
            $(wildcard runtime/nvn/maxwell/*.h) $(wildcard runtime/nvn/vulkan/*.h) $(wildcard runtime/ui/*.h)
UI_SRC   := $(wildcard runtime/ui/*.mm)
UI_OBJ   := $(patsubst runtime/%.mm,build/rt/%.o,$(UI_SRC))
IMGUI_OBJ := build/imgui/imgui.o build/imgui/imgui_draw.o build/imgui/imgui_tables.o build/imgui/imgui_widgets.o \
             build/imgui/imgui_impl_sdl3.o

ifeq ($(PLATFORM),macos)
SDL      := /opt/homebrew/opt/sdl3
FFMPEG   := /opt/homebrew/opt/ffmpeg
EXE      := build/lasrecomp
DEPINC   := -I$(SDL)/include -I$(FFMPEG)/include
LDFLAGS  := -L$(SDL)/lib -lSDL3 -Wl,-rpath,$(SDL)/lib -L$(FFMPEG)/lib -lavformat -lavcodec -lavutil -lswscale -Wl,-rpath,$(FFMPEG)/lib \
            -framework CoreFoundation -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers
BACKEND_SRC := $(wildcard runtime/nvn/*.m)
BACKEND_OBJ := $(patsubst runtime/%.m,build/rt/%.o,$(BACKEND_SRC))
IMGUI_OBJ += build/imgui/imgui_impl_metal.o
UIFLAGS  := -fobjc-arc
else
EXE      := build/lasrecomp.exe
DEPINC   :=
OSFLAGS  := -D_FILE_OFFSET_BITS=64 -D_POSIX_THREAD_SAFE_FUNCTIONS -D_CRT_RAND_S -DWIN32_LEAN_AND_MEAN -DNOMINMAX
GENARCH  ?= -march=x86-64-v3  # AVX2 + FMA for the lifted FP/SIMD code (simd.h); override for older CPUs
GENFLAGS += -D_FILE_OFFSET_BITS=64 $(GENARCH)
LDFLAGS  := -fuse-ld=lld -Wl,--stack,16777216 -lSDL3 -lavformat -lavcodec -lavutil -lswscale -lvulkan-1 \
            -lwinmm -lole32 -lshell32 -lcomdlg32 -luuid -lshaderc_shared
BACKEND_SRC := $(wildcard runtime/nvn/vulkan/*.c) $(wildcard runtime/nvn/vulkan/*.cpp)
BACKEND_OBJ := $(patsubst runtime/%.cpp,build/rt/%.o,$(patsubst runtime/%.c,build/rt/%.o,$(BACKEND_SRC)))
BACKEND_OBJ += build/rt/platform/windows_rc.o  # the .exe's icon (Explorer, taskbar)
WINDRES  ?= windres
IMGUI_OBJ += build/imgui/imgui_impl_vulkan.o
UIFLAGS  := -x c++ $(OSFLAGS)  # the .mm UI sources are plain C++ apart from __APPLE__ blocks
endif

RT_OBJ   := $(patsubst runtime/%.c,build/rt/%.o,$(RT_SRC))
RTFLAGS  := -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Iruntime -Iruntime/nvn $(DEPINC) $(OSFLAGS)
CXXFLAGS := -O2 -g -std=c++17 -I$(IMGUI) -I$(IMGUI)/backends -Iruntime -Iruntime/nvn $(DEPINC)

all: $(EXE)

build/obj/%.o: generated/%.c runtime/cpu.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@

build/obj/tools/%.o: tools/%.c
	@mkdir -p $(dir $@)
	$(CC) $(GENFLAGS) -c $< -o $@

build/rt/%.o: runtime/%.c $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

build/rt/%.o: runtime/%.cpp $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(OSFLAGS) -c $< -o $@

build/rt/%.o: runtime/%.m $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@

# linked to a temp file, then renamed over: a copy of the game still running keeps its (old) file - relinking in
# place gets running copies killed by macOS (code signature of the changed pages)
$(EXE): $(GEN_OBJ) $(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ) $(IMGUI_OBJ)
	$(CXX) -o $@.tmp $^ $(LDFLAGS)
	mv -f $@.tmp $@

build/rt/ui/%.o: runtime/ui/%.mm $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(UIFLAGS) -c $< -o $@

build/imgui/%.o: $(IMGUI)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/imgui/imgui_impl_%.o: $(IMGUI)/backends/imgui_impl_%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/imgui/imgui_impl_metal.o: $(IMGUI)/backends/imgui_impl_metal.mm
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -fobjc-arc -c $< -o $@

# Python: tools/venv (macOS: bin/python, Windows: Scripts/python.exe)
PY := $(firstword $(wildcard tools/venv/bin/python) $(wildcard tools/venv/Scripts/python.exe))

gen:
	cd tools && ../$(PY) gen.py sdk ../extracted/exefs/sdk 0x7004000000 ../generated/sdk --hle ../runtime/hle/hle_symbols.txt
	cd tools && ../$(PY) gen.py main ../extracted/exefs/main 0x7000000000 ../generated/main

gen-objs: $(GEN_OBJ)

# Runtime objects only (no generated code, no link): quick compile check
runtime-objs: $(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ)

build/rt/platform/windows_rc.o: runtime/platform/windows.rc docs/icon/icon.ico
	@mkdir -p $(dir $@)
	$(WINDRES) -I docs/icon -O coff $< -o $@

# hactool (ISC): the start screen extracts the user's dump with it; shipped next to the executable
HACTOOL  := tools/hactool/hactool$(if $(filter windows,$(PLATFORM)),.exe)
$(HACTOOL):
	[ -d tools/hactool ] || git clone -q https://github.com/SciresM/hactool tools/hactool
	cd tools/hactool && cp -n config.mk.template config.mk; $(MAKE) CC=clang
hactool: $(HACTOOL)

VERSION  := $(shell sed -n 's/^\#define LARECOMP_VERSION "\(.*\)"/\1/p' runtime/ui/launcher.mm)

# macOS: build/LAS Recomp.app (tools/bundle_macos.sh). Game files, keys and fonts are never included.
app: $(EXE) $(HACTOOL)
	tools/bundle_macos.sh

# Windows (UNTESTED): build/dist/LAS Recomp-<version>-windows.zip, top folder "LAS Recomp/": the exe, hactool, the
# seed generator helper when built, and the MSYS2 DLLs they load (runs without MSYS2). vulkan-1.dll is left out:
# every Vulkan driver installs the loader in System32. Saves, seeds and game files go next to the exe at run time.
DIST     := build/dist/LAS Recomp
dist: $(EXE) $(HACTOOL)
	rm -rf build/dist && mkdir -p "$(DIST)"
	cp $(EXE) $(HACTOOL) "$(DIST)/"
	cp docs/icon/icon_1024.png "$(DIST)/icon.png"
	[ ! -e build/lasrecomp-seedgen.exe ] || cp -R build/lasrecomp-seedgen.exe "$(DIST)/"
	ldd $(EXE) $(HACTOOL) | awk '/ucrt64/ && !/vulkan-1/ {print $$3}' | sort -u | xargs -I{} cp -u {} "$(DIST)/"
	cd build/dist && if command -v zip >/dev/null; then zip -qr "LAS Recomp-$(VERSION)-windows.zip" "LAS Recomp"; \
	    else /c/Windows/System32/tar.exe -a -cf "LAS Recomp-$(VERSION)-windows.zip" "LAS Recomp"; fi
	@echo "build/dist/LAS Recomp-$(VERSION)-windows.zip"

.PHONY: all gen gen-objs runtime-objs hactool app dist

build/test_shaders: tools/test_shaders.m runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h
	clang -O1 -fobjc-arc -framework Metal -framework Foundation -o $@ tools/test_shaders.m runtime/nvn/maxwell/translate.c
