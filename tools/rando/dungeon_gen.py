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


TEXTURE_BUDGET = 245  # a dungeon level loads at most ~250 map textures (256 crash; notes/PLAN.md)
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


def plan(cat, level, entrance, seed, size=14, exit_side='S', tries=400, romfs=None):
    pool = sorted(k for k, v in cat.items() if len(v['unit']) == 1 and movable(v) and k != entrance)
    base_tex = set()
    if romfs:  # the dungeon's own roof / fade models are always loaded
        mapdir = os.path.join(romfs, 'region_common', 'map')
        for f in os.listdir(mapdir):
            if f.startswith('DungeonRoof') and f.endswith('.bfres'):
                import re
                base_tex |= {m.group().decode() for m in re.finditer(rb'MI_[A-Za-z0-9_.]+', open(os.path.join(mapdir, f), 'rb').read())}
        base_tex &= set(room_textures(romfs, entrance)) | set(_tex_cache.get(level, set()))
    op = {k: openings(cat, k) for k in pool + [entrance]}
    ec, er = cell_pos(entrance)
    for attempt in range(tries):
        rng = random.Random(f'{seed}-{level}-{attempt}')
        placed = {(ec, er): entrance}
        used = {entrance}
        tex = set(base_tex) | (set(room_textures(romfs, entrance)) if romfs else set())

        def nbr(c, r, s):
            dc, dr = rooms.STEP[s]
            return c + dc, r + dr

        def inside(c, r):
            return 0 <= c < COLS and 1 <= r <= ROWS

        def frontier():
            out = []
            for (c, r), room in placed.items():
                for s in 'NSWE':
                    if not op[room][s] or (room == entrance and s == exit_side):
                        continue
                    n = nbr(c, r, s)
                    if n not in placed:
                        out.append(((c, r), s, n))
            return out

        def fits(room, c, r):
            new = 0
            for s in 'NSWE':
                n = nbr(c, r, s)
                if n in placed:
                    other = placed[n]
                    theirs = () if (other == entrance and rooms.OPP[s] == exit_side) else op[other][rooms.OPP[s]]
                    if not _openings_match(op[room][s], theirs):
                        return None
                elif op[room][s]:
                    if not inside(*n):
                        return None
                    new += 1
            return new

        ok = True
        while True:
            fr = frontier()
            if not fr:
                break
            fr.sort(key=lambda f: rng.random())
            (c0, r0), s, (c, r) = fr[0]
            want_close = len(placed) >= size
            cands = []
            for room in pool:
                if room in used:
                    continue
                n = fits(room, c, r)
                if n is None:
                    continue
                if romfs and len(tex | room_textures(romfs, room)) > TEXTURE_BUDGET:
                    continue
                if want_close and n:
                    continue
                cands.append((n, rng.random(), room))
            if not cands:
                ok = False
                break
            # grow while small (prefer rooms that open 1-2 more doorways), then close
            cands.sort(key=lambda t: (abs(t[0] - 1.5) if not want_close else 0, t[1]))
            room = cands[0][2]
            placed[(c, r)] = room
            used.add(room)
            if romfs:
                tex |= room_textures(romfs, room)
            if len(placed) > size * 3:
                ok = False
                break
        if ok and len(placed) >= max(4, size // 2):
            return {cell_name(level, c, r): room for (c, r), room in placed.items()}
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


def _heights_ok(a, b):
    return all(x[1] is None or y[1] is None or abs(x[1] - y[1]) < 0.3 for x, y in zip(a, b))


def _openings_match(a, b):
    """Two facing sides join when they have the same doorway centres at the same floor height (None = a door;
    shallow water -0.05 counts as ground), or - door jumps - the same number of open doorways (no door actors, no
    wide openings) at any centres: Link is moved to the partner doorway when he walks into his (_jumps)."""
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
            theirs = openings(cat, layout[nb])[rooms.OPP[s]]
            if len(theirs) != len(mine[s]):
                continue
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

    def __init__(self, next_global=GLOBAL_FLAG_BASE):
        self.g, self.l = {}, {}
        self.next_g, self.next_l = next_global, 1

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
    rooms.remove_actors(r, lambda a: a.type in WARP_PADS)
    if missing is not None:
        cover = _roof_for(romfs, rooms.level_of(cell), missing)
        for a in r.actors:
            if a.type == rooms.ROOF and cover:
                a.parameters = [cover[0].encode(), cover[1].encode(), cover[2].encode()] + list(a.parameters[3:])
    for a in r.actors:
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


def write(romfs, out, level, layout, entrance, own_zones=False, all_starts=False):
    rooms_list = []
    # camera zones use the target dungeon's own zone record (environment / lighting set / music): a zone naming
    # another dungeon's environment (e.g. 'Lv10Base') isn't loaded in this level and the load throws
    _, home_zone = _source_records(romfs, entrance)
    # The game reads the RomFS image itself: a seed can override files but not add new names. A cell this
    # level never had loads its room from a donor: an original room file of the level the layout doesn't use.
    lvdir = os.path.join(romfs, 'region_common', 'level', level)
    # The dungeon map finds a room's image by the room FILE's name: donors must have one (01F / 01G of Tail Cave
    # have none -> the Map item crashed the map); donors with images first, then the rest
    imgs = _map_image_names(romfs)
    donors = sorted((f[:-4] for f in os.listdir(lvdir) if f.endswith('.leb') and f[:-4] not in layout),
                    key=lambda n: (n not in imgs, n))
    zone_ids = {cell: 300 + i for i, cell in enumerate(sorted(layout))}  # one camera zone per cell
    flags = FlagMap()
    donor_of = {}
    for cell, src in sorted(layout.items()):
        if src != cell:
            rooms.transplant(romfs, out, src, cell, merge_textures=False)
        c0, r0 = cell_pos(cell)
        here = {cell_pos(k) for k in layout}
        missing = ''.join(L for L, (dc, dr) in (('U', (0, -1)), ('D', (0, 1)), ('L', (-1, 0)), ('R', (1, 0)))
                          if (c0 + dc, r0 + dr) not in here)
        _fix_room(romfs, out, cell, src, zone_ids[cell], flags, missing)
        area, own = _source_records(romfs, src)
        r = {'name': cell, 'unit': zone_ids[cell], 'area_data': area, 'zone_data': own if own_zones else home_zone}
        if not os.path.exists(os.path.join(lvdir, cell + '.leb')):
            if not donors:
                raise RuntimeError('no donor room file left for ' + cell)
            donor = donors.pop(0)
            donor_of[cell] = donor
            written = os.path.join(out, 'region_common', 'level', level, cell + '.leb')
            os.replace(written, os.path.join(out, 'region_common', 'level', level, donor + '.leb'))
            r['path'] = f'level/{level}/{donor}.leb'
        rooms_list.append(r)
    base_path = os.path.join(romfs, 'region_common', 'level', level, level + '.lvb')
    base = open(base_path, 'rb').read()
    fh = fixedhash.FixedHash(base)
    starts = {}
    for e in fh.get(b'tagPlayerStart').data.entries:
        n = e.name.decode()
        if n.startswith(entrance) or n == 'OcarinaWarpPoint':
            starts[n] = struct.unpack_from('<4f', e.data, 0)
    # test / warp starts: one named after each cell at its centre (warp straight into any generated room)
    for cell in layout:
        rc = cell.rsplit('_', 1)[1]
        x0, z0 = (ord(rc[2]) - ord('A')) * 15.0, (int(rc[:2]) - 1) * 12.0
        starts.setdefault(cell, (x0 + 7.5, 0.0, z0 + 6.0, 0.0))
    lvb = level_builder.build(base, rooms_list, starts=None if all_starts else starts, static=False)
    p = os.path.join(out, 'region_common', 'level', level, level + '.lvb')
    os.makedirs(os.path.dirname(p), exist_ok=True)
    open(p, 'wb').write(lvb)
    _dungeon_map_rooms(romfs, out, layout, entrance, donor_of)
    # door jumps: rando/<seed>/door_jumps.tsv next to the seed's romfs (read by runtime/hle/doorjump.c)
    cat = json.load(open(os.path.join(HERE, 'room_catalog.json')))
    jumps = _jumps(cat, level, layout)
    with open(os.path.join(os.path.dirname(os.path.abspath(out)), 'door_jumps.tsv'), 'w') as f:
        for j in jumps:
            f.write('\t'.join(map(str, j)) + '\n')
    _dungeon_map_images(romfs, out, layout, donor_of)
    _level_textures(romfs, out, level, layout)


def _level_textures(romfs, out, level, layout):
    """The level's map bntx = exactly the textures its rooms' models (and the dungeon roof models) reference,
    from the level's own archive first, then the source dungeons'."""
    import re
    import bntx_merge
    mapdir = os.path.join(romfs, 'region_common', 'map')
    models = set(layout.values()) | {f[:-6] for f in os.listdir(mapdir) if f.startswith('DungeonRoof') and f.endswith('.bfres')}
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


def _dungeon_map_images(romfs, out, layout, donor_of=None):
    """Dungeon-map room images live in ui/DgnTex.arc (one combined bntx: '<room>' + '<room>_Mask', all 160x128);
    the map looks them up by cell name -> each cell shows its source room's image. Patched in place (re-saving
    that 1053-texture archive breaks it): cells the dungeon has get the source pixels, new cells take over an
    unused cell name of the same dungeon (same name length) and get the source pixels. A cell loading its room
    from a donor file is also looked up under the donor's name (the Map item draws every room: a donor image
    renamed away as a spare crashed it, null resource 'Lv01TailCave_01F_Mask') -> donors keep their names and get
    the source pixels too."""
    donor_of = donor_of or {}
    import oead
    import bntx_merge
    rel = os.path.join('region_common', 'ui', 'DgnTex.arc')
    src = os.path.join(out, rel) if os.path.exists(os.path.join(out, rel)) else os.path.join(romfs, rel)
    raw = open(src, 'rb').read()
    compressed = raw[:4] == b'Yaz0'
    sarc = oead.Sarc(oead.yaz0.decompress(raw) if compressed else raw)
    name = 'timg/__Combined.bntx'
    data = bytes(sarc.get_file(name).data)
    e = bntx_merge._open(data)
    have = {t.name for t in e.bntx.textures}
    level = next(iter(layout)).rsplit('_', 1)[0]
    spare = sorted(n for n in have if n.startswith(level + '_') and not n.endswith('_Mask')
                   and n not in layout and n not in layout.values()  # (a source room's image is still needed)
                   and n not in donor_of.values()
                   and n + '_Mask' in have and len(n) == len(level) + 4)
    rename, set_from = {}, {}
    for cell, srcroom in sorted(layout.items()):
        if cell not in have:
            if not spare:
                raise RuntimeError('no spare dungeon-map image for ' + cell)
            d = spare.pop(0)
            rename[d], rename[d + '_Mask'] = cell, cell + '_Mask'
        if srcroom != cell and srcroom in have and srcroom + '_Mask' in have:
            set_from[cell], set_from[cell + '_Mask'] = srcroom, srcroom + '_Mask'
            d = donor_of.get(cell)
            if d and d in have and d + '_Mask' in have:
                set_from[d], set_from[d + '_Mask'] = srcroom, srcroom + '_Mask'
    data = bntx_merge.patch_in_place(data, {}, rename)  # names first, then pixels by the new names
    data = bntx_merge.patch_in_place(data, set_from)
    w = oead.SarcWriter.from_sarc(sarc)
    w.files[name] = data
    blob = bytes(w.write()[1])
    if compressed:
        blob = bytes(oead.yaz0.compress(blob))
    os.makedirs(os.path.dirname(os.path.join(out, rel)), exist_ok=True)
    open(os.path.join(out, rel), 'wb').write(blob)


def _dungeon_map_rooms(romfs, out, layout, entrance, donor_of=None):
    """The dungeon map keys every room by name (UiDungeonArea.gsheet: room, floor, ...); a room missing there
    throws on level load (std::out_of_range). Add the layout's new cells (floor info copied from the entrance).
    The map also looks rooms up by their FILE name: a cell loading from a donor file needs the donor's entry too
    (pruned -> the Map item crashed the map, null deref in f_7000e82250)."""
    names = set(layout) | set((donor_of or {}).values())
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
        return all(not r.startswith(level + '_') or r in layout for r in rs)
    sheet['values'] = [x for x in sheet['values'] if ok(x)]
    oead_tools.writeSheet(os.path.join(out, rel), sheet)


def ascii_map(layout):
    cells = {cell_pos(k): v for k, v in layout.items()}
    lines = []
    for r in range(1, ROWS + 1):
        lines.append(' '.join((cells[(c, r)].split('_')[0][2:4] + cells[(c, r)][-3:]) if (c, r) in cells else '  .   '
                              for c in range(COLS)))
    return '\n'.join(lines)


if __name__ == '__main__':
    romfs, out, level, entrance = sys.argv[1:5]
    seed = sys.argv[5] if len(sys.argv) > 5 else 'LARecomp'
    size = int(sys.argv[6]) if len(sys.argv) > 6 else 14
    cat = json.load(open(os.path.join(HERE, 'room_catalog.json')))
    layout = plan(cat, level, entrance, seed, size, romfs=romfs)
    if not layout:
        sys.exit('no layout')
    print(ascii_map(layout))
    for k, v in sorted(layout.items()):
        print(f'{k} <- {v}')
    write(romfs, out, level, layout, entrance)
    print(len(layout), 'rooms')
