#!/usr/bin/env python3
"""Item logic for shuffled dungeons (Dungeon room shuffle: Coherent / Chaos, tools/rando/dungeon_gen.py).

LAS's dungeon logic describes the vanilla layouts: a few "room" regions per dungeon named after cells (D1-8D,
D1-6F...) and each check gated by one of them plus key counts and what the check itself needs. With rooms moved
that no longer holds, so for every shuffled dungeon this module builds the logic from the generated layout:

  graph      cells of the layout; edges = doorways that connect (neighbours whose doorways line up, door jumps -
             Coherent and Chaos, directed for Chaos), plus the stairs links (side-view passages; stairs rooms are
             anchors and never move)
  doors      only a room's OWN door actors count (a "(mirror)" door stood in the old neighbour, which isn't there):
             lock -> the dungeon's small keys, boss door -> its Nightmare Key, cracked wall -> bombs, shutter ->
             something to fight with / hit switches (approximate), pot in the doorway -> break-pot, water in the
             doorway -> flippers, crystal -> break-crystal; one-way doors, statues and chests in a doorway are left
             out (impassable for the logic: safe, never relied on)
  keys       a lock needs ALL of the dungeon's small keys (always solvable: the keys sit before every lock); the
             number of small keys per dungeon = the number of locks in its new layout
  cells      each cell's requirement = OR over paths from the entrance of AND of the door requirements, computed
             as a fixed point in minimal sum-of-products form (LAS evaluates conditions recursively, so cyclic
             region references aren't possible - the finished, loop-free condition goes into the logic)
  regions    LAS's cell regions (Dn-XY) are redefined as "reach cell XY of the new layout" (macros elsewhere use them)
  checks     reach any cell holding the check's room (Coherent duplicates count, also in other dungeons) AND what
             the check needs inside its room: its vanilla condition with the region / key tokens taken out (where
             such a token sat inside an OR, the OR becomes an AND - stricter, never weaker). A check whose room isn't
             used anywhere is excluded (junk). Dungeon items go to the dungeon a check physically is in now.

Not modelled yet (stricter or approximate): what a room needs to cross it between two doorways (pits, water,
blocks inside the room), the exact enemies / switches behind each shutter, key counts along paths.
"""
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))

LEVELS = {
    'Lv10ClothesDungeon': (0, 'color-dungeon'), 'Lv01TailCave': (1, 'tail-cave'), 'Lv02BottleGrotto': (2, 'bottle-grotto'),
    'Lv03KeyCavern': (3, 'key-cavern'), 'Lv04AnglersTunnel': (4, 'angler-tunnel'), 'Lv05CatfishsMaw': (5, 'catfish-maw'),
    'Lv06FaceShrine': (6, 'face-shrine'), 'Lv07EagleTower': (7, 'eagle-tower'), 'Lv08TurtleRock': (8, 'turtle-rock'),
}
SHUTTER = 'sword | shoot-arrows | bombs | rod | boomerang | hookshot'  # fight the room's enemies / hit its switches
DOOR_REQ = {'cracked': 'bombs', 'potdoor': 'break-pot', 'blocked:water': 'flippers', 'blocked:crystal': 'break-crystal',
            'blocked:block': None, 'shutter': 'rs-shutter'}
IMPASSABLE = {'oneway', 'blocked:statue', 'blocked:chest'}
STEP = {'N': (0, -1), 'S': (0, 1), 'W': (-1, 0), 'E': (1, 0)}
OPP = {'N': 'S', 'S': 'N', 'W': 'E', 'E': 'W'}
MAX_TERMS = 48


def cell_pos(cell):  # '06C' -> (col 2, row 6)
    return ord(cell[2]) - ord('A'), int(cell[:2])


def cell_name(col, row):
    return f'{row:02d}{chr(ord("A") + col)}'


# ---------------------------------------------------------------- conditions: parse, strip, print
TOK = re.compile(r'\s*(\(|\)|&|\||!|[^\s()&|!]+)')


