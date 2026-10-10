# LAS Recomp build
# macOS: Homebrew clang/SDL3/FFmpeg, Metal renderer.
# Windows: MSYS2 UCRT64 shell (see docs/BUILD-windows.md), clang + Vulkan renderer.
UNAME := $(shell uname -s)
ifneq ($(filter MINGW% MSYS% CYGWIN% Windows_NT,$(UNAME) $(OS)),)
PLATFORM := windows
else
PLATFORM := macos
endif

# B: build dir. MACOS_MIN: oldest macOS to run on (default: this one). DEPS: prefix with SDL3 / FFmpeg instead of
# Homebrew's (make deps). `make app` sets all three (build/mac15, 15.0, build/deps); plain `make` uses none.
B         ?= build
MACOS_MIN ?=
DEPS      ?=
MINFLAG  := $(if $(MACOS_MIN),-mmacosx-version-min=$(MACOS_MIN))
CC       := clang $(MINFLAG)
CXX      := clang++ $(MINFLAG)
IMGUI    := third_party/imgui
GENFLAGS := -O1 -fno-strict-aliasing -Wno-return-type -Wno-unused-label -Iruntime

GEN_SRC  := $(wildcard generated/main/*.c) $(wildcard generated/sdk/*.c)
# no generated code yet (make gen): link a stub, the start screen works
ifeq ($(strip $(GEN_SRC)),)
GEN_SRC  := tools/nogen_stub.c
endif
GEN_OBJ  := $(patsubst %.c,$(B)/obj/%.o,$(patsubst generated/%,%,$(GEN_SRC)))
RT_SRC   := $(wildcard runtime/*.c) $(wildcard runtime/hle/*.c) $(wildcard runtime/services/*.c) \
            $(wildcard runtime/nvn/*.c) $(wildcard runtime/nvn/maxwell/*.c) runtime/platform/$(PLATFORM).c
RT_HDRS  := $(wildcard runtime/*.h) $(wildcard runtime/platform/*.h) $(wildcard runtime/nvn/*.h) \
            $(wildcard runtime/nvn/maxwell/*.h) $(wildcard runtime/nvn/vulkan/*.h) $(wildcard runtime/ui/*.h)
UI_SRC   := $(wildcard runtime/ui/*.mm)
UI_OBJ   := $(patsubst runtime/%.mm,$(B)/rt/%.o,$(UI_SRC))
IMGUI_OBJ := $(B)/imgui/imgui.o $(B)/imgui/imgui_draw.o $(B)/imgui/imgui_tables.o $(B)/imgui/imgui_widgets.o \
             $(B)/imgui/imgui_impl_sdl3.o

ifeq ($(PLATFORM),macos)
SDL      := $(or $(DEPS),/opt/homebrew/opt/sdl3)
FFMPEG   := $(or $(DEPS),/opt/homebrew/opt/ffmpeg)
EXE      := $(B)/lasrecomp
DEPINC   := -I$(SDL)/include -I$(FFMPEG)/include
LDFLAGS  := -L$(SDL)/lib -lSDL3 -Wl,-rpath,$(SDL)/lib -L$(FFMPEG)/lib -lavformat -lavcodec -lavutil -lswscale -Wl,-rpath,$(FFMPEG)/lib \
            -framework CoreFoundation -framework Foundation -framework Metal -framework MetalFX -framework QuartzCore -framework AppKit -framework ImageIO -framework CoreGraphics -framework UniformTypeIdentifiers
BACKEND_SRC := $(wildcard runtime/nvn/*.m)
BACKEND_OBJ := $(patsubst runtime/%.m,$(B)/rt/%.o,$(BACKEND_SRC))
IMGUI_OBJ += $(B)/imgui/imgui_impl_metal.o
UIFLAGS  := -fobjc-arc
else
EXE      := $(B)/lasrecomp.exe
DEPINC   :=
OSFLAGS  := -D_FILE_OFFSET_BITS=64 -D_POSIX_THREAD_SAFE_FUNCTIONS -D_CRT_RAND_S -DWIN32_LEAN_AND_MEAN -DNOMINMAX
GENARCH  ?= -march=x86-64-v3  # AVX2 + FMA for the lifted FP/SIMD code (simd.h); override for older CPUs
GENFLAGS += -D_FILE_OFFSET_BITS=64 $(GENARCH)
LDFLAGS  := -fuse-ld=lld -Wl,--stack,16777216 -lSDL3 -lavformat -lavcodec -lavutil -lswscale -lvulkan-1 \
            -lwinmm -lole32 -lshell32 -lcomdlg32 -luuid -lshaderc_shared
BACKEND_SRC := $(wildcard runtime/nvn/vulkan/*.c) $(wildcard runtime/nvn/vulkan/*.cpp)
BACKEND_OBJ := $(patsubst runtime/%.cpp,$(B)/rt/%.o,$(patsubst runtime/%.c,$(B)/rt/%.o,$(BACKEND_SRC)))
BACKEND_OBJ += $(B)/rt/platform/windows_rc.o  # the .exe's icon (Explorer, taskbar)
WINDRES  ?= windres
IMGUI_OBJ += $(B)/imgui/imgui_impl_vulkan.o
UIFLAGS  := -x c++ $(OSFLAGS)  # the .mm UI sources are plain C++ apart from __APPLE__ blocks
endif

RT_OBJ   := $(patsubst runtime/%.c,$(B)/rt/%.o,$(RT_SRC))
RTFLAGS  := -O2 -g -fno-strict-aliasing -Wall -Wno-unused-function -Iruntime -Iruntime/nvn $(DEPINC) $(OSFLAGS)
CXXFLAGS := -O2 -g -std=c++17 -I$(IMGUI) -I$(IMGUI)/backends -Iruntime -Iruntime/nvn $(DEPINC)

all: $(EXE)

$(B)/obj/%.o: generated/%.c runtime/cpu.h
	@mkdir -p $(dir $@)
	@$(CC) $(GENFLAGS) -c $< -o $@

$(B)/obj/tools/%.o: tools/%.c
	@mkdir -p $(dir $@)
	$(CC) $(GENFLAGS) -c $< -o $@

$(B)/rt/%.o: runtime/%.c $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -c $< -o $@

$(B)/rt/%.o: runtime/%.cpp $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(OSFLAGS) -c $< -o $@

$(B)/rt/%.o: runtime/%.m $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CC) $(RTFLAGS) -fobjc-arc -c $< -o $@

# linked to a temp file, then renamed over: a copy of the game still running keeps its (old) file - relinking in
# place gets running copies killed by macOS (code signature of the changed pages)
$(EXE): $(GEN_OBJ) $(RT_OBJ) $(BACKEND_OBJ) $(UI_OBJ) $(IMGUI_OBJ)
	$(CXX) -o $@.tmp $^ $(LDFLAGS)
	mv -f $@.tmp $@

$(B)/rt/ui/%.o: runtime/ui/%.mm $(RT_HDRS)
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) $(UIFLAGS) -c $< -o $@

$(B)/imgui/%.o: $(IMGUI)/%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(B)/imgui/imgui_impl_%.o: $(IMGUI)/backends/imgui_impl_%.cpp
	@mkdir -p $(dir $@)
	$(CXX) $(CXXFLAGS) -c $< -o $@

$(B)/imgui/imgui_impl_metal.o: $(IMGUI)/backends/imgui_impl_metal.mm
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

$(B)/rt/platform/windows_rc.o: runtime/platform/windows.rc docs/icon/icon.ico
	@mkdir -p $(dir $@)
	$(WINDRES) -I docs/icon -O coff $< -o $@

# hactool (ISC): the start screen extracts the user's dump with it; shipped next to the executable
HACTOOL  := tools/hactool/hactool$(if $(filter windows,$(PLATFORM)),.exe)
$(HACTOOL):
	[ -d tools/hactool ] || git clone -q https://github.com/SciresM/hactool tools/hactool
	cd tools/hactool && cp -n config.mk.template config.mk; $(MAKE) CC=clang
hactool: $(HACTOOL)

VERSION  := $(shell sed -n 's/^\#define LARECOMP_VERSION "\(.*\)"/\1/p' runtime/ui/launcher.mm)

# macOS: build/LAS Recomp.app, runs on macOS $(APP_MIN)+: the game rebuilt for that in build/mac15 against build/deps
# (`make deps`: SDL3, LGPL FFmpeg, hactool, keystone, Python, from pinned sources), the generator helper when built
# (`make rando-helper` after `make deps`), packaged by tools/bundle_macos.sh. No game files, keys or fonts.
APP_MIN  := 15.0
APP_B    := build/mac15
deps:
	MACOS_MIN=$(APP_MIN) tools/build_deps_macos.sh
app:
	@[ -f build/deps/lib/libSDL3.0.dylib ] || { echo "make deps first"; exit 1; }
	$(MAKE) B=$(APP_B) MACOS_MIN=$(APP_MIN) DEPS=$(CURDIR)/build/deps $(APP_B)/lasrecomp
	MACOS_MIN=$(APP_MIN) tools/bundle_macos.sh $(APP_B)/lasrecomp

# Windows (UNTESTED): build/dist/LAS Recomp-<version>-windows.zip, top folder "LAS Recomp/": the exe, hactool, the
# seed generator helper when built, and the MSYS2 DLLs they load (runs without MSYS2). vulkan-1.dll is left out:
# every Vulkan driver installs the loader in System32. Saves, seeds and game files go next to the exe at run time.
DIST     := build/dist/LAS Recomp
dist: $(EXE) $(HACTOOL)
	rm -rf build/dist && mkdir -p "$(DIST)"
	cp $(EXE) $(HACTOOL) "$(DIST)/"
	cp docs/icon/icon_1024.png "$(DIST)/icon.png"
	[ ! -d build/helper/rando-gen ] || cp -R build/helper/rando-gen "$(DIST)/"  # (make rando-helper)
	ldd $(EXE) $(HACTOOL) | awk '/ucrt64/ && !/vulkan-1/ {print $$3}' | sort -u | xargs -I{} cp -u {} "$(DIST)/"
	cd build/dist && if command -v zip >/dev/null; then zip -qr "LAS Recomp-$(VERSION)-windows.zip" "LAS Recomp"; \
	    else /c/Windows/System32/tar.exe -a -cf "LAS Recomp-$(VERSION)-windows.zip" "LAS Recomp"; fi
	@echo "build/dist/LAS Recomp-$(VERSION)-windows.zip"

# Seed generator as a standalone helper, so players need no Python: build/helper/rando-gen/ (rando-gen[.exe] +
# _internal/), frozen by PyInstaller from tools/rando/rando_gen.spec in its own venv (build/rando-venv). Ship the
# rando-gen folder next to the exe (Windows) or as "LAS Recomp.app"/Contents/Resources/rando-gen (runtime/ui/rando_tab.mm
# generator_cmd). PyInstaller only builds for the OS it runs on.
# macOS arm64: the relocatable Python 3.12 and keystone from `make deps` (macOS 11+ / 15+: the helper runs where the
#   app does); without them Homebrew's python@3.12 and keystone (then only on the macOS they were built for). The
#   keystone wheel has no dylib: KEYSTONE_LIB tells rando_gen.spec which one to take.
# Windows x86-64 (untested): from the MSYS2 shell with a python.org CPython 3.12 (MSYS2's Python has no oead wheel),
#   e.g. make rando-helper RANDO_PY="/c/Users/<you>/AppData/Local/Programs/Python/Python312/python.exe"
ifeq ($(PLATFORM),macos)
RANDO_PY  ?= $(firstword $(wildcard build/deps/python/bin/python3.12) python3.12)
export KEYSTONE_LIB ?= $(wildcard $(CURDIR)/build/deps/lib/libkeystone.dylib)
RANDO_VPY := build/rando-venv/bin/python
else
RANDO_PY  ?= py -3.12
RANDO_VPY := build/rando-venv/Scripts/python.exe
endif

rando-helper: build/rando-venv/.ok
	$(RANDO_VPY) -m PyInstaller --noconfirm --clean --log-level WARN --distpath build/helper --workpath build/pyinstaller \
	    tools/rando/rando_gen.spec
	@du -sh build/helper/rando-gen

build/rando-venv/.ok: third_party/LAS-Randomizer/requirements.txt
	$(RANDO_PY) -m venv build/rando-venv
	$(RANDO_VPY) -m pip install -q -r third_party/LAS-Randomizer/requirements.txt pyinstaller==6.22.3
	touch $@

.PHONY: all gen gen-objs runtime-objs hactool deps app dist rando-helper

build/test_shaders: tools/test_shaders.m runtime/nvn/maxwell/translate.c runtime/nvn/maxwell/shader.h
	clang -O1 -fobjc-arc -framework Metal -framework Foundation -o $@ tools/test_shaders.m runtime/nvn/maxwell/translate.c
