// Randomizer tab: choose / generate LAS-Randomizer seeds (rando/<seed>/). Switching seeds reboots the game in place
// (game data is read at boot: runtime/main.c), the window stays; each seed keeps its own save slots.
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <string>
#include <vector>
#include <algorithm>

#include "imgui.h"

extern "C" {
#include "../hle.h"
#include "../rando.h"
#include "../settings.h"
extern const char *g_romfs_dir;
}

struct Seed { std::string name, logic, spoiler, id; long mtime; };
static std::vector<Seed> g_seeds;
static bool g_scanned;
static int g_selected = -1;

static std::string read_file(const std::string &p) {
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) return "";
    std::string s;
    char buf[8192];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) s.append(buf, n);
    fclose(f);
    return s;
}

static std::string json_str(const std::string &j, const char *key) {
    std::string k = std::string("\"") + key + "\": \"";
    size_t p = j.find(k);
    if (p == std::string::npos) return "";
    p += k.size();
    size_t e = j.find('"', p);
    return e == std::string::npos ? "" : j.substr(p, e - p);
}

// Deletes rando/<name> (the seed's game files, spoiler and its save slots).
static bool delete_seed(const std::string &name) {
    if (name.empty() || name == "." || name == ".." || name.find_first_of("/\\") != std::string::npos) return false;
    std::string dir = "rando/" + name;
    bool ok = plat_remove_tree(dir.c_str());
    LOG("[rando] deleted seed %s: %s\n", name.c_str(), ok ? "ok" : strerror(errno));
    return ok;
}

static void scan(void) {
    g_seeds.clear();
    DIR *d = opendir("rando");
    if (!d) return;
    while (struct dirent *e = readdir(d)) {
        if (e->d_name[0] == '.') continue;
        std::string dir = std::string("rando/") + e->d_name;
        struct stat sb;
        if (stat((dir + "/exefs/1.0.0.pchtxt").c_str(), &sb)) continue;
        Seed s;
        s.name = e->d_name;
        s.mtime = sb.st_mtime;
        std::string js = read_file(dir + "/settings.json");
        s.logic = json_str(js, "logic");
        s.spoiler = dir + "/spoiler.txt";
        if (stat(s.spoiler.c_str(), &sb)) s.spoiler = dir + "/spoiler_" + s.name + ".txt";  // (older seeds)
        s.id = read_file(dir + "/seed_id.txt");
        while (!s.id.empty() && (s.id.back() == '\n' || s.id.back() == ' ')) s.id.pop_back();
        g_seeds.push_back(s);
    }
    closedir(d);
    std::sort(g_seeds.begin(), g_seeds.end(), [](const Seed &a, const Seed &b) { return a.mtime > b.mtime; });
    g_scanned = true;
}

// ---- generation (background process)
static PlatProc g_gen_pid;
static std::string g_gen_seed, g_gen_status;
static float g_gen_frac;
static double g_gen_start;
static bool g_gen_failed;

static const char *const kTunics[] = {"default", "random", "Purple", "Orange", "Yellow", "Pink", "Teal", "Sky",
                                      "Brown", "Black", "White", "Grey", "Lime", "Magenta"};

struct GenOpts {
    char seed[64] = "";       // the seed's NAME (its folder, rando/<name>/): any label; the seed ID is separate
    uint64_t rng = 0;         // 36-bit random part of the seed ID
    int logic = 0;            // basic advanced glitched hell none
    int dungeon_items = 3;    // none stone-beak mc mcb
    int keysanity = 0;        // off / small keys anywhere / + Nightmare Keys / all dungeon items
    bool bomb_bag = false, powder_bag = false;  // shuffle-bombs / shuffle-powder
    bool environments = false, pets_in_dungeons = false;  // randomize-environments / bad-pets
    bool skip_story = true;   // skip-story-events (kids after the Cello, remaining Owl talk)
    bool enemy_minibosses = false;  // enemy-minibosses (needs Randomize enemies)
    int tunic = 0;            // tunic-color: index into kTunics (tools/rando/cosmetics.py COLOURS)
    bool inc_fishing = false, inc_rapids = false, inc_dampe = false, inc_trade = false, inc_blue = false;
    int traps = 1;            // none few several many trapsanity
    int seashells = 2;        // max reward included: none 5 15 30 40 50
    bool shuffle_instruments = false, shuffle_dungeons = false, randomize_enemies = false, randomize_music = false;
    bool open_mabe = false, fast_songs = false, ohko = false, boss_cutscenes = true, spoiler = true;
    int start_rupees = 0;
    // planned (LAS Recomp additions, not implemented yet)
    int entrances = 0;        // off / dungeons / ...
    bool decoupled = false, pots = false, grass = false;
    bool no_buffs = false;    // no-buff-drops: enemies never drop Guardian Acorns / Pieces of Power
    bool bushes = false;      // bushsanity: every overworld bush hides an item (tools/rando/bushes.py)
    int room_shuffle = 0;     // dungeon-room-shuffle: off / coherent / chaos / madness (tools/rando/dungeon_gen.py)
};
static GenOpts g_opts;

