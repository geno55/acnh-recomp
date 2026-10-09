#!/usr/bin/env python3
"""Trendsanity (LAS Recomp addition on top of LAS-Randomizer): every Trendy Game prize is a check.

Checks: LAS's trendy-prize-1..6 (Yoshi doll, the two pieces of heart, the two secret seashells, the chamber stone;
forced vanilla by LAS until now), the ten figures (new trendy-figure-1..10, Small BowWow .. BowWow, rupee filler
added to the pool) and LAS's trendy-prize-final (Trendy's gift for the last figure, already randomized by LAS's
GameShopOwner edit once not forced vanilla).

In the game (CranePrize.gsheet): each check is a new featured prize row (21+) in the vanilla prize's featured
group and floor spot, showing the randomized item's model; the vanilla rows it replaces never appear. Prize models
are actor/Prize<symbol>.bfres with a model named <symbol>: a copy of the item's model with the model renamed in
place to a unique name of the same length (same last character, so the file's name dictionary still finds it).
Winning one: AddPrizeByKey -> runtime/hle/shopsanity.c sets the check's flags (won: the row's layout condition
hides it from then on; "give": PrizeCommon gives the item with its item-get animation). A figure check also adds
that figure (house shelf; the BowWow figure starts Trendy's final gift as in the vanilla game).

Featured prizes of one floor spot come one at a time; each check's condition is its vanilla instrument (none for
the Yoshi doll / first heart piece / first seashell / Small BowWow; all eight for the BowWow figure, as the final
gift). Logic: can-farm-rupees (10 rupees a try) & the same instruments.
"""
import copy
import os

# (location, vanilla CranePrize row, its layout, featured group, record, place (type, index), instruments)
INSTR = ['full-moon-cello', 'conch-horn', 'sea-lilys-bell', 'surf-harp', 'wind-marimba', 'coral-triangle',
         'evening-calm-organ', 'thunder-drum']
INSTR_KEY = {'full-moon-cello': 'FullMoonCello', 'conch-horn': 'ConchHorn', 'sea-lilys-bell': 'SeaLilysBell',
             'surf-harp': 'SurfHarp', 'wind-marimba': 'WindMarimba', 'coral-triangle': 'CoralTriangle',
             'evening-calm-organ': 'EveningCalmOrgan', 'thunder-drum': 'ThunderDrum'}
CHECKS = [
    ('trendy-prize-1', 7, 0, 1, 0, (1, 0), []),
    ('trendy-figure-1', 10, 0, 1, 1, (1, 2), []),
    ('trendy-figure-2', 11, 0, 1, 2, (2, 1), INSTR[0:1]),
    ('trendy-figure-3', 12, 0, 1, 3, (1, 2), INSTR[1:2]),
    ('trendy-figure-4', 13, 0, 1, 4, (2, 1), INSTR[2:3]),
    ('trendy-figure-5', 14, 0, 1, 5, (1, 2), INSTR[3:4]),
    ('trendy-figure-6', 15, 0, 1, 6, (2, 1), INSTR[4:5]),
    ('trendy-figure-7', 16, 0, 1, 7, (1, 2), INSTR[5:6]),
    ('trendy-figure-8', 17, 0, 1, 8, (2, 1), INSTR[6:7]),
    ('trendy-figure-9', 18, 0, 1, 9, (1, 2), INSTR[7:8]),
    ('trendy-figure-10', 19, 0, 1, 10, (2, 1), INSTR),
    ('trendy-prize-2', 8, 0, 2, 0, (1, 1), []),
    ('trendy-prize-3', 9, 0, 2, 1, (1, 1), []),
    ('trendy-prize-4', 20, 0, 2, 2, (2, 0), INSTR[1:2]),
    ('trendy-prize-5', 8, 1, 2, 3, (2, 1), INSTR[2:3]),
    ('trendy-prize-6', 9, 1, 2, 4, (2, 0), INSTR[3:4]),
]
FIGURE_ROWS = range(10, 20)
FILLER = 'rupee-50'
FIRST_ROW = 21  # AddPrize knows rows 0-20


def enabled(settings):
    return bool(settings.get('trendsanity'))


def add_to_logic(logic_defs, item_defs):
    """Returns {entrance door: [(location, condition)]} for shuffled interiors."""
    need = {1: [], 2: []}  # a group's featured prizes come one at a time: everything the earlier ones need too
    for loc, row, _, group, _, _, instr in CHECKS:
        need[group] += [i for i in instr if i not in need[group]]
        d = logic_defs.get(loc)
        if d is None:
            d = logic_defs[loc] = {'type': 'item', 'subtype': 'standing', 'content': FILLER, 'region': 'trendy',
                                   'spoiler-region': 'mabe-village'}
            item_defs[FILLER]['quantity'] += 1
        d['condition-basic'] = ' & '.join(['can-farm-rupees'] + need[group])
    return {'trendy-game': [(c[0], logic_defs[c[0]]['condition-basic']) for c in CHECKS]}


def rename_model(data, old, new):
    """The bfres with its (only) model renamed in the string pool (same length: offsets stay valid)."""
    assert len(old) == len(new)
    pat = len(old).to_bytes(2, 'little') + old.encode() + b'\0'
    assert data.count(pat) == 1, old
    i = data.index(pat)
    return data[:i + 2] + new.encode() + data[i + 2 + len(old):]


def symbol_for(model_name, n):
    """Unique prize symbol of the model name's length, ending with its last character."""
    code = ''
    v = n
    for _ in range(len(model_name) - 2):
        code = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ'[v % 36] + code
        v //= 36
    assert v == 0 and len(model_name) >= 3, model_name
    return 'L' + code + model_name[-1]


