#!/usr/bin/env python3
"""Pots randomizer (LAS Recomp addition on top of LAS-Randomizer).

Every liftable pot (ObjDungeonPot 0x1a7, ObjHousePot 0xeb) outside the Chamber Dungeons becomes an item location.
The item is a SinkingSword (0x194) item actor -- the same actor LAS uses for Heart Pieces -- placed at the pot's
position and scaled down so the pot model hides it: lifting, smashing or throwing the pot reveals it. Picking it up
sets a new GlobalFlags entry so it stays collected. The pot keeps its vanilla drop.

Logic (LAS logic.yml vocabulary; everything also needs LAS's `break-pot` = bracelet | bombs | sword:2):
  houses / caves  region of the door outside (tools/rando/entrance_data.yml) & that door's requirements
  Kanalet Castle  kanalet-inside;  Southern Face Shrine: armos-maze
  dungeons        conservative: the dungeon region AND every LAS location condition in that dungeon, i.e. the pot
                  counts as reachable only once the whole dungeon is (all keys, boss, every item check). Per-room
                  logic would be more generous; this never puts progression somewhere the player can't get to.
"""
import copy
import glob
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))

POT_TYPES = {0x1a7: 'ObjDungeonPot', 0xeb: 'ObjHousePot'}
SKIP_LEVEL_PREFIX = 'Panel'  # Chamber Dungeons (Dampe): rebuilt from the panel files, not real locations

DUNGEONS = {  # level -> (LAS location prefix, region, spoiler region)
    'Lv02BottleGrotto': ('D2', 'bottle-grotto', 'bottle-grotto'),
    'Lv03KeyCavern': ('D3', 'key-cavern', 'key-cavern'),
    'Lv04AnglersTunnel': ('D4', 'angler-tunnel', 'angler-tunnel'),
    'Lv05CatfishsMaw': ('D5', 'catfish-maw', 'catfish-maw'),
    'Lv06FaceShrine': ('D6', 'face-shrine', 'face-shrine'),
    'Lv07EagleTower': ('D7', 'eagle-tower', 'eagle-tower'),
    'Lv08TurtleRock': ('D8', 'turtle-rock', 'turtle-rock'),
    'Lv10ClothesDungeon': ('D0', 'color-dungeon', 'color-dungeon'),
}
SPECIAL = {  # level -> (region, extra condition)
    'KanaletCastle': ('kanalet-inside', None),
    'ArmosShrine': ('armos-maze', None),
}

# extra filler added to the pool, one per pot location (fractions of the pot count; user 2026-10-08: not only
# rupees - what pots really drop: single hearts, single arrows, bomb / powder refills). rupee-5 = the blue rupee.
JUNK_MIX = [('rupee-5', 0.26), ('rupee-20', 0.12), ('rupee-50', 0.05), ('rupee-100', 0.03),
            ('pot-heart', 0.22), ('pot-arrows', 0.12), ('pot-bombs', 0.12), ('pot-powder', 0.08)]
# pot filler items (LAS item defs). Refills only work once the item is owned: placed with REFILL_INDEX, the
# runtime (runtime/hle/keysanity.c rt_add_item) gives a blue rupee instead when the bombs / powder / bow are missing.
FILLER_DEFS = {
    'pot-heart': {'item-key': 'Heart', 'model-path': 'ItemRecoveryHeart.bfres', 'model-name': 'RecoveryHeart',
                  'npc-key': 'ItemRecoveryHeart'},
    'pot-arrows': {'item-key': 'Arrow', 'model-path': 'ItemArrow.bfres', 'model-name': 'Arrow', 'npc-key': 'ItemArrow'},
    'pot-bombs': {'item-key': 'Bomb', 'model-path': 'ItemBomb.bfres', 'model-name': 'Bomb', 'npc-key': 'ItemBomb'},
    'pot-powder': {'item-key': 'MagicPowder', 'model-path': 'ItemMagicPowder.bfres', 'model-name': 'MagicPowder',
                   'npc-key': 'ItemMagicPowder'},
}
REFILLS = ('pot-arrows', 'pot-bombs', 'pot-powder')
REFILL_INDEX = 80
QUICK = ('pot-heart',) + REFILLS  # picked up like rupees: no item-get animation
# traps among the pot filler, by LAS's trap setting (fraction of the pot count; never the Zol trap - it needs a chest)
POT_TRAPS = {'none': 0.0, 'few': 0.02, 'several': 0.06, 'many': 0.12, 'trapsanity': 0.25}
FLAG_BASE = 1240  # first GlobalFlags index we may use (vanilla <= 1118, LAS adds ~100 after it)
HIDE_SCALE = 0.7


def _and(*conds):
    parts = [c for c in conds if c]
    return ' & '.join(f'({c})' for c in parts) if parts else None


