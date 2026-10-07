#!/usr/bin/env python3
"""Headless driver for LAS-Randomizer (third_party/LAS-Randomizer, MIT, by Owen-Splat and contributors).

Runs the item shuffler and the mod generator without the Qt GUI, using GUI-equivalent defaults.

usage: las_headless.py <romfs dir> <out dir> <settings.json>
settings.json: {"seed": "...", "logic": "basic", ...any LAS setting key..., "exclude": [...]} -- keys missing
from the file get the LAS GUI defaults. The output dir receives romfs/ (replacement files), exefs patches
(1.0.0.pchtxt) and the spoiler log.
"""
import json
import os
import sys
import types

LAS = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', 'third_party', 'LAS-Randomizer')
LAS = os.path.normpath(LAS)


# ---- minimal PySide6.QtCore stand-in: the core only uses QThread.run() and Signal.emit/connect
class _Signal:
    def __init__(self, *types_):
        self._slots = []

    def __get__(self, obj, objtype=None):
        if obj is None:
            return self
        key = '_sig_%d' % id(self)
        if key not in obj.__dict__:
            obj.__dict__[key] = _BoundSignal()
        return obj.__dict__[key]


class _BoundSignal:
    def __init__(self):
        self.slots = []

    def connect(self, f):
        self.slots.append(f)

    def emit(self, *a):
        for f in self.slots:
            f(*a)


class _QThread:
    def __init__(self, parent=None):
        pass

    def setParent(self, p):
        pass

    def start(self):
        self.run()


qtcore = types.ModuleType('PySide6.QtCore')
qtcore.QThread = _QThread
qtcore.Signal = _Signal
qtcore.QObject = object
pyside = types.ModuleType('PySide6')
pyside.QtCore = qtcore
sys.modules['PySide6'] = pyside
sys.modules['PySide6.QtCore'] = qtcore

ARGS = [os.path.abspath(a) for a in sys.argv[1:4]]
sys.argv[0] = os.path.join(LAS, 'randomizer.py')  # LAS resolves its data paths from argv[0]
sys.path.insert(0, LAS)
os.chdir(LAS)

import yaml  # noqa: E402
from RandomizerCore import randomizer_data as rd  # noqa: E402
from RandomizerCore.shuffler import ItemShuffler  # noqa: E402
from RandomizerCore.mod_generator import ModsProcess  # noqa: E402


def default_settings(seed):
    excluded = set()
    excluded.update(rd.FISHING_REWARDS)
    excluded.update(rd.RAPIDS_REWARDS)
    excluded.update(rd.DAMPE_REWARDS)
    excluded.update(rd.TRADE_GIFT_LOCATIONS)
    excluded.update(rd.BLUE_RUPEES)
    excluded.update(['30-seashell-reward', '40-seashell-reward', '50-seashell-reward'])
    return {
        'seed': seed, 'logic': 'basic', 'platform': 'emulator', 'create-spoiler': True, 'free-book': True,
        'extended-consumable-drop': True, 'dungeon-items': 'mcb', 'unlocked-bombs': True, 'shuffle-bombs': False,
        'shuffle-powder': False, 'fast-fishing': False, 'fast-stealing': True, 'fast-songs': False,
        'shuffle-instruments': False, 'starting-instruments': 0, 'bad-pets': False, 'open-kanalet': True,
        'open-bridge': True, 'open-mamu': True, 'traps': 'few', 'blupsanity': False, 'classic-d2': False,
        'owl-overworld-gifts': False, 'owl-dungeon-gifts': False, 'fast-stalfos': False, 'chest-aspect': 'default',
        'seashells-important': True, 'trade-important': False, 'randomize-music': False, 'open-mabe': False,
        'boss-cutscenes': True, 'randomize-enemies': False, 'randomize-enemy-sizes': False, 'shuffle-dungeons': False,
        'blur-removal': False, 'OHKO': False, 'lv1-beam': False, 'nice-rod': True, 'nice-bombs': False,
        'stealing': 'always', 'fast-chests': True, 'fast-keys': True,
        'starting-items': ['sword', 'shield', 'ocarina', 'song-mambo'], 'starting-rupees': 0,
        'excluded-locations': excluded,
    }


def main():
    romfs, out_dir, settings_file = ARGS
    with open(settings_file) as f:
        user = json.load(f)
    settings = default_settings(str(user.get('seed', 'LARecomp')))
    for k, v in user.items():
        if k == 'exclude':
            settings['excluded-locations'].update(v)
        elif k == 'include':
            settings['excluded-locations'].difference_update(v)
        else:
            settings[k] = v
    settings['excluded-locations'] = set(settings['excluded-locations'])
    logic_defs = yaml.safe_load(rd.LOGIC_RAW)
    import copy
    item_defs = copy.deepcopy(rd.ITEM_DEFS)
    os.makedirs(out_dir, exist_ok=True)

    result = {}
    errors = []
    sh = ItemShuffler(out_dir, settings['seed'], settings['logic'], settings, item_defs, copy.deepcopy(logic_defs))
    sh.give_placements.connect(lambda p: result.update(placements=p[0], randstate=p[1]))
    sh.error.connect(lambda e: errors.append(e))
    sh.start()
    if errors or 'placements' not in result:
        print('SHUFFLE ERROR', errors, file=sys.stderr)
        sys.exit(1)
    print('placements ready', flush=True)

    mods = ModsProcess(result['placements'], romfs, out_dir, item_defs, settings['seed'], result['randstate'])
    last = [0]

    def progress(n):
        if n - last[0] >= 25:
            last[0] = n
            print('progress', n, flush=True)

    mods.progress_update.connect(progress)
    mods.error.connect(lambda e: errors.append(e))
    mods.start()
    if errors:
        print('MODS ERROR', errors, file=sys.stderr)
        sys.exit(2)
    with open(os.path.join(out_dir, 'settings.json'), 'w') as f:
        s = dict(settings)
        s['excluded-locations'] = sorted(s['excluded-locations'])
        json.dump(s, f, indent=1)
    print('done', flush=True)


if __name__ == '__main__':
    main()
