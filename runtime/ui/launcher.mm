// Start screen, shown before the game boots (user 2026-10-08, styled after Dusklight's launcher): PLAY (with
// ‹ Vanilla / seed › picker), SETTINGS, QUIT, game-files status at the lower left. Nothing of the game ships with
// LAS Recomp: on first launch the user picks their own Switch dump (XCI / NSP, v1.0.0) and prod.keys, we extract
// exefs + romfs with hactool (tools/hactool, ISC) and check the main module's build id; PLAY stays disabled until
// that worked. The background is a frame of the game's own title movie (from the user's files) once extracted.
//
// Skipped with --play, LARECOMP_NO_LAUNCHER=1, or any scripted test run (LARECOMP_INPUT): tests boot straight in.
// The in-game menu's "Title screen" comes back here without leaving the process (runtime/main.c reboots the game).
#ifdef __APPLE__
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#endif
#include <SDL3/SDL.h>
#include <dirent.h>
#include <pthread.h>
#include <string>
#include <sys/stat.h>
#include <vector>
#include <algorithm>

#include "imgui.h"
#ifdef __APPLE__
#include "imgui_impl_metal.h"
#else
#include "imgui_impl_vulkan.h"
#endif
#include "imgui_impl_sdl3.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswscale/swscale.h>
#include "platform.h"
#include "ui/ui_scale.h"
#include "settings.h"
void ui_window_init(void);
SDL_Window *ui_window(void);
#ifdef __APPLE__
void *ui_metal_layer(void);
void *ui_metal_device(void);
#else
// runtime/nvn/vulkan: window frames and ImGui plumbing
bool vk_frame_begin(const float clear[4]);
void vk_frame_end(const char *shot_path);
void *vk_frame_cmd(void);
bool vk_imgui_backend_init(void);
void vk_imgui_backend_shutdown(void);
uint64_t vk_imgui_texture_rgba(const void *rgba, int w, int h);
#endif
}
#ifdef __APPLE__
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

// (test) BGRA texture -> PNG (the game renderer's saver isn't up yet before the game boots)
static void save_png(id<MTLTexture> tex, const char *path) {
    size_t w = tex.width, h = tex.height;
    std::vector<uint8_t> px(w * h * 4);
    [tex getBytes:px.data() bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px.data(), w, h, 8, w * 4, cs,
                                             kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)path, strlen(path), false);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dest, img, NULL);
    CGImageDestinationFinalize(dest);
    CFRelease(dest), CFRelease(url), CGImageRelease(img), CGContextRelease(ctx), CGColorSpaceRelease(cs);
}
#endif

static const uint8_t BUILD_ID[8] = {0xae, 0x16, 0xf7, 0x1e, 0x00, 0x2a, 0xf8, 0xcb};  // Link's Awakening v1.0.0 main
#define LARECOMP_VERSION "0.1"

// ------------------------------------------------------------------ game files
static std::string g_root;  // extracted game: <root>/exefs, <root>/romfs

static bool file_exists(const std::string &p) {
    struct stat st;
    return stat(p.c_str(), &st) == 0;
}

// "" = ready, else what is wrong
static std::string check_game_files(const std::string &root) {
    FILE *f = fopen((root + "/exefs/main").c_str(), "rb");
    if (!f) return "No game files";
    uint8_t id[8] = {0};
    fseek(f, 0x40, SEEK_SET);
    size_t n = fread(id, 1, 8, f);
    fclose(f);
    if (n != 8 || memcmp(id, BUILD_ID, 8)) return "Wrong game version (needs v1.0.0)";
    if (!file_exists(root + "/romfs/region_common") || !file_exists(root + "/romfs.bin")) return "Game data missing";
    return "";
}

// ------------------------------------------------------------------ extraction (background thread)
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static std::string g_dump, g_keys;  // picked files
static std::string g_job;           // current extraction step / result for the status line
static bool g_busy, g_job_failed;

static void set_job(const std::string &s, bool failed = false) {
    pthread_mutex_lock(&g_lock);
    g_job = s;
    g_job_failed = failed;
    pthread_mutex_unlock(&g_lock);
}

static int run(const std::vector<std::string> &args, const std::string &log) {
    std::vector<const char *> av;
    for (auto &a : args) av.push_back(a.c_str());
    av.push_back(NULL);
    PlatProc p = plat_spawn(av.data(), log.c_str(), true);
    if (!p) return -1;
    return plat_proc_wait(p, true);
}

static std::string largest_with(const std::string &dir, const char *ext) {
    std::string best;
    off_t best_sz = -1;
    if (DIR *d = opendir(dir.c_str())) {
        while (struct dirent *e = readdir(d)) {
            std::string n = e->d_name;
            if (n.size() < strlen(ext) || n.compare(n.size() - strlen(ext), strlen(ext), ext)) continue;
            struct stat st;
            if (stat((dir + "/" + n).c_str(), &st) == 0 && st.st_size > best_sz) { best_sz = st.st_size; best = dir + "/" + n; }
        }
        closedir(d);
    }
    return best;
}

