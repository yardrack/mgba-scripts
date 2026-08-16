-- Complete English Pokemon LeafGreen tool suite.
GEN3_SUITE_GAME="BPGE"
GEN3_SUITE_NAME="LeafGreen"
local source=debug.getinfo(1,"S").source
local launcherPath=source:sub(1,1)=="@" and source:sub(2) or source
GEN3_SUITE_DIR=(script and script.dir) or launcherPath:match("^(.*)[/\\][^/\\]+$") or "."
dofile(GEN3_SUITE_DIR.."/lib/Launcher.lua").start()
