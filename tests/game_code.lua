local root=arg[1] or "."
local gameCode=dofile(root.."/lib/GameCode.lua")

local cases={
    BPEE="BPEE",["AGB-BPEE"]="BPEE",
    AXVE="AXVE",["AGB-AXVE"]="AXVE",
    AXPE="AXPE",["AGB-AXPE"]="AXPE",
    BPRE="BPRE",["AGB-BPRE"]="BPRE",
    BPGE="BPGE",["AGB-BPGE"]="BPGE"
}

for reported,expected in pairs(cases) do
    assert(gameCode.normalize(reported)==expected,string.format("%s did not normalize to %s",reported,expected))
end

print("PASS game code normalization for short and AGB-prefixed identifiers")
