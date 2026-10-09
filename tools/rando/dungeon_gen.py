#!/usr/bin/env python3
"""Generated dungeons v1: a new layout of real rooms (any dungeon) inside a dungeon level.

The dungeon's own entrance room stays at its cell (the overworld stairs arrive at its start point); from there
rooms are placed on a fresh grid, growing outward: every doorway of a placed room must meet a matching doorway
(same side slots, tools/rando/rooms.py) or face a free cell that gets filled later; once the dungeon has its
target size only rooms that open nothing new are used, so the layout closes. Each room is used once.
Backtracking search, deterministic per seed.

Output: the rooms transplanted into their cells (+ merged textures) and a new .lvb (tools/rando/level_builder.py).

    python3 dungeon_gen.py <romfs> <out romfs> <level> <entrance room> [seed] [size]

v1 limits (next steps in notes/PLAN.md): single-cell rooms only; no roles yet (boss / mini-boss / instrument /
key doors ...); items in the moved rooms are still their original contents (logic comes next); the entrance's
exit side is kept out of the layout; rooms in new cells have no darkness cover (roof) yet.
Runs in the LAS venv.
"""
import functools
import json
import os
import random
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, '..', '..', 'third_party', 'LAS-Randomizer'))

import fixedhash  # noqa: E402
import level_builder  # noqa: E402
import rooms  # noqa: E402

NOT_MOVABLE = ('Stairs', 'Downstairs', 'Upstairs', 'Warp', 'Hole', 'PlayerStart', 'Npc', 'Shop', 'Panel',
               'LevelOpen', 'FullMoon', 'Instrument', 'ConchHorn', 'SeaLily', 'SurfHarp', 'WindMarimba',
               'CoralTriangle', 'EveningCalm', 'ThunderDrum', 'HeartContainer', 'Owl', 'Return')
# doorways that only work with their original neighbour (user 2026-10-08: tie them to their vanilla partner rather
# than chase them): Tail Cave 06A's hallway north - every jump into another room there was undone by the game
PINNED = {('Lv01TailCave_06A', 'N')}


def pinned_ok(room, s, other):
    """False when `room`'s side `s` (or `other`'s facing side) is pinned to an original neighbour that isn't there."""
    if (room, s) in PINNED and other != rooms.neighbour(room, s):
        return False
    return not ((other, rooms.OPP[s]) in PINNED and room != rooms.neighbour(other, rooms.OPP[s]))


BOSS_TYPES = set(range(0x51, 0x70)) | {0x220}  # bosses / mini-bosses, environment switches (TagChangeEnv)
COLS, ROWS = 8, 8  # A-H, rows 01-08 (side-view rooms of a level sit further east, x >= 135)


def movable(v):
    if BOSS_TYPES & set(v.get('types', [])):
        return False
    return not any(k in a for a in v['actors'] for k in NOT_MOVABLE)


def cell_name(level, col, row):
    return f'{level}_{row:02d}{chr(ord("A") + col)}'


def cell_pos(name):
    rc = name.rsplit('_', 1)[1][:3]
    return ord(rc[2]) - ord('A'), int(rc[:2])


# A level's map texture archive: archives over 255 textures crashed - a LAS BNTX writer bug (relocation stride,
# fixed 2026-10-08); the budget is now about memory (a 78 MB merge ran out). LARECOMP_TEXTURE_BUDGET overrides.
TEXTURE_BUDGET = int(os.environ.get('LARECOMP_TEXTURE_BUDGET', 330))  # 308 textures = 63 MB loaded fine
_tex_cache = {}


def room_textures(romfs, room):
    """Names of the map textures a room's model needs (only those its dungeon's archive has)."""
    if room in _tex_cache:
        return _tex_cache[room]
    import re
    mapdir = os.path.join(romfs, 'region_common', 'map')
    lv = rooms.level_of(room)
    if lv not in _tex_cache:
        from RandomizerCore.Tools.bntx_editor import bntx_editor
        e = bntx_editor.BNTXEditor()
        e.openFile(open(os.path.join(mapdir, lv + '.bntx'), 'rb').read())
        _tex_cache[lv] = {t.name for t in e.bntx.textures}
    p = os.path.join(mapdir, room + '.bfres')
    refs = {m.group().decode() for m in re.finditer(rb'MI_[A-Za-z0-9_.]+', open(p, 'rb').read())} if os.path.exists(p) else set()
    _tex_cache[room] = frozenset(refs & _tex_cache[lv])
    return _tex_cache[room]


def anchors_of(cat, level):
    """Rooms of `level` that stay at their own cells in a generated dungeon: everything not movable (stairs, holes,
    warps, the boss / mini-boss rooms, instrument, exits, NPCs...) and every multi-cell room."""
    out = set()
    for k, v in cat.items():
        if k.startswith(level + '_') and not movable(v):
            out |= set(v['unit'])
    # multi-cell rooms stay too (the pool is single rooms; moving units is queued): a free unit's cells were
    # unfillable holes otherwise (Key Cavern 01D above the boss area; Tail Cave 05C-06E: an exact room set can't
    # rebuild its own dungeon)
    for k, v in cat.items():
        if k.startswith(level + '_') and len(v['unit']) > 1:
            out |= set(v['unit'])
    # rooms without a doorway (Bottle Grotto 03C) can't be placed anywhere: they stay where they are
    return out | {k for k in cat if k.startswith(level + '_') and not any(openings(cat, k).values())}


