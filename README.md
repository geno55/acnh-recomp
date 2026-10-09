# LAS Recomp

> [!IMPORTANT]
> **This project was made almost exclusively with AI.** Nearly all of the code, tooling, reverse engineering and
> documentation in this repository was written by and will be maintained by an AI (Anthropic's Claude, through Claude Code),
> directed, tested and reviewed by a human. As a huge fan of this game, I made this for myself. Sharing it is a curtesy,
> if you don't agree with the usage of AI, do not trust code written by AI, that is your right but I'm not interested
> in the controversy in relation to this project. You may simply ignore this project and its code.
> As with anything on the internet, you run the code at your own discretion.

**LAS Recomp** is a static recompilation of *The Legend of Zelda: Link's Awakening* (Nintendo Switch, 2019) into a
native Windows and macOS application.

> [!NOTE]
> Currently supported Platforms:
> macOS - Apple Silicon Only, Metal Graphics Backend + MetalFX
> Windows - x86 Only, Vulkan Graphics Backend

![Mabe Village in a 21:9 window: the unlocked aspect ratio shows more of the island](docs/ultrawide.jpg)

> [!NOTE]
> **No game files are included.** LAS Recomp needs your own legally obtained copy of the game: a dump of
> *Link's Awakening* **v1.0.0** (XCI or NSP) from your console and your console's `prod.keys`. 
> Instructions on how to obtain these files from your Switch and game copy will **NOT** be provided.
> On first launch the start screen extracts what it needs. Nothing owned by Nintendo is part of this repository.
> Screenshot shows the start screen after extraction, no Nintendo Artwork is included until provided by the user.

![The start screen: choose vanilla or a randomizer seed, set up your game files, settings](docs/start_screen.jpg)

## Project Discord
https://discord.gg/DhrgdYqdcY

## Status

This is a 0.1 alpha release. That means bug are likely, crashes could occur, randomizer seeds could possibly be unsolvable (dungeon room shuffle modes are especially experimental at this point), some graphics issue remain (especially in wide and ultrawide aspect ratios), this is a work in progress thus the alpha designation. Please use the Discord for discussing possible randomizer logic issues and submitting bug reports.

## Features

**Runs natively**
- **This is not emulation.** Runs native on Windows and macOS using static recompilation of the switch code. 
- Unlocked aspect ratio: wider (or taller) windows show more of the island, up to ultrawide; houses and dungeons
  keep their framing. The original 16:9 framing is one option away.
- Start screen: play vanilla or any randomizer seed, set up game files from your own dump, import fonts.
  - Switch games use fonts built into the Switch operating system for some text. Some sensible replacements were picked but optionally you may setup the Switch fonts for an authentic look. Switch fonts are Nintendo IP, you must provide them from your own hardware.
- In-game overlay menu (F1, or Minus + Plus on a controller)
- Keyboard and controller support
- Apple MetalFX upscaler for macOS builds. Default.
- Internal resolution adjustments. Pick how high you want the resolution to be or cut it down, match the display and dynamic resolution options. When combined with the MetalFX upscaler on Macs even a Macbook Air should be able to handle this easily with the right settings. Bilenear upscaling is the only option on Windows currently.

**Randomizer**
- In game seed generator.
- Seed system for sharing or reproducing exact seeds.
- Per seed save games
- Full item shuffle.
- Trade Quest shuffle.
- Disable Acorn/Piece of Power drops.
- Bombs / Magic Powder shuffle.
- Environment Randomizer - Randomizes in game environmental effects.
- Music Randomizer
- Potsanity - Every pot is a check. Pots are golden until checks so you visibly know what pots you've checked.
- Bushsanity - Every single cuttable bush (not the grass) is a check. Like pots bushes are golden until checked for the first time.
- Digsanity - A truly insane setting which makes every diggable tile on the overworld a check, holes stay dug permanently so you know where you've dug. Made for shovel enthusiasts. 
- Keysanity - Keys can be found anywhere for any dungeon.
- Shopsanity - Every item in the shop shuffled. Random prices, or just steal it.
- Trendsantiy - Full Trendy Game randomization
- Pets - Ghost, Marin (unlocks Dessert, open dessert an option and Marin not in the pool), Rooster (In Logic for Feather checks, including in dungeons if enabled), Ghost (Find the Ghost drop to unlock grave check)
- Entrance Randomizer - Shuffles all entrances. Includes a decoupled option.
- Dungeon Room Shuffler - Shuffles all dungeon rooms creating unique custom dungeons every seed. Three modes:
  - Coherent: Dungeon rooms are shuffled but connecting rooms are lined up, to make this work in logic dungeons use duplicate rooms sometimes (as little as possible) to maintain a workable logical dungeon.
  - Chaos: Dungeon rooms are shuffled but don't need to make sense. Walking north may lead you to door from another direction.
  - Madness: Dungeon rooms are shuffled in a way that doesn't need to make sense AND are uncoupled creating nightmares to navigate.
  - Optionally the map can show what's connected to what as you explore or in full when you find the in game map.
- Inventory screen tracks keys and trade items for individual dungeons so you can see at a glance what you have keys for or what trade items you have. 
- Built in check tracker on overworld map (optional)

## Building from source

Requirements (macOS on Apple Silicon): Xcode command line tools (clang), [Homebrew](https://brew.sh) `sdl3` and
`ffmpeg`, Python 3.12.

1. Put your game files in place: run the app once and use the start screen's game-file setup, or extract your
   v1.0.0 dump yourself into `extracted/` (`exefs/`, `romfs/` and `romfs.bin`) with [hactool](https://github.com/SciresM/hactool).
2. Recompile the game code: `make gen` (writes `generated/`, from your own `extracted/exefs`).
3. Build: `make -j10` -> `build/larecomp`.
4. Randomizer: create the Python environment for LAS-Randomizer in `third_party/LAS-Randomizer/venv`:
   `python3.12 -m venv venv && venv/bin/pip install -r requirements.txt`.
5. Run: `./build/larecomp extracted` (start screen) or `./build/larecomp extracted --play` (straight into the game).

## Credits

**LAS-Randomizer** - the randomizer at the heart of this project's randomizer features, vendored (with local
changes) in `third_party/LAS-Randomizer` under the MIT license. Huge thanks to its authors and community:
- **Owen_Splat** - LAS-Randomizer (https://github.com/Owen-Splat/LAS-Randomizer)
- **Glan** - created the original early builds of the randomizer (https://github.com/la-switch/LAS-Randomizer)
- **ProfessorLaw** - additional programming
- and everyone who has reported bugs, given feedback or contributed to LAS-Randomizer

**Libraries and tools**
- [SDL 3](https://libsdl.org) - windowing, input, audio (zlib license)
- [FFmpeg](https://ffmpeg.org) - movie playback (LGPL)
- [Dear ImGui](https://github.com/ocornut/imgui) - overlay menu and start screen (MIT)
- [Vulkan Memory Allocator](https://github.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator) - Windows renderer (MIT)
- [hactool](https://github.com/SciresM/hactool) by SciresM - game file extraction (ISC)
- [oead](https://github.com/zeldamods/oead) and [evfl](https://github.com/zeldamods/evfl) - Nintendo file formats, used by LAS-Randomizer
- [Capstone](https://www.capstone-engine.org) - disassembly in the development tools
- [envytools](https://github.com/envytools/envytools) - NVIDIA GPU documentation used for the shader translator
- The Switch homebrew community's documentation ([Switchbrew](https://switchbrew.org))

## Legal

LAS Recomp is a fan project. It is not affiliated with, endorsed by or sponsored by Nintendo. *The Legend of Zelda*
and *Link's Awakening* are trademarks of Nintendo. No Nintendo code or assets are distributed in this repository;
you must provide your own legally obtained copy of the game to play. 

## License

LAS Recomp's own code (the recompiler tools, the runtime, the randomizer additions) is open source under the
[MIT License](LICENSE). Third-party components keep their own licenses: LAS-Randomizer (MIT), Dear ImGui (MIT),
Vulkan Memory Allocator (MIT), SDL 3 (zlib), FFmpeg (LGPL 2.1+, linked dynamically), hactool (ISC), oead / evfl (used by
the randomizer's Python environment, under their own licenses). The license covers LAS Recomp's code only - it grants
nothing for Nintendo's game, which you must supply yourself.
