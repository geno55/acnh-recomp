import random
from RandomizerCore.randomizer_data import ENEMY_DATA

# LARecomp: mini-bosses that work as overworld enemies (spawn and fight outside their dungeon arena; Hinox is woken by
# the runtime, runtime/hle/miniboss.c). id -> leb parameters. Only replaces randomized 'land' enemies on the Field
# (never the Excluded_Actors kept vanilla for logic / tricks, so no check needs one killed), at most one per room,
# with MINIBOSS_CHANCE per land enemy (setting 'enemy-minibosses'). No switches: no defeat flag is ever written.
# Left out: Cue Ball 0x58 (circles its arena's channel; on the Field it never leaves its spawn state), Gohma 0x5a
# (charges along its arena's row, left the screen in tests; unconfirmed), Avalaunch 0x60 (unconfirmed), Rolling Bones
# 0x51 / Moblin Chief 0x52 (don't spawn outside their rooms), Lanmola 0x57 (sand only), Master Stalfos 0x59 / Grim
# Creeper 0x5d (scripted fights that flee), Smasher 0x5c (crashes on spawn), Blaino 0x5f (knock-out warps Link to a
# locator only its dungeon has).
FIELD_MINIBOSSES = {
    0x53: ['HinoxStart'],  # Hinox
    0x56: [],              # Dodongo Snake (bombs)
    0x5B: [],              # Armos Knight
    0x61: [],              # Giant Buzz Blob (Magic Powder, then sword)
    0x5C: [],              # Smasher (with its iron ball)
    0x60: [],              # Avalaunch
    0x51: ['RolaStart'],   # Rolling Bones (with its spike bar)
    0x5A: [],              # Gohma
    0x5F: [],              # Blaino (his knock-out punch sends Link back to the screen's start)
    0x59: [],              # Master Stalfos (starts by himself)
}
MINIBOSS_CHANCE = 0.08
# Mini-bosses that need what stands with them in their dungeon room (2026-10-12): the arena room and the actor types
# copied from it next to the mini-boss (same offsets, linked both ways as there): Smasher's iron ball (without it the
# game crashes spawning him), Rolling Bones' spike bar, and the room's AreaEventBox. The runtime wakes them
# (runtime/hle/miniboss.c). Needs enemy_settings['arena'] (room name -> leb.Room of the original game).
MINIBOSS_KITS = {
    0x5C: ('Lv06FaceShrine_05F', (0x1E4, 0x191)),
    0x60: ('Lv10ClothesDungeon_06E', (0x191,)),
    0x51: ('Lv01TailCave_06G', (0x11A, 0x191)),
    0x5A: ('Lv05CatfishsMaw_05D', (0x191,)),
    0x5F: ('Lv08TurtleRock_03H', (0x191,)),
    0x59: ('Lv05CatfishsMaw_05F', (0x191,)),
}


def add_miniboss_kit(room_data, mi, arena):
    """Appends the kit actors of room_data.actors[mi]'s mini-boss (copied from its arena room) and links them."""
    import copy
    act = room_data.actors[mi]
    src_i = next(i for i, x in enumerate(arena.actors) if x.type == act.type)
    src = arena.actors[src_i]
    links = []
    for i, x in enumerate(arena.actors):
        if x.type not in MINIBOSS_KITS[act.type][1]:
            continue
        a = copy.deepcopy(x)
        a.posX, a.posY, a.posZ = act.posX + (x.posX - src.posX), act.posY + (x.posY - src.posY), act.posZ + (x.posZ - src.posZ)
        a.roomID = act.roomID
        a.relationships.section_1, a.relationships.x = [], 0
        a.relationships.section_2, a.relationships.z = [], 0
        room_data.actors.append(a)
        n = len(room_data.actors) - 1
        a.relationships.section_3, a.relationships.y = [mi], 1
        links.append([[b'', b''], n])
    act.relationships.section_1, act.relationships.x = links, len(links)



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
            if (enemy_settings.get('minibosses') and FIELD_MINIBOSSES and folder == 'Field' and enemy_type == 'land'
                    and not room_has_miniboss and random.random() < MINIBOSS_CHANCE):
                mini = random.choice(sorted(FIELD_MINIBOSSES))
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
