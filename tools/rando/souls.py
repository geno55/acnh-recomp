#!/usr/bin/env python3
"""Boss souls (LAS Recomp randomizer option "Boss souls", request key boss-souls).

Each dungeon boss has a soul in the item pool. Until it's found the boss doesn't appear in its arena (the arena stays
open and empty, Link can walk out), so it can't be beaten and its reward can't be had: the runtime
(runtime/hle/souls.c, factory hook tools/patches.py BOSS_SPAWN_SITE) refuses to create the boss and the reward
actor (the instrument; the Color Dungeon's Great Fairy) while the soul's event flag is clear.

The soul is a new item: an Items.gsheet row per boss (the Secret Medicine's model; its gettingFlag = the soul flag),
an Item.bfevfl entry point showing the get message, System.msbt text "You got Moldorm's Soul!" (English in every
language folder). The item-get chains set the flag themselves (LAS item_get / chests, patched for 'BossSoul' keys).
Logic: the boss's LAS kill condition (kill-moldorm...) needs the soul, so every check behind it does too - also after
tools/rando/room_logic.py rewrites dungeon checks (it keeps non-room atoms such as kill-moldorm). The Color
Dungeon's fairy rewards get kill-evil-orb (LAS never asked for the boss there).
"""
import os
import glob

# dungeon (0 = Color Dungeon), boss, its actor type, LAS kill token, level
BOSSES = [
    (1, 'Moldorm', 0x63, 'kill-moldorm', 'Lv01TailCave'),
    (2, 'Genie', 0x64, 'kill-genie', 'Lv02BottleGrotto'),
    (3, 'Slime Eye', 0x65, 'kill-slime-eye', 'Lv03KeyCavern'),
    (4, 'Angler Fish', 0x66, 'kill-angler', 'Lv04AnglersTunnel'),
    (5, 'Slime Eel', 0x67, 'kill-slime-eel', 'Lv05CatfishsMaw'),
    (6, 'Facade', 0x68, 'kill-facade', 'Lv06FaceShrine'),
    (7, 'Evil Eagle', 0x69, 'kill-evil-eagle', 'Lv07EagleTower'),
    (8, 'Hot Head', 0x6a, 'kill-hothead', 'Lv08TurtleRock'),
    (0, 'Evil Orb', 0x62, 'kill-evil-orb', 'Lv10ClothesDungeon'),
]
ITEM_ID_BASE = 82  # Items.gsheet itemIDs 82-90: unused (LAS's extra rows: 63-70, 127+, 200+; pets carry 79-81; shop 230+)
FAIRY_QUEEN = 0x6D0024005CF48AC2  # the Color Dungeon's Great Fairy (Lv10ClothesDungeon_04C): its tunics are the reward
JUNK = ('rupee-50', 'rupee-20', 'rupee-100', 'rupee-300')  # pool junk the souls replace
MODEL = {'model-path': 'ItemSecretMedicine.bfres', 'model-name': 'SecretMedicine', 'npc-key': 'ItemSecretMedicine'}


def item_key(boss):
    return 'BossSoul' + boss.replace(' ', '')


def las_name(boss):
    return 'soul-' + boss.lower().replace(' ', '-')


def add_to_logic(logic_defs, item_defs):
    """Souls into the pool (replacing junk, LAS needs one item per location) and into the bosses' kill conditions."""
    for n, boss, _, kill, _ in BOSSES:
        item_defs[las_name(boss)] = dict(MODEL, **{'type': 'important', 'quantity': 1, 'item-key': item_key(boss)})
        for k, c in list(logic_defs[kill].items()):
            if k.startswith('condition-'):
                logic_defs[kill][k] = f'({c}) & {las_name(boss)}'
    for loc in ('D0-fairy-1', 'D0-fairy-2'):
        logic_defs[loc]['condition-basic'] += ' & kill-evil-orb'
    # (only rupees no location keeps vanilla: the blue rupees and some chamber stones stay put when not shuffled)
    for _ in BOSSES:
        junk = max(JUNK, key=lambda k: item_defs[k]['quantity'])
        assert item_defs[junk]['quantity'] > 0
        item_defs[junk]['quantity'] -= 1
    return len(BOSSES)


