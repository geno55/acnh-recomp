#!/usr/bin/env python3
"""Logic for the LAS Recomp entrance randomizer (single-entrance interiors), on top of LAS-Randomizer's logic.yml.

LAS reachability is a fixpoint over named nodes, so the shuffle is expressed as new nodes:
  door-<id>    you can stand outside door <id> and get through it: outer_region & outer_extra & door_req
  inside-<id>  you are inside the interior that door <id> led to in vanilla: OR of door-<d> over every door d
               that now leads into it
Every LAS location inside that interior moves to region inside-<id> with the condition it has once you're inside
(tools/rando/entrance_data.yml `inside`). Decoupled exits add the reverse edges: leaving interior I puts you
outside door c, so region outer_region(c) also becomes reachable from inside-I.

Pool (v1): `single` doors that are land doors, recommended for shuffling, not reached through a pocket, and not
Marin & Tarin's house (the game starts inside it). Dungeons use LAS's own `shuffle-dungeons`. Connectors later.
"""
import os
import random

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
KEEP = {'marin-tarin-house'}  # game start
# conditions elsewhere that mean "you can get inside this interior"
INSIDE_TOKENS = {('christine-grateful', 'mr-write-house'): 'mr-write-house'}


def load(path=os.path.join(HERE, 'entrance_data.yml')):
    with open(path) as f:
        return yaml.safe_load(f)


def pool(ed):
    out = []
    for d in ed['doors']:
        if d['type'] != 'single' or d['id'] in KEEP:
            continue
        if d.get('water') or d.get('pocket') or d.get('outer_extra') or d.get('shuffle_recommended') is False:
            continue
        out.append(d)
    return out


def shuffle(doors, decoupled, rng):
    """entry: door id -> interior (vanilla door id) it now leads into; exit: interior -> door id it exits to."""
    ids = [d['id'] for d in doors]
    targets = ids[:]
    rng.shuffle(targets)
    entry = dict(zip(ids, targets))
    if decoupled:
        outs = ids[:]
        rng.shuffle(outs)
        exit_ = dict(zip(ids, outs))
    else:
        exit_ = {t: d for d, t in entry.items()}
    return entry, exit_


def _and(*parts):
    parts = [p for p in parts if p]
    return ' & '.join(f'({p})' for p in parts) if parts else None


def _or_into(node, extra):
    """region node condition |= extra (a region without a condition is always reachable already)."""
    c = node.get('condition-basic')
    if c is None:
        return
    node['condition-basic'] = f'({c}) | ({extra})'


def apply_logic(logic, doors, entry, exit_, extra_inside=None):
    """extra_inside: {vanilla door id: [(location, cond)]} for added locations (e.g. item pots) in interiors."""
    by_id = {d['id']: d for d in doors}
    for d in doors:
        logic[f"door-{d['id']}"] = {'type': 'region',
                                     'condition-basic': _and(d['outer_region'], d.get('outer_extra'), d.get('door_req'))}
    into = {}
    for d, t in entry.items():
        into.setdefault(t, []).append(d)
    for t, ds in into.items():
        logic[f'inside-{t}'] = {'type': 'region', 'condition-basic': ' | '.join(f'door-{d}' for d in ds)}
    moved = 0
    for t in into:
        for it in list(by_id[t].get('inside') or []) + [{'location': l, 'cond': c} for l, c in (extra_inside or {}).get(t, [])]:
            loc = logic.get(it['location'])
            if not loc:
                continue
            loc['region'] = f'inside-{t}'
            for k in ('condition-advanced', 'condition-glitched', 'condition-hell'):
                loc.pop(k, None)  # those were written against vanilla outer access; basic-only is never looser
            if it.get('cond'):
                loc['condition-basic'] = str(it['cond'])
            else:
                loc.pop('condition-basic', None)
            moved += 1
    for (loc, token), door in INSIDE_TOKENS.items():
        if loc in logic and door in by_id and f'inside-{door}' in logic:
            c = logic[loc].get('condition-basic', '')
            logic[loc]['condition-basic'] = ' '.join(f'inside-{door}' if w == token else w for w in c.split())
    # leaving interior I through door c puts Link outside c (coupled: the door he came in by)
    for t, c in exit_.items():
        region = by_id[c]['outer_region']
        if region in logic and f'inside-{t}' in logic:
            _or_into(logic[region], f'inside-{t}')
    return moved


def spoiler(doors, entry, exit_):
    by_id = {d['id']: d for d in doors}
    lines = ['Entrances (door -> interior it leads into):']
    for d in sorted(entry):
        lines.append(f'  {d:32} -> {entry[d]:32} ({by_id[entry[d]]["dest_level"]})')
    if any(exit_[t] != d for d, t in entry.items()):
        lines.append('Exits (interior -> outside of door):')
        for t in sorted(exit_):
            lines.append(f'  {t:32} -> {exit_[t]}')
    return '\n'.join(lines)