static void *extract_thread(void *) {
    std::string dump, keys;
    pthread_mutex_lock(&g_lock);
    dump = g_dump, keys = g_keys;
    pthread_mutex_unlock(&g_lock);
    std::string hactool = "tools/hactool/hactool" PLAT_EXE_SUFFIX, tmp = g_root + "/.extract", log = g_root + "/extract.log";
    mkdir(g_root.c_str(), 0755);
    mkdir(tmp.c_str(), 0755);
    bool nsp = dump.size() > 4 && !strcasecmp(dump.c_str() + dump.size() - 4, ".nsp");
    set_job("Reading the game dump...");
    std::vector<std::string> a = {hactool, "-k", keys};
    std::string titlekey;
    if (nsp) {
        a.insert(a.end(), {"-t", "pfs0", "--outdir=" + tmp, dump});
    } else {
        a.insert(a.end(), {"-t", "xci", "--securedir=" + tmp, dump});
    }
    if (run(a, log)) { set_job("Could not read the dump (keys correct?)", true); goto done; }
    if (nsp) {  // NSP content is title-key encrypted: the (encrypted) key is in the ticket at 0x180
        std::string tik = largest_with(tmp, ".tik");
        FILE *f = tik.empty() ? NULL : fopen(tik.c_str(), "rb");
        uint8_t k[16];
        if (f && fseek(f, 0x180, SEEK_SET) == 0 && fread(k, 1, 16, f) == 16) {
            char hex[33];
            for (int i = 0; i < 16; i++) snprintf(hex + 2 * i, 3, "%02x", k[i]);
            titlekey = hex;
        }
        if (f) fclose(f);
    }
    {
        std::string nca = largest_with(tmp, ".nca");  // the program NCA (game code + data) is by far the largest
        if (nca.empty()) { set_job("No game content found in the dump", true); goto done; }
        set_job("Extracting game files (a few minutes)...");
        // romfs.bin (raw image) is what the game's file system reads; romfs/ (files) the tools and the movie player use
        std::vector<std::string> b = {hactool, "-k", keys, "--exefsdir=" + g_root + "/exefs", "--romfsdir=" + g_root + "/romfs",
                                      "--romfs=" + g_root + "/romfs.bin"};
        if (!titlekey.empty()) b.push_back("--titlekey=" + titlekey);
        b.push_back(nca);
        if (run(b, log)) { set_job("Extraction failed (see " + log + ")", true); goto done; }
    }
    {
        std::string why = check_game_files(g_root);
        set_job(why.empty() ? "Game files ready." : why, !why.empty());
    }
done:
    plat_remove_tree(tmp.c_str());
    pthread_mutex_lock(&g_lock);
    g_busy = false;
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

// ------------------------------------------------------------------ file dialogs (SDL calls back on any thread)
static void SDLCALL picked(void *which, const char *const *files, int) {
    if (!files || !files[0]) return;
    pthread_mutex_lock(&g_lock);
    (which == (void *)1 ? g_dump : g_keys) = files[0];
    pthread_mutex_unlock(&g_lock);
}

// ------------------------------------------------------------------ the user's own Nintendo fonts (not shipped)
// runtime/hle/pl.c loads fonts/ first, else a close substitute (Hiragino Sans). Import copies recognized files only.
static const char *FONT_STD[] = {"nintendo_udsg-r_std_003.bfttf", "nintendo_udsg-r_std_003.ttf",
                                 "nintendo_udsgr_std_003.ttf", "nintendo_udsgr_std_003.bfttf"};
static const char *FONT_EXT[] = {"nintendo_ext_003.bfttf", "nintendo_ext_003.ttf"};
static std::vector<std::string> g_font_picks;
static std::string g_font_msg;

static bool have_font(const char *const *names, int n) {
    for (int i = 0; i < n; i++)
        if (file_exists(std::string("fonts/") + names[i])) return true;
    return false;
}

static void SDLCALL picked_fonts(void *, const char *const *files, int) {
    if (!files) return;
    pthread_mutex_lock(&g_lock);
    for (int i = 0; files[i]; i++) g_font_picks.push_back(files[i]);
    pthread_mutex_unlock(&g_lock);
}

static void import_fonts() {
    pthread_mutex_lock(&g_lock);
    std::vector<std::string> picks;
    picks.swap(g_font_picks);
    pthread_mutex_unlock(&g_lock);
    if (picks.empty()) return;
    mkdir("fonts", 0755);
    int ok = 0, skipped = 0;
    for (auto &src : picks) {
        std::string base = src.substr(src.find_last_of('/') + 1), low = base;
        for (auto &c : low) c = (char)tolower(c);
        bool known = false;
        for (auto n : FONT_STD) known |= low == n;
        for (auto n : FONT_EXT) known |= low == n;
        if (!known) { skipped++; continue; }
        FILE *in = fopen(src.c_str(), "rb"), *out = fopen(("fonts/" + low).c_str(), "wb");
        if (in && out) {
            char buf[65536];
            size_t n;
            while ((n = fread(buf, 1, sizeof buf, in)) > 0) fwrite(buf, 1, n, out);
            ok++;
        }
        if (in) fclose(in);
        if (out) fclose(out);
    }
    g_font_msg = std::to_string(ok) + " font file(s) imported" + (skipped ? ", " + std::to_string(skipped) + " not recognized" : "") +
                 ". Used from the next game start.";
}

static void remove_fonts() {
    for (auto n : FONT_STD) unlink((std::string("fonts/") + n).c_str());
    for (auto n : FONT_EXT) unlink((std::string("fonts/") + n).c_str());
    g_font_msg = "Imported fonts removed: the substitute font is used.";
}

// ------------------------------------------------------------------ background: a title movie frame
#ifdef __APPLE__
static id<MTLTexture> g_bg;
#define BG_TEXID ((ImTextureID)(__bridge void *)g_bg)
typedef id<MTLDevice> GpuDevice;
#else
static uint64_t g_bg;  // ImGui texture id (Vulkan descriptor set)
#define BG_TEXID ((ImTextureID)g_bg)
typedef void *GpuDevice;
#endif
static int g_bg_w, g_bg_h;

static void load_background(GpuDevice dev) {
    std::string path = g_root + "/romfs/region_common/movie/title.webm";
    AVFormatContext *fmt = NULL;
    if (avformat_open_input(&fmt, path.c_str(), NULL, NULL) < 0) return;
    int si = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (si >= 0 && avformat_find_stream_info(fmt, NULL) >= 0) {
        AVStream *st = fmt->streams[si];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        AVCodecContext *cc = avcodec_alloc_context3(codec);
        avcodec_parameters_to_context(cc, st->codecpar);
        if (codec && avcodec_open2(cc, codec, NULL) == 0) {
            AVPacket *pkt = av_packet_alloc();
            AVFrame *fr = av_frame_alloc();
            int64_t want = (int64_t)(6.0 / av_q2d(st->time_base));  // a few seconds in: the island, not black
            av_seek_frame(fmt, si, want, AVSEEK_FLAG_BACKWARD);
            bool got = false;
            while (!got && av_read_frame(fmt, pkt) >= 0) {
                if (pkt->stream_index == si && avcodec_send_packet(cc, pkt) == 0)
                    while (avcodec_receive_frame(cc, fr) == 0)
                        if (fr->best_effort_timestamp >= want) { got = true; break; }
                av_packet_unref(pkt);
            }
            if (got) {
                int w = fr->width, h = fr->height;
                std::vector<uint8_t> rgba((size_t)w * h * 4);
                SwsContext *sws = sws_getContext(w, h, (AVPixelFormat)fr->format, w, h, AV_PIX_FMT_RGBA, SWS_BILINEAR, NULL, NULL, NULL);
                uint8_t *dst[1] = {rgba.data()};
                int dst_ls[1] = {w * 4};
                sws_scale(sws, fr->data, fr->linesize, 0, h, dst, dst_ls);
                sws_freeContext(sws);
#ifdef __APPLE__
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                              width:w height:h mipmapped:NO];
                g_bg = [dev newTextureWithDescriptor:td];
                [g_bg replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:rgba.data() bytesPerRow:w * 4];
#else
                (void)dev;
                g_bg = vk_imgui_texture_rgba(rgba.data(), w, h);
#endif
                g_bg_w = w, g_bg_h = h;
            }
            av_frame_free(&fr);
            av_packet_free(&pkt);
        }
        avcodec_free_context(&cc);
    }
    avformat_close_input(&fmt);
}