def parse(s):
    toks = [t for t in TOK.findall(s or '') if t.strip()]
    pos = [0]

    def peek():
        return toks[pos[0]] if pos[0] < len(toks) else None

    def take():
        pos[0] += 1
        return toks[pos[0] - 1]

    def expr():
        n = [term()]
        while peek() == '|':
            take()
            n.append(term())
        return n[0] if len(n) == 1 else ('|', n)

    def term():
        n = [factor()]
        while peek() == '&':
            take()
            n.append(factor())
        return n[0] if len(n) == 1 else ('&', n)

    def factor():
        t = take()
        if t == '!':
            return ('!', [factor()])
        if t == '(':
            e = expr()
            take()  # ')'
            return e
        return ('atom', t)
    if not toks:
        return None
    return expr()


def strip(node, drop):
    """Removes atoms for which drop(atom) is true (treated as satisfied). Returns (node or None, stripped?). An OR
    whose branches lost something becomes an AND of its branches (strict)."""
    if node is None:
        return None, False
    kind = node[0]
    if kind == 'atom':
        return (None, True) if drop(node[1]) else (node, False)
    if kind == '!':
        sub, s = strip(node[1][0], drop)
        return (('!', [sub]) if sub else None), s
    parts, any_s = [], False
    for c in node[1]:
        sub, s = strip(c, drop)
        any_s |= s
        if sub is not None:
            parts.append(sub)
    if kind == '|' and any_s:
        kind = '&'
    if not parts:
        return None, any_s
    return (parts[0] if len(parts) == 1 else (kind, parts)), any_s


def show(node):
    if node is None:
        return ''
    kind = node[0]
    if kind == 'atom':
        return node[1]
    if kind == '!':
        return '!' + paren(node[1][0])
    return f' {kind} '.join(paren(c) if c[0] in ('|', '&') and c[0] != kind else show(c) for c in node[1])


def paren(n):
    return show(n) if n[0] in ('atom', '!') else '(' + show(n) + ')'


def dnf_str(terms):
    if not terms:
        return None
    out = []
    for t in sorted(terms, key=lambda t: (len(t), sorted(t))):
        out.append(' & '.join(f'({a})' if '|' in a else a for a in sorted(t)) if t else '')
    out = [o for o in out if o]
    return ' | '.join(f'({o})' for o in out) if len(out) > 1 else (out[0] if out else None)


# ---------------------------------------------------------------- the dungeon graph
def own_doors(cat, room, side, slot):
    """Types of the room's own door actors at that doorway (no '(mirror)')."""
    out = []
    for d in cat.get(room, {}).get('doors', []):
        if len(d) > 3 and d[0] == side and abs(d[3] - slot) <= 1 and not d[2].endswith('(mirror)'):
            out.append(d[2])
    return out


def door_terms(types, n):
    """frozenset of requirement atoms for passing these door types, or None if impassable."""
    req = set()
    for t in types:
        if t in IMPASSABLE:
            return None
        if t == 'lock':
            req.add(f'KEYS-D{n}')
        elif t == 'bossdoor':
            req.add(f'nightmare-key-D{n}')
        elif DOOR_REQ.get(t):
            req.add(DOOR_REQ[t])
    return frozenset(req)


def stairs_links(romfs, level):
    """[(grid room, grid room)] joined through side-view passages under the stairs."""
    import sys
    sys.path.insert(0, os.path.join(HERE, '..', '..', 'third_party', 'LAS-Randomizer'))
    from RandomizerCore.Tools import leb
    d = os.path.join(romfs, 'region_common', 'level', level)
    down, up = {}, {}  # grid -> side-view room; side-view -> grid
    for f in sorted(os.listdir(d)):
        if not f.endswith('.leb'):
            continue
        room = f[:-4]
        r = leb.Room(open(os.path.join(d, f), 'rb').read())
        for a in r.actors:
            n = a.name.decode(errors='ignore')
            if not a.parameters or not isinstance(a.parameters[0], bytes):
                continue
            target = a.parameters[0].decode(errors='ignore')
            if n.startswith('AreaDownstairs'):
                down.setdefault(room, set()).add(target)
            elif n.startswith('AreaUpstairs'):
                up.setdefault(room, set()).add(target)
    side = set(up) | {t for v in down.values() for t in v}
    parent = {s: s for s in side}

    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for s in side:  # side-view rooms next to each other in a row: one passage
        m = re.search(r'_(\d\d)([A-P])$', s)
        if m:
            nb = f'{s[:m.start()]}_{m.group(1)}{chr(ord(m.group(2)) + 1)}'
            if nb in parent:
                parent[find(s)] = find(nb)
    comp = {}
    for g, ts in down.items():
        for t in ts:
            if t in parent:
                comp.setdefault(find(t), set()).add(g)
    for s, gs in up.items():
        if s in parent:
            comp.setdefault(find(s), set()).update(gs)
    links = []
    for gs in comp.values():
        gs = sorted(gs)
        for i in range(len(gs)):
            for j in range(i + 1, len(gs)):
                links.append((gs[i], gs[j]))
    return links


