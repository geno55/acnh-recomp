#!/usr/bin/env python3
"""Runtime lookup tables for a generated seed: rando/<seed>/flags.tsv (GlobalFlags name -> index for the flags
the runtime reads, e.g. the TradeXxxGet flags LAS adds). seed_tables.py <seed dir> regenerates it."""
import os
import sys
import types

WANT = ('Trade',)
# + the flags runtime/hle/pets.c reads / sets (tools/rando/pets.py RUNTIME_FLAGS)
EXACT = {'unused0427', 'unused0428', 'unused0429', 'unused0430', 'GhostClear1', 'Ghost2_Clear', 'Ghost3_Clear',
         'Ghost4_Clear', 'WalrusAwaked'}


def write_flags(seed_dir, oead_tools, romfs=None):
    p = os.path.join(seed_dir, 'romfs', 'region_common', 'datasheets', 'GlobalFlags.gsheet')
    if not os.path.exists(p) and romfs:
        p = os.path.join(romfs, 'region_common', 'datasheets', 'GlobalFlags.gsheet')
    sheet = oead_tools.readSheet(p)
    rows = [f"{v['symbol']}\t{int(v['index'])}\n" for v in sheet['values'] if str(v['symbol']).startswith(WANT) or str(v['symbol']) in EXACT]
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