// ------------------------------------------------------------------ seeds
static std::vector<std::string> list_seeds() {
    std::vector<std::string> out;
    if (DIR *d = opendir("rando")) {
        while (struct dirent *e = readdir(d)) {
            if (e->d_name[0] == '.') continue;
            std::string dir = std::string("rando/") + e->d_name;
            if (file_exists(dir + "/settings.json") && file_exists(dir + "/romfs")) out.push_back(e->d_name);
        }
        closedir(d);
    }
    std::sort(out.begin(), out.end());
    return out;
}

// ------------------------------------------------------------------ screen
static ImFont *g_font_title, *g_font_menu, *g_font_small;
enum Page { MAIN, SETTINGS, SETUP };

// A big menu line: gold + a marker when focused / hovered (keyboard, gamepad or mouse), grey when disabled
static bool g_menu_small;  // sub pages: buttons in the small font

static bool menu_item(const char *label, bool enabled, bool *hovered = NULL) {
    ImGui::PushFont(g_menu_small ? g_font_small : g_font_menu);
    ImGui::BeginDisabled(!enabled);
    ImVec2 at = ImGui::GetCursorScreenPos();
    ImGui::PushID(label);
    ImVec2 sz = ImGui::CalcTextSize(label);
    bool clicked = ImGui::InvisibleButton("##b", ImVec2(sz.x + 40, sz.y + 6));
    bool hot = ImGui::IsItemFocused() || ImGui::IsItemHovered();
    ImGui::PopID();
    if (hovered) *hovered = hot;
    ImU32 col = !enabled ? IM_COL32(150, 150, 150, 130) : hot ? IM_COL32(250, 205, 90, 255) : IM_COL32(245, 245, 240, 255);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    if (hot && enabled) {  // a drawn arrow (the fonts we use have no glyph for one: it showed as '?')
        float h = sz.y * 0.42f, cx = at.x - sz.y * 0.55f, cy = at.y + sz.y * 0.52f;
        dl->AddTriangleFilled(ImVec2(cx - h * 0.45f, cy - h * 0.6f), ImVec2(cx - h * 0.45f, cy + h * 0.6f),
                              ImVec2(cx + h * 0.55f, cy), col);
    }
    dl->AddText(at, col, label);
    ImGui::Dummy(ImVec2(0, sz.y * 0.35f));  // line spacing
    ImGui::EndDisabled();
    ImGui::PopFont();
    return clicked;
}