// ---- Seed IDs: a 20-character code (Crockford base32, XXXXX-XXXXX-XXXXX-XXXXX) holding the random seed and every
// generation option, with a checksum. Same ID + same LAS Recomp version = the same seed, so IDs can be shared. The
// generator gets the ID itself as its seed string. Bump SEED_ID_VERSION when the bit layout changes.
enum { SEED_ID_VERSION = 3, SEED_ID_BITS = 100 };  // v2: 36-bit random part; v3: + dungeon room shuffle (v2 IDs still load)
static const char kB32[] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

struct Bits {
    uint8_t b[SEED_ID_BITS] = {};
    int n = 0;
    void put(uint64_t v, int w) { for (int i = 0; i < w; i++) b[n++] = (v >> i) & 1; }
    uint64_t get(int w) { uint64_t v = 0; for (int i = 0; i < w; i++) v |= (uint64_t)b[n++] << i; return v; }
};

static bool *opt_flags(GenOpts &o, int i) {  // the yes/no options, in ID order (append only)
    bool *f[] = {&o.bomb_bag, &o.powder_bag, &o.environments, &o.pets_in_dungeons, &o.skip_story, &o.enemy_minibosses,
                 &o.inc_fishing, &o.inc_rapids, &o.inc_dampe, &o.inc_trade, &o.inc_blue, &o.shuffle_instruments,
                 &o.shuffle_dungeons, &o.randomize_enemies, &o.randomize_music, &o.open_mabe, &o.fast_songs,
                 &o.boss_cutscenes, &o.spoiler, &o.decoupled, &o.pots, &o.no_buffs, &o.bushes};
    return i < (int)(sizeof f / sizeof *f) ? f[i] : NULL;
}

static uint32_t id_check(const Bits &x, int upto) {
    uint32_t h = 0x811c9dc5u;
    for (int i = 0; i < upto; i++) { h ^= x.b[i]; h *= 0x01000193u; }
    return (h ^ (h >> 5) ^ (h >> 10) ^ (h >> 15)) & 31;
}

static void seed_id_encode(GenOpts &o, char *out, size_t cap) {
    Bits x;
    x.put(SEED_ID_VERSION, 4);
    x.put(o.rng, 36);
    x.put(o.logic, 3); x.put(o.dungeon_items, 2); x.put(o.keysanity, 2); x.put(o.traps, 3); x.put(o.seashells, 3);
    x.put(o.tunic, 4); x.put(o.entrances, 2); x.put(o.start_rupees, 10);
    x.put(o.room_shuffle, 2);  // (v3)
    for (int i = 0; bool *f = opt_flags(o, i); i++) x.put(*f, 1);
    int data = x.n;
    x.put(0, SEED_ID_BITS - 5 - data);
    x.put(id_check(x, SEED_ID_BITS - 5), 5);
    std::string s;
    for (int c = 0; c < SEED_ID_BITS / 5; c++) {
        if (c && c % 5 == 0) s += '-';
        int v = 0;
        for (int k = 0; k < 5; k++) v |= x.b[c * 5 + k] << k;
        s += kB32[v];
    }
    snprintf(out, cap, "%s", s.c_str());
}

// "" = ok (options + rng set), else what's wrong with the text
static std::string seed_id_decode(const char *text, GenOpts &o) {
    Bits x;
    int chars = 0;
    for (const char *p = text; *p; p++) {
        char ch = (char)toupper((unsigned char)*p);
        if (ch == '-' || ch == ' ') continue;
        if (ch == 'O') ch = '0';
        if (ch == 'I' || ch == 'L') ch = '1';
        const char *q = strchr(kB32, ch);
        if (!q || !ch) return "not a seed ID (unexpected character)";
        if (chars == SEED_ID_BITS / 5) return "too long for a seed ID";
        x.put((uint64_t)(q - kB32), 5);
        chars++;
    }
    if (chars != SEED_ID_BITS / 5) return "a seed ID has 20 characters";
    if ((uint32_t)(x.b[95] | x.b[96] << 1 | x.b[97] << 2 | x.b[98] << 3 | x.b[99] << 4) != id_check(x, SEED_ID_BITS - 5))
        return "typo? (checksum doesn't match)";
    x.n = 0;
    int ver = (int)x.get(4);
    if (ver != SEED_ID_VERSION && ver != 2) return "made by another LAS Recomp version (ID format " + std::to_string(ver) + ")";
    GenOpts t = o;
    t.rng = x.get(36);
    t.logic = (int)x.get(3); t.dungeon_items = (int)x.get(2); t.keysanity = (int)x.get(2); t.traps = (int)x.get(3);
    t.seashells = (int)x.get(3); t.tunic = (int)x.get(4); t.entrances = (int)x.get(2); t.start_rupees = (int)x.get(10);
    t.room_shuffle = ver >= 3 ? (int)x.get(2) : 0;
    for (int i = 0; bool *f = opt_flags(t, i); i++) *f = x.get(1);
    if (t.room_shuffle > 3 || t.logic > 4 || t.traps > 4 || t.seashells > 5 || t.tunic >= 14 || t.entrances > 2 || t.start_rupees > 999)
        return "not a valid seed ID";
    t.ohko = false;
    o = t;
    return "";
}