def _reward_keys(out_romfs, romfs, leb):
    """Instrument actor key per dungeon (LAS writes 'D<n>-instrument' into its parameters)."""
    keys = {0: FAIRY_QUEEN}
    for n, _, _, _, level in BOSSES:
        if not n:
            continue
        files = {os.path.basename(f): f for f in glob.glob(os.path.join(romfs, 'region_common', 'level', level, '*.leb'))}
        files.update({os.path.basename(f): f for f in glob.glob(os.path.join(out_romfs, 'region_common', 'level', level, '*.leb'))})
        for f in files.values():
            with open(f, 'rb') as fh:
                room = leb.Room(fh.read())
            for a in room.actors:
                if f'D{n}-instrument'.encode() in a.parameters:
                    keys[n] = a.key
    return keys


def apply(out_dir, romfs, leb, oead_tools, event_tools, msbt):
    """After LAS's ModsProcess: flags, item rows, get messages, rando/<seed>/souls.tsv for the runtime."""
    out_romfs = os.path.join(out_dir, 'romfs')

    def src(rel):
        p = os.path.join(out_romfs, rel)
        return p if os.path.exists(p) else os.path.join(romfs, rel)

    def dst(rel):
        p = os.path.join(out_romfs, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        return p

    # event flags, after LAS's own (before potsanity's 1240+)
    rel = 'region_common/datasheets/GlobalFlags.gsheet'
    sheet = oead_tools.readSheet(src(rel))
    nxt = max(int(v['index']) for v in sheet['values'] if int(v['index']) < 1240) + 1
    flags = {}
    for _, boss, _, _, _ in BOSSES:
        flags[boss] = nxt
        sheet['values'].append({'symbol': item_key(boss), 'index': nxt})
        nxt += 1
    assert nxt <= 1240, nxt
    oead_tools.writeSheet(dst(rel), sheet)

    # item rows: the Secret Medicine's, renamed (the get sequence looks items up by key)
    rel = 'region_common/datasheets/Items.gsheet'
    sheet = oead_tools.readSheet(src(rel))
    base = next(oead_tools.parseStruct(v) for v in sheet['values'] if v['symbol'] == 'SecretMedicine')
    for i, (_, boss, _, _, _) in enumerate(BOSSES):
        row = dict(base, symbol=item_key(boss), itemID=ITEM_ID_BASE + i, gettingFlag=item_key(boss), npcKey=MODEL['npc-key'])
        sheet['values'].append(oead_tools.dictToStruct(row))
    oead_tools.writeSheet(dst(rel), sheet)

    # get messages: GenericItemGetSequenceByKey runs the Item.bfevfl entry point named by its messageEntry
    rel = 'region_common/event/Item.bfevfl'
    flow = event_tools.readFlow(src(rel))
    for _, boss, _, _, _ in BOSSES:
        k = item_key(boss)
        event_tools.addEntryPoint(flow.flowchart, k)
        ev = event_tools.createActionEvent(flow.flowchart, 'Dialog', 'Show', {'message': f'System:Get{k}'})
        event_tools.insertEventAfter(flow.flowchart, k, ev)
    event_tools.writeFlow(dst(rel), flow)
    red, white = b'\x0e\x00\x00\x03\x00\x04\x00\xd9Em\xff', b'\x0e\x00\x00\x03\x00\x04\x00\xed\xed\xed\xff'
    end = b'\x0e\x01\x00\x04\x00\x00\x00\x00'
    n_msg = 0
    for f in glob.glob(os.path.join(romfs, 'region*', '*', 'message', 'System.msbt')):
        rel = os.path.relpath(f, romfs)
        m = msbt.Msbt(open(src(rel), 'rb').read())
        for _, boss, _, _, _ in BOSSES:
            m.set(f'Get{item_key(boss)}', b'You got ' + red + f"{boss}'s Soul".encode() + white +
                  f'!\n{boss} now awaits you in its lair.'.encode() + end)
        with open(dst(rel), 'wb') as fh:
            fh.write(m.pack())
        n_msg += 1

    rewards = _reward_keys(out_romfs, romfs, leb)
    with open(os.path.join(out_dir, 'souls.tsv'), 'w') as f:  # dungeon, boss actor type, flag, name, reward actor key
        for n, boss, typ, _, _ in BOSSES:
            f.write(f'{n}\t{typ:#x}\t{flags[boss]}\t{boss}\t{rewards.get(n, 0):#x}\n')
    return f'{len(BOSSES)} souls (flags {min(flags.values())}-{max(flags.values())}), {len(rewards)} rewards held back, {n_msg} message files'
