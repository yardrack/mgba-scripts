-- Delay suite startup until mGBA has attached a loaded game to this script.
-- The global `emu` object does not exist when a script is loaded before a ROM.

local M={}

function M.start()
    local loaded=false

    local function loadSuite()
        if loaded or not emu then return false end
        loaded=true
        dofile(GEN3_SUITE_DIR.."/lib/GameSuite.lua")
        return true
    end

    if loadSuite() then return true end

    if console and console.log then
        console:log((GEN3_SUITE_NAME or "Gen 3 suite").." is waiting for a ROM to be loaded.")
    end
    callbacks:add("frame",loadSuite)
    return false
end

return M
