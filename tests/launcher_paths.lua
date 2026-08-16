local root=arg[1] or "."
local launchers={"Emerald.lua","Ruby.lua","Sapphire.lua","FireRed.lua","LeafGreen.lua"}
local realDofile=dofile

local function normalize(path)
    return tostring(path):gsub("\\","/"):gsub("/$","")
end

for _,launcher in ipairs(launchers) do
    script=nil
    GEN3_SUITE_DIR=nil
    local loadedPath=nil
    dofile=function(path) loadedPath=path end

    local chunk=assert(loadfile(root.."/"..launcher))
    local ok,problem=pcall(chunk)
    dofile=realDofile

    assert(ok,launcher.." failed without the mGBA script global: "..tostring(problem))
    assert(normalize(GEN3_SUITE_DIR)==normalize(root),launcher.." resolved the wrong suite directory")
    assert(normalize(loadedPath)==normalize(root.."/lib/GameSuite.lua"),launcher.." loaded the wrong suite entry point")
end

print("PASS launcher paths without mGBA script global (5 games)")
