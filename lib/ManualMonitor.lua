-- Shared compact UI and observation logic for Manual Starter / Manual Wild.

local kind=MANUAL_MONITOR_KIND
local combined=kind=="combined"
if combined then kind="starter" end
if kind~="starter" and kind~="wild" then error("ManualMonitor needs starter, wild, or combined mode.") end

local supported={BPEE=true,AXVE=true,AXPE=true,BPRE=true,BPGE=true}
local gameCode=GEN3_GAME_CODE or tostring(emu:getGameCode()):sub(-4)
if not supported[gameCode] then
    error("Manual monitors support English Emerald, Ruby, Sapphire, FireRed, and LeafGreen.")
end

local suiteDir=STARTER_HUNTER_DIR or (script and script.dir)
if not suiteDir then error("The manual monitor could not locate the suite folder.") end
STARTER_HUNTER_DIR=suiteDir
local frameClock=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local gameProfile=dofile(suiteDir.."/lib/GameProfiles.lua").resolve(gameCode,emu:read8(0x080000BC))
local function rawCaptureFrame()
    -- Gen III increments gMain.vblankCounter2 once in the hardware VBlank
    -- interrupt. Counter 1 is a pointer in FR/LG, while counter 2 is a direct
    -- u32 in all five games. Reading it makes paused Ctrl+N stepping exact
    -- even when mGBA emits several Lua callbacks for one frontend action.
    return gameProfile and gameProfile.gMain and emu:read32(gameProfile.gMain+0x24)
        or frameClock:currentFrame()
end
local captureClock=dofile(suiteDir.."/lib/CaptureClock.lua").new(rawCaptureFrame())
local function captureFrame() return captureClock:value() end
callbacks:add("key",function(event)
    local key=tonumber(event.key)
    local state=tonumber(event.state)
    local modifiers=tonumber(event.modifiers) or 0
    local inputState=C and C.INPUT_STATE or {}
    local keyMods=C and C.KMOD or {}
    local control=tonumber(keyMods.CONTROL) or 0
    if control==0 or (modifiers&control)==0 then return end
    if key==string.byte("N") or key==string.byte("n") then
        captureClock:frameAdvanceKey(state,inputState.DOWN,inputState.UP)
    elseif (key==string.byte("P") or key==string.byte("p")) and state==inputState.DOWN then
        -- Whether this press pauses or resumes, Ctrl+N will arm suppression
        -- again when needed. Re-anchoring here also supports scripts loaded
        -- while mGBA was already paused.
        captureClock:resume(rawCaptureFrame())
    end
end)
STARTER_HUNTER_ENCOUNTER_DATA=dofile(suiteDir.."/lib/encounter_data.lua")
if not MANUAL_MONITOR_SHOW_RNG_PANELS then STARTER_HUNTER_HIDE_CORE_UI=true end
STARTER_HUNTER_DIAGNOSTIC=true
STARTER_HUNTER_MANUAL_REQUIRE_INPUT=MANUAL_MONITOR_REQUIRE_INPUT~=false
dofile(suiteDir.."/lib/RNGCore.lua")

-- The combined entry is primarily used for starter timing. Always default to
-- Starter, even when it is loaded after the starter entered the party. Wild
-- remains an explicit M toggle and can never silently replace the starter
-- with the opposing battle Pokemon.
if combined then kind=MANUAL_MONITOR_DEFAULT_KIND=="wild" and "wild" or "starter" end
starterHunter:setMode(kind)
if kind=="wild" then
    starterHunter:setWildMethod(2)
    starterHunter:detectWildArea(true)
end
-- Clear stale encounter details without erasing calibration from the previous
-- attempt when the monitor is reloaded.
starterHunter:resetFrameDiagnostics(true)

-- TID/SID live in the save block and can be temporarily unreadable while a
-- state is loading or the game is changing callbacks.  Keep a local display
-- copy and refresh it from the shared profile reader instead of requiring any
-- manual entry.
local captureTid,captureSid=nil,nil
local function refreshTrainerIds()
    if not starterHunter or not starterHunter.getProfile then return end
    local ok,profile=pcall(function() return starterHunter:getProfile() end)
    if ok and profile and profile.tid and profile.sid then
        captureTid,captureSid=profile.tid,profile.sid
    end
