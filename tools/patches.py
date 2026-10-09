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


# Warp support: the level-jump request object (filled by GameControl.RequestLevelJump via main+0x81b950)
# registers itself in its parent while a level loads: `str xR, [x8, #0x1c0]` at these two sites (two scene
# kinds). Record it so runtime/hle/warp.c can fill the request itself.
WARP_REQUEST_SITES = {0x700080c464: 20, 0x700080d718: 19}


def _warp_request(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    rt = WARP_REQUEST_SITES[a]
    assert w == (0xf900e100 | rt), hex(w)  # str xRT, [x8, #0x1c0]
    return ('{ extern void rt_warp_request_obj(uint64_t); '
            f'*(uint64_t *)(uintptr_t)(c->x[8] + 0x1c0) = c->x[{rt}]; rt_warp_request_obj(c->x[{rt}]); }}'
            f'  /* {a:#x}: str x{rt}, [x8, #0x1c0] (warp: level-jump request) */')


for _a in WARP_REQUEST_SITES:
    PATCHES[_a] = _warp_request


# Generated dungeons (runtime/hle/chamber.c): every level jump goes through the request processor main+0x81ba80
# (x0 = request); its prologue reports the request so jumps into Tail Cave can be redirected.
LEVEL_REQUEST_SITE = 0x700081ba80


def _level_request(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xd10203ff, hex(w)  # sub sp, sp, #0x80
    return ('{ extern void rt_level_request(Cpu *); rt_level_request(c); c->sp -= 0x80; }'
            f'  /* {a:#x}: sub sp, sp, #0x80 (level-jump request) */')


PATCHES[LEVEL_REQUEST_SITE] = _level_request


# Chamber staircase exit prompt ("Return to Arranging/List" vs "Back to Adventuring"): main+0x7f1540 opens it with
# `bl main+0xf05280` at 0x7f15e0; the callback only stores the chosen option at [main+0x1cb9fb8]+0x18f8 (0 = leave).
# In a generated dungeon the dialog is skipped and 0 stored, so the staircase leaves directly (runtime/hle/chamber.c).
ADV_EXIT_DIALOG_SITE = 0x70007f15e0


def _adv_exit_dialog(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0x9402_5d28 or (w >> 26) == 0x25, hex(w)  # bl
    return ('{ extern int rt_adv_exit_choice(void); extern void f_7000f05280(Cpu *); '
            'if (!rt_adv_exit_choice()) { c->x[30] = 0x70007f15e4ull; f_7000f05280(c); } }'
            f'  /* {a:#x}: bl 0xf05280 (chamber exit prompt) */')


PATCHES[ADV_EXIT_DIALOG_SITE] = _adv_exit_dialog


# Difficulty (runtime/ui/difficulty.mm): Link's damage is computed as `damage << hero` (Hero Mode doubles it;
# hero = PlayerStatus+0x120 == 1) at these `lsl Wd, Wn, Wm` sites, then subtracted from health (+0x84).
# Each is redirected to rt_damage(damage, shift) so the difficulty multiplier / one-hit KO applies.
DAMAGE_LSL_SITES = (0x7000d7c8c0, 0x7000d9694c, 0x7000d4c738)
# Fixed damage (-2 quarter hearts, -4 in Hero Mode: `csel w20, w10, w9, eq` with w10=-4, w9=-2).
DAMAGE_FIXED_SITE = 0x7000db1f6c


def _damage_lsl(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert (w & 0xffe0fc00) == 0x1ac02000, hex(w)  # lslv (32-bit)
    rd, rn, rm = w & 31, (w >> 5) & 31, (w >> 16) & 31
    return (f'{{ extern int32_t rt_damage(int32_t, int32_t); c->x[{rd}] = (uint32_t)rt_damage((int32_t)c->x[{rn}], '
            f'(int32_t)(c->x[{rm}] & 31)); }}  /* {a:#x}: lsl w{rd}, w{rn}, w{rm} (damage) */')


def _damage_fixed(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert (w & 0xffe00c00) == 0x1a800000 and (w & 31) == 20, hex(w)  # csel w20, ...
    return ('{ extern int32_t rt_damage(int32_t, int32_t); extern int rt_hero_mode(void); '
            'c->x[20] = (uint32_t)(-rt_damage(2, rt_hero_mode())); }'
            f'  /* {a:#x}: csel w20, -4, -2 (fixed damage) */')


for _a in DAMAGE_LSL_SITES:
    PATCHES[_a] = _damage_lsl
PATCHES[DAMAGE_FIXED_SITE] = _damage_fixed


# Items page description ("UI:ItemExplanation_{n}"): main+0xeb6604.. builds the item name then looks the explanation
# message up (bl 0x903250 -> [sp+0xf0]); a null result takes the no-text path (buffer already cleared). In randomizer
# seeds the explanation is hidden (it overlaps the key / trade-item rows of the inventory overlay; player knows).
ITEM_EXPLANATION_SITE = 0x7000eb66c0


def _item_explanation(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xf9407bf6, hex(w)  # ldr x22, [sp, #0xf0]
    return ('{ extern int rt_hide_item_explanation(void); '
            'c->x[22] = rt_hide_item_explanation() ? 0 : LD64(c->sp + 0xf0); }'
            f'  /* {a:#x}: ldr x22, [sp, #0xf0] (item explanation message) */')


PATCHES[ITEM_EXPLANATION_SITE] = _item_explanation

# ... and the item NAME ("UI:ItemName_{0}"): main+0xeb6658 `bl 0xf8c8b0` sets the name pane from that message; in
# randomizer seeds it is skipped too (user 2026-10-08: the name showed under the key rows of the inventory overlay).
ITEM_NAME_SITE = 0x7000eb6658


def _item_name(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0x94035896, hex(w)  # bl 0x7000f8c8b0
    return ('c->x[30] = 0x7000eb665cull; { extern int rt_hide_item_explanation(void); '
            'if (!rt_hide_item_explanation()) f_7000f8c8b0(c); }'
            f'  /* {a:#x}: bl 0xf8c8b0 (set the item name pane) */')


PATCHES[ITEM_NAME_SITE] = _item_name


# Keysanity (runtime/hle/keysanity.c): AddItem (main+0x7e18b0, x0 item / x1 count / x2 index) only adds dungeon
# items to the current dungeon; with an explicit dungeon index the hook updates that dungeon's save record instead.
ADD_ITEM_SITE = 0x70008d08e0  # inner add (34 callers: events, chests, drops); AddItem 0x7e18b0 wraps it


def _add_item(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xd10143ff, hex(w)  # sub sp, sp, #0x50
    return ('{ extern int rt_add_item(Cpu *); if (rt_add_item(c)) return; c->sp -= 0x50; }'
            f'  /* {a:#x}: sub sp, sp, #0x50 (AddItem: keysanity) */')


PATCHES[ADD_ITEM_SITE] = _add_item


# Trendsanity (runtime/hle/shopsanity.c): AddPrizeByKey (main+0x7e1c70) looked the prize row up (x0) and is about to
# call AddPrize(row, count, index) (main+0x1489c0, rows 0-20 only): a randomized prize row sets its check's flags.
PRIZE_ADD_SITE = 0x70007e1d10


def _prize_add(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0x2a1403e2, hex(w)  # mov w2, w20
    return ('{ c->x[2] = (uint32_t)c->x[20]; extern void rt_add_prize(Cpu *); rt_add_prize(c); }'
            f'  /* {a:#x}: mov w2, w20 (AddPrize index; trendsanity) */')


PATCHES[PRIZE_ADD_SITE] = _prize_add


# Inventory overlay (runtime/ui/inventory_overlay.mm): main+0xeb7cd0 runs once per frame only while the pause
# menu's Items page is shown (found by profiling Items vs Map/System pages). Its prologue reports that.
ITEMS_PAGE_SITE = 0x7000eb7cd0


def _items_page(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xd10243ff, hex(w)  # sub sp, sp, #0x90
    return ('{ extern void rt_items_page_tick(void); rt_items_page_tick(); c->sp -= 0x90; }'
            f'  /* {a:#x}: sub sp, sp, #0x90 (items page shown) */')


PATCHES[ITEMS_PAGE_SITE] = _items_page


# Check tracker (runtime/ui/tracker_overlay.mm): main+0xe93800 runs once per frame only while the pause menu's
# Map page is shown (fnprof diff of Map vs Items/System/closed). Its prologue reports that.
MAP_PAGE_SITE = 0x7000e93800


def _map_page(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xd10203ff, hex(w)  # sub sp, sp, #0x80
    return ('{ extern void rt_map_page_tick(Cpu *); rt_map_page_tick(c); c->sp -= 0x80; }'
            f'  /* {a:#x}: sub sp, sp, #0x80 (map page shown) */')


PATCHES[MAP_PAGE_SITE] = _map_page


# Chaos map letters (runtime/ui/chaos_overlay.mm): main+0xe78740 runs once per frame while the DUNGEON map page is
# shown (fnprof: map open vs closed in Face Shrine); x0 = the dungeon map page.
DGN_MAP_SITE = 0x7000e78740


def _dgn_map(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xd10243ff, hex(w)  # sub sp, sp, #0x90
    return ('{ extern void rt_dgnmap_tick(Cpu *); rt_dgnmap_tick(c); c->sp -= 0x90; }'
            f'  /* {a:#x}: sub sp, sp, #0x90 (dungeon map page shown) */')


PATCHES[DGN_MAP_SITE] = _dgn_map


# Debug (LARECOMP_LOG_RESNAME=1): main+0x10def30 builds a resource handle from a name (x2 -> {char *name, ...})
# and looks it up; the generated-dungeon map crash dereferences a handle whose resource wasn't found.
RES_NAME_SITE = 0x70010def30


def _res_name(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xd10503ff, hex(w)  # sub sp, sp, #0x140
    return ('{ extern void rt_log_resname(uint64_t); rt_log_resname(c->x[2]); c->sp -= 0x140; }'
            f'  /* {a:#x}: sub sp, sp, #0x140 (resource-by-name debug log) */')


PATCHES[RES_NAME_SITE] = _res_name


# Field mini-bosses (enemy randomizer): a mini-boss starts its fight when the dungeon's zone-change signal reaches
# it (zone manager -> f_7000029520 -> actor vfunc +0x100), which never happens in the Field. f_70003bf2b0 (a type
# check run on these actors every frame) tells the runtime which actors exist (runtime/hle/miniboss.c), and the
# runtime sends the start itself.
MB_SEEN_SITE = 0x70003bf2b0


def _mb_seen(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xf81e0ff3, hex(w)  # str x19, [sp, #-32]!
    return ('{ extern void rt_mb_seen(Cpu *); rt_mb_seen(c); uint64_t ea = c->sp - 32; ST64(ea, c->x[19]); c->sp = ea; }'
            f'  /* {a:#x}: str x19, [sp, #-32]! (mini-boss actor seen) */')


PATCHES[MB_SEEN_SITE] = _mb_seen


# Frame pacing (runtime/hle/framepace.c): the game's frame timer (f_700000c910) advances by its frame period times
# the swap interval it reads from the system object (+0x812c, written only by the interval setter f_7000017800). It
# reads it here and nowhere else: we hand it the number of vsyncs that really passed since the last frame, so a
# late frame advances the world by the time that passed (no slow motion below 60 fps).
FRAME_STEPS_SITE = 0x700000c954


def _frame_steps(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xb8696908, hex(w)  # ldr w8, [x8, x9]
    return ('{ extern uint32_t rt_frame_steps(uint32_t interval); '
            'c->x[8] = rt_frame_steps(LD32(c->x[8] + c->x[9])); }'
            f'  /* {a:#x}: ldr w8, [x8, x9] (swap interval -> vsyncs elapsed: runtime/hle/framepace.c) */')


PATCHES[FRAME_STEPS_SITE] = _frame_steps


# Escape Bottle (runtime/hle/escape.c): the player's per-item "use it now?" predicates (one per item slot, main+0xd50e60
# .. 0xd52f00; each: X / Y newly pressed with that slot equipped on it) only run while Link may use items (no cutscene,
# dialog, menu or transition). main+0xd50e60 is the third bottle's (slot 0xf): owned (PlayerStatus+0xa9 bit 7) and
# empty (+0xc0 bit 2 clear) -> `cset w0, eq` = yes, and the bottle swing starts. In randomizer seeds that bottle is the
# Escape Bottle: the runtime warps instead and the answer is no.
BOTTLE3_USE_SITE = 0x7000d50f0c


def _bottle3_use(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0x1a9f17e0, hex(w)  # cset w0, eq
    return ('{ extern int rt_bottle3_use(void); c->x[0] = COND_NE(c) ? 0 : 1; if (c->x[0] && rt_bottle3_use()) c->x[0] = 0; }'
            f'  /* {a:#x}: cset w0, eq (third bottle used: Escape Bottle) */')


PATCHES[BOTTLE3_USE_SITE] = _bottle3_use


# 360-degree movement (runtime/hle/qol.c, setting move_360): main+0xded9f0 snaps Link's stick vector (s1 = x, s2 = y)
# to one of 8 directions and returns it as a 32-bit angle (full turn = 2^32, 0 = down). With the setting on, the
# runtime returns the stick's own angle instead (as the community "360 Controls" mod does).
SNAP_DIR_SITE = 0x7000ded9f0


def _snap_dir(gen, a):
    w = struct.unpack_from('<I', gen.nso.image, a - gen.base)[0]
    assert w == 0xd10103ff, hex(w)  # sub sp, sp, #0x40
    return ('{ extern int rt_snap_dir(Cpu *); if (rt_snap_dir(c)) return; c->sp -= 0x40; }'
            f'  /* {a:#x}: sub sp, sp, #0x40 (8-way stick snap: 360-degree movement) */')


PATCHES[SNAP_DIR_SITE] = _snap_dir