static uint64_t new_rng(void) { return ((uint64_t)arc4random() << 4 ^ arc4random()) & 0xFFFFFFFFFull; }

static const char *ADJ[] = {"Sleepy", "Brave", "Lucky", "Rapid", "Quiet", "Golden", "Wild", "Secret", "Dreamy", "Mighty"};
static const char *NOUN[] = {"Marin", "Tarin", "Owl", "Cucco", "BowWow", "Moblin", "Zora", "Shell", "WindFish", "Toadstool"};

static void random_seed_name(char *out, size_t n) {
    snprintf(out, n, "%s%s%d", ADJ[arc4random_uniform(10)], NOUN[arc4random_uniform(10)], (int)arc4random_uniform(1000));
}

static std::string clean_name(const char *in) {  // a seed name as a folder name: letters, digits, space - _ ( ) '
    std::string n;
    for (const char *p = in; *p; p++) {
        unsigned char ch = (unsigned char)*p;
        n += (isalnum(ch) || strchr(" -_()'", ch)) && ch ? (char)ch : '_';
    }
    while (!n.empty() && n.back() == ' ') n.pop_back();
    while (!n.empty() && (n[0] == ' ' || n[0] == '.')) n.erase(0, 1);
    return n;
}

static void start_generation(void) {
    if (!g_opts.seed[0]) random_seed_name(g_opts.seed, sizeof g_opts.seed);
    std::string name = clean_name(g_opts.seed);
    if (name.empty()) name = "Seed";
    struct stat sb;
    for (int k = 2; !stat(("rando/" + name).c_str(), &sb); k++) {  // never overwrite a seed: "Name (2)"
        std::string base = clean_name(g_opts.seed);
        name = (base.empty() ? "Seed" : base) + " (" + std::to_string(k) + ")";
    }
    strlcpy(g_opts.seed, name.c_str(), sizeof g_opts.seed);
    if (!g_opts.rng) g_opts.rng = new_rng();
    char id[32];
    seed_id_encode(g_opts, id, sizeof id);
    std::string dir = std::string("rando/") + g_opts.seed;
    mkdir("rando", 0755);
    mkdir(dir.c_str(), 0755);
    if (FILE *idf = fopen((dir + "/seed_id.txt").c_str(), "w")) { fprintf(idf, "%s\n", id); fclose(idf); }
    static const char *logic[] = {"basic", "advanced", "glitched", "hell", "none"};
    static const char *ditems[] = {"none", "stone-beak", "mc", "mcb"};
    static const char *traps[] = {"none", "few", "several", "many", "trapsanity"};
    static const char *shell_excl[] = {
        "\"5-seashell-reward\", \"15-seashell-reward\", \"30-seashell-reward\", \"40-seashell-reward\", \"50-seashell-reward\"",
        "\"15-seashell-reward\", \"30-seashell-reward\", \"40-seashell-reward\", \"50-seashell-reward\"",
        "\"30-seashell-reward\", \"40-seashell-reward\", \"50-seashell-reward\"", "\"40-seashell-reward\", \"50-seashell-reward\"",
        "\"50-seashell-reward\"", ""};
    std::string req = dir + "/request.json";
    FILE *f = fopen(req.c_str(), "w");
    if (!f) { g_gen_status = "Cannot write " + req; g_gen_failed = true; return; }
    fprintf(f, "{\"seed\": \"%s\", \"logic\": \"%s\", \"dungeon-items\": \"%s\", \"traps\": \"%s\",\n", id,
            logic[g_opts.logic], ditems[g_opts.dungeon_items], traps[g_opts.traps]);
    fprintf(f, " \"shuffle-instruments\": %s, \"shuffle-dungeons\": %s, \"randomize-enemies\": %s, \"randomize-music\": %s,\n",
            g_opts.shuffle_instruments ? "true" : "false", g_opts.shuffle_dungeons ? "true" : "false",
            g_opts.randomize_enemies ? "true" : "false", g_opts.randomize_music ? "true" : "false");
    fprintf(f, " \"open-mabe\": %s, \"fast-songs\": %s, \"OHKO\": %s, \"boss-cutscenes\": %s, \"create-spoiler\": %s,\n",
            g_opts.open_mabe ? "true" : "false", g_opts.fast_songs ? "true" : "false", g_opts.ohko ? "true" : "false",
            g_opts.boss_cutscenes ? "true" : "false", g_opts.spoiler ? "true" : "false");
    fprintf(f, " \"starting-rupees\": %d, \"blur-removal\": false,\n", g_opts.start_rupees);
    fprintf(f, " \"pots\": %s, \"no-buff-drops\": %s, \"bushes\": %s,\n", g_opts.pots ? "true" : "false",
            g_opts.no_buffs ? "true" : "false", g_opts.bushes ? "true" : "false");
    fprintf(f, " \"include-fishing\": %s, \"include-rapids\": %s, \"include-dampe\": %s, \"include-trade-gifts\": %s,"
               " \"include-blue-rupees\": %s,\n", g_opts.inc_fishing ? "true" : "false", g_opts.inc_rapids ? "true" : "false",
            g_opts.inc_dampe ? "true" : "false", g_opts.inc_trade ? "true" : "false", g_opts.inc_blue ? "true" : "false");
    fprintf(f, " \"shuffle-bombs\": %s, \"unlocked-bombs\": %s, \"shuffle-powder\": %s,\n", g_opts.bomb_bag ? "true" : "false",
            g_opts.bomb_bag ? "false" : "true", g_opts.powder_bag ? "true" : "false");
    fprintf(f, " \"randomize-environments\": %s, \"bad-pets\": %s,\n", g_opts.environments ? "true" : "false",
            g_opts.pets_in_dungeons ? "true" : "false");
    fprintf(f, " \"skip-story-events\": %s, \"tunic-color\": \"%s\", \"enemy-minibosses\": %s,\n",
            g_opts.skip_story ? "true" : "false", kTunics[g_opts.tunic],
            g_opts.randomize_enemies && g_opts.enemy_minibosses ? "true" : "false");
    static const char *ks[] = {"off", "keys", "keys+nk", "all"};
    fprintf(f, " \"keysanity\": \"%s\",\n", ks[g_opts.keysanity]);
    static const char *rs[] = {"off", "coherent", "chaos", "madness"};
    fprintf(f, " \"dungeon-room-shuffle\": \"%s\",\n", rs[g_opts.room_shuffle]);
    fprintf(f, " \"entrance-tier\": %d, \"entrance-decoupled\": %s,\n", g_opts.entrances, g_opts.entrances >= 2 && g_opts.decoupled ? "true" : "false");
    fprintf(f, " \"include\": [\"5-seashell-reward\", \"15-seashell-reward\", \"30-seashell-reward\", \"40-seashell-reward\", \"50-seashell-reward\"],\n");
    fprintf(f, " \"exclude\": [%s]}\n", shell_excl[g_opts.seashells]);
    fclose(f);
    std::string log = dir + "/generate.log";
    std::string py = "third_party/LAS-Randomizer/" PLAT_VENV_PYTHON;
    std::string romfs = g_romfs_dir ? g_romfs_dir : "extracted/romfs";
    const char *argv[] = {py.c_str(), "tools/rando/las_headless.py", romfs.c_str(), dir.c_str(), req.c_str(), NULL};
    setenv("PYTHONHASHSEED", "0", 1);  // (set iteration order must not differ between runs: same ID, same seed)
    g_gen_pid = plat_spawn(argv, log.c_str(), false);
    int rc = !g_gen_pid;
    g_gen_seed = g_opts.seed;
    g_gen_failed = rc != 0;
    g_gen_status = rc ? "Could not start the generator (is the Python venv set up?)" : "Starting...";
    g_gen_frac = 0;
    g_gen_start = ImGui::GetTime();
    if (rc) g_gen_pid = 0;
}