end
refreshTrainerIds()

local panelName=MANUAL_MONITOR_PANEL_NAME or (combined and "Manual RNG" or (kind=="starter" and "Manual Starter" or "Manual Wild"))
local panel=STARTER_HUNTER_HEADLESS and {
    setSize=function() end,moveCursor=function() end,print=function() end
} or console:createBuffer(panelName)
local WIDTH,HEIGHT=54,16
panel:setSize(WIDTH,HEIGHT)

local observedPid,lastStarterPid,lastWildPid,observedPokemon=0,0,0,nil
local pinnedStarterPid,stableResult=0,nil
local starterBaselinePid=0
local pendingFrameInput=false
local lastText,lastRenderClock="",os.clock()
local REFRESH_SECONDS=0.10

local function snapshot()
    local state=starterHunter:getFrameHitState()
    local result=state.result
    -- Keep the last completed measurement visible. RNGCore legitimately
    -- clears its transient result during a reset/new read; that used to make
    -- Hit/Miss/Corrected flash and then turn back into --.
    if stableResult and (not state.targetArmed or stableResult.targetFrame~=state.targetFrame) then stableResult=nil end
    if result and result.landedFrame and (observedPid==0 or result.pid==observedPid) then stableResult=result end
    if stableResult and state.targetArmed and stableResult.targetFrame==state.targetFrame then
        if not result or not result.landedFrame or (observedPid~=0 and result.pid~=observedPid) then result=stableResult end
    elseif observedPid~=0 and result and result.pid~=observedPid then
        result=nil
    end
    local runtime=starterHunter:getRuntimeState()
    local searching=runtime.mode=="searching"
    local inputFrame=state.targetArmed and not searching and (result and result.targetFrame or state.targetFrame) or nil
    local inputText=state.editing and ((state.editText or "").."_")
        or (inputFrame and tostring(inputFrame) or "G to enter")
    local correction=result and result.correction or state.correction
    local targetDetails=starterHunter:getManualTargetDetails()
    local pokemon=observedPokemon
    return {
        kind=kind,
        videoFrame=captureFrame(),
        myFrame=state.currentFrame,
        initialSeed=runtime.initialSeed,
        initialSeedBits=runtime.initialSeedBits,
        currentSeed=runtime.currentSeed,
        inputFrame=inputFrame,
        inputText=inputText,
        landedFrame=result and result.landedFrame or nil,
        resolveError=result and result.error or nil,
        miss=result and result.miss or nil,
        adjustedOffset=inputFrame and correction or nil,
        correctedFrame=inputFrame and math.max(0,inputFrame+correction) or nil,
        targetPid=targetDetails and targetDetails.pid or nil,
        targetIsShiny=targetDetails and targetDetails.shinyValue<8 or false,
        shinyPid=targetDetails and targetDetails.shinyValue<8 and targetDetails.pid or nil,
        shinyMethod=targetDetails and targetDetails.method or nil,
        pid=kind=="starter" and observedPid
            or (result and result.pid)
            or state.pid or 0,
        pokemon=pokemon,
        resolving=state.resolving,
        waitingFreshStarter=kind=="starter" and starterBaselinePid~=0,
        editing=state.editing,searching=searching
    }
end

