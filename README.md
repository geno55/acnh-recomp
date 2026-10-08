# LARecomp

> [!IMPORTANT]
> **This project was made almost exclusively with AI.** Nearly all of the code, tooling, reverse engineering and
> documentation in this repository was written by an AI coding assistant (Anthropic's Claude, through Claude Code),
> directed, tested and reviewed by a human. Expect the strengths and the rough edges that come with that.

**LARecomp** is a static recompilation of *The Legend of Zelda: Link's Awakening* (Nintendo Switch, 2019) into a
native desktop application. The game's original program is translated ahead of time into C and compiled for your
computer, so it runs natively - no emulator - with its own renderer, audio, input and a built-in randomizer.

Currently it runs on **macOS (Apple Silicon, Metal)**. A **Windows** version (Vulkan) is planned.

![Mabe Village in a 21:9 window: the unlocked aspect ratio shows more of the island](docs/ultrawide.jpg)

> [!NOTE]
> **No game files are included.** LARecomp needs your own legally obtained copy of the game: a dump of
> *Link's Awakening* **v1.0.0** (XCI or NSP) and your console's `prod.keys`. On first launch the start screen
> extracts what it needs. Nothing owned by Nintendo is part of this repository.

![The start screen: choose vanilla or a randomizer seed, set up your game files, settings](docs/start_screen.jpg)

## Features

**Runs natively**
- 60 fps, any window size and resolution, fullscreen
- **Unlocked aspect ratio**: wider (or taller) windows show more of the island, up to ultrawide; houses and dungeons
  keep their framing. The original 16:9 framing is one option away.
- Start screen: play vanilla or any randomizer seed, set up game files from your own dump, import fonts
- In-game overlay menu (F1, or Minus + Plus on a controller): display, audio, save editor, randomizer, warp, cheats,
  difficulty presets, controls - and back to the title screen
- Keyboard and controller support, including text entry for naming your file

**Randomizer** (built on [LAS-Randomizer](https://github.com/Owen-Splat/LAS-Randomizer))
- Generate and play seeds without leaving the game; spoiler log and readable walkthrough viewer, check tracker on
  the map, inventory overlay with every dungeon's keys
- Extra options on top of LAS-Randomizer: **potsanity** (every pot is a check, with hearts, arrows, refills and
  traps as filler), **entrance randomizer**, **keysanity**, extra checks (fishing, rapids, Dampé, trade gifts),
  "bombs / powder must be found first", skip story scenes, tunic colours, environment shuffle, companions
- Experimental: **generated dungeons** built from real rooms of every dungeon, with seamless room transitions even
  where the doorways don't line up

## Status

Work in progress. The game is playable from start to finish; rough edges remain, and the generated dungeons are
experimental. The running development log - every finding, fix and plan - is [`notes/PLAN.md`](notes/PLAN.md).

## Building from source

Requirements (macOS on Apple Silicon): Xcode command line tools (clang), [Homebrew](https://brew.sh) `sdl3` and
`ffmpeg`, Python 3.12.

1. Put your game files in place: run the app once and use the start screen's game-file setup, or extract your
   v1.0.0 dump yourself into `extracted/` (`exefs/`, `romfs/` and `romfs.bin`) with [hactool](https://github.com/SciresM/hactool).
2. Recompile the game code: `make gen` (writes `generated/`, from your own `extracted/exefs`).
3. Build: `make -j10` -> `build/larecomp`.
4. Randomizer: create the Python environment for LAS-Randomizer in `third_party/LAS-Randomizer/venv`
   (`python3.12 -m venv venv && venv/bin/pip install -r requirements.txt`).
5. Run: `./build/larecomp extracted` (start screen) or `./build/larecomp extracted --play` (straight into the game).

## Credits

**LAS-Randomizer** - the randomizer at the heart of this project's randomizer features, vendored (with local
changes) in `third_party/LAS-Randomizer` under the MIT license. Huge thanks to its authors and community:
- **Owen_Splat** - LAS-Randomizer (https://github.com/Owen-Splat/LAS-Randomizer)
- **Glan** - created the original early builds of the randomizer (https://github.com/la-switch/LAS-Randomizer)
- **j_im** - created the original tracker for the randomizer
- **Br00ty** - maintains and updates the tracker
- **ProfessorLaw** - additional programming
- **theboy181** - blur removal patch
- and everyone who has reported bugs, given feedback or contributed to LAS-Randomizer

**Libraries and tools**
- [SDL 3](https://libsdl.org) - windowing, input, audio (zlib license)
- [FFmpeg](https://ffmpeg.org) - movie playback (LGPL)
- [Dear ImGui](https://github.com/ocornut/imgui) - overlay menu and start screen (MIT)
- [hactool](https://github.com/SciresM/hactool) by SciresM - game file extraction (ISC)
- [oead](https://github.com/zeldamods/oead) and [evfl](https://github.com/zeldamods/evfl) - Nintendo file formats, used by LAS-Randomizer
- [Capstone](https://www.capstone-engine.org) - disassembly in the development tools
- [envytools](https://github.com/envytools/envytools) - NVIDIA GPU documentation used for the shader translator
- The Switch homebrew community's documentation ([Switchbrew](https://switchbrew.org))

## Legal

LARecomp is a fan project. It is not affiliated with, endorsed by or sponsored by Nintendo. *The Legend of Zelda*
and *Link's Awakening* are trademarks of Nintendo. No Nintendo code or assets are distributed in this repository;
you must provide your own copy of the game.

A license for LARecomp's own code has not been chosen yet. Third-party components keep their own licenses.