static void poll_generation(void) {
    if (!g_gen_pid) return;
    std::string log = read_file("rando/" + g_gen_seed + "/generate.log");
    size_t p = log.rfind("\nstage ");  // `stage <fraction> <label>` lines from tools/rando/las_headless.py
    if (p != std::string::npos) {
        size_t e = log.find('\n', p + 1);
        std::string line = log.substr(p + 7, e == std::string::npos ? std::string::npos : e - p - 7);
        g_gen_frac = (float)atof(line.c_str());
        size_t sp = line.find(' ');
        if (sp != std::string::npos) g_gen_status = line.substr(sp + 1) + "...";
    }
    int st = plat_proc_wait(g_gen_pid, false);
    if (st >= 0) {
        g_gen_pid = 0;
        g_gen_failed = st != 0;
        g_gen_status = g_gen_failed ? "Generation failed: see rando/" + g_gen_seed + "/generate.log" : "Seed \"" + g_gen_seed + "\" ready.";
        g_scanned = false;
        g_opts.seed[0] = 0;
        g_opts.rng = new_rng();  // next seed: a fresh ID
    }
}

// ---- UI helpers (same look as the other tabs)
static float g_col;
static void label(const char *t) {
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(t);
    ImGui::SameLine(g_col);
    ImGui::SetNextItemWidth(-1);
}
static void combo(const char *t, int *v, const char *const *names, int n, bool enabled = true) {
    ImGui::PushID(t);
    ImGui::BeginDisabled(!enabled);
    label(t);
    if (ImGui::BeginCombo("##c", names[*v])) {
        for (int i = 0; i < n; i++)
            if (ImGui::Selectable(names[i], i == *v)) *v = i;
        ImGui::EndCombo();
    }
    if (enabled && ImGui::IsItemFocused()) {
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadRight) || ImGui::IsKeyPressed(ImGuiKey_RightArrow)) *v = (*v + 1) % n;
        if (ImGui::IsKeyPressed(ImGuiKey_GamepadDpadLeft) || ImGui::IsKeyPressed(ImGuiKey_LeftArrow)) *v = (*v + n - 1) % n;
    }
    ImGui::EndDisabled();
    ImGui::PopID();
}
static void section(const char *t) {
    ImGui::Spacing();
    ImGui::TextColored(ImVec4(0.93f, 0.76f, 0.33f, 1), "%s", t);
    ImGui::Separator();
}

