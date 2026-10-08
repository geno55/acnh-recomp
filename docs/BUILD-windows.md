# Building LARecomp on Windows (x86-64)

Status: work in progress on the `windows-port` branch. The platform layer (runtime/platform/windows.c) builds;
the Vulkan renderer (runtime/nvn/vulkan/) and the portable FP/SIMD lowering in the lifter are in progress.

## One-time setup
Run in PowerShell from the repo root:

    powershell -ExecutionPolicy Bypass -File tools\setup_windows.ps1

This installs MSYS2 (UCRT64: clang, lld, make, SDL3, FFmpeg, Vulkan loader + headers, shaderc), Python 3.12
for the tools (`tools\venv`: unicorn, capstone, lz4), and switches the clone to LF line endings.

## Build
From an MSYS2 UCRT64 shell, or Git Bash with MSYS2 first on PATH:

    export PATH="/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
    make gen        # once: recompile the game from extracted/exefs (your own dump; see the start screen)
    make -j         # -> build/larecomp.exe

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
- Restart (seed switch, "Title screen") starts a new process and exits instead of exec().
