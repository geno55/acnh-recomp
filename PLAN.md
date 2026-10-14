# ACNH Recomp — Plan

Goal: a **native PC port of Animal Crossing: New Horizons with mod support**, built by extending
[LASRecomp](https://github.com/peiikai/LASRecomp) (a static recompilation of Link's Awakening for Switch)
and fed over time by the matching decomp at `E:\games\acnh`.

This repo is a fork of LASRecomp. `main` tracks upstream unchanged; ACNH work happens on `acnh`.

## Why this approach

| Path | Rough time to a native port with mods |
|---|---|
| Hooks + partial decomp (exlaunch on Switch/emulator) | Weeks–months, but not native |
| **Recomp to native, decomp swapped in over time** | **Depends on the spike below** |
| Full matching decomp to native | Many years |

LASRecomp already provides the generic pieces that would otherwise take years to build:

- `tools/gen.py` + `lifter.py` + `nso.py`: AArch64 NSO → C, one C function per guest function. Function
  discovery from `.eh_frame`, ELF symbols, `R_AARCH64_RELATIVE` relocs (vtables), `bl` and ADR/ADRP+ADD
  targets. Indirect calls go through `rt_dispatch`; jump tables are resolved with Unicorn; unsupported
  instructions become runtime traps instead of build failures.
- `runtime/kernel.c`, `loader.c`, `ipc.c`, `services/`: Horizon OS replacement.
- `runtime/nvn/`: NVN on Vulkan (Windows/Linux) and Metal (macOS), with a Maxwell shader translator.
- Mod hooks: `--hle` function replacement by symbol name (`runtime/hle/hle_symbols.txt`) and
  instruction patches in `tools/patches.py` that check the original instruction word at each site.

The decomp supplies names, types and, eventually, native replacements for generated functions, so the
port becomes more readable and moddable over time.

## Known gaps vs. ACNH

- **Scale:** ACNH's executable is far larger than Link's Awakening's, so expect more unlifted
  instructions, unresolved jump tables and longer builds.
- **Modules:** `make gen` only handles `main` and `sdk`. Check ACNH's ExeFS for extra `subsdk*`
  modules and add them.
- **Services:** only `acc`, `am`, `audio`, `fs`, `hid`/`set`, `time` and `misc` exist. ACNH will also
  need at least nifm, friends, bcat, ldn (local play), nfp (amiibo), prepo and online/NEX. Stub most to
  "offline" first.
- **Graphics:** NVN coverage and the shader translator only cover what Link's Awakening uses. ACNH's
  engine (sead / agl / gsys / Lp) will exercise more API surface, formats and shader features.
- **Link's Awakening-specific code** to disable (not delete, to keep upstream merges clean):
  `runtime/hle/*` game features, `runtime/rando.*`, `tools/rando/`, `third_party/LAS-Randomizer`,
  randomizer UI, `tools/patches.py` entries.
- **Maturity:** upstream is a beta, mostly AI-written with human review, and targets LA v1.0.0 only.
  Verify, don't trust.

## Phase 0 — Spike (time-box: 1–2 weeks)

Answer one question: is extending LASRecomp months of work, or a rewrite?

1. **Setup**
   - [x] Build upstream for Windows as-is (`docs/BUILD-windows.md`, MSYS2 UCRT64), start screen only.
         Needed one fix: `runtime/hle/qol.c` called a generated function directly, so the no-code build
         didn't link (now goes through dispatch).
   - [x] Decide which ACNH version to target: build ID `0400F824B4DA556E1FDD2A73B486B768`, the decomp's.
   - [x] Put the user's own ACNH ExeFS in `extracted/exefs/` (gitignored). The RomFS image is
         hard-linked as `extracted/romfs.bin`.
   - [x] List the ACNH ExeFS modules and their load addresses: `rtld`; `main` 65.5 MiB at
         `0x7000000000`; `subsdk0` (the SDK's multimedia library) 6.7 MiB at `0x7004200000`; `sdk`
         13.2 MiB at `0x7004A00000` (moved: LA leaves main only 64 MiB). See `runtime/rt.h`.
2. **Generate**
   - [x] Add an ACNH `gen` path in the `Makefile`: `make GAME=acnh gen` / `make GAME=acnh`
         (`generated-acnh/`, `build/acnh/`, `-DGAME_ACNH`, `gen.py --no-patches`).
   - [x] Record the results (after the jump-table fix below):

         | | main | subsdk0 | sdk |
         |---|---|---|---|
         | Functions | 170,697 (decomp: 168,645) | 13,638 | 36,824 |
         | Unsupported-instruction traps | 0 | 0 | 0 |
         | Jump tables resolved / unresolved | 1,938 / 393 | 311 / 24 | 521 / 54 |
         | Lift time | ~70 s | ~6 s | ~11 s |

         Generated C is about 780 MB. It compiles and links in about 9 minutes on 8 threads (i7-9700K)
         into a 239 MB exe.
   - Generator fixes: ADR/ADRP+ADD targets followed by a `br` on the same register are jump-table
     bases, not function starts. Splitting there had left most tables unresolvable. Stale chunk
     files are now removed.
3. **Boot**
   - [x] Run with the LA-specific HLE and randomizer disabled (game-thread ticks, `game_in_play()`,
         widescreen zone and seeds are off under `GAME_ACNH`). Start with `build/acnh/lasrecomp.exe --play`;
         the launcher only accepts LA's build ID.
   - [x] Log every service/IPC call, NVN entry point and guest trap until it stops
         (`LARECOMP_TRACE_HLE=1` logs the first call of each NVN/SDK host function).
   - [ ] Stub unimportant services as offline and push as far as possible: boot → title → in-game.
         **Reached:** SDK and multimedia init, main's 7,234 static initializers, 30+ threads, time,
         fs, hid, acc, audio renderer, shared fonts. nifm, friend and bcat are logging stubs. The
         NVN device, window and Vulkan swapchain come up, and command buffers are recorded every
         frame; 150 NVN entry points are used, none missing. No frame is submitted yet.
         **Stopped at:** an abort after `OpenDataStorageByDataId 0x0100000000000823` (a system
         data archive) fails.
   - Runtime fixes so far:
     - the newer SDK's 3-callback `nn::init::Start`;
     - entering a generated function mid-way when an unresolved table jump lands inside it
       (`Cpu.mid_entry`, `*_fn_ends`);
     - NVN API version 53.313 (ACNH's sead requires it);
     - a host overflow chunk when the game's command memory runs out (temporary, see next steps);
     - `AddCommandMemory` with a null pool is now ignored.
4. **Decomp swap-in proof**
   - [x] Read `cpu.h`/`loader.c`: guest addresses are host addresses, so native code reads the
         decomp's structs in place. Calls out to still-generated code need `guest_call` (an adapter per
         call), so decomp C++ can't be compiled unchanged yet.
   - [x] Replace one generated function with a decompiled one. `gen.py --hle` now also takes
         `<offset> <name>` lines (`runtime/acnh/hle_main.txt`). Run-time `hle_override` only catches
         indirect calls. `RootTask::enter` and `RootTask::calc` are native in
         `runtime/acnh/decomp_swap.c`.
   - [ ] Confirm in a boot log that they run (`[decomp]` lines); not seen yet.
5. **Write up** results in this file and decide.

### Next steps (Phase 0, step 3 continued)

1. [x] Get past the missing system data archive `0x0100000000000823` (NgWord2). It is read by
   `nn::ngc::ProfanityFilter::Initialize`, called from `RootTask::prepare`. `runtime/hle/ngc.c`
   replaces the filter with one that knows no words: every check passes and no text is masked.
2. [x] Keep the runtime's NVN command records in host memory instead of the game's command memory
   (`runtime/nvn/cmdbuf.c`). Each piece of guest command memory gets a host "shadow", keyed by its
   guest address and written again when the game hands that memory back, so host memory stays
   bounded by the game's own use. Use is reported to the game in guest bytes at about NVN's rate
   (16 bytes per command plus inline data). The game's own small buffers are now enough: no
   overflow, no heap exhaustion. Buffers given memory with no pool are kept apart per command
   buffer. This replaces the overflow workaround and the null-pool guard, and suits LA as well.
2b. [x] Null dereference in `RootTask::prepare` → `AppSys::unkB6340` → 0x71013fdd40 →
   0x71013c1030. Traced:
   - the constructor got `this` = null from `operator new(0xd78, heap = null)`;
   - with no current heap either, the null came from `sead::ExpHeap::create("Doubutsugo::Mgr",
     size 0 = all that's left)`, which failed because its parent "Game::Sound::System" was full;
   - the sound heap was full because `audren:u` `GetWorkBufferSize` returned a flat 16 MB per
     renderer.

   Fix: the work-buffer size is now estimated from the renderer parameters
   (`runtime/services/audio.c`); the runtime never uses that buffer. Native, logging versions of
   `operator new(size_t, sead::Heap*, s32)` and `sead::ExpHeap::create` (`runtime/acnh/decomp_swap.c`)
   now report which heap ran out.
4. [x] Confirm the `RootTask` swap-in runs: `RootTask::enter (native): first scene 0` and
   `RootTask::calc (native) first call` are in the boot log.
2c. [x] `nn::nfp::Initialize` (amiibo) crashed on a null: `nfp:user` had no implementation, and the
   logging stub returned OK without the `IUser` object. `runtime/services/nfp.c` is an offline
   `nfp:user`: it initializes and lists no devices, and device operations return DeviceNotFound.
3. [ ] **First frame submitted and presented** (`nvnQueueSubmitCommands`, `nvnQueuePresentTexture`):
   one black 1920×1080 frame.
3b. [x] Hang after the first frame. `LARECOMP_THREAD_DUMP=<s>[,<s>...]` (kernel.c) now dumps every guest
   thread: the SVC it's in, its wait object and a frame-pointer call stack.
   - **What the dump showed:** the frame loop and two job workers ping-ponged about 1,000 times a
     second through the address arbiter. They were all in the same parallel loop (main+0x5f410),
     synchronizing through a barrier (main+0x102af0).
   - **Why:** each thread's progress slot comes from `nn::os::GetCurrentCoreNumber`. The game pins
     its threads with `SetThreadCoreMask` (masks 1, 2, 4), which the runtime ignored, so all of them
     said "core 0", shared one slot, and the loop never finished.
   - **Fix:** `SetThreadCoreMask` now sets the thread's core (an explicit ideal core, or the lowest
     core of the mask).
3c. [x] Black screen. Fixed in order:
   - `nn::hid::ShowControllerSupport` waited forever for the controller applet. It is now replaced,
     with player 1 confirmed at once.
   - Offline `nifm:u` (`runtime/services/nifm.c`): requests end with "no internet".
   - Offline BCAT (`runtime/hle/bcat.c`): an empty delivery cache.
   - Lifter: jump-table targets in other pieces of a split function now become function starts
     (main: 1,999 tables resolved, 332 unresolved).
   - Maxwell `TLD4S` and `TLD4` (texture gather) in the shader translator.
   - NVN command records: a linear host mirror of guest command memory (×5) instead of per-chunk
     shadows. Reusing a guest range must overwrite only the matching host range, because lists
     called by handle (`CallCommands`) elsewhere must survive. `CopyCommands` now really copies.
   - **The cause of the black screen:** `nvnCommandBufferSetRenderEnableConditional` was a no-op.
     ACNH clears its layers' shared colour buffer conditionally, and run unconditionally the clears
     wiped the frame before the final copy. Render enable and conditional render enable (compare the
     64-bit values at +0 and +16) now skip draws and clears.
   - Debug tools added: `LARECOMP_DEBUG_OPS`, per-pass target logs, vertex constant-buffer and
     blend dumps (`LARECOMP_DEBUG_DATA`), `LARECOMP_SOLID_FS=<fs addr>[:fetch]`, `LARECOMP_LOG_PRESENT`,
     and the abort result code on `svcBreak`.
3d. [x] Black 3D scene behind the dialogue. The scene was rendering all along; the final tonemap
   pass multiplies everything through an 8×8×8 colour-grading LUT (`agl::pfx::ColorCorrection`,
   main+0x1df88d0 / 0x1df9bc0), and that LUT was all zeros. Three bugs, each enough on its own:
   - **3D render targets** were refused by the Vulkan backend (an LA-era shortcut). ACNH fills the
     LUT with one full-screen draw into 8 colour targets, each a view of a different z-slice. 3D
     images are now created 2D-array-compatible, and a render view is one slice as a 2D-array layer.
   - **The bake ran only once** and was skipped because its shader was still compiling in the
     background. Draws into 3D textures now wait for their program and pipeline (~20-300 ms, once).
   - **`LDC.64 R0, c[4][R0]`** (dynamic constant-buffer load whose destination overwrites its own
     address register) read the second word from the clobbered address, so the LUT shader picked
     garbage parameters and wrote 0. The address is now taken before either word lands.
   - Debug tools: `LARECOMP_FS_SUB=<fs addr>|<from>|<to>` (text substitution in one fragment
     shader), `LARECOMP_DEBUG_DATA=hex` (whole constant buffers as words),
     `LARECOMP_WATCH_TEX=<addr>` (log textures created over a guest address).
3e. [x] Timmy and Tommy missing. Their skinning vertex shader reads bone matrix rows with negative
   constant-buffer offsets (`LDC c[6][R9 + 0xfff8]`, i.e. R9 - 8). The translator added 0xfff8 as
   unsigned, read past the buffer (clamped to its last row) and placed the vertices nowhere. Dynamic
   constant-buffer addresses now wrap to 16 bits, as on the hardware.
3f. [x] Intermittent crash (about 1 boot in 8): a draw read a vertex buffer at 0x5000000033, which
   is really a barrier record's header (op 51, size 80) written over a pre-recorded bindings list.
   - ACNH packs up to 64 display lists back to back (main+0x1ecbaa0). It measures them in one pass,
     sets the region's budget to the total, and then records them for real, advancing by each
     list's `GetCommandMemoryUsed`.
   - Our command mirror skipped guest bytes when a record would straddle a 1 MiB mirror page,
     so a list's usage depended on where it landed. A list crossing a page in the real pass grew by
     up to its record size, the last lists ran past the budget, and the next structure's lists were
     written over them. When one of those was called, it ran a corrupted binding.
   - Fix (`cmdbuf.c`): mirror pages have slack; a record that runs past the end of its page spills
     into the slack and is followed by a jump to the next page. Guest usage never depends on
     placement. 16 boots clean afterwards.
   - Kept for diagnosis: `LARECOMP_CMD_CHECK=1` (each 16-byte granule of command memory knows its
     list; calling a list that was written over logs both sides), and `guest_copy` now refuses
     addresses outside guest memory (logged with the draw's recent records) instead of crashing.
3g. [x] Input, and the crash after name / birthday entry.
   - ACNH reads the controller with `nn::hid::GetNpadStates` (a list of samples); only LA's
     `GetNpadState` was implemented, so the game never saw a button. Added for all five styles.
   - Crash in the vibration thread about a minute in: heap pointers 0x72.. had become 0x63..
     (−0xF0000_0000). The game reads `GetTouchScreenStates<16>` into a stack buffer and then reads
     `states[0].count` whatever the call returned; the SDK's own call, over our empty shared memory,
     wrote nothing, so it used stack garbage as the touch count and subtracted 15 from "touch
     coordinates" far across the heap (main+0x18726b0). The touch screen readers now return one
     sample with no touches.
   - Found with `LARECOMP_WATCH=<lo>,<hi>` (dispatch.c): the pages are protected and each access
     single-stepped (Windows trap flag), logging every change to the 16 bytes at lo, and any store in
     the range that leaves a 0x6x_xxxx_xxxx value, with the host code and guest lr.
   - Headless repro: `LARECOMP_INPUT="1600:A:6,1700:A:6,..."` (A every 100 frames) reaches the
     name entry keyboard.
3h. [x] Character voices (Animalese). Silent, then left ear only:
   - Splitters were ignored: most voices and several sub mixes reach their mixes only through them
     (mix id 0x7fffffff, a splitter id). Now parsed (REV8: 'SNDH' header; 'SNDI' id, rate, count,
     ids, 12 stale bytes; 'SNDD' id, 24 volumes, mix, in use; only changes are sent) and mixed:
     destination k takes source channel / mix buffer k % channels. Sub mixes are ordered by depth
     over splitter edges too.
   - Aux (effect 2) was ignored: ACNH runs nearly every mix through the game's own processing, which
     pans the mono voices. Implemented as the SDK's `nn::audio::dsp::WriteAuxBufferDsp` /
     `ReadAuxBufferDsp`: int32 ring buffers, the DSP half of each info block at +0x40.
   - `LARECOMP_AUDIO_ROUTES=<frame>` dumps the routing graph.
**Now:** the intro plays: dialogue over the 3D Nook Inc. counter with Timmy and Tommy, name and
birthday entry, voices and sound, 60 fps. Open issues:
   - Intermittent hang at startup (once in ~10 runs, seen only in a visible window): the game stops
     after its first controller read, before the first frame. A run with `LARECOMP_THREAD_DUMP`
     that hangs will show where.
   - A cube-array texture (256×256×6, target 9) is sampled as a cube: "type mismatch" (30 logs).
   - Audio effects 3, 5 and 6 (delay, I3dl2 reverb, biquad filter) are not implemented.
3. Get the first frame submitted and presented (`nvnQueueSubmitCommands`, present).
4. [x] Confirm the `RootTask` swap-in runs (see 4 above).
5. Implement the `am` commands that are currently unhandled, as needed.
6. Write up and make the go/no-go call.

### Go / no-go

- **Go:** output compiles with a list of missing instructions you can enumerate, it reaches rendering,
  and the missing services/NVN calls form a bounded list.
- **Rethink:** the lifter breaks down on ACNH code, swap-in is impractical because of the memory model,
  or NVN and shader support is too tied to Link's Awakening's engine to extend.

## Phase 1 — Playable (if go)

- [ ] Lifter coverage: zero traps on paths that are hit.
- [ ] Services needed for single-player: save data, time (ACNH relies on the clock), audio, input.
- [ ] Rendering correctness: island, interiors, UI, text/fonts, movies.
- [ ] Saves: native location, ideally importing an existing Switch save.
- [ ] Stable 30 fps at native resolution, then unlocked resolution/aspect ratio.

## Phase 2 — Mod support

- [ ] Symbol source: import names from the decomp (`E:\games\acnh` symbol list, pinned commit) so HLE
      hooks and patches use names, not raw addresses.
- [ ] A mod-loading API on top of `--hle` and patches: hook before/after/replace, load mods from
      a folder, and handle conflicts.
- [ ] Asset/RomFS overlay: load replacement files from a mods folder (most existing ACNH mods are
      asset mods).
- [ ] Port a few well-known existing mods as proof.

## Phase 3 — Hybrid convergence (ongoing)

- [ ] Steer decomp priorities toward port and mod needs: save format, items, villagers, platform
      layer in sead/gsys.
- [ ] Swap decompiled functions in as they match; track percentage of runtime spent in native vs.
      generated code.
- [ ] Optional/late: local play (ldn), amiibo (nfp). Online play is out of scope.

## Repo conventions

- Two directories: `E:\games\acnh` is the matching decomp (Clang 8.0.1, byte-matching), and
  `E:\games\acnh-recomp` is this fork (modern toolchain). They stay separate repos.
- Remotes: `origin` = `geno55/acnh-recomp`, `upstream` = `peiikai/LASRecomp`. Fetch upstream regularly
  and merge into `acnh`.
- Disable LA-specific code with build flags rather than deleting it until the branches have clearly
  diverged.
- No game files, keys, dumps or generated code in git (see `.gitignore`).
- Upstream contributions: generic fixes (lifter, NVN, services) should be offered upstream as separate
  PRs.
- License: MIT (keep upstream `LICENSE` and notices). Note the GPL components in the randomizer helper
  if anything from it ships.