def offgrid_rooms(romfs, cat, level):
    """The level's rooms that aren't top-down grid cells (side-view passages under the stairs, ...): kept as they are."""
    d = os.path.join(romfs, 'region_common', 'level', level)
    return sorted(f[:-4] for f in os.listdir(d) if f.endswith('.leb') and f[:-4] not in cat)


def _exit_sides(cat, room):
    """Sides of an unmoved room whose opening led out of the dungeon grid in the original (to the overworld, a
    side-view passage, ...): no room needs to meet them."""
    out = set()
    for s in 'NSWE':
        nb = rooms.neighbour(room, s)
        if cat[room]['openings'][s] and (nb is None or nb not in cat):
            out.add(s)
    return out


def plan(cat, level, entrance, seed, size=None, exit_side=None, tries=400, romfs=None, anchors=None, exclude=(),
         stats=None, max_moved=None, exact=None, seal=False, avoid=()):
    """A layout {cell: source room} for `level`: the entrance and `anchors` (default anchors_of) at their own cells,
    movable single-cell rooms of any dungeon (not in `exclude`) grown around them until every doorway meets a
    matching one (door jumps allowed, _openings_match) and every anchor is reachable from the entrance.
    max_moved: at most this many rooms brought in from elsewhere; the rest of the cells get their own original rooms
    (plan_all: the dungeons share one pool of movable rooms). exact: a set of rooms the layout must use, all of them
    and nothing else (plan_all trades rooms between dungeons). seal: a plain doorway may stay unconnected (it gets a
    door that never opens, sealable()) - an open side toward an empty cell or a room that doesn't match it.
    avoid: rooms to use only when nothing else fits (plan_all: rooms another dungeon already has)."""
    if anchors is None:
        anchors = anchors_of(cat, level)
    fixed = set(anchors) | {entrance}
    if exact is not None:
        size = len(fixed) + len(exact)
    if size is None:
        size = len(fixed) + 10
    pool = sorted(k for k, v in cat.items() if len(v['unit']) == 1 and movable(v) and k not in fixed
                  and k not in exclude and not k.startswith('Lv07EagleTower') and (exact is None or k in exact))
    base_tex = set()
    if romfs:  # the dungeon's own roof / fade models are always loaded
        mapdir = os.path.join(romfs, 'region_common', 'map')
        for f in os.listdir(mapdir):
            if f.startswith('DungeonRoof') and f.endswith('.bfres'):
                import re
                base_tex |= {m.group().decode() for m in re.finditer(rb'MI_[A-Za-z0-9_.]+', open(os.path.join(mapdir, f), 'rb').read())}
        base_tex &= set(room_textures(romfs, entrance)) | set(_tex_cache.get(level, set()))
    offgrid = offgrid_rooms(romfs, cat, level) if romfs else []
    level_files = {k for k in cat if k.startswith(level + '_')}  # grid rooms with a file (side-view ones excluded)
    op = {k: openings(cat, k) for k in pool + sorted(fixed)}
    exits = {k: _exit_sides(cat, k) for k in fixed}
    if exit_side:
        exits[entrance].add(exit_side)

    so = {k: {s: () if s in exits.get(k, ()) else op[k][s] for s in 'NSWE'} for k in op}  # (hot: precomputed)
    orig_nb = {k: {s: rooms.neighbour(k, s) for s in 'NSWE'} for k in op}
    names = {(c, r): cell_name(level, c, r) for c in range(-1, COLS + 1) for r in range(0, ROWS + 2)}

    def side_open(room, s):
        return so[room][s]

    def can_seal(room, s):
        return seal and sealable(op[room][s])

    def joined(a, b, s, home_pair):
        x, y = side_open(a, s), side_open(b, rooms.OPP[s])
        return bool(x) and bool(y) and (home_pair or _openings_match(x, y))

    def nbr(c, r, s):
        dc, dr = rooms.STEP[s]
        return c + dc, r + dr

    def inside(c, r):
        return 0 <= c < COLS and 1 <= r <= ROWS

    for attempt in range(tries):
        rng = random.Random(f'{seed}-{level}-{attempt}')
        placed = {cell_pos(k): k for k in sorted(fixed)}  # (sorted: set order varies per run -> same seed, same dungeon)
        used = set(fixed)
        tex = set(base_tex)
        if romfs:  # the rooms that stay (anchors, side-view passages) count against the texture budget too
            for k in sorted(fixed) + offgrid:
                tex |= room_textures(romfs, k)

        def frontier():
            out = {}
            for (c, r), room in placed.items():
                for s, a in so[room].items():
                    if not a:
                        continue
                    dc, dr = rooms.STEP[s]
                    n = (c + dc, r + dr)
                    if n not in placed:
                        out[n] = out.get(n, 0) + 1
            return out

        def required(fr):
            # open cells some doorway needs (with seal: one that can't be sealed)
            if not seal:
                return set(fr)
            req = set()
            for (c, r), room in placed.items():
                for s in 'NSWE':
                    n = nbr(c, r, s)
                    if n in fr and side_open(room, s) and not can_seal(room, s):
                        req.add(n)
            return req

        def fits(room, c, r):
            new = 0
            home = names[(c, r)] == room  # a room back at its own cell
            for s in 'NSWE':
                n = nbr(c, r, s)
                if n in placed:
                    if not pinned_ok(room, s, placed[n]):
                        return None
                    # next to its original neighbour, an original room always fits (the game proves it; the doorway
                    # model is stricter in a few spots, e.g. Face Shrine 03A under 02A's door)
                    if home and placed[n] == orig_nb[room][s]:
                        continue
                    a, b = op[room][s], side_open(placed[n], rooms.OPP[s])
                    if not _openings_match(a, b) and not (seal and (not a or can_seal(room, s))
                                                          and (not b or can_seal(placed[n], rooms.OPP[s]))):
                        return None
                elif op[room][s]:
                    if not inside(*n):
                        return None
                    new += 1
            return new

        # stairs: the side-view passages under them join the anchors with stairs (Key Cavern's halves meet only there);
        # reaching one stairs room reaches them all (approximation: one passage network per dungeon)
        stairs = {cell_pos(k) for k in fixed if any(t in a for a in cat[k]['actors'] for t in ('Downstairs', 'Upstairs'))}

        def connected():
            seen, todo = {cell_pos(entrance)}, [cell_pos(entrance)]
            while todo:
                c, r = todo.pop()
                if (c, r) in stairs:
                    for st in stairs - seen:
                        seen.add(st)
                        todo.append(st)
                for s in 'NSWE':
                    n = nbr(c, r, s)
                    if n in placed and n not in seen and joined(placed[(c, r)], placed[n], s,
                                                                placed[n] == orig_nb[placed[(c, r)]][s]
                                                                and placed[n] == names[n]
                                                                and placed[(c, r)] == names[(c, r)]):
                        seen.add(n)
                        todo.append(n)
            return all(cell_pos(k) in seen for k in fixed if any(op[k].values()))  # (doorless rooms: no way in)

        # Backtracking: fill the most constrained open cell (most placed neighbours); try a few candidate rooms
        # each (grow while small: prefer rooms opening 1-2 more doorways; then only rooms that close), undo on a
        # dead end. A node budget per attempt; attempts differ by seed.
        budget = [1500]

        def solve():
            fr = frontier()
            req = required(fr)
            left = None if exact is None else len(fixed) + len(exact) - len(used)
            if not fr or (seal and not req and (left == 0 or (left is None and len(placed) >= size))):
                return (exact is None or left == 0) and connected()
            if left is not None and len(req) > left:
                return False  # more open cells than rooms left
            budget[0] -= 1
            if budget[0] < 0:
                return False
            want_close = len(placed) >= size

            moved = sum(1 for p, k in placed.items() if k != names.get(p))

            def candidates(c, r):
                out = []
                for room in pool:
                    if room in used:
                        continue
                    if max_moved is not None and moved >= max_moved and room != names[(c, r)]:
                        continue
                    n = fits(room, c, r)
                    if n is None:
                        continue
                    if romfs and len(tex | room_textures(romfs, room)) > TEXTURE_BUDGET:
                        continue
                    # grow while small (rooms opening 1-2 more doorways first), then close (rooms opening nothing
                    # first; opening more is still allowed - exact dead ends are rare)
                    out.append((room in avoid, abs(n - 1.5) if not want_close else n, rng.random(), room))
                return out
            # fewest candidates first (and give up at once when an open cell has none)
            best = None
            for cell in sorted(fr, key=lambda n: rng.random()):
                if not inside(*cell):
                    if stats is not None: stats['off-grid'] = stats.get('off-grid', 0) + 1
                    return False
                cs = candidates(*cell)
                if not cs:
                    if stats is not None:
                        k = 'no room for %s' % cell_name(level, *cell)[-3:]
                        stats[k] = stats.get(k, 0) + 1
                    return False
                if best is None or len(cs) < len(best[1]):
                    best = (cell, cs)
            cell, cands = best
            cands.sort()
            for *_, room in cands[:6]:
                placed[cell] = room
                used.add(room)
                added = room_textures(romfs, room) - tex if romfs else set()
                tex.update(added)
                if len(placed) <= size * 3 and solve():
                    return True
                del placed[cell]
                used.discard(room)
                tex.difference_update(added)
            return False

        if solve():
            return {cell_name(level, c, r): room for (c, r), room in placed.items()}
        if stats is not None: stats['disconnected'] = stats.get('disconnected', 0) + 1
    return None


