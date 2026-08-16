-- Lightweight party/encounter monitor used by the combined Capture script.

local CONFIG={
 BPE={name="Emerald",seed=0x03005D80,partyCount=0x020244E9,party=0x020244EC,enemy=0x02024744,save1Ptr=0x03005D8C,save2Ptr=0x03005D90},
 AXV={name="Ruby",seed=0x03004818,partyCount=0x03004350,party=0x03004360,enemy=0x030045C0,save1=0x02025734,save2=0x02024EA4},
 AXP={name="Sapphire",seed=0x03004818,partyCount=0x03004350,party=0x03004360,enemy=0x030045C0,save1=0x02025734,save2=0x02024EA4},
 BPR={name="FireRed",seed=0x03005000,partyCount=0x02024029,party=0x02024284,enemy=0x0202402C,save1Ptr=0x03005008,save2Ptr=0x0300500C},
 BPG={name="LeafGreen",seed=0x03005000,partyCount=0x02024029,party=0x02024284,enemy=0x0202402C,save1Ptr=0x03005008,save2Ptr=0x0300500C},
}
local gameCode=GEN3_GAME_CODE or tostring(emu:getGameCode()):sub(-4)
local game=CONFIG[gameCode:sub(1,3)]
if not game then error("Pokemon Info supports English Emerald, Ruby, Sapphire, FireRed, and LeafGreen.") end
local suiteDir=GEN3_SUITE_DIR or STARTER_HUNTER_DIR or (script and script.dir)
if not suiteDir then error("Load Pokemon Info and Capture.lua instead of lib/PokemonInfoCore.lua directly.") end
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local rngMath=dofile(suiteDir.."/lib/RNGMath.lua")

local PARTY_SIZE=0x64
local frame,lastText,sessionCalls,previousSeed=0,"",0,nil
local panel=(EMERALD_AUTOMATION_HEADLESS or POKEMON_INFO_HIDE_UI) and {setSize=function()end,clear=function()end,print=function()end,moveCursor=function()end}
    or console:createBuffer("Pokemon Info")
panel:setSize(58,16)
local PANEL_WIDTH,PANEL_HEIGHT=58,16
local RUNNING_REFRESH_SECONDS=0.10
local lastRenderClock,lastFrameClock=os.clock(),os.clock()
local forceNextFrameRender=false

local ORDER={
 {0,1,2,3},{0,1,3,2},{0,2,1,3},{0,3,1,2},{0,2,3,1},{0,3,2,1},
 {1,0,2,3},{1,0,3,2},{2,0,1,3},{3,0,1,2},{2,0,3,1},{3,0,2,1},
 {1,2,0,3},{1,3,0,2},{2,1,0,3},{3,1,0,2},{2,3,0,1},{3,2,0,1},
 {1,2,3,0},{1,3,2,0},{2,1,3,0},{3,1,2,0},{2,3,1,0},{3,2,1,0}}
local function validRam(p) return p and p>=0x02000000 and p<0x02040000 end
local function saveAddress(fixed,pointer)
    if fixed then return fixed end
    local p=pointer and emu:read32(pointer) or 0
    return validRam(p) and p or nil
end
local function readPokemon(address)
    local pid,ot=emu:read32(address),emu:read32(address+4)
    if pid==0 and ot==0 then return nil end
    local order=ORDER[(pid%24)+1]; if not order then return nil end
    local key=pid~ot
    local species=(emu:read32(address+0x20+order[1]*12)~key)&0xFFFF
    local ivs=emu:read32(address+0x20+order[4]*12+4)~key
    if species==0 or ((ivs>>30)&1)==1 then return nil end
    return {pid=pid,species=species,level=emu:read8(address+0x54),hp=emu:read16(address+0x56),maxHp=emu:read16(address+0x58)}