def level_graph(cat, romfs, level, layout, jump_rows, openings):
    """{cell: [(cell, frozenset req)]} directed edges; lock count."""
    n = LEVELS[level][0]
    pos = {cell_pos(c): c for c in layout}
    edges = {c: [] for c in layout}
    locks = 0
    for cell, room in layout.items():
        for d in cat.get(room, {}).get('doors', []):
            if len(d) > 3 and d[2] == 'lock':
                locks += 1
    jumped = set()
    for row in jump_rows:
        if row[0] != level:
            continue
        cell, side, own = row[1], row[2], int(row[3])
        if len(row) > 6:  # Chaos: (level, cell, side, own, partner, tcell, tside, ...)
            target = row[5]
        else:  # Coherent jump: to the neighbour
            c, r = cell_pos(cell)
            dc, dr = STEP[side]
            target = pos.get((c + dc, r + dr))
        jumped.add((cell, side, own))
        if target not in layout:
            continue
        req = door_terms(own_doors(cat, layout[cell], side, own), n)
        if req is not None:
            edges[cell].append((target, req))
    for cell, room in layout.items():
        op = openings(cat, room)
        c, r = cell_pos(cell)
        for side in 'NSWE':
            nb = pos.get((c + STEP[side][0], r + STEP[side][1]))
            if nb is None:
                continue
            theirs = {x[0] for x in openings(cat, layout[nb])[OPP[side]]}
            for x in op[side]:
                slot = x[0]
                if (cell, side, slot) in jumped or slot not in theirs:
                    continue
                req_out = door_terms(own_doors(cat, room, side, slot), n)
                req_in = door_terms(own_doors(cat, layout[nb], OPP[side], slot), n)
                if req_out is None or req_in is None:
                    continue
                edges[cell].append((nb, req_out | req_in))
    for a, b in stairs_links(romfs, level):
        ca, cb = a.rsplit('_', 1)[1], b.rsplit('_', 1)[1]
        if layout.get(ca) == a and layout.get(cb) == b:  # (stairs rooms stay home)
            edges[ca].append((cb, frozenset()))
            edges[cb].append((ca, frozenset()))
    return edges, locks


def reach_terms(edges, start, base):
    """{cell: set of frozensets} minimal sum-of-products of what reaching the cell needs."""
    req = {c: set() for c in edges}
    req[start] = {frozenset([base])}
    changed = True
    while changed:
        changed = False
        for a, outs in edges.items():
            for b, er in outs:
                for t in list(req[a]):
                    nt = t | er
                    if any(o <= nt for o in req[b]):
                        continue
                    req[b] = {o for o in req[b] if not nt <= o}
                    req[b].add(nt)
                    if len(req[b]) > MAX_TERMS:  # keep the cheapest
                        req[b] = set(sorted(req[b], key=lambda t: (len(t), sorted(t)))[:MAX_TERMS])
                    changed = True
    return req


