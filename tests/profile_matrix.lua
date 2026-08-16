local root=assert((...),"suite root required")
STARTER_HUNTER_DIR=root
local profiles=dofile(root.."/lib/GameProfiles.lua")

local cases={
    {"BPEE",0,"E",0x083185C8,0x0831C898,0x085839A0,0x08085E5C},
    {"AXVE",0,"RS",0x081F716C,0x081FB12C,0x083C5564,0x080543A4},
    {"AXVE",1,"RS",0x081F7184,0x081FB144,0x083C5580,0x080543C4},
    {"AXVE",2,"RS",0x081F7184,0x081FB144,0x083C5580,0x080543C4},
    {"AXPE",0,"RS",0x081F70FC,0x081FB0BC,0x083C55BC,0x080543A8},
    {"AXPE",1,"RS",0x081F7114,0x081FB0D4,0x083C55DC,0x080543C8},
    {"AXPE",2,"RS",0x081F7114,0x081FB0D4,0x083C55DC,0x080543C8},
    {"BPRE",0,"FRLG",0x08245EE0,0x08250C04,0x083DB028,0x080565B4},
    {"BPRE",1,"FRLG",0x08245F50,0x08250C74,0x083DB098,0x080565C8},
    {"BPGE",0,"FRLG",0x08245EBC,0x08250BE0,0x083DAE64,0x080565B4},
    {"BPGE",1,"FRLG",0x08245F2C,0x08250C50,0x083DAED4,0x080565C8},
}
local layouts={
    RS={{0x560,20,99,true,false},{0x600,16,99,true,false},{0x640,64,99,false,false},{0x740,46,999,false,false},{0x5B0,20,99,true,true}},
    E={{0x560,30,99,true,false},{0x650,16,99,true,false},{0x690,64,99,false,false},{0x790,46,999,false,false},{0x5D8,30,99,true,true}},
    FRLG={{0x310,42,999,false,false},{0x3B8,30,999,false,true},{0x430,13,999,false,false},{0x464,58,999,false,false},{0x54C,43,999,false,false}},
}
local pc={RS={0x498,50,true},E={0x498,50,true},FRLG={0x298,30,false}}
local required={"party","partyCount","enemy","speciesInfo","speciesNames","moveNames","battleMoves","items",
    "gMain","cb2Overworld","cb2Battle","battleType","battleMons","battleOutcome","battleActionCursor",
    "battleMoveCursor","moveToLearn","activeBattler","battlerPartyIndexes","battlerControllerFuncs","chooseAction","chooseMove"}
local checks=0
for _,case in ipairs(cases) do
    local code,revision,family,speciesNames,battleMoves,items,overworld=table.unpack(case)
    local p=assert(profiles.resolve(code,revision),code.." rev"..revision)
    assert(p.family==family and p.romRevision==revision)
    assert(p.speciesNames==speciesNames and p.battleMoves==battleMoves and p.items==items and p.cb2Overworld==overworld)
    checks=checks+6
    for _,field in ipairs(required) do assert(type(p[field])=="number",code.." missing "..field); checks=checks+1 end
    for pocketId,expected in ipairs(layouts[family]) do
        local pocket=assert(p.bagPockets[pocketId])
        assert(pocket.offset==expected[1] and pocket.capacity==expected[2] and pocket.stack==expected[3])
        assert((pocket.split==true)==expected[4] and (pocket.protected==true)==expected[5])
        checks=checks+5
    end
    assert(p.pcItemsOffset==pc[family][1] and p.pcItemsCapacity==pc[family][2] and (p.pcSplitStacks==true)==pc[family][3])
    checks=checks+3
end

-- resolve() must not leak a revision override or caller mutation into another load.
local fr0,fr1=profiles.resolve("BPRE",0),profiles.resolve("BPRE",1)
fr0.bagPockets[1].capacity=1
assert(fr1.bagPockets[1].capacity==42 and profiles.resolve("BPRE",0).bagPockets[1].capacity==42)
print(string.format("PASS profile matrix: %d checks across %d English Gen III ROM revisions",checks,#cases))