def openings(cat, room):
    """{side: ((slot, floor height, own door), ...)}: slot = doorway centre in half tiles, height None at a door
    (its tiles carry the closed door's collision), own door = a door actor of this room stands in it (shutter, lock,
    bombable wall)."""
    r = cat[room]
    own = [(d[0], d[3]) for d in r['doors'] if len(d) > 3 and not d[2].endswith('(mirror)')]  # + blockers

    def has_own(s, sl):
        return not isinstance(sl, str) and any(ds == s and abs(h - sl) <= 1 for ds, h in own)
    return {s: tuple((sl, h, has_own(s, sl)) for sl, h in zip(r['openings'][s], r.get('heights', {}).get(s, [0.0] * 10)))
            for s in 'NSWE'}


JUMPS = True  # mismatched doorways joined by the runtime door jump (runtime/hle/doorjump.c)


def sealable(side):
    """A side whose doorway can be shut for good (a door that never opens): one plain doorway (no wide opening, no
    door actor of its own)."""
    return len(side) == 1 and not isinstance(side[0][0], str) and not side[0][2]


def seals(cat, level, layout):
    """[(cell, side)]: doorways of a layout that lead nowhere (no neighbour, or one that doesn't match) and get shut."""
    out = []
    for cell, room in sorted(layout.items()):
        c, r = cell_pos(cell)
        for s in 'NSWE':
            a = openings(cat, room)[s]
            if not a:
                continue
            dc, dr = rooms.STEP[s]
            n = cell_name(level, c + dc, r + dr)
            if n in layout:
                if layout[n] == rooms.neighbour(room, s) and room == cell and layout[n] == n:
                    continue  # original pair
                if _openings_match(a, openings(cat, layout[n])[rooms.OPP[s]]):
                    continue
            out.append((cell, s))
    return out