bool spoiler_view_draw(const std::string &seed, float scale);  // spoiler_view.mm
static std::string g_spoiler_seed;  // seed whose spoiler page is open

extern "C" void rando_tab_draw(float scale) {
    (void)scale;
    if (!g_scanned) scan();
    static bool spoiler_test;  // LARECOMP_SPOILER_TEST=<seed>: open that seed's spoiler page (test hook)
    if (!spoiler_test && getenv("LARECOMP_SPOILER_TEST")) { spoiler_test = true; g_spoiler_seed = getenv("LARECOMP_SPOILER_TEST"); }
    if (!g_spoiler_seed.empty()) {  // the spoiler page replaces the tab until Back
        if (!spoiler_view_draw(g_spoiler_seed, scale)) g_spoiler_seed.clear();
        return;
    }
    static bool test_once;  // LARECOMP_RANDO_GEN_TEST=1: generate a seed as soon as the tab is shown (test hook)
    if (!test_once && getenv("LARECOMP_RANDO_GEN_TEST")) { test_once = true; strlcpy(g_opts.seed, "MenuTest", sizeof g_opts.seed); start_generation(); }
    poll_generation();
    g_col = ImGui::GetContentRegionAvail().x * 0.4f;
    const char *active = rando_seed_dir() ? rando_seed_dir() + 6 : NULL;

    ImGui::AlignTextToFramePadding();
    if (active) ImGui::Text("Playing seed:  %s", active);
    else ImGui::TextUnformatted("Playing:  Vanilla (no randomizer)");
    if (active) {
        ImGui::SameLine();
        if (ImGui::Button("Switch to vanilla")) {
            rando_select("");
            rt_request_reboot(RT_REBOOT_GAME);
        }
    }
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("Each seed has its own save files.");
    ImGui::PopTextWrapPos();

    ImGui::Checkbox("Show dungeon keys on the Items screen", &g_settings.inv_keys);
    if (ImGui::IsItemDeactivatedAfterEdit()) settings_save();
    ImGui::SameLine();
    ImGui::Checkbox("Check tracker on the Map screen", &g_settings.tracker);
    if (ImGui::IsItemDeactivatedAfterEdit()) settings_save();
    {  // room shuffle doorway letters on the dungeon map (runtime/ui/chaos_overlay.mm)
        static const char *letters[] = {"Off", "As you explore", "As you explore, all with the Map"};
        ImGui::AlignTextToFramePadding();
        ImGui::TextUnformatted("Dungeon map doorway letters");
        ImGui::SameLine();
        ImGui::SetNextItemWidth(360 * scale);
        if (ImGui::Combo("##chaos_letters", &g_settings.chaos_letters, letters, 3)) settings_save();
        if (ImGui::IsItemHovered())
            ImGui::SetTooltip("Chaos room shuffle: matching letters (A-A, B-B...) on the dungeon map show which doorways\n"
                              "connect. As you explore: a pair appears once you've walked through either end. All with the\n"
                              "Map: every pair of the dungeon once you have its Map.");
    }

    section("Seeds");
    if (g_seeds.empty()) ImGui::TextDisabled("No seeds yet: make one below.");
    if (ImGui::BeginTable("##seeds", 3, ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH)) {
        ImGui::TableSetupColumn("Seed", ImGuiTableColumnFlags_WidthStretch);
        ImGui::TableSetupColumn("Logic", ImGuiTableColumnFlags_WidthFixed, 180 * scale);
        ImGui::TableSetupColumn("", ImGuiTableColumnFlags_WidthFixed, 560 * scale);
        static std::string confirm_delete;  // seed whose Delete was pressed once (asks again before deleting)
        static std::string renaming;         // seed being renamed (inline text field)
        static char rename_buf[64];
        std::string rename_from, rename_to;
        std::string to_delete;
        for (size_t i = 0; i < g_seeds.size(); i++) {
            const Seed &s = g_seeds[i];
            ImGui::PushID((int)i);
            ImGui::TableNextRow();
            ImGui::TableNextColumn();
            ImGui::AlignTextToFramePadding();
            bool is_active = active && s.name == active;
            if (renaming == s.name) {
                ImGui::SetNextItemWidth(-1);
                if (ImGui::IsWindowAppearing() || !ImGui::IsAnyItemActive()) ImGui::SetKeyboardFocusHere();
                if (ImGui::InputText("##rename", rename_buf, sizeof rename_buf, ImGuiInputTextFlags_EnterReturnsTrue)) {
                    rename_from = s.name, rename_to = clean_name(rename_buf);
                }
                if (ImGui::IsKeyPressed(ImGuiKey_Escape)) renaming.clear();
            } else if (is_active) ImGui::TextColored(ImVec4(0.6f, 0.9f, 0.6f, 1), "%s  (playing)", s.name.c_str());
            else ImGui::TextUnformatted(s.name.c_str());
            if (!s.id.empty()) {
                ImGui::TextDisabled("%s", s.id.c_str());
                ImGui::SameLine();
                if (ImGui::SmallButton("Copy ID")) ImGui::SetClipboardText(s.id.c_str());
            }
            ImGui::TableNextColumn();
            ImGui::AlignTextToFramePadding();
            ImGui::TextUnformatted(s.logic.empty() ? "-" : s.logic.c_str());
            ImGui::TableNextColumn();
            if (!is_active && ImGui::Button("Play")) {
                rando_select(s.name.c_str());
                rt_request_reboot(RT_REBOOT_GAME);
            }
            ImGui::SameLine();
            if (ImGui::Button("Spoiler")) g_spoiler_seed = s.name;
            ImGui::SameLine();
            ImGui::BeginDisabled(is_active);  // (the game is reading its files)
            if (ImGui::Button("Rename")) { renaming = s.name; strlcpy(rename_buf, s.name.c_str(), sizeof rename_buf); }
            ImGui::EndDisabled();
            ImGui::SameLine();
            if (is_active) {
                ImGui::BeginDisabled();
                ImGui::Button("Delete");
                ImGui::EndDisabled();
                if (ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled))
                    ImGui::SetTooltip("Switch to another seed or vanilla first");
            } else if (confirm_delete == s.name) {
                ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.7f, 0.15f, 0.15f, 1));
                ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.85f, 0.2f, 0.2f, 1));
                if (ImGui::Button("Delete seed + saves")) to_delete = s.name;
                ImGui::PopStyleColor(2);
                ImGui::SameLine();
                if (ImGui::Button("Cancel")) confirm_delete.clear();
            } else if (ImGui::Button("Delete")) {
                confirm_delete = s.name;
            }
            ImGui::PopID();
        }
        ImGui::EndTable();
        if (!rename_from.empty()) {
            struct stat sb;
            std::string to = "rando/" + rename_to;
            if (rename_to.empty() || rename_to == rename_from) renaming.clear();
            else if (!stat(to.c_str(), &sb)) g_gen_status = "A seed named \"" + rename_to + "\" already exists.";
            else if (rename(("rando/" + rename_from).c_str(), to.c_str()) == 0) {
                // (seeds made before seed IDs name their spoiler after the folder)
                rename((to + "/spoiler_" + rename_from + ".txt").c_str(), (to + "/spoiler_" + rename_to + ".txt").c_str());
                LOG("[rando] renamed seed %s -> %s\n", rename_from.c_str(), rename_to.c_str());
                renaming.clear();
                scan();
            }
        }
        if (!to_delete.empty()) {
            delete_seed(to_delete);
            confirm_delete.clear();
            scan();
        }
    }

    section("New seed");
    static const char *logic[] = {"Basic (no tricks)", "Advanced (skews, bomb arrows)", "Glitched", "Hell", "None (may be unbeatable)"};
    static const char *ditems[] = {"Shuffled", "Start with stone beaks", "Start with maps + compasses", "Start with maps, compasses, beaks"};
    static const char *traps[] = {"None", "Few", "Several", "Many", "Trapsanity"};
    static const char *shells[] = {"None", "Up to 5", "Up to 15", "Up to 30", "Up to 40", "All (50)"};
    label("Seed name");
    ImGui::InputTextWithHint("##seed", "random name (yours to choose)", g_opts.seed, sizeof g_opts.seed);
    // Seed ID: shows the ID of the options below (+ this seed's random part); paste one to load a shared seed
    static char idbuf[48];
    static std::string id_msg;
    if (!g_opts.rng) g_opts.rng = new_rng();
    label("Seed ID");
    float bw = 150 * scale;
    ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x - 2 * bw - 2 * ImGui::GetStyle().ItemSpacing.x);
    bool editing = ImGui::InputTextWithHint("##seedid", "paste a shared seed ID", idbuf, sizeof idbuf,
                                            ImGuiInputTextFlags_CharsUppercase);
    bool active_id = ImGui::IsItemActive();
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Share this ID: with the same LAS Recomp version it makes exactly the same seed (items, options).\n"
                          "Paste someone's ID here to load their options, then Generate. The name is only your label.");
    if (editing) {
        GenOpts t = g_opts;
        id_msg = seed_id_decode(idbuf, t);
        if (id_msg.empty()) { g_opts.rng = t.rng; char keep[64]; strlcpy(keep, g_opts.seed, sizeof keep); g_opts = t;
                              strlcpy(g_opts.seed, keep, sizeof g_opts.seed); id_msg = "Loaded: options set from this ID."; }
    }
    if (!active_id) {  // follow the options
        char cur[48];
        seed_id_encode(g_opts, cur, sizeof cur);
        if (strcmp(cur, idbuf)) { strlcpy(idbuf, cur, sizeof idbuf); if (id_msg.rfind("Loaded", 0)) id_msg.clear(); }
    }
    ImGui::SameLine();
    if (ImGui::Button("Copy##id", ImVec2(bw, 0))) ImGui::SetClipboardText(idbuf);
    ImGui::SameLine();
    if (ImGui::Button("New ID", ImVec2(bw, 0))) { g_opts.rng = new_rng(); id_msg.clear(); }
    if (ImGui::IsItemHovered()) ImGui::SetTooltip("Same options, a different random seed.");
    if (!id_msg.empty()) {
        ImGui::SetCursorPosX(g_col);
        if (id_msg.rfind("Loaded", 0)) ImGui::TextColored(ImVec4(1, 0.5f, 0.4f, 1), "%s", id_msg.c_str());
        else ImGui::TextColored(ImVec4(0.6f, 0.9f, 0.6f, 1), "%s", id_msg.c_str());
    }
    combo("Logic", &g_opts.logic, logic, 5);
    combo("Dungeon items", &g_opts.dungeon_items, ditems, 4);
    static const char *ksn[] = {"Off (in their own dungeon)", "Small keys anywhere", "Small + Nightmare keys anywhere",
                                "All dungeon items anywhere"};
    combo("Keysanity", &g_opts.keysanity, ksn, 4);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Dungeon keys can be found anywhere in the world (with logic). A key always opens doors in the\n"
                          "dungeon it belongs to; the Items screen shows each dungeon's keys.");
    combo("Traps", &g_opts.traps, traps, 5);
    combo("Seashell Mansion rewards", &g_opts.seashells, shells, 6);
    if (ImGui::BeginTable("##opts", 2)) {
        struct { const char *n; bool *v; } o[] = {
            {"Shuffle instruments", &g_opts.shuffle_instruments}, {"Shuffle dungeons", &g_opts.shuffle_dungeons},
            {"Randomize enemies", &g_opts.randomize_enemies}, {"Randomize music", &g_opts.randomize_music},
            {"Open Mabe Village", &g_opts.open_mabe}, {"Fast songs", &g_opts.fast_songs},
            {"Boss cutscenes", &g_opts.boss_cutscenes}, {"Spoiler log", &g_opts.spoiler},
        };
        for (auto &x : o) { ImGui::TableNextColumn(); ImGui::Checkbox(x.n, x.v); }
        ImGui::EndTable();
    }
    // "Mini-bosses among overworld enemies" (enemy-minibosses): wired in LAS enemies.py, hidden until a mini-boss
    // actually fights outside its arena (they wait for their dungeon start event; notes/PLAN.md 2026-10-08)
    ImGui::Checkbox("Bombs must be found first", &g_opts.bomb_bag);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Bombs are an item in the pool; until you find them, shops don't sell bombs and none drop.");
    ImGui::SameLine();
    ImGui::Checkbox("Magic Powder must be found first", &g_opts.powder_bag);
    ImGui::Checkbox("Randomize environments", &g_opts.environments);
    if (ImGui::IsItemHovered()) ImGui::SetTooltip("Each area gets another area's lighting / atmosphere (cosmetic).");
    ImGui::SameLine();
    ImGui::Checkbox("Companions allowed in dungeons", &g_opts.pets_in_dungeons);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("BowWow, the Rooster etc. follow Link into dungeons; the logic then counts what they can do there\n"
                          "(e.g. the Rooster carrying Link over gaps).");
    ImGui::Checkbox("No Guardian Acorns / Pieces of Power", &g_opts.no_buffs);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Defeating enemies in a row never drops a Guardian Acorn or a Piece of Power.");
    ImGui::Checkbox("Skip story scenes", &g_opts.skip_story);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("No Owl talks and no kids running up about BowWow; their flags are set as if you'd seen them.");
    ImGui::SameLine();
    ImGui::SetNextItemWidth(220);
    ImGui::Combo("Tunic colour", &g_opts.tunic, kTunics, IM_ARRAYSIZE(kTunics));
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Recolours Link's green tunic and cap (cosmetic). The red and blue tunics keep their colours.");
    ImGui::TextDisabled("Extra checks (off = those spots give junk):");
    if (ImGui::BeginTable("##incl", 3)) {
        struct { const char *n; bool *v; const char *tip; } o[] = {
            {"Fishing prizes", &g_opts.inc_fishing, "Prizes of the fishing pond"},
            {"Rapids race prizes", &g_opts.inc_rapids, "Prizes of the Rapids Ride race"},
            {"Dampe's rewards", &g_opts.inc_dampe, "Chamber Dungeon challenge rewards"},
            {"Trade quest gifts", &g_opts.inc_trade, "Gifts from the trade quest NPCs"},
            {"Blue rupees", &g_opts.inc_blue, "Every hidden blue rupee holds an item"},
        };
        for (auto &x : o) {
            ImGui::TableNextColumn();
            ImGui::Checkbox(x.n, x.v);
            if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", x.tip);
        }
        ImGui::EndTable();
    }
    label("Starting rupees");
    ImGui::SliderInt("##rup", &g_opts.start_rupees, 0, 999, "%d", ImGuiSliderFlags_AlwaysClamp);

    ImGui::Checkbox("Pots hold items", &g_opts.pots);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Every liftable pot in houses, caves and dungeons hides an item from the pool (about 400 more checks).\n"
                          "Unchecked pots are golden. Lift, smash or throw a pot to reveal its item.");
    ImGui::SameLine();
    ImGui::Checkbox("Bushes hold items", &g_opts.bushes);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Every bush on the island hides an item from the pool (about 380 more checks; tall grass stays as it is).\n"
                          "Unchecked bushes are golden. Cut a bush to reveal its item.");
    static const char *ent[] = {"Off", "Dungeon entrances", "Dungeons + houses & caves"};
    combo("Entrance randomizer", &g_opts.entrances, ent, 3);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Houses & caves: the 43 single-entrance interiors are shuffled among themselves (with logic).\n"
                          "Marin & Tarin's house, water entrances and caves only reached through other caves stay vanilla.");
    ImGui::BeginDisabled(g_opts.entrances < 2);
    ImGui::Checkbox("Decoupled entrances", &g_opts.decoupled);
    if (ImGui::IsItemHovered()) ImGui::SetTooltip("Leaving a house puts you outside a different door than the one you came in by.");
    ImGui::EndDisabled();
    static const char *rshuf[] = {"Off", "Coherent", "Chaos", "Madness"};
    combo("Dungeon room shuffle", &g_opts.room_shuffle, rshuf, 4);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Rebuilds the dungeons (all but Eagle's Tower) from shuffled rooms. Boss, mini-boss, stairs and\n"
                          "other key rooms stay where they are.\n"
                          "Coherent: rooms connect north/south/east/west like they look and the dungeon map is right. To keep\n"
                          "every dungeon connected, a few rooms appear in two dungeons.\n"
                          "Chaos: any doorway can lead to any doorway of the dungeon. Every room is used once. Matching letters\n"
                          "(A-A, B-B...) appear on the dungeon map once you've been through a doorway, or all of them with the Map.\n"
                          "Madness: Chaos with one-way doorways - going back through the door you came in by takes you\n"
                          "somewhere else. Every room can still be reached and left.\n"
                          "The item logic follows the new layout (keys, locks, boss doors, one-way doors). Without keysanity\n"
                          "a dungeon's keys are inside that dungeon. Experimental: what a room needs to cross it (pits, water\n"
                          "inside the room) and what opens each shutter are approximated.");
    ImGui::Spacing();
    ImGui::TextDisabled("Experimental:");
    ImGui::BeginDisabled(!g_opts.randomize_enemies);
    ImGui::Checkbox("Mini-bosses among overworld enemies", &g_opts.enemy_minibosses);
    if (ImGui::IsItemHovered(ImGuiHoveredFlags_AllowWhenDisabled))
        ImGui::SetTooltip("Needs Randomize enemies. Some overworld enemies become mini-bosses (Hinox, Cue Ball, ...).\n"
                          "Known issue: they appear but don't fight yet (they wait for their dungeon room's start event).");
    ImGui::EndDisabled();
    ImGui::Spacing();
    ImGui::TextDisabled("In development: connector caves in the entrance pool, grass holds items.");
    ImGui::Spacing();
    ImGui::BeginDisabled(g_gen_pid != 0);
    if (ImGui::Button(g_gen_pid ? "Generating..." : "Generate seed", ImVec2(320 * scale, 0))) start_generation();
    ImGui::EndDisabled();
    if (g_gen_pid) {  // progress bar with the current step and elapsed time
        char over[160];
        int secs = (int)(ImGui::GetTime() - g_gen_start);
        snprintf(over, sizeof over, "%s  %d:%02d", g_gen_status.c_str(), secs / 60, secs % 60);
        ImGui::SameLine();
        ImGui::ProgressBar(g_gen_frac > 0.005f ? g_gen_frac : -0.3f * (float)ImGui::GetTime(), ImVec2(-1, 0), over);
    } else if (!g_gen_status.empty()) {
        ImGui::SameLine();
        ImGui::AlignTextToFramePadding();
        if (g_gen_failed) ImGui::TextColored(ImVec4(1, 0.5f, 0.4f, 1), "%s", g_gen_status.c_str());
        else ImGui::TextUnformatted(g_gen_status.c_str());
    }
}
