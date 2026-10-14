// Guest address -> recompiled function lookup, and host (HLE) function registry.
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "hle.h"

extern const uint64_t main_fn_addrs[], sdk_fn_addrs[];
extern const GuestFn main_fn_ptrs[], sdk_fn_ptrs[];
extern const uint64_t main_fn_count, sdk_fn_count;
// (weak: generated code from before gen.py emitted them, and the no-code stub, have none)
extern const uint64_t main_fn_ends[] __attribute__((weak)), sdk_fn_ends[] __attribute__((weak));
#ifdef GAME_ACNH
extern const uint64_t subsdk0_fn_addrs[];
extern const GuestFn subsdk0_fn_ptrs[];
extern const uint64_t subsdk0_fn_count;
extern const uint64_t subsdk0_fn_ends[] __attribute__((weak));
#define NTABLES 3
#else
#define NTABLES 2
#endif

// ends[i]: end of function i if it can be entered at any of its instructions (gen.py: all-instruction labels), else 0
typedef struct { const uint64_t *addrs; const GuestFn *fns; uint64_t count, lo, hi; const uint64_t *ends; } FnTable;
static FnTable tables[NTABLES];

// HLE stubs live at fake addresses HLE_BASE + 16*i
#define MAX_HLE 4096
typedef struct { const char *name; HostFn fn; } HleSlot;
static HleSlot hle_slots[MAX_HLE];
static int hle_count;

// Overrides of recompiled guest functions (by address)
#define MAX_OVERRIDE 1024
static struct { uint64_t addr; HostFn fn; const char *name; } overrides[MAX_OVERRIDE];
static int override_count;

// Host implementations registered by name (runtime/hle/*.c fill this via HLE_FUNC)
typedef struct { const char *name; HostFn fn; } HleImpl;
#ifdef __APPLE__
extern const HleImpl __start_hle_impls[] __asm__("section$start$__DATA$__hle_impls");
extern const HleImpl __stop_hle_impls[] __asm__("section$end$__DATA$__hle_impls");
#elif defined(__linux__)
extern const HleImpl __start_hle_impls[], __stop_hle_impls[];  // (ELF: defined by the linker)
#else
// PE/COFF: the linker sorts .hle$a < .hle$m (entries, hle.h) < .hle$z by the text after '$'.
__attribute__((section(".hle$a"), used)) static const HleImpl __start_hle_impls[1];
__attribute__((section(".hle$z"), used)) static const HleImpl __stop_hle_impls[1];
#endif

HostFn hle_lookup_impl(const char *name) {
    const char *skip = getenv("LARECOMP_HLE_SKIP");  // debugging: disable HLE for names containing this
    if (skip && strstr(name, skip)) return NULL;
    const HleImpl *start = __start_hle_impls, *stop = __stop_hle_impls;
    __asm__("" : "+r"(start), "+r"(stop));  // separate objects: keep the compiler from reasoning about them
    for (const HleImpl *p = start; p < stop; p++)
        if (p->name && !strcmp(p->name, name)) return p->fn;
    return NULL;
}

static void hle_unimplemented(Cpu *c);

uint64_t hle_register(const char *name, HostFn fn) {
    for (int i = 0; i < hle_count; i++)
        if (!strcmp(hle_slots[i].name, name)) return HLE_BASE + 16ull * i;
    if (hle_count == MAX_HLE) FATAL("too many HLE stubs\n");
    hle_slots[hle_count].name = strdup(name);
    hle_slots[hle_count].fn = fn;
    return HLE_BASE + 16ull * hle_count++;
}

void hle_override(uint64_t addr, HostFn fn, const char *name) {
    if (override_count == MAX_OVERRIDE) FATAL("too many overrides\n");
    overrides[override_count].addr = addr;
    overrides[override_count].fn = fn;
    overrides[override_count].name = name;
    override_count++;
}

static __thread uint64_t unimpl_pc;
static int unimpl_counts[MAX_HLE];
static void hle_unimplemented(Cpu *c) {
    int i = (int)((unimpl_pc - HLE_BASE) / 16);
    if (unimpl_counts[i]++ < 3)
        LOG("[hle] UNIMPLEMENTED %s (x0=%llx x1=%llx lr=%llx) -> returning 0\n", hle_slots[i].name, c->x[0],
            c->x[1], c->x[30]);
    c->x[0] = 0;
}

uint64_t guest_sym(const char *name) {
    // small cache: callers pass string literals, so pointer identity is a good key
    static struct { const char *name; uint64_t addr; } cache[64];
    static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&m);
    for (int i = 0; i < 64 && cache[i].name; i++)
        if (cache[i].name == name) { uint64_t a = cache[i].addr; pthread_mutex_unlock(&m); return a; }
    pthread_mutex_unlock(&m);
    uint64_t a = loader_find_symbol(name);
    if (!a) FATAL("guest symbol %s not found\n", name);
    pthread_mutex_lock(&m);
    for (int i = 0; i < 64; i++) if (!cache[i].name) { cache[i].name = name; cache[i].addr = a; break; }
    pthread_mutex_unlock(&m);
    return a;
}