def _heights_ok(a, b):
    return all(x[1] is None or y[1] is None or abs(x[1] - y[1]) < 0.3 for x, y in zip(a, b))


@functools.lru_cache(maxsize=None)
def _openings_match(a, b):
    """Two facing sides join when they have the same doorway centres at the same floor height (None = a door;
    shallow water -0.05 counts as ground), or - door jumps - the same number of open doorways (no door actors, no
    wide openings) at any centres: Link is moved to the partner doorway when he walks into his (_jumps)."""
    # a doorway whose door actor stood in the old neighbour (height None, no own door) only works opposite a room
    # bringing its own door there (Face Shrine 03H's north door with another room in 02H: Link got stuck / lost)
    if len(a) == len(b) and any(x[1] is None and not x[2] and not (y[2] and x[0] == y[0])
                                for p, q in ((a, b), (b, a)) for x, y in zip(p, q)):
        return False
    if [x[0] for x in a] == [x[0] for x in b]:
        return _heights_ok(a, b)
    if not JUMPS or len(a) != len(b):
        return False
    if any(isinstance(x[0], str) or x[2] for x in a + b):
        return False
    return _heights_ok(a, b)


def _jumps(cat, level, layout):
    """[(level, cell, side, own centre, partner centre)] for every joined pair of doorways that don't line up."""
    out = []
    pos = {cell_pos(c): c for c in layout}
    for cell, room in sorted(layout.items()):
        c, r = cell_pos(cell)
        mine = openings(cat, room)
        for s in 'NSWE':
            dc, dr = rooms.STEP[s]
            nb = pos.get((c + dc, r + dr))
            if not nb or not mine[s]:
                continue
            if room == cell and layout[nb] == nb and rooms.neighbour(room, s) == nb:
                continue  # an original pair: the game's own doorway (the catalog can differ, Angler's 06D/07D)
            theirs = openings(cat, layout[nb])[rooms.OPP[s]]
            if len(theirs) != len(mine[s]) or any(isinstance(x[0], str) for x in mine[s] + theirs):
                continue  # (wide openings never jump)
            for x, y in zip(mine[s], theirs):
                if x[0] != y[0]:
                    out.append((level, cell.rsplit('_', 1)[1], s, x[0], y[0]))
    return out


WARP_PADS = {0xF3}  # ObjDungeonWarp: paired warp tiles naming '<room>_Warp' starts of their own dungeon


GLOBAL_FLAG_BASE = 1600  # fresh event flags for generated rooms (the game uses < 1119; save bitfield = 2048 bits)


class FlagMap:
    """Room objects keep their state in flags: switch slot (type 1, index) = a global event flag (unique per room in
    the game: a room used twice, or played before in another dungeon, would share / inherit state), (type 0,
    index) = a level-local flag (0..254 per dungeon; rooms from different dungeons collide). Every generated
    dungeon gets fresh numbers; objects sharing a flag in their source room keep sharing it."""

    def __init__(self, next_global=GLOBAL_FLAG_BASE, reserved_local=()):
        self.g, self.l = {}, {}
        self.next_g, self.next_l = next_global, 1
        self.reserved = set(reserved_local)  # local flags of the rooms that keep theirs (anchors)

    def glob(self, i):
        if i not in self.g:
            self.g[i] = self.next_g
            self.next_g += 1
            if self.next_g >= 2048:
                raise RuntimeError('out of free event flags')
        return self.g[i]

    def local(self, level, i):
        if i in (0, 255):
            return i
        k = (level, i)
        if k not in self.l:
            while self.next_l in self.reserved:
                self.next_l += 1
            self.l[k] = self.next_l
            self.next_l += 1
            if self.next_l >= 255:
                raise RuntimeError('out of level-local flags')
        return self.l[k]


_roof_cache = {}