end
local function isShiny(pid,tid,sid) return (tid~sid~(pid&0xFFFF)~((pid>>16)&0xFFFF))<8 end
local function updateCalls()
    local seed=emu:read32(game.seed)
    if previousSeed and seed~=previousSeed then
        local distance=rngMath.distance(previousSeed,seed)
        if distance and distance<=1000000 then sessionCalls=sessionCalls+distance else sessionCalls=0 end
    end
    previousSeed=seed
end
local function snapshot()
    local s1=saveAddress(game.save1,game.save1Ptr)
    local s2=saveAddress(game.save2,game.save2Ptr)
    if not s1 or not s2 then return {ready=false,status="Load a save."} end
    local result={ready=true,game=game.name,tid=emu:read16(s2+0xA),sid=emu:read16(s2+0xC),
        videoFrame=frameClock:currentFrame(),rngCalls=game.advances and emu:read32(game.advances) or sessionCalls,
        seed=emu:read32(game.seed),party={}}
    local count=math.min(6,emu:read8(game.partyCount))
    for slot=0,count-1 do
        local p=readPokemon(game.party+slot*PARTY_SIZE)
        if p then p.slot=slot; p.shiny=isShiny(p.pid,result.tid,result.sid); result.party[#result.party+1]=p end
    end
    result.enemy=readPokemon(game.enemy)
    if result.enemy then result.enemy.shiny=isShiny(result.enemy.pid,result.tid,result.sid) end
    result.current=result.enemy or result.party[1]
    return result
end
local function render(force)
    local s=snapshot(); local lines={"POKEMON INFO  |  "..game.name,""}
    if not s.ready then lines[#lines+1]=s.status else
        lines[#lines+1]=string.format("VIDEO FRAME  %u",s.videoFrame)
        lines[#lines+1]=string.format("RNG calls %u   Seed %08X",s.rngCalls,s.seed)
        lines[#lines+1]=string.format("TID %05d   SID %05d",s.tid,s.sid)
        if s.current then lines[#lines+1]=string.format("PID %08X   Species %d%s",s.current.pid,s.current.species,s.current.shiny and "   SHINY" or "") end
        lines[#lines+1]=""
        for _,p in ipairs(s.party) do
            lines[#lines+1]=string.format("%d  #%-3d Lv%-3d %3d/%-3d  %08X%s",p.slot+1,p.species,p.level,p.hp,p.maxHp,p.pid,p.shiny and " *" or "")
        end
        if s.enemy then lines[#lines+1]=""; lines[#lines+1]=s.enemy.shiny and "ENCOUNTER: CONFIRMED SHINY" or "ENCOUNTER: normal" end
    end
    local text=table.concat(lines,"\n")
    if force or text~=lastText then
        local padded={}; local row=0
        for line in (text.."\n"):gmatch("(.-)\n") do
            row=row+1; if row>PANEL_HEIGHT then break end
            padded[row]=line:sub(1,PANEL_WIDTH)..string.rep(" ",math.max(0,PANEL_WIDTH-#line))
        end
        while row<PANEL_HEIGHT do row=row+1; padded[row]=string.rep(" ",PANEL_WIDTH) end
        panel:moveCursor(0,0); panel:print(table.concat(padded,"\n")); lastText=text
    end
end
PokemonInfo={snapshot=snapshot,render=function() render(true) end}
callbacks:add("key",function(event)
    if event.state==1 and ((event.modifiers or 0)&0xC)~=0 and (event.key==78 or event.key==110) then forceNextFrameRender=true end
end)
-- The suite keeps this module loaded only as a shared reader. Its own panel is
-- hidden there, so polling and formatting it every frame is pure overhead.
-- Standalone Pokemon Info retains the original live refresh behaviour.
if not POKEMON_INFO_HIDE_UI then
    frameClock:add(function()
        frame=frame+1; updateCalls()
        local now=os.clock(); local manuallySpaced=(now-lastFrameClock)>=0.08; lastFrameClock=now
        if forceNextFrameRender or manuallySpaced or (now-lastRenderClock)>=RUNNING_REFRESH_SECONDS then
            render(false); lastRenderClock=now; forceNextFrameRender=false
        end
    end)
end
render(true)
