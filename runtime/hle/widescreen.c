// Widescreen: the camera code's 16:9 aspect literal loads are patched (tools/patches.py) to call
// rt_aspect_site(); the renderer sets the wide factor (output aspect / 16:9) each frame.
#include <math.h>
#include <stdbool.h>
#include <stdlib.h>

#include "../hle.h"
#include "../settings.h"

#define BACKDROP_HASHES 0x71fe31bbf03c3515ull

static float g_wide = 1.0f;  // output aspect divided by 16:9 (1 = normal)

void widescreen_set_factor(float f) { g_wide = f; }
float widescreen_factor(void) { return g_wide; }

// Off in rooms that should keep 16:9 framing (interiors, dungeons) -- see widescreen_update.
static bool g_allowed = true;
static bool g_indoor;
bool widescreen_allowed(void) { return g_allowed && g_settings.aspect == ASPECT_UNLOCKED && !getenv("LARECOMP_NO_WIDESCREEN"); }
void widescreen_set_allowed(bool on) { g_allowed = on; }

// Interiors and dungeons use cameras that never load the patched overworld aspect (site 0). Count
// site-0 loads per presented frame; frames without any are framed 16:9 (pillar/letterboxed).
static volatile uint64_t g_site0_frame = ~0ull;
static int g_indoor_streak, g_outdoor_streak;

void widescreen_frame_end(uint64_t frame) {
    bool saw = g_site0_frame == frame;
    if (saw) { g_outdoor_streak++; g_indoor_streak = 0; }
    else { g_indoor_streak++; g_outdoor_streak = 0; }
    bool was = g_indoor;
    if (!g_indoor && g_indoor_streak >= 3) g_indoor = true;
    if (g_indoor && g_outdoor_streak >= 1) g_indoor = false;
    if (was != g_indoor && getenv("LARECOMP_LOG_INDOOR"))
        LOG("[widescreen] %s at frame %llu\n", g_indoor ? "interior (16:9 framing)" : "overworld (wide)", (unsigned long long)frame);
}

float rt_aspect_site(int site) {
    if (site == 0) { extern uint64_t renderer_present_count(void); g_site0_frame = renderer_present_count(); }
    static long mask = -2;
    if (mask == -2) mask = getenv("LARECOMP_ASPECT_SITES") ? strtol(getenv("LARECOMP_ASPECT_SITES"), NULL, 0) : -1;
    float base = 16.0f / 9.0f;
    if (mask != -1 && !(mask & (1L << site))) return base;
    return base * g_wide;  // the output's aspect (wider or narrower than 16:9)
}

// Culling aspect: the game's own value (camera field), widened like the camera.
float rt_cull_aspect(float orig) {
    static float last = -1;
    if (orig != last && getenv("LARECOMP_LOG_CULL")) { LOG("[widescreen] culling aspect field %f\n", orig); last = orig; }
    return rt_aspect_site(6) * (orig > 0.1f && orig < 10.0f ? orig / (16.0f / 9.0f) : 1.0f);
}

// Vertical field of view: unchanged for wide outputs; for tall ones (factor < 1) widened so the
// horizontal view stays what the game shows at 16:9.
float rt_fovy(float orig) {
    static float last = -1;
    if (orig != last && getenv("LARECOMP_LOG_CULL")) { LOG("[widescreen] fovy field %f\n", orig); last = orig; }
    if (g_wide >= 1.0f || !(orig > 0)) return orig;
    bool degrees = orig > 3.2f;  // radians otherwise
    float half = (degrees ? orig * (float)M_PI / 180.0f : orig) * 0.5f;
    float wide = 2.0f * atanf(tanf(half) / g_wide);
    return degrees ? wide * 180.0f / (float)M_PI : wide;
}

// Interiors: the indoor shadow setup runs while an interior is rendered (tools/patches.py).
static uint64_t g_indoor_frame;
float rt_indoor_aspect(void) {
    extern uint64_t renderer_present_count(void);
    uint64_t f = renderer_present_count();
    if (getenv("LARECOMP_LOG_INDOOR") && f / 60 != g_indoor_frame / 60) LOG("[widescreen] indoor at frame %llu\n", (unsigned long long)f);
    g_indoor_frame = f;
    return 16.0f / 9.0f;
}

void romfs_file_read_hook(const char *path) { (void)path; }

// Interior backdrop (16:9 quad covering the overworld behind rooms), identified by shader code hash.
static uint64_t g_backdrop_hash = 0;  // set below once known
static uint64_t g_backdrop_frame = ~0ull;
void widescreen_backdrop_seen(uint64_t hash) {
    static const uint64_t known[] = {BACKDROP_HASHES};
    for (unsigned i = 0; i < sizeof known / sizeof known[0]; i++)
        if (known[i] && hash == known[i]) { extern uint64_t renderer_present_count(void); g_backdrop_frame = renderer_present_count(); }
    (void)g_backdrop_hash;
}
bool widescreen_frame_boxed(uint64_t frame) {
    static bool last;
    bool b = g_backdrop_frame == frame;
    if (b != last && getenv("LARECOMP_LOG_INDOOR")) LOG("[widescreen] boxed %d at frame %llu\n", b, (unsigned long long)frame);
    last = b;
    return b;
}