# ---------------------------------------------------------------- applying it to LAS's logic
def apply(cat, romfs, layouts, jump_rows, logic_defs, item_defs, settings, extra_locations=None):
    """Rewrites logic_defs / item_defs for the shuffled dungeons. extra_locations: {name: room} (pots...).
    Returns a summary string. Sets settings['dungeon-of'] (location -> 'Dn') and adds unreachable checks to
    settings['excluded-locations']."""
    import dungeon_gen
    lr = json.load(open(os.path.join(HERE, 'location_rooms.json')))
    rooms_at = {}  # room -> [(level, cell)]
    cell_expr = {}  # (level, cell) -> condition string
    lock_count = {}
    logic_defs['rs-shutter'] = {'type': 'interaction', 'condition-basic': SHUTTER}
    boss_cell = {}
    for level, layout in layouts.items():
        n, region = LEVELS[level]
        for cell, room in layout.items():
            rooms_at.setdefault(room, []).append((level, cell))
            for d in cat.get(room, {}).get('doors', []):
                if len(d) > 3 and d[2] == 'bossdoor':  # the boss sits behind it
                    c, r = cell_pos(cell)
                    dc, dr = STEP[d[0]]
                    boss_cell[level] = cell_name(c + dc, r + dr)
        edges, locks = level_graph(cat, romfs, level, layout, jump_rows, dungeon_gen.openings)
        lock_count[n] = locks
        terms = reach_terms(edges, dungeon_gen.ENTRANCES[level], region)
        for cell, t in terms.items():
            s = dnf_str(t)
            if s:
                s = s.replace(f'KEYS-D{n}', f'key-D{n}:{locks}' if locks else '')
                s = re.sub(r'\(\s*&\s*|\s*&\s*\)', lambda m: '(' if '(' in m.group(0) else ')', s)
                s = re.sub(r'&\s*&', '&', s).strip(' &')
            cell_expr[(level, cell)] = s
        # LAS's cell regions of this dungeon: "reach that cell of the new layout"
        for k, v in logic_defs.items():
            if v.get('type') == 'room' and re.match(rf'D{n}-\d\d?[A-P]$', k):
                cell = k.split('-', 1)[1].rjust(3, '0')
                logic_defs[k]['condition-basic'] = cell_expr.get((level, cell)) or f'nightmare-key-D{n} & !nightmare-key-D{n}'
        # small keys: as many as the new layout has locks
        if f'key-D{n}' in item_defs:
            item_defs[f'key-D{n}']['quantity'] = locks
    shuffled = {LEVELS[lv][0] for lv in layouts}
    region_tok = {k for k, v in logic_defs.items() if v.get('type') in ('room', 'region')}

    def drop(atom):
        return atom in region_tok or re.match(r'key-D\d(:\d+)?$', atom) is not None

    dungeon_of = settings.setdefault('dungeon-of', {})
    excluded = settings.setdefault('excluded-locations', set())
    rewritten = unused = fallback = 0
    targets = {k: (v.get('room'), v.get('level')) for k, v in lr.items()}
    for k, room in (extra_locations or {}).items():
        targets[k] = (room, room.rsplit('_', 1)[0])
    for loc, v in list(logic_defs.items()):
        if v.get('type') != 'item' or loc not in targets:
            continue
        room, level = targets[loc]
        m = re.match(r'D(\d)-', loc)
        home = int(m.group(1)) if m else (LEVELS[level][0] if level in LEVELS else None)
        if home not in shuffled:
            continue
        if room is None and v.get('subtype') == 'boss':
            lv = next(l for l, (i, _) in LEVELS.items() if i == home)
            if lv in boss_cell:
                room = layouts[lv].get(boss_cell[lv])
        cond = v.get('condition-basic', '')
        if room is None:  # no room known (owl statues, Color Dungeon rupees...): vanilla condition on the new cells
            fallback += 1
            n = home
            v['condition-basic'] = re.sub(rf'key-D{n}:\d+', f'key-D{n}:{lock_count.get(n, 0)}' if lock_count.get(n) else '', cond)
            v['condition-basic'] = re.sub(r'&\s*&', '&', v['condition-basic']).strip(' &') or LEVELS[lv][1]
            continue
        places = rooms_at.get(room, [])
        reach = [cell_expr[p] for p in places if cell_expr.get(p)]
        if not reach:
            excluded.add(loc)
            unused += 1
            continue
        local, _ = strip(parse(cond), drop)
        r = reach[0] if len(reach) == 1 else ' | '.join(f'({x})' for x in reach)
        v['condition-basic'] = f'({r}) & ({show(local)})' if local else r
        for key in ('condition-advanced', 'condition-glitched', 'condition-hell'):
            v.pop(key, None)  # (the vanilla tricks describe the vanilla layout)
        lvl0 = next((p for p in places if LEVELS[p[0]][0] == home), places[0])[0]
        dungeon_of[loc] = f'D{LEVELS[lvl0][0]}'
        rewritten += 1
    return (f'{len(layouts)} dungeons, {rewritten} checks rewritten, {unused} in unused rooms (excluded), '
            f'{fallback} without a room (vanilla condition), locks {dict(sorted(lock_count.items()))}')
