#!/usr/bin/env python3
"""Pets (LAS Recomp addition): companions found as items, like any other item in the pool.

  Rooster  (setting pet-rooster): logic token `rooster` (LAS logic already uses it wherever the Flying Rooster can stand
           in for the feather or hookshot, inside dungeons only with bad-pets = "Companions allowed in dungeons").
           The vanilla revival at the rooster's grave in Mabe still works but leaves the logic.
  Ghost    (setting pet-ghost): the Ghost's grave check (`ghost-reward`, the Owl at the grave) needs the Ghost found:
           finding him skips his house visit (Ghost2/3 flags) so he asks for his grave right away. The Surf Harp no
           longer finishes the Ghost's quest, and he no longer appears by himself after the Harp (GhostJoinCheck).
  Marin    (open-desert off): the Walrus sleeps in front of Yarna Desert until Marin sings to him (vanilla event),
           so the desert needs Marin found. With open-desert on (LAS default: WalrusAwaked from the start) Marin
           isn't in the pool.

A pet item is a dummy Items.gsheet entry (the companion's model on the chest / in Link's hands) that reaches the
game's AddItem with index PET_INDEX + n; the runtime (runtime/hle/pets.c) turns that into the companion following
Link (save +0x555D) and remembers it (event flag FLAGS[n]) so the in-game menu can call any found pet back.
"""

PET_INDEX = 90
# itemID the dummies carry: PanelDungeonPieceSet (79), never given in a seed. Checked in game: Link holds up the
# npcKey's model (the pet) and no get message shows (the runtime toasts "<pet> joins you!"). ClothesGreen (17) showed
# "You got the green tunic!" and no model.
CARRIER_ID = 79
# item name (= logic token) -> (Items.gsheet symbol, npcKey, model file, model name, setting that puts it in the pool)
PETS = {
    'rooster': ('PetRooster', 'NpcFlyingCucco', 'NpcFlyingCucco.bfres', 'FlyingCucco'),
    'marin-companion': ('PetMarin', 'NpcMarin', 'NpcMarin.bfres', 'Marin'),
    'ghost': ('PetGhost', 'NpcGhost', 'NpcGhost.bfres', 'Ghost'),
}
ORDER = ['rooster', 'marin-companion', 'ghost']  # n in PET_INDEX + n (runtime/hle/pets.c kPets)
# runtime flags (unused vanilla GlobalFlags; flags.tsv via seed_tables.py EXACT): found rooster / Marin / Ghost,
# BowWow sent away by a pet (so he can be called back)
FLAGS = ['unused0427', 'unused0428', 'unused0429', 'unused0430']


def enabled(settings):
    out = []
    if settings.get('pet-rooster'):
        out.append('rooster')
    if not settings.get('open-desert', True):
        out.append('marin-companion')
    if settings.get('pet-ghost'):
        out.append('ghost')
    return out


def add_to_pool(logic, item_defs, settings):
    """Pet items into the pool (one 50-rupee less each) and the logic changes they make. Returns the pets."""
    pets = enabled(settings)
    for p in pets:
        sym, npc, path, model = PETS[p]
        item_defs[p] = {'type': 'important', 'quantity': 1, 'item-key': sym, 'model-path': path, 'model-name': model,
                        'npc-key': npc}
        item_defs['rupee-50']['quantity'] -= 1
    if 'rooster' in pets:
        del logic['rooster-statue']  # (LAS: the rooster follower location; the pet is the rooster now)
    if 'ghost' in pets:
        assert logic['ghost-reward'].get('condition-basic') == 'surf-harp'
        logic['ghost-reward']['condition-basic'] = 'ghost'
    if 'marin-companion' in pets:
        assert logic['desert'].get('condition-basic') == 'animal-village & break-bush'
        logic['desert']['condition-basic'] = 'animal-village & break-bush & marin-companion'  # (the Walrus)
    return pets


def mark_indexes(placements, logic):
    idx = placements.setdefault('indexes', {})
    n = 0
    for loc, item in list(placements.items()):
        if logic.get(loc, {}).get('type') == 'item' and item in ORDER:
            idx[loc] = PET_INDEX + ORDER.index(item)
            n += 1
    return n


def apply(out_dir, romfs, pets, oead_tools, event_tools):
    """After LAS's ModsProcess: the dummy item entries, the Walrus without Marin. (In LAS: no WalrusAwaked at the
    start without open-desert (player_start.py), GhostJoinCheck off and no Ghost4_Clear from the Surf Harp with
    pet-ghost (conditions.py, item_get.py GHOST_PET).)"""
    import os
    ds = os.path.join(out_dir, 'romfs', 'region_common', 'datasheets')

    def path(sub, name):
        p = os.path.join(out_dir, 'romfs', 'region_common', sub, name)
        return p if os.path.exists(p) else os.path.join(romfs, 'region_common', sub, name)

    sheet = oead_tools.readSheet(path('datasheets', 'Items.gsheet'))
    # (as LAS's own dummy entries: a YoshiDoll copy - that item actor shows the npcKey's model)
    d = oead_tools.parseStruct(next(v for v in sheet['values'] if v['symbol'] == 'YoshiDoll'))  # (parsed once,
    for p in pets:                                                                               # like LAS does)
        sym, npc = PETS[p][:2]
        d.update(symbol=sym, itemID=CARRIER_ID, npcKey=npc, gettingFlag='')
        sheet['values'].append(oead_tools.dictToStruct(d))
    os.makedirs(ds, exist_ok=True)
    oead_tools.writeSheet(os.path.join(ds, 'Items.gsheet'), sheet)
    ev = os.path.join(out_dir, 'romfs', 'region_common', 'event')
    os.makedirs(ev, exist_ok=True)
    if 'ghost' in pets:  # laid to rest he gives the vanilla bottle (Bottle 0): the check is his Owl (ghost-reward)
        flow = event_tools.readFlow(path('event', 'Field.bfevfl'))
        assert event_tools.findEvent(flow.flowchart, 'Event72').data.actor_action.v.v == 'AddBottle'
        event_tools.insertEventAfter(flow.flowchart, 'Event18', 'Event8')  # Ghost Destroy -> LeaveCompanion
        event_tools.writeFlow(os.path.join(ev, 'Field.bfevfl'), flow)
    if 'marin-companion' in pets:
        # talking to the sleeping Walrus without Marin sets WalrusTalked (vanilla: Marin then moves to the Animal
        # Village and the trade NPCs change): skip it, only Marin's song (WalrusAwaked) changes anything
        flow = event_tools.readFlow(path('event', 'Walrus.bfevfl'))
        e12 = event_tools.findEvent(flow.flowchart, 'Event12')
        assert e12.data.params.data['symbol'] == 'WalrusTalked'
        event_tools.insertEventAfter(flow.flowchart, 'Event123', 'Event58')
        event_tools.writeFlow(os.path.join(ev, 'Walrus.bfevfl'), flow)
    return len(pets)
