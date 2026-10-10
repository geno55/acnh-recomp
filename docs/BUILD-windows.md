# Building LARecomp on Windows (x86-64)

Status: work in progress on the `windows-port` branch. Builds and runs the start screen on Vulkan; booting the game
needs the portable FP/SIMD lowering in the lifter (in progress) and your own game files.

## One-time setup
Run in PowerShell from the repo root:

    powershell -ExecutionPolicy Bypass -File tools\setup_windows.ps1

This installs MSYS2 (UCRT64: clang, lld, make, SDL3, FFmpeg, Vulkan loader + headers, shaderc, Vulkan Memory
Allocator, validation layers), Python 3.12 for the tools (`tools\venv`: unicorn, capstone, lz4) and the randomizer
(`third_party\LAS-Randomizer\venv`), builds hactool (`tools\hactool`), and switches the clone to LF line endings.

## Build
From an MSYS2 UCRT64 shell, or Git Bash with MSYS2 first on PATH:

    export PATH="/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
    make gen        # once: recompile the game from extracted/exefs (your own dump; see the start screen)
    make -j         # -> build/lasrecomp.exe

Without `generated/` the build links a stub (tools/nogen_stub.c): the start screen works, the game doesn't boot.
`make runtime-objs` compiles the runtime only (quick check).

Run from a shell that has `C:\msys64\ucrt64\bin` on PATH (SDL3, FFmpeg, Vulkan, shaderc DLLs).

## Differences from macOS
- Guest window 0x70_0000_0000..0x73_2000_0000 is reserved with VirtualAlloc and committed per region
  (kernel regions, modules, HLE heap); stray first touches are committed by a vectored exception handler.
- AArch64 FP/SIMD instructions are lowered to C (`gen.py --simd=c`, the default on non-arm64 hosts) instead of
  inline-asm passthrough.
- Renderer: Vulkan (runtime/nvn/vulkan) instead of Metal; shaders are translated to GLSL and compiled with
  shaderc. macOS keeps Metal.
- Seed switches and "Title screen" reboot the game in place on both (runtime/main.c); the only re-exec left is
  the startup retry when the guest window is taken, which on Windows starts a new process and exits.

## Tests
- `tools/test_translate.sh`: shader translator fuzz (MSL output unchanged, GLSL compiles and validates).
- `tools/test_vk_pipelines.sh`: fuzzed shaders through the backend's compile/reflection into real pipelines.
- `LARECOMP_VK_VALIDATION=1` with `VK_ADD_LAYER_PATH` pointing at `C:\msys64\ucrt64\bin`: Khronos validation layer.
- Run test windows directly, not under MSYS `timeout` (it stalls the window).