def scan(romfs, leb):
    """All randomizable pots: list of dicts with level, room, key, pos."""
    pots = []
    for f in sorted(glob.glob(os.path.join(romfs, 'region_common', 'level', '*', '*.leb'))):
        level = os.path.basename(os.path.dirname(f))
        if level.startswith(SKIP_LEVEL_PREFIX):
            continue
        room_name = os.path.basename(f)[:-4]
        with open(f, 'rb') as fh:
            room = leb.Room(fh.read())
        n = 0
        for i, a in enumerate(room.actors):
            if a.type not in POT_TYPES:
                continue
            pots.append({'level': level, 'room': room_name, 'key': a.key, 'n': n})
            n += 1
    return pots


def location_name(p):
    d = DUNGEONS.get(p['level'])
    room = p['room'].split('_')[-1]
    if d:  # 'D<n>-' prefix: LAS's dungeon-item placement treats these as in-dungeon locations
        return f"{d[0]}-pot-{room}-{p['n'] + 1}"
    return f"pot-{p['level']}-{room}-{p['n'] + 1}"


def _door_logic(entrance_data):
    out = {}
    for d in entrance_data['doors']:
        if d['type'] == 'single' or d['dest_level'] not in out:
            out[d['dest_level']] = (d['outer_region'], _and(d.get('outer_extra'), d.get('door_req')))
    return out


def add_to_logic(pots, logic_defs, item_defs, entrance_data, traps='none', rng=None):
    """Adds a location per pot to LAS's logic and matching filler to the pool (JUNK_MIX, traps by the seed's
    trap setting). Returns {location: pot}."""
    doors = _door_logic(entrance_data)
    spoiler_of = {}
    for k, v in logic_defs.items():
        if v.get('type') == 'item' and v.get('region') and v.get('spoiler-region'):
            spoiler_of.setdefault(v['region'], v['spoiler-region'])
    dungeon_cond = {}
    for level, (prefix, region, _) in DUNGEONS.items():
        conds = [v.get('condition-basic') for k, v in logic_defs.items()
                 if v.get('type') == 'item' and k.startswith(prefix + '-') and v.get('condition-basic')]
        dungeon_cond[level] = _and(*sorted(set(conds)))
    locs = {}
    skipped = set()
    for p in pots:
        lv = p['level']
        if lv in DUNGEONS:
            _, region, spoiler = DUNGEONS[lv]
            cond = _and(dungeon_cond[lv], 'break-pot')
        elif lv in SPECIAL:
            region, extra = SPECIAL[lv]
            cond, spoiler = _and(extra, 'break-pot'), spoiler_of.get(region)
        elif lv in doors:
            region, extra = doors[lv]
            cond, spoiler = _and(extra, 'break-pot'), spoiler_of.get(region)
        else:
            skipped.add(lv)
            continue
        name = location_name(p)
        logic_defs[name] = {'type': 'item', 'subtype': 'standing', 'content': 'rupee-5', 'region': region,
                            'spoiler-region': spoiler or 'mabe-village', 'condition-basic': cond}
        locs[name] = p
    for k, d in FILLER_DEFS.items():
        item_defs.setdefault(k, dict(d, type='junk', quantity=0, **{'chest-type': 'junk'}))
    n = len(locs)
    trap_kinds = [k for k in item_defs if k.endswith('-trap') and not k.startswith('zol')]
    n_traps = int(round(n * POT_TRAPS.get(traps, 0.0))) if trap_kinds else 0
    if n_traps:
        import random
        rng = rng or random.Random(n)
        for _ in range(n_traps):
            item_defs[rng.choice(trap_kinds)]['quantity'] += 1
    left = n - n_traps
    m = left
    for i, (item, frac) in enumerate(JUNK_MIX):
        k = left if i == len(JUNK_MIX) - 1 else int(round(m * frac))
        item_defs.setdefault(item, {'quantity': 0})
        item_defs[item]['quantity'] += k
        left -= k
    return locs, skipped


def mark_refills(placements):
    """Every location holding a bomb / powder / arrow refill (pots, chests, ...) gets REFILL_INDEX: the runtime
    turns it into a blue rupee while the item isn't owned (a refill must not unlock bombs / powder)."""
    idx = placements.setdefault('indexes', {})
    n = 0
    for loc, item in list(placements.items()):
        if loc != 'indexes' and item in REFILLS:
            idx[loc] = REFILL_INDEX
            n += 1
    return n


