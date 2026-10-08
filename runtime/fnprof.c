// Function-entry profiler. LARECOMP_FNPROF=<from>:<to> counts guest function entries (every generated
// function calls FN_ENTER) between those presented frames, then writes build/fnprof.txt (addr count, most
// called first). Diffing two runs shows which game functions a change brings in; counts also show hot code.
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

#include "hle.h"

volatile int g_fnprof;

#define NSLOT (1 << 18)
static struct { _Atomic uint64_t addr; _Atomic uint64_t count; } slots[NSLOT];

void fnprof_hit(uint64_t a) {
    uint32_t h = (uint32_t)((a >> 2) * 0x9E3779B1u) & (NSLOT - 1);
    for (int n = 0; n < NSLOT; n++, h = (h + 1) & (NSLOT - 1)) {
        uint64_t cur = atomic_load_explicit(&slots[h].addr, memory_order_relaxed);
        if (cur == a || (cur == 0 && atomic_compare_exchange_strong(&slots[h].addr, &cur, a)) || cur == a) {
            atomic_fetch_add_explicit(&slots[h].count, 1, memory_order_relaxed);
            return;
        }
    }
}

static int cmp(const void *x, const void *y) {
    uint64_t a = ((const uint64_t *)x)[1], b = ((const uint64_t *)y)[1];
    return a < b ? 1 : a > b ? -1 : 0;
}

void fnprof_frame(uint64_t frame) {
    static long from = -2, to;
    if (from == -2) {
        from = -1;
        const char *e = getenv("LARECOMP_FNPROF");
        if (e && sscanf(e, "%ld:%ld", &from, &to) != 2) from = -1;
    }
    if (from < 0) return;
    if ((long)frame == from) { g_fnprof = 1; LOG("[fnprof] on at frame %llu\n", (unsigned long long)frame); }
    if ((long)frame != to) return;
    g_fnprof = 0;
    uint64_t (*rows)[2] = malloc(sizeof(uint64_t[2]) * NSLOT);
    int n = 0;
    for (int i = 0; i < NSLOT; i++)
        if (slots[i].addr) { rows[n][0] = slots[i].addr; rows[n][1] = slots[i].count; n++; }
    qsort(rows, n, sizeof rows[0], cmp);
    FILE *f = fopen("build/fnprof.txt", "w");
    for (int i = 0; f && i < n; i++) fprintf(f, "%llx %llu\n", (unsigned long long)rows[i][0], (unsigned long long)rows[i][1]);
    if (f) fclose(f);
    free(rows);
    LOG("[fnprof] %d functions, written build/fnprof.txt (frames %ld-%ld)\n", n, from, to);
    from = -1;
}
