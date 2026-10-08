// Randomizer tab: choose / generate LAS-Randomizer seeds (rando/<seed>/). Switching seeds restarts the game
// (game data is read at boot); each seed keeps its own save slots.
#include <dirent.h>
#include <ftw.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <string>
#include <vector>
#include <algorithm>

#include "imgui.h"

extern "C" {
#include "../hle.h"
#include "../rando.h"
#include "../settings.h"
void rt_restart(void);
extern const char *g_romfs_dir;
extern char **environ;
}

struct Seed { std::string name, logic, spoiler; long mtime; };
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
static int rm_entry(const char *path, const struct stat *, int, struct FTW *) { return remove(path); }
static bool delete_seed(const std::string &name) {
    if (name.empty() || name == "." || name == ".." || name.find('/') != std::string::npos) return false;
    std::string dir = "rando/" + name;
    bool ok = nftw(dir.c_str(), rm_entry, 16, FTW_DEPTH | FTW_PHYS) == 0;
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
        s.spoiler = dir + "/spoiler_" + s.name + ".txt";
        g_seeds.push_back(s);
    }
    closedir(d);
    std::sort(g_seeds.begin(), g_seeds.end(), [](const Seed &a, const Seed &b) { return a.mtime > b.mtime; });
    g_scanned = true;
}

// ---- generation (background process)
static pid_t g_gen_pid;
static std::string g_gen_seed, g_gen_status;
static float g_gen_frac;
static double g_gen_start;
static bool g_gen_failed;

static const char *const kTunics[] = {"default", "random", "Purple", "Orange", "Yellow", "Pink", "Teal", "Sky",
                                      "Brown", "Black", "White", "Grey", "Lime", "Magenta"};

struct GenOpts {
    char seed[64] = "";
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
    // planned (LARecomp additions, not implemented yet)
    int entrances = 0;        // off / dungeons / ...
    bool decoupled = false, pots = false, grass = false;
};
static GenOpts g_opts;

static const char *ADJ[] = {"Sleepy", "Brave", "Lucky", "Rapid", "Quiet", "Golden", "Wild", "Secret", "Dreamy", "Mighty"};
static const char *NOUN[] = {"Marin", "Tarin", "Owl", "Cucco", "BowWow", "Moblin", "Zora", "Shell", "WindFish", "Toadstool"};

static void random_seed_name(char *out, size_t n) {
    snprintf(out, n, "%s%s%d", ADJ[arc4random_uniform(10)], NOUN[arc4random_uniform(10)], (int)arc4random_uniform(1000));
}