local function render(force)
    local state=snapshot()
    local mon=state.pokemon
    local miss=state.miss and string.format("%+d (%s)",state.miss,state.miss==0 and "exact" or (state.miss>0 and "late" or "early")) or "--"
    local ivs=mon and mon.ivs
    local initialSeedFormat=state.initialSeedBits==16 and "%04X" or "%08X"
    local text=table.concat({
        "Mode              "..(state.kind=="starter" and "Starter" or "Wild")..(combined and "  (M toggle)" or ""),
        "Initial Seed      "..string.format(initialSeedFormat,state.initialSeed or 0),
        "Current Seed      "..string.format("%08X",state.currentSeed or 0),
        "Trainer TID / SID "..(captureTid and captureSid and string.format("%05d / %05d",captureTid,captureSid) or "waiting for live state"),
        string.format("Current Frame     %d",state.videoFrame),
        string.format("Advances          %d",state.myFrame),
        "Target Frame      "..state.inputText.."  (G edit)",
        "Hit Frame         "..(state.landedFrame and tostring(state.landedFrame)
            or (state.waitingFreshStarter and "WAIT RESET" or (state.resolveError and "NO MATCH" or "--"))),
        "Miss              "..miss,
        "Adjusted Offset   "..(state.adjustedOffset and string.format("%+d",state.adjustedOffset) or "--"),
        "Corrected Frame   "..(state.correctedFrame and tostring(state.correctedFrame) or "--"),
        "Target PID        "..(state.targetPid and string.format("%08X  %s",state.targetPid,state.targetIsShiny and "SHINY" or "NOT SHINY") or "--"),
        "Pokemon           "..(mon and string.format("%s  Lv%d",mon.speciesName or ("Species "..tostring(mon.species or 0)),mon.level or 0) or "--"),
        "PID / Nature      "..(mon and string.format("%08X  %s%s",mon.pid,mon.nature or "--",mon.shiny and "  SHINY" or "") or "--"),
        "Ability           "..(mon and string.format("%s (%d)",mon.ability or "--",mon.abilityNum or 0) or "--"),
        "IVs HP/Atk/Def/SpA/SpD/Spe  "..(ivs and table.concat(ivs,"/") or "--"),
        "Hidden Power      "..(mon and mon.hiddenPower and string.format("%s %d",mon.hiddenPower,mon.hiddenPowerPower) or "--")
    },"\n")
    if force or text~=lastText then
        local rows={}
        for line in (text.."\n"):gmatch("(.-)\n") do
            local clipped=line:sub(1,WIDTH)
            rows[#rows+1]=clipped..string.rep(" ",WIDTH-#clipped)
        end
        panel:moveCursor(0,0)
        panel:print(table.concat(rows,"\n"))
        lastText=text
    end
end

local function observeStarter(actual,force)
    if kind~="starter" or not actual or not actual.valid or actual.pid==0 then return false end
    local state=starterHunter:getFrameHitState()
    -- Always resolve the received starter. Entering a target with G is only
    -- required for targeting/Auto; it must not be required for Landed frame.
    if state.editing or state.resolving then return false end
    observedPid,observedPokemon=actual.pid,actual
    if not force and actual.pid==lastStarterPid then return false end
    lastStarterPid=actual.pid
    -- Starter PID recovery is synchronous so results still appear if the user
    -- pauses immediately on the battle screen. Wild retains its exact spread
    -- resolver because species, level and all IVs identify H-2/H-1/H-4.
    local center=state.targetArmed and state.targetFrame or state.currentFrame
    return starterHunter:resolveStarterPid(actual.pid,center,state.targetArmed)
end

local function observeWild(actual,force)
    if kind~="wild" or not actual or not actual.valid or actual.pid==0 then return false end
    observedPid,observedPokemon=actual.pid,actual
    -- The script may have been loaded on a different map or before the save
    -- pointer became readable. Refresh the live route before matching the
    -- encounter spread; otherwise every candidate can use the wrong slots.
    starterHunter:detectWildArea(false)
    local state=starterHunter:getFrameHitState()
    if state.editing or state.resolving or (not force and actual.pid==lastWildPid) then return false end
    lastWildPid=actual.pid
    if not state.targetArmed then return true end
    if state.result and state.result.pid==actual.pid and state.result.landedFrame then return true end
    return starterHunter:resolveManualPokemon(actual,state.targetFrame)
end

local function pollWild(force)
    if kind~="wild" then return false end
    return observeWild(starterHunter:getEnemyPokemon(),force==true)
end

local function switchMode()
    if not combined then return false end
    kind=kind=="starter" and "wild" or "starter"
    starterHunter:setMode(kind)
    if kind=="wild" then starterHunter:setWildMethod(2); starterHunter:detectWildArea(true) end
    starterHunter:resetFrameDiagnostics()
    observedPid,lastStarterPid,lastWildPid,observedPokemon=0,0,0,nil
    pinnedStarterPid,stableResult,starterBaselinePid=0,nil,0
    pendingFrameInput=false
    render(true)
    return true
end

local function pollStarter(force)
    -- Once a received starter is seen, keep following that exact party PID.
    -- Do not jump to another occupied slot during a transient party rewrite.
    if pinnedStarterPid~=0 then
        for slot=1,6 do
            local actual=starterHunter:getPartyPokemon(slot)
            if actual and actual.pid==pinnedStarterPid then
                if starterBaselinePid~=0 and actual.pid==starterBaselinePid then return false end
                starterBaselinePid=0
                return observeStarter(actual,force)
            end
        end
    end
    for slot=1,6 do
        local actual=starterHunter:getPartyPokemon(slot)
        if actual then
            pinnedStarterPid=actual.pid
            if starterBaselinePid~=0 and actual.pid==starterBaselinePid then return false end
            starterBaselinePid=0
            return observeStarter(actual,force)
        end
    end
    -- A reset/savestate can remove the starter before the next attempt. Clear
    -- the remembered PID so that even a repeated generation is inspected.
    lastStarterPid,pinnedStarterPid=0,0
    return false
end

callbacks:add("key",function(event)
    if GEN3_SUITE_ACTIVE_TOOL and GEN3_SUITE_ACTIVE_TOOL~="Capture" then return end
    if event.state~=1 or ((event.modifiers or 0)&0xC)~=0 then return end
    local key=event.key
    if GEN3_SUITE_MANAGED then
        local suiteKey=key==71 or key==103 or key==77 or key==109 or key==81 or key==113 or
            key==73 or key==105 or key==0x0A or key==0x0D or key==0x800050
        if not suiteKey then return end
    end
    if key==71 or key==103 then
        stableResult=nil
        pendingFrameInput=true
        lastStarterPid=0
        if kind=="wild" then lastWildPid=starterHunter:getEnemyPid() end
    elseif pendingFrameInput and (key==0x0A or key==0x0D or key==0x800050) then
        pendingFrameInput=false
        lastStarterPid=0
        if kind=="starter" then
            -- Ignore a starter left over from the previous attempt. Calibration
            -- begins only after reset replaces it with a newly generated PID.
            local existing=nil
            for slot=1,6 do existing=starterHunter:getPartyPokemon(slot); if existing then break end end
            starterBaselinePid=existing and existing.pid or 0
            if starterBaselinePid==0 then pollStarter(true) end
        else pollWild(true) end
    elseif key==81 or key==113 then
        stableResult=nil
        starterHunter:resetFrameDiagnostics()
        starterBaselinePid=0
        lastStarterPid,lastWildPid=0,starterHunter:getEnemyPid()
    elseif key==73 or key==105 then
        if kind=="starter" then pollStarter(true) else pollWild(true) end
    elseif combined and (key==77 or key==109) then
        switchMode()
    end
    render(true)
end)

local frameCounter=0
frameClock:add(function()
    captureClock:update(rawCaptureFrame())
    if GEN3_SUITE_ACTIVE_TOOL and GEN3_SUITE_ACTIVE_TOOL~="Capture" then return end
    frameCounter=frameCounter+1
    if frameCounter%30==0 then refreshTrainerIds() end
    if not STARTER_HUNTER_MANUAL_TEST then
        if kind=="starter" then pollStarter(false)
        elseif frameCounter%6==0 then pollWild(false) end
    end
    -- Normal play uses a wall-clock throttle so the console stays light. In
    -- fast-forward mGBA can execute many emulated frames before that clock
    -- advances enough for a redraw, so force a bounded refresh every 30
    -- callbacks as a fallback. The frame counter and RNG reads keep running
    -- on every callback regardless of how often the panel is painted.
    if frameCounter%6==0 then
        local now=os.clock()
        if now-lastRenderClock>=REFRESH_SECONDS or frameCounter%30==0 then
            render(false)
            lastRenderClock=now
        end
    end
end)

ManualMonitor={
    kind=kind,combined=combined,
    getKind=function() return kind end,
    switchMode=switchMode,
    snapshot=snapshot,
    render=function() render(true) end,
    testObserve=function(actual) return observeStarter(actual,true) end,
    testObserveWild=function(actual) return observeWild(actual,true) end,
    testSearchState=function() return frameCounter end
}
render(true)