static uint64_t hle_next = HLE_HEAP;
RT_ON_RESET(hle_heap_reset) { hle_next = HLE_HEAP; }  // (guest memory, wiped by the reboot)

void *hle_alloc(uint64_t size) {
    static pthread_mutex_t m = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&m);
    uint64_t a = hle_next;
    hle_next += (size + 63) & ~63ull;
    if (hle_next > HLE_HEAP + HLE_HEAP_SIZE) FATAL("HLE heap exhausted\n");
    pthread_mutex_unlock(&m);
    plat_commit(a, size);
    memset((void *)a, 0, size);
    return (void *)a;
}

void dispatch_init(void) {
    tables[0] = (FnTable){main_fn_addrs, main_fn_ptrs, main_fn_count, main_fn_addrs[0], main_fn_addrs[main_fn_count - 1],
                          main_fn_ends};
    tables[1] = (FnTable){sdk_fn_addrs, sdk_fn_ptrs, sdk_fn_count, sdk_fn_addrs[0], sdk_fn_addrs[sdk_fn_count - 1],
                          sdk_fn_ends};
#ifdef GAME_ACNH
    tables[2] = (FnTable){subsdk0_fn_addrs, subsdk0_fn_ptrs, subsdk0_fn_count, subsdk0_fn_addrs[0],
                          subsdk0_fn_addrs[subsdk0_fn_count - 1], subsdk0_fn_ends};
#endif
}

GuestFn dispatch_lookup(uint64_t addr) {
    for (int t = 0; t < NTABLES; t++) {
        FnTable *ft = &tables[t];
        if (addr < ft->lo || addr > ft->hi) continue;
        uint64_t lo = 0, hi = ft->count;
        while (lo < hi) {
            uint64_t mid = (lo + hi) / 2;
            if (ft->addrs[mid] < addr) lo = mid + 1;
            else hi = mid;
        }
        if (lo < ft->count && ft->addrs[lo] == addr) return ft->fns[lo];
    }
    return NULL;
}

// The function containing addr, if it can be entered there (see FnTable.ends).
static GuestFn dispatch_inside(uint64_t addr) {
    for (int t = 0; t < NTABLES; t++) {
        FnTable *ft = &tables[t];
        if (!ft->ends || addr < ft->lo || addr & 3) continue;
        uint64_t lo = 0, hi = ft->count;  // last function starting at or below addr
        while (lo < hi) {
            uint64_t mid = (lo + hi) / 2;
            if (ft->addrs[mid] <= addr) lo = mid + 1;
            else hi = mid;
        }
        if (lo && addr < ft->ends[lo - 1]) return ft->fns[lo - 1];
    }
    return NULL;
}

// Small direct-mapped cache in front of the binary search
#define DCACHE 4096
static __thread struct { uint64_t addr; GuestFn fn; } dcache[DCACHE];

static GuestFn dispatch_slow(Cpu *c) {
    uint64_t pc = c->pc;
    if (pc >= HLE_BASE && pc < HLE_BASE + HLE_SIZE) {
        rt_unwind_point();  // (HLE calls aren't cached below, so every one passes here: a reboot's safe point)
        int i = (int)((pc - HLE_BASE) / 16);
        if (i < hle_count) {
            if (ENV("LARECOMP_TRACE_HLE")) {  // first call of each host function (NVN entry points, SDK HLE)
                static _Atomic unsigned char seen[MAX_HLE];
                if (!seen[i] && (seen[i] = 1)) LOG("[hle] first call %s (lr=%llx x0=%llx x1=%llx)\n", hle_slots[i].name, c->x[30], c->x[0], c->x[1]);
            }
            if (hle_slots[i].fn) return hle_slots[i].fn;
            unimpl_pc = pc;
            return hle_unimplemented;
        }
    }
    for (int i = 0; i < override_count; i++)
        if (overrides[i].addr == pc) return overrides[i].fn;
    GuestFn f = dispatch_lookup(pc);
    if (!f && (f = dispatch_inside(pc))) {
        // an unresolved table jump into another function's body (a function split in two by the generator): enter
        // it at its label switch. Not cached: each entry needs mid_entry set.
        static int nlog;
        if (nlog < 20) { nlog++; LOG("[dispatch] mid-function entry %llx (lr=%llx)\n", pc, c->x[30]); }
        c->mid_entry = 1;
        return f;
    }
    if (!f) {
        uint64_t off;
        const char *s = loader_symbol_at(c->x[30], &off);
        FATAL("no function at %llx (lr=%llx %s+%llx)\n", pc, c->x[30], s ? s : "?", off);
    }
    unsigned h = (unsigned)(pc >> 2) & (DCACHE - 1);
    dcache[h].addr = pc;
    dcache[h].fn = f;
    return f;
}