def _roof_variants(romfs):
    """{dungeon roof model file: set of model names in it} (map/DungeonRoofLv*.bfres)."""
    if not _roof_cache:
        import re
        mapdir = os.path.join(romfs, 'region_common', 'map')
        for f in sorted(os.listdir(mapdir)):
            if f.startswith('DungeonRoofLv') and f.endswith('.bfres'):
                names = {m.group().decode() for m in re.finditer(rb'Dungeon(?:Roof|Fade)(?:_ex[UDLR]+)?(?=\x00)',
                                                                open(os.path.join(mapdir, f), 'rb').read())}
                _roof_cache['map/' + f] = names
    return _roof_cache


def _roof_for(romfs, level, missing):
    """Darkness cover (roof actor 0x1B6 params: model file, roof model, fade model) for a cell whose sides
    `missing` (subset of 'UDLR', in that order) have no room: the generic 'DungeonRoof_ex<missing>' models cover
    the neighbour cells that exist (181/200 rooms of the original game follow this). A moved room's own cover was
    made for its old surroundings (user saw blacked-out areas). Prefers the level's own roof file."""
    roof = 'DungeonRoof_ex' + missing if missing else 'DungeonRoof'
    fade = 'DungeonFade_ex' + missing if missing else 'DungeonFade'
    files = _roof_variants(romfs)
    own = 'map/DungeonRoofLv%d.bfres' % int(level[2:4])
    order = ([own] if own in files else []) + [f for f in files if f != own]
    for f in order:  # a file with both matching models first, then roof only
        if roof in files[f] and fade in files[f]:
            return f, roof, fade
    for f in order:
        if roof in files[f]:
            return f, roof, 'DungeonFade' if 'DungeonFade' in files[f] else fade
    return None


def _fix_room(romfs, out, cell, src, zone_id, flags=None, missing=None):
    """Every actor records the camera zone it belongs to (actor +0x10 'roomID' = zone id): stamp the cell's new
    zone (stale ids -> the room isn't drawn: black screen). Warp pads are removed (their partner start in the
    old dungeon is gone -> std::out_of_range on load)."""
    from RandomizerCore.Tools import leb
    p = os.path.join(out, 'region_common', 'level', rooms.level_of(cell), cell + '.leb')
    data = open(p, 'rb').read() if os.path.exists(p) else open(rooms._leb_path(romfs, src), 'rb').read()
    r = leb.Room(data)
    if src != cell:  # (unmoved rooms keep their warp pads: the partner starts are kept)
        rooms.remove_actors(r, lambda a: a.type in WARP_PADS)
    if missing is not None:
        cover = _roof_for(romfs, rooms.level_of(cell), missing)
        for a in r.actors:
            if a.type == rooms.ROOF and cover:
                a.parameters = [cover[0].encode(), cover[1].encode(), cover[2].encode()] + list(a.parameters[3:])
    for a in r.actors:
        if zone_id is not None:
            a.roomID = zone_id
        if flags is not None:
            sw = []
            for t, i in a.switches:
                if t == 1:
                    i = flags.glob(i)
                elif t == 0:
                    i = flags.local(rooms.level_of(src), i)
                sw.append((t, i))
            a.switches = sw
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(r.repack())


def _source_records(romfs, room):
    """The room's own area record and the record of the camera zone holding it, from its source level."""
    lv = rooms.level_of(room)
    fh = fixedhash.FixedHash(open(os.path.join(romfs, 'region_common', 'level', lv, lv + '.lvb'), 'rb').read())
    areas = fh.get(b'area').data.entries
    names = [e.name.decode() for e in areas]
    area = areas[names.index(room)].data
    zone = None
    for z in fh.get(b'zone').data.entries:
        n = z.data[0x9c + 6]
        if names.index(room) in z.data[0x9c + 7:0x9c + 7 + n]:
            zone = z.data
    return area, zone


ENTRANCES = {  # each dungeon's entrance room (its AreaLevelOpen back to the overworld, 'DungeonOut')
    'Lv01TailCave': 'Lv01TailCave_08D', 'Lv02BottleGrotto': 'Lv02BottleGrotto_08C', 'Lv03KeyCavern': 'Lv03KeyCavern_08B',
    'Lv04AnglersTunnel': 'Lv04AnglersTunnel_08D', 'Lv05CatfishsMaw': 'Lv05CatfishsMaw_08H',
    'Lv06FaceShrine': 'Lv06FaceShrine_08D', 'Lv08TurtleRock': 'Lv08TurtleRock_08D',
    'Lv10ClothesDungeon': 'Lv10ClothesDungeon_08C'}  # (Eagle's Tower: its own rules, notes/PLAN.md)


