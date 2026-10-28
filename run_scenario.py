#!/usr/bin/env python3
"""Runs one simulated BG3 scene against a given BootstrapServer.lua.

    pip install lupa
    python3 sim/run_scenario.py sim/scenario1.lua <mod.lua> [extra lua prelude]
"""
import sys, lupa
scenario = sys.argv[1]
modfile = sys.argv[2]
prelude = sys.argv[3] if len(sys.argv) > 3 else None
lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute('MODFILE = "%s"' % modfile)
if prelude:
    lua.execute(prelude)
lua.execute('dofile("%s")' % scenario)
