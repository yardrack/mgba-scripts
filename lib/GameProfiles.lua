-- Aggregates isolated English Gen 3 game-family memory maps.
local suiteDir=STARTER_HUNTER_DIR
if not suiteDir then error("Set STARTER_HUNTER_DIR to the suite folder before loading GameProfiles.lua.") end
local base=suiteDir.."/lib/games/"
local profiles={}
for _,name in ipairs({"Emerald.lua","RubySapphire.lua","FireRedLeafGreen.lua"}) do
    for code,profile in pairs(dofile(base..name)) do profiles[code]=profile end
end
local function copy(value,seen)
    if type(value)~="table" then return value end
    seen=seen or {}; if seen[value] then return seen[value] end
    local result={}; seen[value]=result
    for key,item in pairs(value) do result[copy(key,seen)]=copy(item,seen) end
    return result
end
local modernSignatures={
    BPE={address=0x08067A80,bytes={0x00,0xB5,0x05,0x48,0x35,0xF0,0xAE,0xFE}},
    AXV={address=0x0803A6C0,bytes={0x00,0xB5,0x05,0x48,0x2E,0xF0,0x5E,0xFE}},
    AXP={address=0x0803A6C0,bytes={0x00,0xB5,0x05,0x48,0x2E,0xF0,0x60,0xFE}},
    BPR={address=0x0803D97C,bytes={0x00,0xB5,0x05,0x48,0x30,0xF0,0xCA,0xFE}},
    BPG={address=0x0803D97C,bytes={0x00,0xB5,0x05,0x48,0x30,0xF0,0xCA,0xFE}},
}

local function isModernShinyRom(code)
    local signature=modernSignatures[code]
    if not signature or not emu or type(emu.read8)~="function" then return false end
    for offset,expected in ipairs(signature.bytes) do
        if emu:read8(signature.address+offset-1)~=expected then return false end
    end
    return true
end

local function resolve(code,revision)
    local base=profiles[tostring(code):sub(1,3)]
    if not base then return nil end
    local result=copy(base)
    local override=result.revisionOverrides and result.revisionOverrides[tonumber(revision) or 0]
    if override then for key,value in pairs(override) do result[key]=copy(value) end end
    if isModernShinyRom(tostring(code):sub(1,3)) and result.modern then
        for key,value in pairs(result.modern) do result[key]=copy(value) end
    end
    result.modern=nil
    result.romRevision=tonumber(revision) or 0
    return result
end
return {
    profiles=profiles,
    resolve=resolve,
    natures={
        "Hardy","Lonely","Brave","Adamant","Naughty","Bold","Docile","Relaxed","Impish","Lax",
        "Timid","Hasty","Serious","Jolly","Naive","Modest","Mild","Quiet","Bashful","Rash",
        "Calm","Gentle","Sassy","Careful","Quirky"
    },
    abilities={
        "None","Stench","Drizzle","Speed Boost","Battle Armor","Sturdy","Damp","Limber","Sand Veil","Static",
        "Volt Absorb","Water Absorb","Oblivious","Cloud Nine","Compound Eyes","Insomnia","Color Change","Immunity","Flash Fire","Shield Dust",
        "Own Tempo","Suction Cups","Intimidate","Shadow Tag","Rough Skin","Wonder Guard","Levitate","Effect Spore","Synchronize","Clear Body",
        "Natural Cure","Lightning Rod","Serene Grace","Swift Swim","Chlorophyll","Illuminate","Trace","Huge Power","Poison Point","Inner Focus",
        "Magma Armor","Water Veil","Magnet Pull","Soundproof","Rain Dish","Sand Stream","Pressure","Thick Fat","Early Bird","Flame Body",
        "Run Away","Keen Eye","Hyper Cutter","Pickup","Truant","Hustle","Cute Charm","Plus","Minus","Forecast",
        "Sticky Hold","Shed Skin","Guts","Marvel Scale","Liquid Ooze","Overgrow","Blaze","Torrent","Swarm","Rock Head",
        "Drought","Arena Trap","Vital Spirit","White Smoke","Pure Power","Shell Armor","Cacophony","Air Lock"
    }
}
