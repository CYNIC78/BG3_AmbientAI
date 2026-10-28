#!/bin/sh
# Runs every simulated scene against the original and the patched script.
cd "$(dirname "$0")/.."
ORIG=unpacked_original/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua
FIXED=unpacked_fixed/Mods/AmbientAI/ScriptExtender/Lua/BootstrapServer.lua
for f in sim/scenario1.lua sim/s2_stale_burning.lua sim/s4_engines.lua sim/s5_rearm.lua \
         sim/s7_long.lua sim/s8_blocked_approach.lua sim/s9_far_stall.lua \
         sim/s10_seat_standup.lua sim/s11_sit_vanish.lua sim/s12_void_seat.lua sim/s13_silent_seat.lua; do
  for build in "$ORIG" "$FIXED"; do
    echo "===== $f  [$build]"
    python3 sim/run_scenario.py "$f" "$build" | grep -E "RESULT|TIMER-ERROR|LuaError|ERROR executing"
  done
done