def plan_all(cat, seed, romfs, levels=None, stats=None, rounds=None):
    """Layouts for every dungeon of a seed, each movable room used once across all of them where possible.
    The pool (85 single rooms) can't close every dungeon without some rooms appearing twice (user 2026-10-08: allow
    duplicates, as few as possible, never twice in one dungeon; duplicated checks become extra checks): several
    rounds, the one with the fewest duplicates wins (then the fewest unused rooms)."""
    levels = levels or list(ENTRANCES)
    if rounds is None:
        rounds = int(os.environ.get('LARECOMP_GEN_ROUNDS', 8))
    fixed = set()
    for lv in levels:
        fixed |= set(anchors_of(cat, lv)) | {ENTRANCES[lv]}
    pool = {k for k, v in cat.items() if len(v['unit']) == 1 and movable(v) and k not in fixed
            and k.split('_')[0] in levels}
    best = None
    for rnd in range(rounds):
        sub = seed if rnd == 0 else f'{seed}#{rnd}'
        used, out, dups = set(), {}, []
        # most constrained dungeons first (most anchors); a dungeon that can't be built from the rooms left may reuse
        # its own original rooms, then (last resort) any room
        order = sorted(levels, key=lambda lv: -len(anchors_of(cat, lv)))
        if rnd:  # later rounds: other orders (whoever goes last tends to reuse its own rooms)
            random.Random(sub).shuffle(order)
        for lv in order:
            own = {k for k in cat if k.startswith(lv + '_')}
            n = len(set(anchors_of(cat, lv)) | {ENTRANCES[lv]})
            L = None
            for size in (n + 10, n + 6, n + 3):  # smaller before duplicating
                L = L or plan(cat, lv, ENTRANCES[lv], sub, size=size, romfs=romfs, exclude=used, stats=stats, tries=8)
            for size in (n + 6, n + 3, None):
                L = L or plan(cat, lv, ENTRANCES[lv], sub, size=size, romfs=romfs, exclude=used - own, avoid=used,
                              stats=stats, tries=8)
            L = (L or plan(cat, lv, ENTRANCES[lv], sub, romfs=romfs, avoid=used, stats=stats, tries=40) or
                 plan(cat, lv, ENTRANCES[lv], sub, romfs=romfs, stats=stats))
            if L is None:
                raise RuntimeError('no layout for ' + lv)
            placed = {src for src in L.values() if src in pool}
            dups += sorted(placed & used)
            used |= placed
            out[lv] = L
        moved = sum(1 for L in out.values() for cell, src in L.items() if src != cell)
        score = (len(dups), len(pool - used), -moved)  # then the most variety
        if best is None or score < best[0]:
            best = (score, out, dups)

    (ndup, unused, moved), out, dups = best
    print(f'dungeons: {ndup} room(s) used twice{": " + ", ".join(dups) if dups else ""}; {unused} room(s) unused; '
          f'{-moved} moved')
    return {lv: out[lv] for lv in levels}


def write_all(romfs, out, layouts):
    """Writes every generated dungeon; global flags numbered across all of them, one door_jumps.tsv."""
    jumps = os.path.join(os.path.dirname(os.path.abspath(out)), 'door_jumps.tsv')
    open(jumps, 'w').close()
    shared = FlagMap()
    for lv, L in layouts.items():
        write(romfs, out, lv, L, ENTRANCES[lv], shared_flags=shared)


def write(romfs, out, level, layout, entrance, own_zones=False, all_starts=False, shared_flags=None):
    rooms_list = []
    # camera zones use the target dungeon's own zone record (environment / lighting set / music): a zone naming
    # another dungeon's environment (e.g. 'Lv10Base') isn't loaded in this level and the load throws
    _, home_zone = _source_records(romfs, entrance)
    # cells the level never had get files of their own: the runtime adds seed files the game's RomFS doesn't have
    # (runtime/services/fs.c add_new_files)
    zone_ids = {cell: 300 + i for i, cell in enumerate(sorted(layout))}  # one camera zone per moved cell
    from RandomizerCore.Tools import leb
    # rooms at their own cells (anchors: boss, stairs, instrument...; the entrance) keep their files' flags and
    # zone ids; moved rooms get fresh flags around the anchors' level-local ones
    unmoved = {cell for cell, src in layout.items() if src == cell}
    reserved = set()
    for cell in unmoved:
        for a in leb.Room(open(rooms._leb_path(romfs, cell), 'rb').read()).actors:
            reserved |= {i for t, i in a.switches if t == 0}
    flags = FlagMap(reserved_local=reserved)
    if shared_flags is not None:  # several dungeons in one seed: global flags continue across them
        flags.next_g = shared_flags.next_g
    for cell, src in sorted(layout.items()):
        if src != cell:
            rooms.transplant(romfs, out, src, cell, merge_textures=False)
        c0, r0 = cell_pos(cell)
        here = {cell_pos(k) for k in layout}
        missing = ''.join(L for L, (dc, dr) in (('U', (0, -1)), ('D', (0, 1)), ('L', (-1, 0)), ('R', (1, 0)))
                          if (c0 + dc, r0 + dr) not in here)
        keep = cell in unmoved
        _fix_room(romfs, out, cell, src, None if keep else zone_ids[cell], None if keep else flags, missing)
        area, own = _source_records(romfs, src)
        r = {'name': cell, 'unit': zone_ids[cell], 'area_data': area, 'zone_data': own if own_zones else home_zone}
        if keep and own:  # own camera zone (boss arenas...) under its own id; cells sharing it stay one zone
            zid = struct.unpack_from('<I', own, 0)[0]
            r.update(unit='z%d' % zid, zone_data=own, keep_zone=zid)
        rooms_list.append(r)
    # side-view passages under the stairs etc.: as they are (own area records, zones, ids)
    cat = json.load(open(os.path.join(HERE, 'room_catalog.json')))
    for n in offgrid_rooms(romfs, cat, level):
        area, own = _source_records(romfs, n)
        r = {'name': n, 'fixed': True, 'area_data': area, 'unit': n}
        if own:
            zid = struct.unpack_from('<I', own, 0)[0]
            r.update(unit='z%d' % zid, zone_data=own, keep_zone=zid)
        rooms_list.append(r)
    base_path = os.path.join(romfs, 'region_common', 'level', level, level + '.lvb')
    base = open(base_path, 'rb').read()
    fh = fixedhash.FixedHash(base)
    # every original start (stairs, side-view passages, warps and the entrance arrive at them) + one per cell
    starts = {}
    for e in fh.get(b'tagPlayerStart').data.entries:
        starts[e.name.decode()] = struct.unpack_from('<4f', e.data, 0)
    # test / warp starts: one named after each cell at its centre (warp straight into any generated room)
    for cell in layout:
        rc = cell.rsplit('_', 1)[1]
        x0, z0 = (ord(rc[2]) - ord('A')) * 15.0, (int(rc[:2]) - 1) * 12.0
        starts.setdefault(cell, (x0 + 7.5, 0.0, z0 + 6.0, 0.0))
    lvb = level_builder.build(base, rooms_list, starts=None if all_starts else starts, static=False)
    p = os.path.join(out, 'region_common', 'level', level, level + '.lvb')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(lvb)
    if shared_flags is not None:
        shared_flags.next_g = flags.next_g
    _dungeon_map_rooms(romfs, out, layout, entrance)
    # door jumps: rando/<seed>/door_jumps.tsv next to the seed's romfs (read by runtime/hle/doorjump.c)
    jumps = _jumps(cat, level, layout)
    with open(os.path.join(os.path.dirname(os.path.abspath(out)), 'door_jumps.tsv'), 'a' if shared_flags else 'w') as f:
        for j in jumps:
            f.write('\t'.join(map(str, j)) + '\n')
    _dungeon_map_images(romfs, out, layout)
    _level_textures(romfs, out, level, layout)