// Always tail-calls, so chains of indirect jumps don't grow the host stack.
void rt_dispatch(Cpu *c) {
    unsigned h = (unsigned)(c->pc >> 2) & (DCACHE - 1);
    GuestFn f = dcache[h].addr == c->pc ? dcache[h].fn : dispatch_slow(c);
    __attribute__((musttail)) return f(c);
}

void guest_call(Cpu *c, uint64_t addr) {
    uint64_t lr = c->x[30];
    c->x[30] = 0;
    c->pc = addr;
    rt_dispatch(c);
    c->x[30] = lr;
}

// Host pc -> recompiled guest function containing it ("f_<addr>"), for hosts without symbol lookup.
static int cmp_host(const void *a, const void *b) {
    uint64_t x = ((const uint64_t *)a)[0], y = ((const uint64_t *)b)[0];
    return x < y ? -1 : x > y;
}
const char *rt_host_fn_name(uint64_t pc, uint64_t *offset) {
    static uint64_t (*byhost)[2];  // {host address, guest address}, sorted by host address
    static uint64_t n;
    static __thread char name[32];
    if (!byhost) {
        uint64_t total = 0, k = 0;
        for (int t = 0; t < NTABLES; t++) total += tables[t].count;
        uint64_t (*v)[2] = malloc(total * sizeof *v);
        if (!v) return NULL;
        for (int t = 0; t < NTABLES; t++)
            for (uint64_t i = 0; i < tables[t].count; i++) {
                v[k][0] = (uint64_t)(uintptr_t)tables[t].fns[i];
                v[k++][1] = tables[t].addrs[i];
            }
        qsort(v, k, sizeof *v, cmp_host);
        n = k;
        byhost = v;
    }
    uint64_t lo = 0, hi = n;  // last entry with host address <= pc
    while (lo < hi) {
        uint64_t mid = (lo + hi) / 2;
        if (byhost[mid][0] <= pc) lo = mid + 1;
        else hi = mid;
    }
    if (!lo || pc - byhost[lo - 1][0] > 0x100000) return NULL;
    snprintf(name, sizeof name, "f_%llx", (unsigned long long)byhost[lo - 1][1]);
    if (offset) *offset = pc - byhost[lo - 1][0];
    return name;
}

static const char *host_sym(uint64_t pc, uint64_t *offset) {
    const char *s = plat_symbol(pc, offset);
    return s ? s : rt_host_fn_name(pc, offset);
}

void rt_fatal_trace(void) {
    fprintf(stderr, "host backtrace (guest functions are f_<addr>):\n");
    plat_print_backtrace();
    Cpu *c = kernel_current_cpu();
    if (c) {
        fprintf(stderr, "guest: sp=%llx lr=%llx\n", c->sp, c->x[30]);
        for (int i = 0; i < 31; i += 4)
            fprintf(stderr, "  x%-2d %016llx  x%-2d %016llx  x%-2d %016llx  x%-2d %016llx\n", i, c->x[i], i + 1,
                    c->x[i + 1], i + 2, c->x[i + 2], i + 3, c->x[i + 3]);
    }
    plat_fatal_notice();
    // our crash handler also catches SIGABRT: without this abort() re-entered it forever (a 5 GB log)
    signal(SIGABRT, SIG_DFL);
    abort();
}

void rt_udf(Cpu *c, uint64_t pc) {
    (void)c;
    FATAL("undefined instruction / trap at %llx\n", pc);
}

void rt_brk(Cpu *c, uint32_t imm, uint64_t pc) {
    (void)c;
    FATAL("brk #%u at %llx\n", imm, pc);
}

// ---- crash reporting

// Debug data watchpoint (LARECOMP_WATCH=<lo>,<hi>, or set by debug code): the page holding lo is protected. An access
// to it faults; the page is opened and the faulting instruction single-stepped (plat: trap flag), then the page is
// closed again. A change to the 16 bytes at lo is logged with the host code that made it and the guest return address.
uint64_t g_watch_lo, g_watch_hi;
static uint64_t watch_page, watch_size;  // (every page of [lo, hi))
static uint64_t watch_val[2], watch_fa, watch_fa_val;
static pthread_mutex_t watch_lock = PTHREAD_MUTEX_INITIALIZER;  // (one access in flight: others wait in the fault)
static void *watch_thread(void *a) {
    (void)a;
    // Kept closed: committing the page (lazily, on first touch) or remapping the heap opens it again.
    for (bool said = false;; usleep(1000)) {
        pthread_mutex_lock(&watch_lock);  // (never in the middle of a single-stepped access)
        int r = plat_protect(watch_page, watch_size, PLAT_PROT_NONE);
        pthread_mutex_unlock(&watch_lock);
        if (r == 0 && !said) fprintf(stderr, "[watch] page %llx protected\n", (unsigned long long)watch_page), said = true;
    }
    return NULL;
}
void watch_arm(void) {
    if (!g_watch_lo || watch_page) return;
    watch_page = g_watch_lo & ~(PLAT_PAGE - 1);
    watch_size = ((g_watch_hi + PLAT_PAGE - 1) & ~(PLAT_PAGE - 1)) - watch_page;
    pthread_t t;
    pthread_create(&t, NULL, watch_thread, NULL);
}

