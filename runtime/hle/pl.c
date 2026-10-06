// nn::pl shared system fonts. The Switch's system fonts are not part of the game, so a host
// TrueType font stands in for every font type (button glyphs will be wrong).
#include <stdlib.h>
#include <string.h>

#include "../hle.h"

static uint64_t font_addr;
static uint64_t font_size;

static void load_font(void) {
    if (font_addr) return;
    const char *path = getenv("LARECOMP_FONT");
    if (!path) path = "/System/Library/Fonts/Supplemental/Arial.ttf";
    FILE *f = fopen(path, "rb");
    if (!f) FATAL("cannot open substitute font %s\n", path);
    fseek(f, 0, SEEK_END);
    font_size = (uint64_t)ftell(f);
    fseek(f, 0, SEEK_SET);
    void *p = hle_alloc(font_size + 16);
    fread(p, 1, font_size, f);
    fclose(f);
    font_addr = (uint64_t)p;
    LOG("[pl] substitute font %s (%llu bytes)\n", path, font_size);
}

HLE_FUNC("_ZN2nn2pl22GetSharedFontLoadStateENS0_14SharedFontTypeE", pl_get_load_state) { c->x[0] = 1; }
HLE_FUNC("_ZN2nn2pl20GetSharedFontAddressENS0_14SharedFontTypeE", pl_get_address) { load_font(); c->x[0] = font_addr; }
HLE_FUNC("_ZN2nn2pl17GetSharedFontSizeENS0_14SharedFontTypeE", pl_get_size) { load_font(); c->x[0] = font_size; }