def _level_textures(romfs, out, level, layout):
    """The level's map bntx = exactly the textures its rooms' models (and the dungeon roof models) reference,
    from the level's own archive first, then the source dungeons'."""
    import re
    import bntx_merge
    mapdir = os.path.join(romfs, 'region_common', 'map')
    cat = json.load(open(os.path.join(HERE, 'room_catalog.json')))
    models = set(layout.values()) | set(offgrid_rooms(romfs, cat, level)) | \
        {f[:-6] for f in os.listdir(mapdir) if f.startswith('DungeonRoof') and f.endswith('.bfres')}
    only = set()
    for m in models:
        p = os.path.join(mapdir, m + '.bfres')
        if os.path.exists(p):
            only |= {x.group().decode() for x in re.finditer(rb'MI_[A-Za-z0-9_.]+', open(p, 'rb').read())}
    levels = [level] + sorted({rooms.level_of(r) for r in layout.values()} - {level})
    sources = [open(os.path.join(mapdir, lv + '.bntx'), 'rb').read() for lv in levels]
    data = bntx_merge.subset(sources, only)
    dst = os.path.join(out, 'region_common', 'map', level + '.bntx')
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    open(dst, 'wb').write(data)


def _map_image_names(romfs):
    import oead
    import bntx_merge
    raw = open(os.path.join(romfs, 'region_common', 'ui', 'DgnTex.arc'), 'rb').read()
    sarc = oead.Sarc(oead.yaz0.decompress(raw) if raw[:4] == b'Yaz0' else raw)
    names = {t.name for t in bntx_merge._open(bytes(sarc.get_file('timg/__Combined.bntx').data)).bntx.textures}
    return {n for n in names if n + '_Mask' in names}


def _dungeon_map_images(romfs, out, layout):
    """Dungeon-map room images live in ui/DgnTex.arc (one combined bntx: '<room>' + '<room>_Mask', all 160x128);
    the map looks them up by cell name -> each cell gets its source room's image: pixels patched in place for
    cells the dungeon has, new textures (copies under the cell's name) for cells it never had."""
    import oead
    import bntx_merge
    rel = os.path.join('region_common', 'ui', 'DgnTex.arc')
    src = os.path.join(out, rel) if os.path.exists(os.path.join(out, rel)) else os.path.join(romfs, rel)
    raw = open(src, 'rb').read()
    compressed = raw[:4] == b'Yaz0'
    sarc = oead.Sarc(oead.yaz0.decompress(raw) if compressed else raw)
    name = 'timg/__Combined.bntx'
    data = bytes(sarc.get_file(name).data)
    texs = {t.name: t for t in bntx_merge._open(data).bntx.textures}
    have = set(texs)

    def same_shape(a, b):
        x, y = texs[a], texs[b]
        return (x.format_, x.width, x.height, x.numMips, x.imageSize) == (y.format_, y.width, y.height, y.numMips, y.imageSize)
    set_from, new = {}, []
    for cell, srcroom in sorted(layout.items()):
        if srcroom not in have or srcroom + '_Mask' not in have:
            if cell in have:
                continue
            # a source without an image (Tail Cave 01F...): any image of the target dungeon, the map item draws
            # every room and a missing one crashes it
            srcroom = next(n for n in sorted(have) if n.startswith(cell.rsplit('_', 1)[0] + '_') and
                           n + '_Mask' in have)
        if cell in have and cell + '_Mask' in have and same_shape(cell, srcroom) and same_shape(cell + '_Mask', srcroom + '_Mask'):
            if srcroom != cell:
                set_from[cell], set_from[cell + '_Mask'] = srcroom, srcroom + '_Mask'
        elif srcroom != cell:  # a new cell, or an image of another size: (re)made as a copy
            new += [(srcroom, cell), (srcroom + '_Mask', cell + '_Mask')]
    data = bntx_merge.patch_in_place(data, set_from)
    if new:
        data = bntx_merge.copy_renamed(data, new)
    w = oead.SarcWriter.from_sarc(sarc)
    w.files[name] = data
    blob = bytes(w.write()[1])
    if compressed:
        blob = bytes(oead.yaz0.compress(blob))
    os.makedirs(os.path.dirname(os.path.join(out, rel)), exist_ok=True)
    open(os.path.join(out, rel), 'wb').write(blob)


