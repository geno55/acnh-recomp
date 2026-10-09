// Registration of host implementations for guest symbols.
#pragma once
#include <stdlib.h>
// Environment lookups that run every frame / per call: looked up once per call site (the variables don't change
// while the game runs). ENV("LARECOMP_X") -> const char * or NULL.
#define ENV(name) ({ static const char *env_v_; static int env_i_; if (!env_i_) { env_v_ = getenv(name); env_i_ = 1; } env_v_; })

#include "rt.h"

typedef struct { const char *name; HostFn fn; } HleImplEntry;

// HLE_FUNC("mangled_symbol", c_function) binds a guest import to a host function.
#define HLE_CAT2(a, b) a##b
#define HLE_CAT(a, b) HLE_CAT2(a, b)
#define HLE_FUNC(sym, fn)                                                                   \
    static void fn(Cpu *c);                                                                 \
    __attribute__((used, section("__DATA,__hle_impls"))) static const HleImplEntry          \
        HLE_CAT(hle_entry_, __LINE__) = {sym, fn};                                          \
    static void fn(Cpu *c)

#define RES_OK 0u
#define MAKE_RESULT(module, desc) ((uint32_t)(module) | ((uint32_t)(desc) << 9))
