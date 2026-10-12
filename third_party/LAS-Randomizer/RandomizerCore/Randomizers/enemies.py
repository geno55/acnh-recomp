import random
from RandomizerCore.randomizer_data import ENEMY_DATA

# LARecomp: mini-bosses that work as overworld enemies (spawn and fight outside their dungeon arena; Hinox is woken by
# the runtime, runtime/hle/miniboss.c). id -> leb parameters. Only replaces randomized 'land' enemies on the Field
# (never the Excluded_Actors kept vanilla for logic / tricks, so no check needs one killed), at most one per room,
# with MINIBOSS_CHANCE per land enemy (setting 'enemy-minibosses'). No switches: no defeat flag is ever written.
# Left out (2026-10-12): Moblin Chief 0x52 / Grim Creeper 0x5d (constructed, then deleted at once by the actor
# manager - their init decides; runtime RE in notes), Lanmola 0x57 (sand only).
FIELD_MINIBOSSES = {
    0x53: ['HinoxStart'],  # Hinox
    0x56: [],              # Dodongo Snake (bombs)
    0x5B: [],              # Armos Knight
    0x61: [],              # Giant Buzz Blob (Magic Powder, then sword)
    0x5C: [],              # Smasher (with its iron ball)
    0x60: [],              # Avalaunch
    0x51: ['RolaStart'],   # Rolling Bones (with its spike bar)
    0x5A: [],              # Gohma
    0x5F: [],              # Blaino (his knock-out punch: Link falls back down - runtime)
    0x58: [1, 0],          # Cue Ball (circles a rail fitted to the room)
    0x59: [],              # Master Stalfos (starts by himself)
}
ANY_TERRAIN_MINIBOSSES = {0x58}  # (also on water / shallow water / air / tree / hole spots: Cue Ball, tested 2026-10-12)
MINIBOSS_CHANCE = 0.08
import os as _os
if _os.environ.get('LARECOMP_ALL_MINIBOSSES'):  # (test: every room with a randomized land enemy gets one)
    MINIBOSS_CHANCE = 1.0
_ONLY = _os.environ.get('LARECOMP_ONLY_MINIBOSS')  # (test: hex type - every randomized Field enemy becomes it, any terrain)
# Mini-bosses that need what stands with them in their dungeon room (2026-10-12): the arena room and the actor types
# copied from it next to the mini-boss (same offsets, linked both ways as there): Smasher's iron ball (without it the
# game crashes spawning him), Rolling Bones' spike bar, Cue Ball's rail. The runtime wakes them
# (runtime/hle/miniboss.c). Needs enemy_settings['arena'] (room name -> leb.Room of the original game).
MINIBOSS_KITS = {  # (no AreaEventBox: it plays the arena intro - camera, music - which the overworld doesn't want)
    0x5C: ('Lv06FaceShrine_05F', (0x1E4,)),  # Smasher's iron ball
    0x51: ('Lv01TailCave_06G', (0x11A,)),    # Rolling Bones' spike bar
    0x58: ('Lv04AnglersTunnel_03E', ()),     # Cue Ball (its rail)
}


def add_miniboss_kit(room_data, mi, arena):
    """Appends the kit actors of room_data.actors[mi]'s mini-boss (copied from its arena room, same offsets) and links
    them as in the arena; rails (section 2: params, rail, point - a global point index too) of every kit actor are
    copied with their points (a rail-riding mini-boss's rail is then fitted to the room: fit_rail)."""
    import copy
    import struct
    act = room_data.actors[mi]
    src_i = next(i for i, x in enumerate(arena.actors) if x.type == act.type)
    src = arena.actors[src_i]
    take = [src_i] + [i for i, x in enumerate(arena.actors) if x.type in MINIBOSS_KITS[act.type][1]]
    newidx = {src_i: mi}
    for i in take[1:]:
        a = copy.deepcopy(arena.actors[i])
        a.posX, a.posY, a.posZ = act.posX + (a.posX - src.posX), act.posY + (a.posY - src.posY), act.posZ + (a.posZ - src.posZ)
        a.roomID = act.roomID
        room_data.actors.append(a)
        newidx[i] = len(room_data.actors) - 1
    sec = lambda room, name: next(e for e in room.fixed_hash.entries if e.name == name)
    sp, sr, dp, dr = sec(arena, b'point'), sec(arena, b'rail'), sec(room_data, b'point'), sec(room_data, b'rail')
    rail_map, point_map = {}, {}
    for i in take:
        srl = arena.actors[i].relationships
        rl = room_data.actors[newidx[i]].relationships
        rl.section_1 = [[s[0], newidx[s[1]]] for s in srl.section_1 if s[1] in newidx]
        rl.section_3 = [newidx[j] for j in srl.section_3 if j in newidx]
        rails = []
        for s2 in srl.section_2:
            ri = s2[1]
            if ri not in rail_map:
                rail = copy.deepcopy(sr.data.entries[ri])
                d = bytearray(rail.data)
                for k in range(struct.unpack_from('<H', d, 0x2C)[0]):
                    pi = struct.unpack_from('<H', d, 0x30 + 2 * k)[0]
                    if pi not in point_map:
                        pt = copy.deepcopy(sp.data.entries[pi])
                        pd = bytearray(pt.data)
                        x, y, z = struct.unpack_from('<3f', pd, 0)
                        struct.pack_into('<3f', pd, 0, act.posX + (x - src.posX), act.posY + (y - src.posY),
                                         act.posZ + (z - src.posZ))
                        pt.data = bytes(pd)
                        dp.data.entries.append(pt)
                        point_map[pi] = len(dp.data.entries) - 1
                    struct.pack_into('<H', d, 0x30 + 2 * k, point_map[pi])
                for k in range(4):  # (string params point into the names section, which repack rebuilds: ints)
                    struct.pack_into('<II', d, 0xC + 8 * k, 0, 3)
                rail.data = bytes(d)
                dr.data.entries.append(rail)
                rail_map[ri] = len(dr.data.entries) - 1
            rails.append([s2[0], rail_map[ri], point_map.get(s2[2], s2[2])])
        rl.section_2 = rails
        rl.x, rl.y, rl.z = len(rl.section_1), len(rl.section_3), len(rl.section_2)
    if act.type in RAIL_FIT and act.relationships.section_2:
        fit_rail(room_data, act, sec(room_data, b'point'), sec(room_data, b'rail').data.entries[act.relationships.section_2[0][1]])


