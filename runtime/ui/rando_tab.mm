// Randomizer tab: choose / generate LAS-Randomizer seeds (rando/<seed>/). Switching seeds restarts the game
// (game data is read at boot); each seed keeps its own save slots.
#include <dirent.h>
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
static bool g_gen_failed;

struct GenOpts {
    char seed[64] = "";
    int logic = 0;            // basic advanced glitched hell none
    int dungeon_items = 3;    // none stone-beak mc mcb
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
    g_gen_status = rc ? "Could not start the generator (is the Python venv set up?)" : "Shuffling items...";
    if (rc) g_gen_pid = 0;
}

static void poll_generation(void) {
    if (!g_gen_pid) return;
    std::string log = read_file("rando/" + g_gen_seed + "/generate.log");
    size_t p = log.rfind("progress ");
    if (log.find("placements ready") != std::string::npos)
        g_gen_status = p != std::string::npos ? "Building game files... " + log.substr(p + 9, log.find('\n', p) - p - 9) + " / 257"
                                              : "Building game files...";
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

extern "C" void rando_tab_draw(float scale) {
    (void)scale;
    if (!g_scanned) scan();
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

    section("Seeds");
    if (g_seeds.empty()) ImGui::TextDisabled("No seeds yet: make one below.");
    if (ImGui::BeginTable("##seeds", 3, ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH)) {
        ImGui::TableSetupColumn("Seed", ImGuiTableColumnFlags_WidthStretch);
        ImGui::TableSetupColumn("Logic", ImGuiTableColumnFlags_WidthFixed, 180 * scale);
        ImGui::TableSetupColumn("", ImGuiTableColumnFlags_WidthFixed, 360 * scale);
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
            if (ImGui::Button("Spoiler")) {
                std::string cmd = "open \"" + s.spoiler + "\"";
                system(cmd.c_str());
            }
            ImGui::PopID();
        }
        ImGui::EndTable();
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
    label("Starting rupees");
    ImGui::SliderInt("##rup", &g_opts.start_rupees, 0, 999, "%d", ImGuiSliderFlags_AlwaysClamp);

    section("LARecomp additions (in development)");
    static const char *ent[] = {"Off", "Dungeon entrances", "+ Single-exit interiors", "+ Connectors / caves", "Full"};
    combo("Entrance randomizer", &g_opts.entrances, ent, 5, false);
    ImGui::BeginDisabled(true);
    ImGui::Checkbox("Decoupled entrances", &g_opts.decoupled); ImGui::SameLine();
    ImGui::Checkbox("Pots hold items", &g_opts.pots); ImGui::SameLine();
    ImGui::Checkbox("Grass holds items", &g_opts.grass);
    ImGui::EndDisabled();

    ImGui::Spacing();
    ImGui::BeginDisabled(g_gen_pid != 0);
    if (ImGui::Button(g_gen_pid ? "Generating..." : "Generate seed", ImVec2(320 * scale, 0))) start_generation();
    ImGui::EndDisabled();
    if (!g_gen_status.empty()) {
        ImGui::SameLine();
        ImGui::AlignTextToFramePadding();
        if (g_gen_failed) ImGui::TextColored(ImVec4(1, 0.5f, 0.4f, 1), "%s", g_gen_status.c_str());
        else ImGui::TextUnformatted(g_gen_status.c_str());
    }
}