// An access fault in the watched page: open it for this one instruction (true: single-step it).
bool rt_fault_watch(uint64_t fa, uint64_t pc) {
    (void)pc;
    if (!watch_page || fa < watch_page || fa >= watch_page + watch_size) return false;
#ifdef _WIN32
    pthread_mutex_lock(&watch_lock);
    plat_protect(watch_page, watch_size, PLAT_PROT_RW);
    memcpy(watch_val, (void *)(uintptr_t)g_watch_lo, sizeof watch_val);
    watch_fa = fa & ~7ull;
    watch_fa_val = *(uint64_t *)(uintptr_t)watch_fa;
#else  // (no single-step there: the page just opens; accesses after this one go unseen)
    plat_protect(watch_page, watch_size, PLAT_PROT_RW);
#endif
    return true;
}
// The instruction at pc has run: log a change, close the page.
void rt_watch_stepped(uint64_t pc) {
    uint64_t v[2];
    memcpy(v, (void *)(uintptr_t)g_watch_lo, sizeof v);
    {   // anywhere in the page: a store that leaves a pointer 0x6x_xxxx_xxxx (heap pointers are 0x72...)
        uint64_t nv = *(uint64_t *)(uintptr_t)watch_fa;
        if (nv != watch_fa_val && (nv >> 36) == 6) {
            uint64_t off = 0;
            const char *nm = host_sym(pc, &off);
            Cpu *c = kernel_current_cpu();
            fprintf(stderr, "[watch] %llx: %llx -> %llx by %s+%llx (guest lr %llx)\n", (unsigned long long)watch_fa,
                    (unsigned long long)watch_fa_val, (unsigned long long)nv, nm ? nm : "?", (unsigned long long)off,
                    c ? (unsigned long long)c->x[30] : 0ull);
            if (c) for (int i = 0; i < 31; i += 4)
                fprintf(stderr, "    x%d %llx x%d %llx x%d %llx x%d %llx\n", i, (unsigned long long)c->x[i], i + 1,
                        (unsigned long long)c->x[i + 1], i + 2, (unsigned long long)c->x[i + 2], i + 3,
                        (unsigned long long)(i + 3 < 31 ? c->x[i + 3] : c->sp));
        }
    }
    if (memcmp(v, watch_val, sizeof v)) {
        uint64_t off = 0;
        const char *nm = host_sym(pc, &off);
        Cpu *c = kernel_current_cpu();
        fprintf(stderr, "[watch] %llx: %llx %llx -> %llx %llx by %s+%llx (guest lr %llx, x0 %llx)\n", (unsigned long long)g_watch_lo,
                (unsigned long long)watch_val[0], (unsigned long long)watch_val[1], (unsigned long long)v[0], (unsigned long long)v[1],
                nm ? nm : "?", (unsigned long long)off, c ? (unsigned long long)c->x[30] : 0ull, c ? (unsigned long long)c->x[0] : 0ull);
    }
    plat_protect(watch_page, watch_size, PLAT_PROT_NONE);
    pthread_mutex_unlock(&watch_lock);
}

void rt_fault_report(const char *what, uint64_t fa, uint64_t pc, uint64_t lr) {
    uint64_t po = 0, lo = 0;
    const char *ps = host_sym(pc, &po), *ls = host_sym(lr, &lo);
    fprintf(stderr, "\n*** %s accessing %#llx\n    host pc %llx (%s+%llx)\n    host lr %llx (%s)\n", what,
            (unsigned long long)fa, (unsigned long long)pc, ps ? ps : "?", (unsigned long long)po,
            (unsigned long long)lr, ls ? ls : "?");
    rt_fatal_trace();
}

void crash_handler_install(void) {
    plat_crash_handler_install();
    // LARECOMP_WATCH=<lo>,<hi> (hex guest addresses): log each function that touches [lo, hi), from the start
    unsigned long long lo, hi;
    const char *e = getenv("LARECOMP_WATCH");
    if (e && sscanf(e, "%llx,%llx", &lo, &hi) == 2 && lo < hi) { g_watch_lo = lo, g_watch_hi = hi; watch_arm(); }
}