static void start_generation(void) {
    if (!g_opts.seed[0]) random_seed_name(g_opts.seed, sizeof g_opts.seed);
    for (char *p = g_opts.seed; *p; p++)
        if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z') || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_')) *p = '_';
    std::string dir = std::string("rando/") + g_opts.seed;
    mkdir("rando", 0755);
    mkdir(dir.c_str(), 0755);
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
    fprintf(f, "{\"seed\": \"%s\", \"logic\": \"%s\", \"dungeon-items\": \"%s\", \"traps\": \"%s\",\n", g_opts.seed,
            logic[g_opts.logic], ditems[g_opts.dungeon_items], traps[g_opts.traps]);
    fprintf(f, " \"shuffle-instruments\": %s, \"shuffle-dungeons\": %s, \"randomize-enemies\": %s, \"randomize-music\": %s,\n",
            g_opts.shuffle_instruments ? "true" : "false", g_opts.shuffle_dungeons ? "true" : "false",
            g_opts.randomize_enemies ? "true" : "false", g_opts.randomize_music ? "true" : "false");
    fprintf(f, " \"open-mabe\": %s, \"fast-songs\": %s, \"OHKO\": %s, \"boss-cutscenes\": %s, \"create-spoiler\": %s,\n",
            g_opts.open_mabe ? "true" : "false", g_opts.fast_songs ? "true" : "false", g_opts.ohko ? "true" : "false",
            g_opts.boss_cutscenes ? "true" : "false", g_opts.spoiler ? "true" : "false");
    fprintf(f, " \"starting-rupees\": %d, \"blur-removal\": false,\n", g_opts.start_rupees);
    fprintf(f, " \"pots\": %s,\n", g_opts.pots ? "true" : "false");
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
    fprintf(f, " \"entrance-tier\": %d, \"entrance-decoupled\": %s,\n", g_opts.entrances, g_opts.entrances >= 2 && g_opts.decoupled ? "true" : "false");
    fprintf(f, " \"include\": [\"5-seashell-reward\", \"15-seashell-reward\", \"30-seashell-reward\", \"40-seashell-reward\", \"50-seashell-reward\"],\n");
    fprintf(f, " \"exclude\": [%s]}\n", shell_excl[g_opts.seashells]);
    fclose(f);
    std::string log = dir + "/generate.log";
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, 1, log.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0644);
    posix_spawn_file_actions_adddup2(&fa, 1, 2);
    std::string py = "third_party/LAS-Randomizer/venv/bin/python";
    std::string romfs = g_romfs_dir ? g_romfs_dir : "extracted/romfs";
    const char *argv[] = {py.c_str(), "tools/rando/las_headless.py", romfs.c_str(), dir.c_str(), req.c_str(), NULL};
    int rc = posix_spawn(&g_gen_pid, py.c_str(), &fa, NULL, (char *const *)argv, environ);
    posix_spawn_file_actions_destroy(&fa);
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
    int st;
    if (waitpid(g_gen_pid, &st, WNOHANG) == g_gen_pid) {
        g_gen_pid = 0;
        g_gen_failed = !(WIFEXITED(st) && WEXITSTATUS(st) == 0);
        g_gen_status = g_gen_failed ? "Generation failed: see rando/" + g_gen_seed + "/generate.log" : "Seed \"" + g_gen_seed + "\" ready.";
        g_scanned = false;
        g_opts.seed[0] = 0;
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
        if (ImGui::Button("Switch to vanilla (restarts)")) {
            g_settings.rando_seed[0] = 0;
            settings_save();
            rt_restart();
        }
    }
    ImGui::PushTextWrapPos(0);
    ImGui::TextDisabled("Each seed has its own save files. Randomizer by Owen-Splat and contributors (LAS-Randomizer).");
    ImGui::PopTextWrapPos();

    ImGui::Checkbox("Show dungeon keys on the Items screen", &g_settings.inv_keys);
    if (ImGui::IsItemDeactivatedAfterEdit()) settings_save();
    ImGui::SameLine();
    ImGui::Checkbox("Check tracker on the Map screen", &g_settings.tracker);
    if (ImGui::IsItemDeactivatedAfterEdit()) settings_save();

    section("Seeds");
    if (g_seeds.empty()) ImGui::TextDisabled("No seeds yet: make one below.");
    if (ImGui::BeginTable("##seeds", 3, ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH)) {
        ImGui::TableSetupColumn("Seed", ImGuiTableColumnFlags_WidthStretch);
        ImGui::TableSetupColumn("Logic", ImGuiTableColumnFlags_WidthFixed, 180 * scale);
        ImGui::TableSetupColumn("", ImGuiTableColumnFlags_WidthFixed, 560 * scale);
        static std::string confirm_delete;  // seed whose Delete was pressed once (asks again before deleting)
        std::string to_delete;
        for (size_t i = 0; i < g_seeds.size(); i++) {
            const Seed &s = g_seeds[i];
            ImGui::PushID((int)i);
            ImGui::TableNextRow();
            ImGui::TableNextColumn();
            ImGui::AlignTextToFramePadding();
            bool is_active = active && s.name == active;
            if (is_active) ImGui::TextColored(ImVec4(0.6f, 0.9f, 0.6f, 1), "%s  (playing)", s.name.c_str());
            else ImGui::TextUnformatted(s.name.c_str());
            ImGui::TableNextColumn();
            ImGui::AlignTextToFramePadding();
            ImGui::TextUnformatted(s.logic.empty() ? "-" : s.logic.c_str());
            ImGui::TableNextColumn();
            if (!is_active && ImGui::Button("Play (restarts)")) {
                strlcpy(g_settings.rando_seed, s.name.c_str(), sizeof g_settings.rando_seed);
                settings_save();
                rt_restart();
            }
            ImGui::SameLine();
            if (ImGui::Button("Spoiler")) g_spoiler_seed = s.name;
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
    ImGui::InputTextWithHint("##seed", "random", g_opts.seed, sizeof g_opts.seed);
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
            {"One-hit KO", &g_opts.ohko}, {"Boss cutscenes", &g_opts.boss_cutscenes}, {"Spoiler log", &g_opts.spoiler},
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

    section("LARecomp additions");
    ImGui::Checkbox("Pots hold items", &g_opts.pots);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Every liftable pot in houses, caves and dungeons hides an item from the pool (about 400 more checks).\n"
                          "Unchecked pots are golden. Lift, smash or throw a pot to reveal its item.");
    static const char *ent[] = {"Off", "Dungeon entrances", "Dungeons + houses & caves"};
    combo("Entrance randomizer", &g_opts.entrances, ent, 3);
    if (ImGui::IsItemHovered())
        ImGui::SetTooltip("Houses & caves: the 43 single-entrance interiors are shuffled among themselves (with logic).\n"
                          "Marin & Tarin's house, water entrances and caves only reached through other caves stay vanilla.");
    ImGui::BeginDisabled(g_opts.entrances < 2);
    ImGui::Checkbox("Decoupled entrances", &g_opts.decoupled);
    if (ImGui::IsItemHovered()) ImGui::SetTooltip("Leaving a house puts you outside a different door than the one you came in by.");
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
