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
