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
**New blocker:** `nn::nfp::Initialize` (amiibo) crashes on a null. `nfp:user` has no
implementation, and the logging stub returns OK without the interface object. It needs an offline
`nfp` service (and likely the same treatment for the other online services).
3. Get the first frame submitted and presented (`nvnQueueSubmitCommands`, present).
4. Confirm the `RootTask` swap-in runs.
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