if __name__ == '__main__':
    ed = load()
    ds = pool(ed)
    print(len(ds), 'doors in the pool')
    e, x = shuffle(ds, False, random.Random(1))
    print(spoiler(ds, e, x)[:800])


def apply_rooms(doors, entry, exit_, read_room, write_room, zones_path=os.path.join(HERE, 'loading_zones.json')):
    """Rewrite loading zones: door d gets the entry params of interior entry[d]; every zone in interior t that
    leads back outside gets the return params of interior exit_[t] (which put Link outside that door)."""
    import json
    import re
    zones = json.load(open(zones_path))

    def base(r):
        m = re.match(r'(.+_\d\d[A-Z])', r)
        return m.group(1) if m else r

    by_id = {d['id']: d for d in doors}
    field = {}  # door id -> params of its field zone
    returns = {}  # door id -> [(room, index)] interior zones leading back to its screen
    ret_params = {}
    for d in doors:
        z = next(z for z in zones if z['room'] == d['field_room'] and z['index'] == d['zone_index'])
        field[d['id']] = list(z['params'])
        rs = [z for z in zones if z['level'] == d['dest_level'] and z['params'][0] == 'Field'
              and base(z['params'][1]) == base(d['return_zone']['target'] if d.get('return_zone') else d['field_room'])]
        returns[d['id']] = [(z['room'], z['index']) for z in rs]
        if rs:
            ret_params[d['id']] = list(rs[0]['params'])
    edits = {}
    for d, t in entry.items():
        edits.setdefault(by_id[d]['field_room'], {})[by_id[d]['zone_index']] = field[t]
    for t, c in exit_.items():
        if c not in ret_params:
            continue
        for room, idx in returns[t]:
            edits.setdefault(room, {})[idx] = ret_params[c]
    for room_name, ze in edits.items():
        room = read_room(room_name)
        zs = [a for a in room.actors if a.type == 0x190]
        for idx, params in ze.items():
            if idx < len(zs):
                for i, p in enumerate(params):
                    zs[idx].parameters[i] = p.encode('utf-8') if isinstance(p, str) else p
        write_room(room_name, room)
    return len(edits)


def verify(seed_dir, romfs):
    """Re-read the seed's rooms and check every shuffled door / interior exit against the spoiler mapping."""
    import json
    import re
    import sys
    import types
    las = os.path.normpath(os.path.join(HERE, '..', '..', 'third_party', 'LAS-Randomizer'))
    sys.modules.setdefault('PySide6', types.ModuleType('PySide6'))
    sys.modules.setdefault('PySide6.QtCore', types.ModuleType('PySide6.QtCore'))
    sys.path.insert(0, las)
    from RandomizerCore.Tools import leb
    doors = {d['id']: d for d in pool(load())}
    sp = open(next(os.path.join(seed_dir, f) for f in os.listdir(seed_dir) if f.startswith('entrances_'))).read()
    entry = dict(re.findall(r'^  (\S+)\s+-> (\S+)\s+\(', sp, re.M))
    exits = dict(re.findall(r'^  (\S+)\s+-> (\S+)$', sp.split('Exits')[1], re.M)) if 'Exits' in sp else {t: d for d, t in entry.items()}
    zones = json.load(open(os.path.join(HERE, 'loading_zones.json')))
    vz = {(z['room'], z['index']): z['params'] for z in zones}

    def room(name):
        lv = re.match(r'(.+)_\d\d[A-Z]', name).group(1)
        for base in (os.path.join(seed_dir, 'romfs', 'region_common', 'level'), os.path.join(romfs, 'region_common', 'level')):
            p = os.path.join(base, lv, name + '.leb')
            if os.path.exists(p):
                return [[x.decode() if isinstance(x, bytes) else x for x in a.parameters] for a in leb.Room(open(p, 'rb').read()).actors if a.type == 0x190]
    bad = 0
    for d, t in entry.items():
        got = room(doors[d]['field_room'])[doors[d]['zone_index']][:2]
        want = vz[(doors[t]['field_room'], doors[t]['zone_index'])][:2]
        if got != want:
            bad += 1
            print('door', d, 'has', got, 'want', want)
    for t, c in exits.items():
        rz = doors[c].get('return_zone')
        tz = doors[t].get('return_zone')
        if not rz or not tz:
            continue
        got = room(tz['room'])[tz['index']][:2]
        want = vz[(rz['room'], rz['index'])][:2]
        if got != want:
            bad += 1
            print('exit of', t, 'has', got, 'want', want)
    print(f'{len(entry)} doors, {len(exits)} exits checked, {bad} mismatches')
    return bad