// Controllers, as in the in-game menu (runtime/ui/menu.mm): read straight from SDL, Nintendo layout - the right face
// button (A) confirms, the bottom one (B) goes back; d-pad / left stick move. (ImGui's own SDL gamepad handling is
// switched off: it used the Xbox layout and, per the user, didn't work on the start screen.)
static ImGuiKey launcher_pad_key(Uint8 b) {
    switch (b) {
    case SDL_GAMEPAD_BUTTON_EAST: return ImGuiKey_GamepadFaceDown;   // A: activate
    case SDL_GAMEPAD_BUTTON_SOUTH: return ImGuiKey_GamepadFaceRight; // B: back
    case SDL_GAMEPAD_BUTTON_NORTH: return ImGuiKey_GamepadFaceUp;
    case SDL_GAMEPAD_BUTTON_WEST: return ImGuiKey_GamepadFaceLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return ImGuiKey_GamepadDpadUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return ImGuiKey_GamepadDpadDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return ImGuiKey_GamepadDpadLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return ImGuiKey_GamepadDpadRight;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ImGuiKey_GamepadL1;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ImGuiKey_GamepadR1;
    case SDL_GAMEPAD_BUTTON_START: return ImGuiKey_GamepadStart;
    case SDL_GAMEPAD_BUTTON_BACK: return ImGuiKey_GamepadBack;
    default: return ImGuiKey_None;
    }
}

static void launcher_pad_open_all(void) {
    int n = 0;
    SDL_JoystickID *ids = SDL_GetGamepads(&n);
    for (int i = 0; ids && i < n; i++) SDL_OpenGamepad(ids[i]);
    SDL_free(ids);
}

// true when the event was a controller event (handled here)
static bool launcher_pad_event(const SDL_Event &e) {
    ImGuiIO &io = ImGui::GetIO();
    switch (e.type) {
    case SDL_EVENT_GAMEPAD_ADDED:
        SDL_OpenGamepad(e.gdevice.which);
        io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
        return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        ImGuiKey k = launcher_pad_key(e.gbutton.button);
        if (k != ImGuiKey_None) io.AddKeyEvent(k, e.type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        float v = e.gaxis.value / 32767.0f;
        if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickLeft, v < -0.3f, v < -0.3f ? -v : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickRight, v > 0.3f, v > 0.3f ? v : 0);
        } else if (e.gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickUp, v < -0.3f, v < -0.3f ? -v : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickDown, v > 0.3f, v > 0.3f ? v : 0);
        }
        return true;
    }
    default: return false;
    }
}

