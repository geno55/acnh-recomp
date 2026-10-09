# Sourced by the test scripts before they start ./build/larecomp: machine-wide cap on test copies of the game (each
# takes ~2 GB; too many at once ran the Mac out of memory). One slot directory per running copy, shared by every
# checkout; a slot whose holder died is taken over. LARECOMP_TEST_SLOTS (default 6), LARECOMP_SLOT_DIR.
GAME_SLOTS=${LARECOMP_TEST_SLOTS:-6}
GAME_SLOT_DIR=${LARECOMP_SLOT_DIR:-$HOME/.cache/larecomp_test_slots}
mkdir -p "$GAME_SLOT_DIR"
GAME_SLOT=
until [ -n "$GAME_SLOT" ]; do
    for i in $(seq 1 "$GAME_SLOTS"); do
        d="$GAME_SLOT_DIR/slot$i"
        if [ -d "$d" ] && ! kill -0 "$(cat "$d/pid" 2>/dev/null)" 2>/dev/null; then rm -rf "$d"; fi
        if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; GAME_SLOT=$d; break; fi
    done
    [ -n "$GAME_SLOT" ] || sleep 2
done
