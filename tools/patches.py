"""Per-instruction replacements applied by gen.py (guest address -> function(gen, addr) returning C code).

Widescreen: the game's camera code loads a 16:9 aspect-ratio literal (0x70016afba4) as the default
projection aspect. These loads are redirected to rt_aspect_site(), which returns the aspect for the
current output shape (or 16:9) per site, so only the 3D cameras widen.
"""
import struct

ASPECT_LITERAL = 0x70016afba4

# address of `ldr sN, [xM, #0xba4]` -> site id (0x7001023c70 is UI layout math: left alone)
ASPECT_SITES = {
    0x700001092c: 0,
    0x7000010b58: 1,
    0x70000c1c84: 2,
    0x70000c3228: 3,
    0x70000c3edc: 4,
    0x700085f824: 5,
}


def _aspect_load(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert (w & 0xffc00000) == 0xbd400000 and ((w >> 10) & 0xfff) * 4 == 0xba4, hex(w)
    rt = w & 31
    return (f'{{ extern float rt_aspect_site(int); float f = rt_aspect_site({ASPECT_SITES[a]}); '
            f'c->v[{rt}] = 0; memcpy(&c->v[{rt}], &f, 4); }}  /* {a:#x}: ldr s{rt}, =16/9 */')


PATCHES = {a: _aspect_load for a in ASPECT_SITES}


# Off-screen culling: the scene's visibility pass loads the camera's aspect from [x27, #0x570] into s9
# (`ldr s9, [x27, #0x570]` at 0x7000852ad4). The community 32:9 patch (Jaddey / KeatonTheBot, build
# AE16F71E...) forces s9 here; we load the runtime aspect instead (site 6).
CULL_ASPECT = 0x7000852ad4


def _cull_aspect(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xbd457369, hex(w)  # ldr s9, [x27, #0x570]
    return ('{ extern float rt_cull_aspect(float); float o; memcpy(&o, (const void *)(uintptr_t)(c->x[27] + 0x570), 4); '
            'float f = rt_cull_aspect(o); c->v[9] = 0; memcpy(&c->v[9], &f, 4); }'
            f'  /* {a:#x}: ldr s9, [x27, #0x570] (culling aspect) */')


PATCHES[CULL_ASPECT] = _cull_aspect


# Vertical field of view (camera field +0x564): taller-than-16:9 outputs keep the designed horizontal view
# and widen the vertical one ("Vert+"). Loaded by the main camera and by the culling pass.
FOVY_SITES = {0x7000010914: (0xbd4566e0, 23), 0x7000852ad0: (0xbd456768, 27)}


def _fovy_load(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    want, rn = FOVY_SITES[a]
    assert w == want, hex(w)
    rt = w & 31
    return ('{ extern float rt_fovy(float); float o; '
            f'memcpy(&o, (const void *)(uintptr_t)(c->x[{rn}] + 0x564), 4); float f = rt_fovy(o); '
            f'c->v[{rt}] = 0; memcpy(&c->v[{rt}], &f, 4); }}  /* {a:#x}: ldr s{rt}, [x{rn}, #0x564] (fovy) */')


for _a in FOVY_SITES:
    PATCHES[_a] = _fovy_load


# Indoor detection: 0x7001023c70 (`ldr s1, =16/9`) is in the indoor shadow setup (community patch notes:
# "Indoor Shadow AR"). It keeps loading 16:9 and tells the runtime an interior is being rendered.
INDOOR_SITE = 0x7001023c70


def _indoor(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert (w & 0xffc00000) == 0xbd400000 and ((w >> 10) & 0xfff) * 4 == 0xba4, hex(w)
    rt = w & 31
    return ('{ extern float rt_indoor_aspect(void); float f = rt_indoor_aspect(); '
            f'c->v[{rt}] = 0; memcpy(&c->v[{rt}], &f, 4); }}  /* {a:#x}: ldr s{rt}, =16/9 (indoor shadow) */')


PATCHES[INDOOR_SITE] = _indoor