def apply(mods, out_dir, romfs, settings, event_tools, oead_tools, item_get, las_data, alloc_flags):
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
    names = [f'LARPrize{n}' for n in range(len(CHECKS))] + [f'LARPrizeGive{n}' for n in range(len(CHECKS))]
    flags = alloc_flags(sheet, names + ['LARPrizeOff'])
    final_flag = next(int(v['index']) for v in sheet['values'] if v['symbol'] == 'BowWowFigureGet')  # Trendy's gift
    oead_tools.writeSheet(out('datasheets/GlobalFlags.gsheet'), sheet)

    sheet = oead_tools.readSheet(path('datasheets/CranePrize.gsheet'))
    rows = [oead_tools.parseStruct(v) for v in sheet['values']]
    assert len(rows) == FIRST_ROW, len(rows)
    checks = []
    for n, (loc, vrow, vlayout, group, rec, place, instr) in enumerate(CHECKS):
        key, index, model_path, model_name = mods.getItemInfo(loc, mods.trap_models)
        sym = symbol_for(model_name, n)
        src = os.path.join(common_out, 'actor', model_path)
        if not os.path.exists(src):
            src = os.path.join(common_in, 'actor', model_path)
        with open(src, 'rb') as f:
            model = rename_model(f.read(), model_name, sym)
        with open(out(f'actor/Prize{sym}.bfres'), 'wb') as f:
            f.write(model)
        conds = [{'category': 2, 'parameter': INSTR_KEY[i]} for i in instr]
        conds.append({'category': 1, 'parameter': f'!LARPrize{n}'})
        new = copy.deepcopy(rows[7])  # the Yoshi doll row: a featured, grabbable "Sample" prize
        new.update(symbol=sym, getCount=1, modelScale=float(las_data.MODEL_SIZES.get(model_name, 1.0)),
                   layouts=[{'itemIndex': -1, 'conditions': conds, 'place': {'type': place[0], 'index': place[1]}}])
        new['options']['isFeatured'] = True
        checks.append({'n': n, 'loc': loc, 'row': FIRST_ROW + n, 'vrow': vrow, 'vlayout': vlayout, 'group': group,
                       'rec': rec, 'key': key, 'index': index, 'sym': sym, 'new': new})
    # the vanilla prizes replaced by checks never appear (rows stay: AddPrize knows them by row)
    for c in checks:
        sheet['values'][c['vrow']]['layouts'][c['vlayout']]['conditions'].append({'category': 1, 'parameter': 'LARPrizeOff'})
    for v in sheet['values']:
        if v['symbol'] == 'RupeeRed':  # LAS: the red rupee in the Yoshi doll's spot waits for the doll to be won
            for lay in v['layouts']:
                for cond in lay['conditions']:
                    if cond['parameter'] == 'TradeYoshiDollGet':
                        cond['parameter'] = 'LARPrize0'
    for c in checks:
        sheet['values'].append(oead_tools.dictToStruct(c['new']))
    oead_tools.writeSheet(out('datasheets/CranePrize.gsheet'), sheet)

    # featured groups: the vanilla order with each record pointing at its check's row (group 1 from the game's own
    # sheet: LAS removed the Yoshi doll's record)
    for g in (1, 2):
        name = f'datasheets/CranePrizeFeaturedPrizeGroup{g}.gsheet'
        sheet = oead_tools.readSheet(os.path.join(common_in, name))
        for c in checks:
            if c['group'] == g:
                sheet['values'][c['rec']]['cranePrizeId'] = c['row']
                sheet['values'][c['rec']]['layoutIndex'] = 0
        oead_tools.writeSheet(out(name), sheet)

    # PrizeCommon 'get': Deactivate -> AddPrizeByKey (the runtime flags a check) -> the check's item, or the vanilla
    # get sequence -> HasPrize(BowWow figure) ... as before. (AddPrize moves before the vanilla fanfare.)
    flow = event_tools.readFlow(path('event/PrizeCommon.bfevfl'))
    fc = flow.flowchart
    seq, add, after = 'Event0', 'Event1', 'Event5'
    assert event_tools.findEvent(fc, seq).data.nxt.v.name == add
    event_tools.insertEventAfter(fc, seq, after)
    nxt = seq
    for c in reversed(checks):
        n = c['n']
        clear = event_tools.createActionEvent(fc, 'EventFlags', 'SetFlag', {'symbol': f'LARPrizeGive{n}', 'value': False}, after)
        give = item_get.insertItemGetAnimation(fc, c['key'], c['index'], None, clear)
        nxt = event_tools.createSwitchEvent(fc, 'EventFlags', 'CheckFlag', {'symbol': f'LARPrizeGive{n}'}, {0: nxt, 1: give})
    event_tools.insertEventAfter(fc, add, nxt)
    event_tools.insertEventAfter(fc, 'Event2', add)
    event_tools.writeFlow(out('event/PrizeCommon.bfevfl'), flow)

    with open(os.path.join(out_dir, 'shopsanity.tsv'), 'a') as f:  # runtime/hle/shopsanity.c
        for c in checks:
            addrow = c['vrow'] if c['vrow'] in FIGURE_ROWS else 255
            f.write(f"prize\t{c['row']}\t{flags['LARPrize%d' % c['n']]}\t{flags['LARPrizeGive%d' % c['n']]}\t{addrow}\n")
    with open(os.path.join(out_dir, 'check_flags.tsv'), 'a') as f:
        for c in checks:
            f.write(f"{c['loc']}\t{flags['LARPrize%d' % c['n']]}\n")
        f.write(f"trendy-prize-final\t{final_flag}\n")
    return [f"  {c['loc']:20} {mods.placements[c['loc']]}" for c in checks]
