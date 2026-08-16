-- Pure Gen 3 LCRNG operations. This module has no emulator/UI dependency and
-- can be syntax- and vector-tested independently.

local M={MULT=0x41C64E6D,ADD=0x00006073,INV_MULT=0xEEB9EB65,INV_ADD=0x0A3561A1}
M.jump={
    {0x41C64E6D,0x00006073},{0xC2A29A69,0xE97E7B6A},{0xEE067F11,0x31B0DDE4},{0xCFDDDF21,0x67DBB608},
    {0x5F748241,0xCBA72510},{0x8B2E1481,0x1D29AE20},{0x76006901,0xBA84EC40},{0x1711D201,0x79F01880},
    {0xBE67A401,0x08793100},{0xDDDF4801,0x6B566200},{0x3FFE9001,0x803CC400},{0x90FD2001,0xA6B98800},
    {0x65FA4001,0xE6731000},{0xDBF48001,0x30E62000},{0xF7E90001,0xF1CC4000},{0xEFD20001,0x23988000},
    {0xDFA40001,0x47310000},{0xBF480001,0x8E620000},{0x7E900001,0x1CC40000},{0xFD200001,0x39880000},
    {0xFA400001,0x73100000},{0xF4800001,0xE6200000},{0xE9000001,0xCC400000},{0xD2000001,0x98800000},
    {0xA4000001,0x31000000},{0x48000001,0x62000000},{0x90000001,0xC4000000},{0x20000001,0x88000000},
    {0x40000001,0x10000000},{0x80000001,0x20000000},{0x00000001,0x40000000},{0x00000001,0x80000000}
}

function M.mulAdd(seed,multiplier,addend)
    local a=(multiplier>>16)*(seed&0xFFFF)+(seed>>16)*(multiplier&0xFFFF)
    return ((multiplier&0xFFFF)*(seed&0xFFFF)+(a&0xFFFF)*0x10000+addend)&0xFFFFFFFF
end
function M.next(seed) return M.mulAdd(seed,M.MULT,M.ADD) end
function M.previous(seed) return M.mulAdd(seed,M.INV_MULT,M.INV_ADD) end
function M.advance(seed,advances)
    local result,bit=seed&0xFFFFFFFF,1
    for _,data in ipairs(M.jump) do
        if (advances&bit)~=0 then result=M.mulAdd(result,data[1],data[2]) end
        bit=bit<<1
    end
    return result
end
function M.distance(startState,endState)
    local state,distance,bit=startState&0xFFFFFFFF,0,1
    for _,data in ipairs(M.jump) do
        if (state&bit)~=(endState&bit) then
            state=M.mulAdd(state,data[1],data[2])
            distance=distance|bit
        end
        bit=bit<<1
    end
    return state==(endState&0xFFFFFFFF) and distance or nil
end
function M.offset(seed,frames)
    if frames>=0 then return M.advance(seed,frames) end
    local result=seed
    for _=1,-frames do result=M.previous(result) end
    return result
end
function M.shinyValue(tid,sid,pid)
    return (tid~sid~(pid&0xFFFF)~((pid>>16)&0xFFFF))&0xFFFF
end
function M.unpackIvs(iv1,iv2)
    -- Public order is HP/Atk/Def/SpA/SpD/Spe; the packed second word stores
    -- Speed before the two special stats.
    return {iv1&31,(iv1>>5)&31,(iv1>>10)&31,(iv2>>5)&31,(iv2>>10)&31,iv2&31}
end

return M