// Returns when PLAY is chosen (seed stored in g_settings.rando_seed); QUIT exits.
extern "C" void launcher_run(const char *root) {
    g_root = root;
    ui_window_init();
    SDL_Window *win = ui_window();
#ifdef __APPLE__
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ui_metal_layer();
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    id<MTLCommandQueue> queue = [dev newCommandQueue];
#else
    GpuDevice dev = NULL;
#endif

    IMGUI_CHECKVERSION();
    ImGuiContext *prev_ctx = ImGui::GetCurrentContext();  // the in-game menu's, when back here after a reboot
    ImGuiContext *ctx = ImGui::CreateContext();
    ImGui::SetCurrentContext(ctx);
    ImGuiIO &io = ImGui::GetIO();
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.IniFilename = NULL;
    const char *fonts[] = {"fonts/nintendo_udsgr_std_003.ttf", "/System/Library/Fonts/Avenir Next.ttc",
                           "/System/Library/Fonts/Helvetica.ttc", "C:/Windows/Fonts/segoeui.ttf"};
    static const ImWchar ranges[] = {0x20, 0xFF, 0x2039, 0x203A, 0x2713, 0x2713, 0x25B8, 0x25B8, 0};  // + ‹ › ✓ ▸
    for (const char *p : fonts) {
        if (g_font_menu || !file_exists(p)) continue;
        g_font_small = io.Fonts->AddFontFromFileTTF(p, 30, NULL, ranges);
        g_font_menu = io.Fonts->AddFontFromFileTTF(p, 52, NULL, ranges);
        g_font_title = io.Fonts->AddFontFromFileTTF(p, 92, NULL, ranges);
    }
    if (!g_font_menu) g_font_small = g_font_menu = g_font_title = io.Fonts->AddFontDefault();
    ImGuiStyle &st = ImGui::GetStyle();
    st.Colors[ImGuiCol_Header] = ImVec4(0, 0, 0, 0);
    st.Colors[ImGuiCol_HeaderHovered] = ImVec4(1, 1, 1, 0.08f);
    st.Colors[ImGuiCol_HeaderActive] = ImVec4(1, 1, 1, 0.14f);
    st.Colors[ImGuiCol_NavCursor] = ImVec4(0.95f, 0.78f, 0.35f, 1);
    st.FrameRounding = st.WindowRounding = 10;
#ifdef __APPLE__
    ImGui_ImplSDL3_InitForMetal(win);
    ImGui_ImplMetal_Init(dev);
#else
    ImGui_ImplSDL3_InitForVulkan(win);
    vk_imgui_backend_init();
#endif
    ImGui_ImplSDL3_SetGamepadMode(ImGui_ImplSDL3_GamepadMode_Manual, NULL, 0);  // (controllers: launcher_pad_event)
    launcher_pad_open_all();
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;

    std::string status = check_game_files(g_root);
    if (status.empty()) load_background(dev);
    std::vector<std::string> seeds = list_seeds();
    std::vector<std::string> choices = {"Vanilla"};
    choices.insert(choices.end(), seeds.begin(), seeds.end());
    int choice = 0;
    for (size_t i = 0; i < seeds.size(); i++)
        if (seeds[i] == g_settings.rando_seed) choice = (int)i + 1;
    Page page = status.empty() ? MAIN : SETUP;
    bool play = false;
    // LARECOMP_LAUNCHER_SHOT=<frame>[:<page>] (test): save build/launcher.png at that frame and exit; page: settings / setup
    long shot_at = getenv("LARECOMP_LAUNCHER_SHOT") ? atol(getenv("LARECOMP_LAUNCHER_SHOT")) : 0, frame = 0;
    if (shot_at) {
#ifdef __APPLE__
        layer.framebufferOnly = NO;
#endif
        const char *pg = strchr(getenv("LARECOMP_LAUNCHER_SHOT"), ':');
        if (pg && !strcmp(pg + 1, "settings")) page = SETTINGS;
        if (pg && !strcmp(pg + 1, "setup")) page = SETUP;
    }

    if (getenv("LARECOMP_LAUNCHER_AUTOPLAY") && status.empty()) play = true;  // (test: PLAY at once)
    if (const char *t = getenv("LARECOMP_LAUNCHER_EXTRACT")) {  // (test) <dump>:<keys>: extract, log, exit
        const char *c = strchr(t, ':');
        if (c) {
            g_dump.assign(t, c - t);
            g_keys = c + 1;
            g_busy = true;
            extract_thread(NULL);
            fprintf(stderr, "[launcher] extract: %s -> %s\n", g_job.c_str(), check_game_files(g_root).empty() ? "READY" : "NOT READY");
            exit(0);
        }
    }
    while (!play) {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (!launcher_pad_event(e)) ImGui_ImplSDL3_ProcessEvent(&e);
            if (e.type == SDL_EVENT_QUIT) exit(0);
        }
        // extraction finished: re-check, load the background
        pthread_mutex_lock(&g_lock);
        bool busy = g_busy;
        pthread_mutex_unlock(&g_lock);
        static bool was_busy;
        if (was_busy && !busy) {
            status = check_game_files(g_root);
            if (status.empty()) { load_background(dev); page = MAIN; }
        }
        was_busy = busy;

#ifdef __APPLE__
        int w, h;
        SDL_GetWindowSizeInPixels(win, &w, &h);
        layer.drawableSize = CGSizeMake(w, h);
        @autoreleasepool {
            id<CAMetalDrawable> drawable = [layer nextDrawable];
            if (!drawable) { SDL_Delay(16); continue; }
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = drawable.texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.04, 0.05, 0.06, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLCommandBuffer> cb = [queue commandBuffer];
            id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
            ImGui_ImplMetal_NewFrame(rp);
#else
        {
            static const float clear_col[4] = {0.04f, 0.05f, 0.06f, 1};
            if (!vk_frame_begin(clear_col)) { SDL_Delay(16); continue; }
            ImGui_ImplVulkan_NewFrame();
#endif
            ImGui_ImplSDL3_NewFrame();
            ImGui::NewFrame();

            ImVec2 ds = io.DisplaySize;
            float s = ds.y / 720.0f;  // layout scale (fonts are built for ~2x)
            ImGui::GetIO().FontGlobalScale = s * 0.5f * ui_text_scale();
            ImDrawList *bg = ImGui::GetBackgroundDrawList();
            if (g_bg) {  // cover the window, keep the aspect
                float ia = (float)g_bg_w / g_bg_h, wa = ds.x / ds.y;
                ImVec2 uv0(0, 0), uv1(1, 1);
                if (wa > ia) { float v = ia / wa; uv0.y = (1 - v) / 2; uv1.y = 1 - uv0.y; }
                else { float u = wa / ia; uv0.x = (1 - u) / 2; uv1.x = 1 - uv0.x; }
                bg->AddImage(BG_TEXID, ImVec2(0, 0), ds, uv0, uv1);
            } else {
                bg->AddRectFilledMultiColor(ImVec2(0, 0), ds, IM_COL32(18, 34, 40, 255), IM_COL32(40, 70, 64, 255),
                                            IM_COL32(12, 20, 24, 255), IM_COL32(8, 12, 16, 255));
            }
            // darken the left side for the menu
            bg->AddRectFilledMultiColor(ImVec2(0, 0), ImVec2(ds.x * 0.6f, ds.y), IM_COL32(0, 0, 0, 200), IM_COL32(0, 0, 0, 0),
                                        IM_COL32(0, 0, 0, 0), IM_COL32(0, 0, 0, 200));

            ImGui::SetNextWindowPos(ImVec2(0, 0));
            ImGui::SetNextWindowSize(ds);
            ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));
            ImGui::Begin("##launcher", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove |
                                                 ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_NoBringToFrontOnFocus);
            float x0 = 90 * s;
            ImGui::SetCursorPos(ImVec2(x0, 170 * s));
            ImGui::PushFont(g_font_title);
            ImGui::TextColored(ImVec4(0.98f, 0.80f, 0.32f, 1), "Link's Awakening");
            ImGui::PopFont();
            ImGui::SetCursorPos(ImVec2(x0, 330 * s));

            if (page == MAIN) {
                bool hov = false;
                char label[192];
                snprintf(label, sizeof label, "PLAY    \xe2\x80\xb9 %s \xe2\x80\xba", choices[choice].c_str());
                ImGui::SetCursorPosX(x0);
                static bool focused_once;
                if (!focused_once) { ImGui::SetKeyboardFocusHere(); focused_once = true; }
                if (menu_item(label, status.empty(), &hov)) play = true;
                if (hov && status.empty()) {
                    if (ImGui::IsKeyPressed(ImGuiKey_LeftArrow) || ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft))
                        choice = (choice + (int)choices.size() - 1) % (int)choices.size();
                    if (ImGui::IsKeyPressed(ImGuiKey_RightArrow) || ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight))
                        choice = (choice + 1) % (int)choices.size();
                }
                ImGui::SetCursorPosX(x0);
                if (menu_item("SETTINGS", true)) page = SETTINGS;
                ImGui::SetCursorPosX(x0);
                if (menu_item(status.empty() ? "GAME FILES" : "SET UP GAME FILES", !busy)) page = SETUP;
                ImGui::SetCursorPosX(x0);
                if (menu_item("QUIT", true)) exit(0);
            } else {
                // sub pages: a dark panel (readable over any background), scrolls if it doesn't fit
                // larger text (ui_scale.h) gets a taller panel: it starts closer to the title, ends closer to the status
                float grow = ui_text_scale() - 1, top = (300 - 50 * grow) * s, bottom = (140 - 25 * grow) * s;
                ImGui::SetCursorPos(ImVec2(x0 - 24 * s, top));
                ImGui::PushStyleColor(ImGuiCol_ChildBg, ImVec4(0.03f, 0.04f, 0.05f, 0.78f));
                ImGui::PushStyleVar(ImGuiStyleVar_ChildRounding, 14 * s);
                ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(24 * s, 18 * s));
                ImGui::BeginChild("##panel", ImVec2(ds.x * 0.58f, ds.y - top - bottom), ImGuiChildFlags_AlwaysUseWindowPadding,
                                  ImGuiWindowFlags_NavFlattened);
                ImGui::PopStyleVar(2);
                ImGui::PopStyleColor();
                g_menu_small = true;
                float x0 = ImGui::GetCursorPosX();
                if (page == SETTINGS) {
                ImGui::PushFont(g_font_small);
                ImGui::SetCursorPosX(x0);
                ImGui::Checkbox("Fullscreen", &g_settings.fullscreen);
                ImGui::SetCursorPosX(x0);
                ImGui::Checkbox("Show FPS", &g_settings.show_fps);
                ImGui::SetCursorPosX(x0);
                ImGui::SetNextItemWidth(420 * s);
                ImGui::SliderFloat("Volume", &g_settings.volume, 0, 1, "%.2f");
                ImGui::SetCursorPosX(x0);
                ImGui::Checkbox("360-degree movement", &g_settings.move_360);
                ImGui::SetCursorPosX(x0);
                ImGui::Checkbox("Remove blur", &g_settings.blur_removal);
                ImGui::SetCursorPosX(x0);
                ImGui::Checkbox("Hide Hero Mode icon", &g_settings.hide_hero_icon);
                ImGui::SetCursorPosX(x0);
                ImGui::SetNextItemWidth(420 * s);
                static const char *const prompts[] = {"Auto (follow the controller)", "Nintendo", "Xbox", "PlayStation"};
                ImGui::Combo("Button icons", &g_settings.prompts, prompts, 4);
                ImGui::SetCursorPosX(x0);
                ImGui::TextDisabled("More options are in the in-game menu (Esc).");
                ImGui::Dummy(ImVec2(0, 12 * s));
                import_fonts();
                bool fs = have_font(FONT_STD, 4), fe = have_font(FONT_EXT, 2);
                ImGui::SetCursorPosX(x0);
                ImGui::TextColored(ImVec4(0.98f, 0.80f, 0.32f, 1), "Game font");
                ImGui::SetCursorPosX(x0);
                ImGui::Text("Text: %s    Button icons: %s", fs ? "Nintendo font (imported)" : "substitute (Hiragino Sans)",
                            fe ? "imported" : "substitute");
                ImGui::SetCursorPosX(x0);
                ImGui::PushTextWrapPos(0);
                ImGui::TextDisabled("Fonts aren't included. For the original look, dump them from your own Switch and import: "
                                    "nintendo_udsg-r_std_003.bfttf (text) and nintendo_ext_003.bfttf (button icons). "
                                    ".ttf versions with the same names work too.");
                ImGui::PopTextWrapPos();
                if (!g_font_msg.empty()) { ImGui::SetCursorPosX(x0); ImGui::Text("%s", g_font_msg.c_str()); }
                ImGui::PopFont();
                static const SDL_DialogFileFilter font_f[] = {{"Switch fonts", "bfttf;ttf"}};
                ImGui::SetCursorPosX(x0);
                if (menu_item("IMPORT FONTS", true)) SDL_ShowOpenFileDialog(picked_fonts, NULL, win, font_f, 1, NULL, true);
                if (fs || fe) {
                    ImGui::SetCursorPosX(x0);
                    if (menu_item("USE SUBSTITUTE FONT", true)) remove_fonts();
                }
                ImGui::SetCursorPosX(x0);
                if (menu_item("BACK", true) || ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                    ImGui::IsKeyPressed(ImGuiKey_Escape, false)) { settings_save(); page = MAIN; }  // (B / Esc: back)
                } else {  // SETUP
                pthread_mutex_lock(&g_lock);
                std::string dump = g_dump, keys = g_keys, job = g_job;
                bool failed = g_job_failed;
                pthread_mutex_unlock(&g_lock);
                if (keys.empty()) {
                    const char *home = getenv("HOME");
                    std::string def = std::string(home ? home : "") + "/.switch/prod.keys";
                    if (file_exists(def)) { keys = def; pthread_mutex_lock(&g_lock); g_keys = def; pthread_mutex_unlock(&g_lock); }
                }
                ImGui::PushFont(g_font_small);
                ImGui::SetCursorPosX(x0);
                ImGui::PushTextWrapPos(0);
                ImGui::TextWrapped("Link's Awakening isn't included. Choose your own dump of the game (v1.0.0, XCI or "
                                   "NSP) and your console's prod.keys; the game files are extracted once.");
                ImGui::PopTextWrapPos();
                ImGui::SetCursorPosX(x0);
                ImGui::Text("Game dump:  %s", dump.empty() ? "(not chosen)" : dump.c_str());
                ImGui::SetCursorPosX(x0);
                ImGui::Text("Keys:       %s", keys.empty() ? "(not chosen)" : keys.c_str());
                ImGui::PopFont();
                static const SDL_DialogFileFilter dump_f[] = {{"Switch game dump", "xci;nsp"}};
                static const SDL_DialogFileFilter keys_f[] = {{"Keys", "keys;txt"}};
                ImGui::SetCursorPosX(x0);
                if (menu_item("CHOOSE GAME DUMP", !busy)) SDL_ShowOpenFileDialog(picked, (void *)1, win, dump_f, 1, NULL, false);
                ImGui::SetCursorPosX(x0);
                if (menu_item("CHOOSE KEYS", !busy)) SDL_ShowOpenFileDialog(picked, (void *)2, win, keys_f, 1, NULL, false);
                ImGui::SetCursorPosX(x0);
                if (menu_item(busy ? "EXTRACTING..." : "EXTRACT", !busy && !dump.empty() && !keys.empty())) {
                    pthread_mutex_lock(&g_lock);
                    g_busy = true;
                    pthread_mutex_unlock(&g_lock);
                    pthread_t t;
                    pthread_create(&t, NULL, extract_thread, NULL);
                    pthread_detach(t);
                }
                if (!job.empty()) {
                    ImGui::PushFont(g_font_small);
                    ImGui::SetCursorPosX(x0);
                    ImGui::TextColored(failed ? ImVec4(1, 0.5f, 0.4f, 1) : ImVec4(0.9f, 0.9f, 0.8f, 1), "%s", job.c_str());
                    ImGui::PopFont();
                }
                ImGui::SetCursorPosX(x0);
                if (menu_item("BACK", !busy) || (!busy && (ImGui::IsKeyPressed(ImGuiKey_GamepadFaceRight, false) ||
                                                           ImGui::IsKeyPressed(ImGuiKey_Escape, false)))) page = MAIN;
                }
                g_menu_small = false;
                ImGui::EndChild();
            }

            // status (lower left) and version (lower right)
            ImGui::PushFont(g_font_small);
            ImGui::SetCursorPos(ImVec2(x0, ds.y - 110 * s));
            if (status.empty()) {
                {  // a drawn check mark (the Switch font has no ✓)
                    ImVec2 p = ImGui::GetCursorScreenPos();
                    float u = ImGui::GetTextLineHeight();
                    ImU32 g = IM_COL32(140, 230, 140, 255);
                    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x + u * 0.1f, p.y + u * 0.55f), ImVec2(p.x + u * 0.35f, p.y + u * 0.8f), g, u * 0.12f);
                    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x + u * 0.35f, p.y + u * 0.8f), ImVec2(p.x + u * 0.85f, p.y + u * 0.2f), g, u * 0.12f);
                    ImGui::SetCursorPosX(x0 + u * 1.3f);
                }
                ImGui::TextColored(ImVec4(0.55f, 0.9f, 0.55f, 1), "Game files ready.");
                ImGui::SetCursorPosX(x0);
                ImGui::TextDisabled("Nintendo Switch  \xc2\xb7  v1.0.0");
            } else {
                ImGui::TextColored(ImVec4(1, 0.72f, 0.4f, 1), "!  %s", busy ? "Extracting game files..." : status.c_str());
                ImGui::SetCursorPosX(x0);
                ImGui::TextDisabled("Set up the game files to play.");
            }
            const char *ver = "LAS Recomp " LARECOMP_VERSION;
            ImGui::SetCursorPos(ImVec2(ds.x - ImGui::CalcTextSize(ver).x - 60 * s, ds.y - 110 * s));
            ImGui::TextDisabled("%s", ver);
            ImGui::PopFont();
            ImGui::End();
            ImGui::PopStyleColor();

            ImGui::Render();