RAIL_FIT = {0x58}  # Cue Ball circles a 4-point rail (its arena's 9 x 6 channel): fitted to the room's free tiles


def fit_rail(room_data, act, points, rail):
    """The 4-point rail of `act` becomes the largest rectangle of free tiles (no collision, water, lava) with the actor's
    tile as a corner; the actor moves onto that corner."""
    import struct
    from RandomizerCore.Tools import leb
    entry = next((e for e in room_data.fixed_hash.entries if e.name == b'grid'), None)
    try:
        g = leb.Grid(entry) if entry else None
    except ValueError:
        g = None
    if g is None or g.info.room_height != 8:
        return
    info = g.info

    def free(row, col):
        if not (0 <= row < info.room_height and 0 <= col < info.room_width):
            return False
        t = g.tilesdata[row * info.room_width + col]
        return not (t.flags1['containscollision'] or t.flags1['deepwaterlava'] or t.flags3['iswaterlava'])
    c0, r0 = int((act.posX - info.x_coord) / info.tile_size), int((act.posZ - info.z_coord) / info.tile_size)
    best = None
    for w in range(7, 1, -1):
        for h in range(5, 1, -1):
            for dx, dz in ((1, 1), (1, -1), (-1, 1), (-1, -1)):
                cs, rs = [c0, c0 + dx * w], [r0, r0 + dz * h]
                per = [(rr, cc) for cc in range(min(cs), max(cs) + 1) for rr in rs] + \
                      [(rr, cc) for rr in range(min(rs), max(rs) + 1) for cc in cs]
                if all(free(rr, cc) for rr, cc in per) and (best is None or w * h > best[0]):
                    best = (w * h, w, h, dx, dz)
    if best is None:
        return
    _, w, h, dx, dz = best
    ctr = lambda rr, cc: (info.x_coord + (cc + 0.5) * info.tile_size, info.z_coord + (rr + 0.5) * info.tile_size)
    corners = [ctr(r0, c0), ctr(r0 + dz * h, c0), ctr(r0 + dz * h, c0 + dx * w), ctr(r0, c0 + dx * w)]
    d = bytes(rail.data)
    for k, (x, z) in enumerate(corners[:struct.unpack_from('<H', d, 0x2C)[0]]):
        pi = struct.unpack_from('<H', d, 0x30 + 2 * k)[0]
        pd = bytearray(points.data.entries[pi].data)
        struct.pack_into('<3f', pd, 0, x, act.posY + 0.2, z)
        points.data.entries[pi].data = bytes(pd)
    act.posX, act.posZ = corners[0]



