// Runtime edits of a few of the game's UI textures, made on upload (runtime/nvn/texpatch.c): Xbox / PlayStation
// button prompts and the hidden Hero Mode icon. Shared by the Metal and Vulkan backends.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#include "nvn.h"

#define TEXPATCH_UNKNOWN (-2)  // (backend's cached id before the first identification)

// Which of the known textures `t` is (by its contents: the user's own game files are read once to know them), or -1.
int texpatch_identify(const NvnTexture *t);
// Changes whenever the wanted look of the known textures changes (prompt style, controller, Hero icon setting):
// backends re-upload identified textures when it differs from the value they uploaded with.
uint32_t texpatch_generation(void);
// Rewrites level 0 of known texture `id` in place: `blocks` = its linear data in the texture's own format
// (rows of 4x4 blocks, `row` bytes apart; RGBA8 rows for uncompressed). No-op for the Nintendo look.
void texpatch_apply(int id, uint8_t *blocks, uint32_t w, uint32_t h, uint32_t row);