def apply(locs, mods, out_dir, romfs, leb, event_tools, oead_tools, item_get, data):
    """Writes the item actors, event entry points and flags for every pot location (after LAS's ModsProcess)."""
    common_out = os.path.join(out_dir, 'romfs', 'region_common')
    common_in = os.path.join(romfs, 'region_common')

    def path(rel):
        p = os.path.join(common_out, rel)
        return p if os.path.exists(p) else os.path.join(common_in, rel)

    def out(rel):
        p = os.path.join(common_out, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    sheet = oead_tools.readSheet(path('datasheets/GlobalFlags.gsheet'))
    used = {int(v['index']) for v in sheet['values']}
    flow = event_tools.readFlow(path('event/SinkingSword.bfevfl'))
    next_flag = max([FLAG_BASE] + [u + 1 for u in used if u >= FLAG_BASE])
    by_room = {}
    for name, p in locs.items():
        by_room.setdefault((p['level'], p['room']), []).append((name, p))
    spoiler = []
    for (level, room_name), entries in sorted(by_room.items()):
        rel = f'level/{level}/{room_name}.leb'
        with open(path(rel), 'rb') as fh:
            room = leb.Room(fh.read())
        by_key = {a.key: a for a in room.actors}
        for name, p in entries:
            pot = by_key.get(p['key'])
            if pot is None:
                continue
            if next_flag >= 2048:
                raise RuntimeError('out of GlobalFlags indices for pots')
            flag = f'LARPot{next_flag}'
            sheet['values'].append({'symbol': flag, 'index': next_flag})
            next_flag += 1
            item_key, item_index, model_path, model_name = mods.getItemInfo(name, mods.trap_models)
            if item_key[:3] == 'Rup' or mods.placements[name] in QUICK:
                get_anim = event_tools.createActionEvent(flow.flowchart, 'Inventory', 'AddItemByKey',
                                                         {'itemKey': item_key, 'count': 1, 'index': item_index,
                                                          'autoEquip': False})
            else:
                get_anim = item_get.insertItemGetAnimation(flow.flowchart, item_key, item_index)
            event_tools.addEntryPoint(flow.flowchart, name)
            event_tools.createActionChain(flow.flowchart, name, [
                ('SinkingSword', 'Destroy', {}),
                ('EventFlags', 'SetFlag', {'symbol': flag, 'value': True})], get_anim)
            it = copy.deepcopy(pot)
            it.key = 0x7A00000000000000 | ((p['n'] & 0xFFFF) << 32) | (pot.key & 0xFFFFFFFF)
            it.name = b'SinkingSword-%016X' % it.key
            it.type = 0x194
            it.parameters = [model_path.encode(), model_name.encode(), name.encode(), flag.encode(),
                             b'true' if item_key == 'Seashell' else b'false', b'', b'', b'']
            it.switches = [(4, 0), (4, 0), (4, 0), (4, 0)]
            s = data.MODEL_SIZES.get(model_name, 1.0) * HIDE_SCALE
            it.scaleX = it.scaleY = it.scaleZ = s
            if model_name in data.MODEL_ROTATIONS:
                it.rotY = data.MODEL_ROTATIONS[model_name]
            room.actors.append(it)
            spoiler.append(f'  {name:34} {mods.placements[name]}')
        with open(out(rel), 'wb') as fh:
            fh.write(room.repack())
    oead_tools.writeSheet(out('datasheets/GlobalFlags.gsheet'), sheet)
    event_tools.writeFlow(out('event/SinkingSword.bfevfl'), flow)
    return spoiler


def write_tsv(seed_dir, leb):
    """rando/<seed>/pots.tsv for the runtime's golden unchecked pots: one line per item pot
    (level, x, y, z, GlobalFlags index), taken from the item actors this module placed in the seed's rooms."""
    rows = []
    for f in sorted(glob.glob(os.path.join(seed_dir, 'romfs', 'region_common', 'level', '*', '*.leb'))):
        level = os.path.basename(os.path.dirname(f))
        with open(f, 'rb') as fh:
            room = leb.Room(fh.read())
        for a in room.actors:
            if a.type != 0x194 or not isinstance(a.parameters[3], bytes):
                continue
            m = re.match(rb'LARPot(\d+)$', a.parameters[3])
            if m:
                rows.append(f'{level}\t{a.posX:g}\t{a.posY:g}\t{a.posZ:g}\t{int(m.group(1))}\n')
    with open(os.path.join(seed_dir, 'pots.tsv'), 'w') as fh:
        fh.writelines(rows)
    return len(rows)


if __name__ == '__main__':  # pots.py <seed dir>: (re)write its pots.tsv
    import sys
    import types
    LAS = os.path.normpath(os.path.join(HERE, '..', '..', 'third_party', 'LAS-Randomizer'))
    sys.modules['PySide6'] = types.ModuleType('PySide6')
    sys.modules['PySide6.QtCore'] = types.ModuleType('PySide6.QtCore')
    sys.path.insert(0, LAS)
    from RandomizerCore.Tools import leb as _leb
    print(write_tsv(os.path.abspath(sys.argv[1]), _leb), 'item pots')