def _dungeon_map_rooms(romfs, out, layout, entrance):
    """The dungeon map keys every room by name (UiDungeonArea.gsheet: room, floor, ...); a room missing there
    throws on level load (std::out_of_range). Add the layout's new cells (floor info copied from the entrance).
    """
    level = entrance.rsplit('_', 1)[0]
    names = set(layout)
    cat = json.load(open(os.path.join(HERE, 'room_catalog.json')))
    names |= set(offgrid_rooms(romfs, cat, level))  # side-view passages keep their rows
    from RandomizerCore.Tools import oead_tools
    rel = os.path.join('region_common', 'datasheets', 'UiDungeonArea.gsheet')
    src = os.path.join(out, rel) if os.path.exists(os.path.join(out, rel)) else os.path.join(romfs, rel)
    sheet = oead_tools.readSheet(src)
    level = entrance.rsplit('_', 1)[0]
    tmpl = next(oead_tools.parseStruct(x) for x in sheet['values']
                if oead_tools.parseStruct(x)['mLeaName'] == entrance)
    # rooms of this dungeon that aren't in the generated level any more would be looked up and not found
    keep = [x for x in sheet['values'] if not oead_tools.parseStruct(x)['mLeaName'].startswith(level + '_')
            or oead_tools.parseStruct(x)['mLeaName'] in names]
    sheet['values'] = keep
    have = {oead_tools.parseStruct(x)['mLeaName'] for x in sheet['values']}
    for cell in sorted(names):
        if cell not in have:
            e = dict(tmpl)
            e['mLeaName'] = cell
            e['mIsBoss'] = False
            sheet['values'].append(oead_tools.dictToStruct(e))
    os.makedirs(os.path.dirname(os.path.join(out, rel)), exist_ok=True)
    oead_tools.writeSheet(os.path.join(out, rel), sheet)
    # stairs pairs (UiDungeonStair: first / second room) of this dungeon: drop pairs with a missing room
    rel = os.path.join('region_common', 'datasheets', 'UiDungeonStair.gsheet')
    src = os.path.join(out, rel) if os.path.exists(os.path.join(out, rel)) else os.path.join(romfs, rel)
    sheet = oead_tools.readSheet(src)
    def ok(x):
        d = oead_tools.parseStruct(x)
        rs = [d['mFirstLeaName'], d['mSceondLeaName']]
        return all(not r.startswith(level + '_') or r in names for r in rs)
    sheet['values'] = [x for x in sheet['values'] if ok(x)]
    oead_tools.writeSheet(os.path.join(out, rel), sheet)


def ascii_map(layout):
    cells = {cell_pos(k): v for k, v in layout.items()}
    lines = []
    for r in range(1, ROWS + 1):
        lines.append(' '.join((cells[(c, r)].split('_')[0][2:4] + cells[(c, r)][-3:]) if (c, r) in cells else '  .   '
                              for c in range(COLS)))
    return '\n'.join(lines)


if __name__ == '__main__' and len(sys.argv) > 3 and sys.argv[3] == '--all':
    # python3 dungeon_gen.py <romfs> <out romfs> --all [seed]: every dungeon (except Eagle's Tower)
    romfs, out = sys.argv[1:3]
    seed = sys.argv[4] if len(sys.argv) > 4 else 'LARecomp'
    cat = json.load(open(os.path.join(HERE, 'room_catalog.json')))
    layouts = plan_all(cat, seed, romfs)
    for lv, L in layouts.items():
        print(lv, len(L), 'cells,', sum(1 for k, v in L.items() if k != v), 'moved')
    write_all(romfs, out, layouts)
    sys.exit(0)

if __name__ == '__main__':
    romfs, out, level, entrance = sys.argv[1:5]
    seed = sys.argv[5] if len(sys.argv) > 5 else 'LARecomp'
    size = int(sys.argv[6]) if len(sys.argv) > 6 else None  # default: anchors + 10
    cat = json.load(open(os.path.join(HERE, 'room_catalog.json')))
    layout = plan(cat, level, entrance, seed, size, romfs=romfs)
    if not layout:
        sys.exit('no layout')
    print(ascii_map(layout))
    for k, v in sorted(layout.items()):
        print(f'{k} <- {v}')
    write(romfs, out, level, layout, entrance)
    print(len(layout), 'rooms')
