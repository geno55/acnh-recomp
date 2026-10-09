#!/usr/bin/env python3
"""Runtime lookup tables for a generated seed: rando/<seed>/flags.tsv (GlobalFlags name -> index for the flags
the runtime reads, e.g. the TradeXxxGet flags LAS adds and the trade NPCs' done flags). seed_tables.py <seed dir> regenerates it."""
import os
import sys
import types

WANT = ('Trade',)
# set by the trade NPCs' flows when they take the item (= traded away; Items-screen trade row, inventory_overlay.mm)
WANT_EXACT = {'RibbonDrop', 'DogfoodDrop', 'BananaDrop', 'StickDrop', 'HoneycombDrop', 'PineappleGet', 'HibiscusDrop',
              'LetterDrop', 'BroomDrop', 'FishhookDrop', 'BrassiereDrop', 'ScaleDrop', 'MarthaStatueOpened'}


def write_flags(seed_dir, oead_tools, romfs=None):
    p = os.path.join(seed_dir, 'romfs', 'region_common', 'datasheets', 'GlobalFlags.gsheet')
    if not os.path.exists(p) and romfs:
        p = os.path.join(romfs, 'region_common', 'datasheets', 'GlobalFlags.gsheet')
    sheet = oead_tools.readSheet(p)
    rows = [f"{v['symbol']}\t{int(v['index'])}\n" for v in sheet['values']
            if str(v['symbol']).startswith(WANT) or v['symbol'] in WANT_EXACT]
    with open(os.path.join(seed_dir, 'flags.tsv'), 'w') as f:
        f.writelines(rows)
    return len(rows)


if __name__ == '__main__':
    here = os.path.dirname(os.path.abspath(__file__))
    las = os.path.normpath(os.path.join(here, '..', '..', 'third_party', 'LAS-Randomizer'))
    sys.modules['PySide6'] = types.ModuleType('PySide6')
    sys.modules['PySide6.QtCore'] = types.ModuleType('PySide6.QtCore')
    sys.path.insert(0, las)
    from RandomizerCore.Tools import oead_tools as ot
    for d in sys.argv[1:]:
        print(d, write_flags(os.path.abspath(d), ot), 'flags')