#ifdef __APPLE__
            ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
            [enc endEncoding];
            id<MTLTexture> shot = nil;
            if (shot_at && ++frame == shot_at) {
                MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:drawable.texture.pixelFormat
                                             width:drawable.texture.width height:drawable.texture.height mipmapped:NO];
                td.storageMode = MTLStorageModeShared;
                shot = [dev newTextureWithDescriptor:td];
                id<MTLBlitCommandEncoder> bl = [cb blitCommandEncoder];
                [bl copyFromTexture:drawable.texture toTexture:shot];
                [bl endEncoding];
            }
            [cb presentDrawable:drawable];
            [cb commit];
            if (shot) {
                [cb waitUntilCompleted];
                save_png(shot, "build/launcher.png");
                exit(0);
            }
#else
            ImGui_ImplVulkan_RenderDrawData(ImGui::GetDrawData(), (VkCommandBuffer)vk_frame_cmd());
            bool shot = shot_at && ++frame == shot_at;
            vk_frame_end(shot ? "build/launcher.png" : NULL);
            if (shot) exit(0);
#endif
        }
    }
    // play: remember the choice, hand the window to the game
    snprintf(g_settings.rando_seed, sizeof g_settings.rando_seed, "%s", choice ? choices[choice].c_str() : "");
    settings_save();
#ifdef __APPLE__
    ImGui_ImplMetal_Shutdown();
#else
    vk_imgui_backend_shutdown();
#endif
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext(ctx);
    ImGui::SetCurrentContext(prev_ctx);
    g_bg = 0;
}
