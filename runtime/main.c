// LARecomp entry: load modules, set up the kernel, run nn::init::Start on the main thread.
#include <libgen.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <crt_externs.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <sys/mman.h>
#include <unistd.h>

#include "hle.h"
#include "kernel.h"

const char *g_romfs_dir;

// rtld normally passes these to nn::init::Start: run every module's init/fini arrays.
static void run_array(Cpu *c, uint64_t arr, uint64_t size) {
    for (uint64_t i = 0; i < size / 8; i++) {
        uint64_t fn = ((uint64_t *)arr)[i];
        if (fn) guest_call(c, fn);
    }
}

// nn::init::Start calls x2 right after nnosInitialize and x3 after nninitStartup, just before
// nnMain: SDK constructors run early, the game's run once nninitStartup has set up its heap.
// rtld runs a module's DT_INIT, which registers it (and its TLS template) with musl via
// __nnmusl_init_dso and then runs its init_array; fall back to the array if there is no DT_INIT.
static void module_init(Cpu *c, Module *m) {
    LOG("init %s (DT_INIT %llx, %llu init_array entries)\n", m->name, m->init, m->init_array_sz / 8);
    if (m->init) guest_call(c, m->init);
    else run_array(c, m->init_array, m->init_array_sz);
}

static void rtld_init_sdk(Cpu *c) { module_init(c, &g_modules[1]); }
static void rtld_init_main(Cpu *c) { module_init(c, &g_modules[0]); }

// Claim the guest address range before anything else can map there. The host allocator places
// regions at random addresses in the same window; on a collision, re-exec for a fresh layout.
__attribute__((constructor(101))) static void reserve_guest_space(void) {
    mach_vm_address_t a = GUEST_LO;
    if (mach_vm_allocate(mach_task_self(), &a, GUEST_HI - GUEST_LO, VM_FLAGS_FIXED) == KERN_SUCCESS) {
        // Everything readable/writable: macOS pages are 16K but the guest maps at 4K granularity.
        // Untouched pages cost nothing.
        return;
    }
    const char *tries = getenv("LARECOMP_REEXEC");
    int n = tries ? atoi(tries) : 0;
    if (n >= 20) {
        fprintf(stderr, "FATAL: guest address range %llx-%llx is not free\n", GUEST_LO, GUEST_HI);
        exit(1);
    }
    char buf[16];
    snprintf(buf, sizeof buf, "%d", n + 1);
    setenv("LARECOMP_REEXEC", buf, 1);
    char path[4096];
    uint32_t len = sizeof path;
    if (_NSGetExecutablePath(path, &len) == 0) execv(path, *_NSGetArgv());
    perror("re-exec");
    exit(1);
}

static char **g_argv;

// Restart the whole program (e.g. to switch randomizer seeds: game data is loaded at boot).
void rt_restart(void) {
    LOG("[main] restarting\n");
    fflush(stderr);
    execv(g_argv[0], g_argv);
    LOG("[main] restart failed\n");
}

// Back to the start screen (runtime/ui/launcher.mm): the same restart without --play / LARECOMP_NO_LAUNCHER.
void rt_restart_to_title(void) {
    static char *av[64];
    int n = 0;
    for (int i = 0; g_argv[i] && n < 63; i++)
        if (strcmp(g_argv[i], "--play")) av[n++] = g_argv[i];
    av[n] = NULL;
    unsetenv("LARECOMP_NO_LAUNCHER");
    LOG("[main] back to the title screen\n");
    fflush(stderr);
    execv(av[0], av);
    LOG("[main] restart failed\n");
}

int main(int argc, char **argv) {
    g_argv = argv;
    setvbuf(stderr, NULL, _IOLBF, 0);
    const char *root = "extracted";
    bool skip_launcher = getenv("LARECOMP_NO_LAUNCHER") || getenv("LARECOMP_INPUT");  // tests boot straight in
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--play")) skip_launcher = true;
        else if (argv[i][0] != '-') root = argv[i];
    }
    if (!skip_launcher) {  // start screen (runtime/ui/launcher.mm): game files setup, seed choice, settings
        extern void launcher_run(const char *root);
        launcher_run(root);
    }
    char exefs[1024], romfs[1024], npdm_path[1024];
    snprintf(exefs, sizeof exefs, "%s/exefs", root);
    snprintf(romfs, sizeof romfs, "%s/romfs", root);
    snprintf(npdm_path, sizeof npdm_path, "%s/main.npdm", exefs);
    g_romfs_dir = strdup(romfs);

    loader_load(exefs);
    kernel_init();
    dispatch_init();

    uint32_t stack_size = 0x100000;
    int prio = 44;
    FILE *f = fopen(npdm_path, "rb");
    if (f) {
        uint8_t meta[0x80];
        if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4)) {
            prio = meta[0xE];
            stack_size = *(uint32_t *)(meta + 0x1C);
        }
        fclose(f);
    }
    LOG("main thread: prio %d, stack 0x%x\n", prio, stack_size);

    uint64_t start = loader_find_symbol("_ZN2nn4init5StartEmmPFvvES2_");
    if (!start) FATAL("nn::init::Start not found\n");
    uint64_t init_fn = hle_register("<rtld_init_sdk>", rtld_init_sdk);
    uint64_t fini_fn = hle_register("<rtld_init_main>", rtld_init_main);
    KThread *t = kernel_create_main_thread(start, stack_size, prio);
    kernel_run_main(t, t->handle, 0, init_fn, fini_fn);  // nn::init::Start(thread_handle, args_region, init, fini)
    ui_run();  // window and input on the main thread; returns only when the window closes
    return 0;
}
