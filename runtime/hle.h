// Registration of host implementations for guest symbols.
#pragma once
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