def shuffleEnemyActors(room_data, folder: str, file: str, enemy_ids: dict, enemy_settings: dict, rand_state: tuple):
    """"""

    random.setstate(rand_state)
    edited_room = False

    excluded_actors = []
    if file[:-4] in list(ENEMY_DATA['Excluded_Actors'].keys()):
        excluded_actors = ENEMY_DATA['Excluded_Actors'][file[:-4]]
    
    restr = list(enemy_ids['restr'])

    # we want to exclude certain enemies from being in 2D rooms
    # some can block your path, others might just be annoying
    if file[:-4] in ENEMY_DATA['2D_Rooms']:
        no_2D = (0x1E, 0x30, 0x37, 0x38, 0x3F, 0x41, 0x4A, 0x4D)
        restr.extend(no_2D)

    total_ids = (
        *enemy_ids['land'],
        *enemy_ids['air'],
        *enemy_ids['water'],
        *enemy_ids['water2D'],
        *enemy_ids['water_shallow'],
        *enemy_ids['tree'],
        *enemy_ids['hole']
    )
    fly_bombs = (0x26, 0x3E, 0x48) # vires, zirros, bone-putters
    blocking = (0x8, 0x9, 0x13, 0x14, 0x2E, 0x2F, 0x30, 0x35, 0x36, 0x41, 0x4D) # shield/spear, mimics, color dungeon orbs
    
    room_has_miniboss = False

    # iterate through each actor
    for e, act in enumerate(room_data.actors):
        if act.type not in total_ids or e in excluded_actors: # check for valid enemy actors
            continue

        if enemy_settings['types']:
            enemy_type = [v for k,v in ENEMY_DATA['Actors'].items() if v['id'] == act.type][0]['type']
            new_enemy = -1
            
            if act.type in restr:
                restr.remove(act.type)
            
            mini = None
            fits = sorted(FIELD_MINIBOSSES) if enemy_type == 'land' else sorted(ANY_TERRAIN_MINIBOSSES)
            if (enemy_settings.get('minibosses') and fits and folder == 'Field'
                    and (_ONLY or (not room_has_miniboss and random.random() < MINIBOSS_CHANCE))):
                mini = random.choice(fits)
                if _ONLY:
                    mini = int(_ONLY, 16)
                room_has_miniboss = True
                new_enemy = mini

            # keep shuffling each actor until it is a valid enemy
            while new_enemy in restr and mini is None:
                if enemy_type == 'land':
                    new_enemy = random.choice(enemy_ids['land'])
                elif enemy_type == 'air':
                    if folder == 'Field':
                        new_enemy = random.choice(enemy_ids['no_vire']) # remove vires from overworld
                    else:
                        new_enemy = random.choice(enemy_ids['air'])
                elif enemy_type == 'water':
                    waters = (*enemy_ids['water'], *enemy_ids['water_shallow'])
                    new_enemy = random.choice(waters)
                elif enemy_type == 'water2D':
                    new_enemy = random.choice(enemy_ids['water2D'])
                elif enemy_type == 'water-shallow':
                    new_enemy = random.choice(enemy_ids['water_shallow'])
                elif enemy_type == 'tree':
                    new_enemy = random.choice(enemy_ids['tree'])
                elif enemy_type == 'hole':
                    new_enemy = random.choice(enemy_ids['hole'])
            
            ### restrict enemy groups to one per room
            if new_enemy in fly_bombs:
                restr.extend(fly_bombs)
            elif new_enemy in blocking:
                restr.extend(blocking)
            
            if mini is not None:
                params = [bytes(p, 'utf-8') if isinstance(p, str) else p for p in FIELD_MINIBOSSES[mini]]
                act.type = mini
                act.parameters = (params + [b''] * 8)[:8]
                act.relationships.e = 1
                act.rotY = 0
                act.scaleX = act.scaleY = act.scaleZ = 1.0
                if mini in MINIBOSS_KITS and enemy_settings.get('arena'):
                    add_miniboss_kit(room_data, e, enemy_settings['arena'](MINIBOSS_KITS[mini][0]))
                edited_room = True
                continue

            # change the enemy data into the new enemy
            if act.type != new_enemy:
                act.type = new_enemy
                try:
                    params = [v for k,v in ENEMY_DATA['Actors'].items() if v['id'] == act.type][0]['parameters']
                    for i in range(8):
                        try:
                            if isinstance(params[i], list):
                                param = random.choice(params[i])
                            else:
                                param = params[i]
                            if isinstance(param, str):
                                param = bytes(param, 'utf-8')
                            act.parameters[i] = param
                        except IndexError:
                            act.parameters[i] = b''
                except KeyError:
                    act.parameters = [b'', b'', b'', b'', b'', b'', b'', b'']

                act.relationships.e = int([v for k,v in ENEMY_DATA['Actors'].items() if v['id'] == act.type][0]['enemy'])

                if act.type == 0x4A: # StretchyGhosts - only includes one color in pool so it will be 1/3 likely now
                    act.type = random.choice((0x4A, 0x4B, 0x4C)) # decide color
                elif act.type == 0x4D: # ColorDungeon Orbs - same thing as above
                    act.type = random.choice((0x4D, 0x4E, 0x4F))
                
                act.rotY = 0 # change each enemy to be facing the screen, some will stay sideways if we don't

                # make sure actor is default size so that anything that's normally big won't cause the new enemy to be big
                act.scaleX = 1.0
                act.scaleY = 1.0
                act.scaleZ = 1.0
                edited_room = True
        
        if enemy_settings['sizes']:
            new_scale = random.uniform(0.5, 1.5)
            act.scaleX = new_scale
            act.scaleY = new_scale
            act.scaleZ = new_scale
            edited_room = True
    
    return random.getstate(), edited_room
