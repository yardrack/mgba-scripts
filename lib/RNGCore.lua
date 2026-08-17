-- Separate Starter, Roamer, and Wild RNG tools for stock mGBA.
-- PokeFinder-compatible Gen 3 target generation + an EonTimer-style countdown.
-- The timer stays visible; exact input/seed work runs quietly in the same script.

local FPS = 59.727500569606
local MAX_SEARCH_FRAME = 5000000
local SHINY_FRAME_CHOICES = math.max(1,math.min(5,tonumber(STARTER_HUNTER_SHINY_FRAME_CHOICES) or 5))
local SEARCH_LEAD_FRAMES = 60
local MAX_VISIBLE_COUNTDOWN_SECONDS = 30
local KEY_BACKSPACE, KEY_ENTER, KEY_ESCAPE, KEY_KP_ENTER = 0x08, 0x0A, 0x1B, 0x800050
local KEY_A, KEY_B, KEY_START, KEY_RIGHT, KEY_LEFT, KEY_UP, KEY_DOWN = 0, 1, 3, 4, 5, 6, 7
local MASK_A, MASK_B, MASK_SELECT, MASK_START = 0x001, 0x002, 0x004, 0x008
local MASK_RIGHT, MASK_LEFT, MASK_UP, MASK_DOWN = 0x010, 0x020, 0x040, 0x080
local MASK_R, MASK_L = 0x100, 0x200
local automationKeyMask, keyReadCount, lastAppliedKeyMask = 0, 0, 0
local stageKeyReads, stageCounterStage = 0, "idle"

local function pressKey(key)
    -- The mask is applied by the keysRead callback immediately before the
    -- emulated game samples input. A frame callback is too late for that frame.
    automationKeyMask = 1 << key
    -- Some revision/profile combinations do not poll KEYINPUT through the
    -- scripting hook every video frame. Holding the same mask directly until
    -- the next frame keeps automation deterministic on those builds too.
    emu:setKeys(automationKeyMask)
end

local suiteDir=STARTER_HUNTER_DIR or GEN3_SUITE_DIR or (script and script.dir)
if not suiteDir then error("The RNG core could not locate the mGBA scripts folder.") end
STARTER_HUNTER_DIR=suiteDir
GEN3_FRAME_CLOCK=GEN3_FRAME_CLOCK or dofile(suiteDir.."/lib/FrameClock.lua")
local gameData=dofile(suiteDir.."/lib/GameProfiles.lua")
local rngMath=dofile(suiteDir.."/lib/RNGMath.lua")
local NATURES,GAME_CONFIGS=gameData.natures,gameData.profiles

local gameCode = GEN3_GAME_CODE or tostring(emu:getGameCode()):sub(-4)
local game = gameData.resolve(gameCode,emu:read8(0x080000BC))
if not game then error("Pokemon RNG tools support main-series Gen 3 Pokemon games only.") end

local PROJECT_DIR = STARTER_HUNTER_RUNTIME_DIR or suiteDir
local SETTINGS_PATH = PROJECT_DIR .. "/settings-" .. game.dataCode .. ".txt"
local BRIDGE_DIR=STARTER_HUNTER_BRIDGE_DIR or PROJECT_DIR
local eonBridge={requestPath=BRIDGE_DIR.."/eontimer-target.txt",resultPath=BRIDGE_DIR.."/eontimer-result.txt",
    ackPath=BRIDGE_DIR.."/eontimer-ack.txt",commandPath=BRIDGE_DIR.."/wild-command.txt",
    lastCommandSequence=nil,nextCommandPoll=0,frameHitEnemyPid=0,frameHitStatus="Waiting for a Pokemon encounter.",
    pidRecoveryJob=nil,targetPokemonConfirmed=false,frameChoiceConfirmed=false,
    manualTargetArmed=not STARTER_HUNTER_MANUAL_REQUIRE_INPUT}
local encounterData = STARTER_HUNTER_ENCOUNTER_DATA or require("lib/encounter_data")
local areas = encounterData.games[game.dataCode] or {}
local speciesNames = encounterData.species

local UI_SIZES = {{54,22,"Small"},{68,30,"Normal"},{82,36,"Large"}}
local uiSizeIndex, simpleUi = 2, true
local function createPanel(name)
    if not STARTER_HUNTER_HEADLESS and not STARTER_HUNTER_HIDE_CORE_UI and console then return console:createBuffer(name) end
    return {setSize=function() end,clear=function() end,print=function() end,moveCursor=function() end}
end
eonBridge.managedPanel=GEN3_SUITE_MANAGED and not STARTER_HUNTER_CAPTURE_ONLY
    and createPanel((GEN3_SUITE_NAME or game.name).." Auto Shiny") or nil
local panels = eonBridge.managedPanel and {eonBridge.managedPanel,eonBridge.managedPanel,eonBridge.managedPanel} or {
    createPanel("Starter RNG"),createPanel("Roamer RNG"),createPanel("Wild RNG")
}
local function applyUiSize()
    local size=RNG_COMPACT_UI and {58,16,"Compact"} or UI_SIZES[uiSizeIndex]
    for _,buffer in ipairs(panels) do buffer:setSize(size[1],size[2]) end
end
local function fixedPanelText(text,width,height)
    local rows={}
    for line in (tostring(text).."\n"):gmatch("(.-)\n") do
        if line=="" then
            rows[#rows+1]=""
        else
            while #line>width do
                rows[#rows+1]=line:sub(1,width)
                line=line:sub(width+1)
            end
            rows[#rows+1]=line
        end
    end
    while #rows<height do rows[#rows+1]="" end
    local visible={}
    for row=1,height do
        local line=rows[row] or ""
        visible[row]=line..string.rep(" ",math.max(0,width-#line))
    end
    return table.concat(visible,"\n")
end
local function replacePanelText(panel,text,_fast)
    -- Never clear a Qt text buffer while it is being used. Clearing can take
    -- keyboard focus away from the Scripting window and make the tool appear
    -- frozen. Overwriting the visible rows keeps R/Esc and the other controls
    -- responsive during automated runs too.
    local size=RNG_COMPACT_UI and {58,16,"Compact"} or UI_SIZES[uiSizeIndex]
    local replaced=false
    if panel.moveCursor then
        replaced=pcall(function()
            -- One Qt document update instead of 30-36 cursor moves and print
            -- operations. Padding overwrites remnants of the previous view.
            panel:moveCursor(0,0)
            panel:print(fixedPanelText(text,size[1],size[2]))
        end)
    end
    if not replaced then panel:clear(); panel:print(text) end
end
applyUiSize()
if STARTER_HUNTER_CAPTURE_ONLY then
    -- Capture uses the seed, PID and spread readers without exposing or
    -- scheduling any automatic hunt controls.
elseif eonBridge.managedPanel then
    eonBridge.managedPanel:print("AUTO SHINY\n\nM switches Starter/Wild. T selects Starter. V selects Wild.\nF scans, locks and runs.")
else
    panels[1]:print("STARTER RNG\n\nPress T to use Starter RNG.")
    panels[2]:print("ROAMER RNG\n\nPress O to use Roamer RNG.")
    panels[3]:print("WILD RNG\n\nPress V to use Wild RNG.")
end

local baseSeed, targetFrame, starterIndex, huntType, roamerIndex = 0, 0, 1, 1, 1
local preTimerSeconds, calibrationFrames = 5.0, 0
local hitCorrectionFrames = 0
local wildTypeIndex, wildAreaIndex, wildSpeciesIndex, wildMethod = 1, 1, 1, 1
local wildAreaAvailable=true
local WILD_TYPES, WILD_METHODS = {"Grass","Surf","Old Rod","Good Rod","Super Rod","Rock Smash"}, {1,2,4}
eonBridge.searchCache={
    grassLimits={20,40,50,60,70,80,85,90,94,98,99,100},
    otherLimits={60,90,95,99,100},
    species=setmetatable({}, {__mode="k"}),
    speciesText=setmetatable({}, {__mode="k"}),
    headerKey=nil,headerId=nil,headerValid=false
}
local tid, sid, target, liveAdvances = nil, nil, nil, 0
local mode, navStage, stageFrames, countdownFrames, frameCounter = "idle", "idle", 0, 0, 0
local status = "Pick a Pokemon, then press F to find a shiny frame."
local editMode, editText, lastPanelText = nil, "", {}
local searchJob = nil
local shinyTargets, shinyTargetIndex = {}, 0
local searchOriginFrame = 0
local lastPeriodicSecond = os.time()
local automationTarget, automationHuntType, automationPokemon, automationTid, automationSid
local seedCandidates, seedAttempt, initialPartyCount, initialEnemyPid = nil, 1, 0, 0
local automationSweetPartySlot, automationSweetMenuIndex = nil, nil
local automationMoveKey = nil
local automationMoveSteps = 0
local wildSeedLocked, wildTaskSeen = false, false
local wildBreakpointId = nil
local suppressedEncounterState = nil
local wildLockDiagnostics = nil
local wrongResults = {}
local lastFrameResult = nil
local previousSeed = nil
local readPokemon -- used by diagnostic search before the reader's definition

local function clearShinyTargets()
    shinyTargets, shinyTargetIndex = {}, 0
    eonBridge.frameChoiceConfirmed=false
end

local function timerValueText(frames)
    local total=math.max(0,frames or 0)/FPS
    local minutes=math.floor(total/60)
    local seconds=total-minutes*60
    return string.format("%02d:%06.3f",minutes,seconds)
end

local mulAdd32,lcgNext,lcgPrevious=rngMath.mulAdd,rngMath.next,rngMath.previous
local advanceSeed,offsetSeed=rngMath.advance,rngMath.offset
local unpackIvs,shinyValue=rngMath.unpackIvs,rngMath.shinyValue

local function save1Address()
    if game.save1 then return game.save1 end
    local pointer = emu:read32(game.save1Ptr)
    return pointer >= 0x02000000 and pointer < 0x02040000 and pointer or nil
end
local function save2Address()
    if game.save2 then return game.save2 end
    local pointer = emu:read32(game.save2Ptr)
    return pointer >= 0x02000000 and pointer < 0x02040000 and pointer or nil
end
eonBridge.catch=dofile(suiteDir.."/lib/CatchCore.lua").new({
    emu=emu,game=game,press=pressKey,save1=save1Address,save2=save2Address
})
eonBridge.roamer=dofile(suiteDir.."/lib/RoamerCore.lua").new({
    emu=emu,game=game,save1=save1Address,shinyValue=shinyValue
})

local ENCOUNTER_TILE_BEHAVIORS={
    [0x02]=true,[0x03]=true,[0x05]=true,[0x06]=true,[0x08]=true,[0x0B]=true,
    [0x10]=true,[0x11]=true,[0x12]=true,[0x15]=true,[0x22]=true,[0x24]=true,[0x25]=true,[0x2C]=true
}
local WATER_ENCOUNTER_TILE_BEHAVIORS={
    [0x10]=true,[0x11]=true,[0x12]=true,[0x14]=true,[0x15]=true,
    [0x18]=true,[0x19]=true,[0x1A]=true,[0x22]=true,[0x2C]=true
}

local function mapTileInfo(x,y)
    if not (game.mapHeader and game.backupMapLayout) then return nil end
    local width=emu:read32(game.backupMapLayout)
    local map=emu:read32(game.backupMapLayout+8)
    local layout=emu:read32(game.mapHeader)
    if width<=0 or width>512 or map<0x02000000 or map>=0x03000000 or layout<0x08000000 then return nil end
    local block=emu:read16(map+2*(x+width*y))
    local id=block&0x3FF
    local tileset=emu:read32(layout+(id<512 and 0x10 or 0x14))
    -- FR/LG place the metatile-attribute pointer after the callback (0x14),
    -- while Ruby/Sapphire/Emerald place it before the callback (0x10).
    local attrs=emu:read32(tileset+(game.frlgMapAttributes and 0x14 or 0x10))
    if attrs<0x08000000 then return nil end
    local attributeIndex=id<512 and id or id-512
    local attribute=game.frlgMapAttributes and emu:read32(attrs+4*attributeIndex) or emu:read16(attrs+2*attributeIndex)
    local behavior=attribute&(game.frlgMapAttributes and 0x1FF or 0xFF)
    local encounter=game.frlgMapAttributes and (((attribute>>24)&7)==1 or ((attribute>>24)&7)==2) or ENCOUNTER_TILE_BEHAVIORS[behavior]
    return behavior,(block>>10)&3,encounter
end

local function playerTile()
    if not (game.playerAvatar and game.objectEvents) then return nil end
    local objectId=emu:read8(game.playerAvatar+5)
    if objectId>=16 then return nil end
    local object=game.objectEvents+objectId*0x24
    return emu:read16(object+0x10),emu:read16(object+0x12)
end

local function findNearbyEncounterStep()
    local x,y=playerTile(); if not x then return nil,nil end
    local _,_,currentEncounter=mapTileInfo(x,y)
    if currentEncounter then return nil,true end
    local choices={{KEY_UP,0,-1},{KEY_DOWN,0,1},{KEY_LEFT,-1,0},{KEY_RIGHT,1,0}}
    local queue={{x=x,y=y,first=nil,distance=0}}
    local seen={[x..":"..y]=true}
    local head=1
    while head<=#queue do
        local node=queue[head]; head=head+1
        if node.distance<16 then
            for _,choice in ipairs(choices) do
                local nx,ny=node.x+choice[2],node.y+choice[3]
                local key=nx..":"..ny
                if not seen[key] then
                    seen[key]=true
                    local behavior,collision,encounter=mapTileInfo(nx,ny)
                    if behavior and collision==0 then
                        local first=node.first or choice[1]
                        if encounter then return first,false end
                        queue[#queue+1]={x=nx,y=ny,first=first,distance=node.distance+1}
                    end
                end
            end
        end
    end
    return nil,false
end
local function readProfile()
    local address = save2Address()
    local newTid,newSid
    if address then
        newTid,newSid=emu:read16(address+0x0A),emu:read16(address+0x0C)
    elseif tid~=nil and sid~=nil then
        -- Keep the identity already read from SaveBlock2 while its pointer is
        -- transiently unavailable. A traded lead must not replace the player.
        return true
    else
        -- Save-block pointers can be cleared briefly while the game changes
        -- callbacks or restores a state. The unencrypted OT ID on an occupied
        -- party slot is a safe live fallback until SaveBlock2 is available.
        local counts={}
        local count=math.min(6,emu:read8(game.partyCount))
        for slot=0,count-1 do
            local mon=game.party+slot*0x64
            local pid,ot=emu:read32(mon),emu:read32(mon+4)
            if pid~=0 or ot~=0 then counts[ot]=(counts[ot] or 0)+1 end
        end
        local best,bestCount=nil,0
        for ot,count in pairs(counts) do
            if count>bestCount then best,bestCount=ot,count end
        end
        if best then newTid,newSid=best&0xFFFF,(best>>16)&0xFFFF end
    end
    if newTid==nil or newSid==nil then return false end
    tid, sid = newTid, newSid
    return true
end

local function currentWildType() return WILD_TYPES[wildTypeIndex] end
local function usesAutomaticSweetScent() return huntType==3 and (currentWildType()=="Grass" or currentWildType()=="Surf") end
local function areaMatchesType(area) return area and area.type == currentWildType() end
local function normalizeArea()
    if #areas == 0 then return end
    if wildAreaIndex < 1 or wildAreaIndex > #areas or not areaMatchesType(areas[wildAreaIndex]) then
        for i, area in ipairs(areas) do
            if areaMatchesType(area) then wildAreaIndex = i; break end
        end
    end
    wildSpeciesIndex = math.max(1, wildSpeciesIndex)
end
local function selectedArea()
    if huntType==3 and not wildAreaAvailable then return nil end
    normalizeArea()
    return areas[wildAreaIndex]
end
local function uniqueSpecies(area)
    local cached=area and eonBridge.searchCache.species[area]
    if cached then return cached end
    local result, seen = {}, {}
    if area then
        for _, slot in ipairs(area.slots) do
            if slot.species > 0 and not seen[slot.species] then result[#result+1] = slot.species; seen[slot.species] = true end
        end
    end
    if area then eonBridge.searchCache.species[area]=result end
    return result
end
local function selectedWildSpecies()
    local list = uniqueSpecies(selectedArea())
    if #list == 0 then return 0 end
    wildSpeciesIndex = ((wildSpeciesIndex - 1) % #list) + 1
    return list[wildSpeciesIndex]
end
local function availablePokemonText(area)
    if area and eonBridge.searchCache.speciesText[area] then return eonBridge.searchCache.speciesText[area] end
    local names={}
    for _,id in ipairs(uniqueSpecies(area)) do names[#names+1]=speciesNames[id] or ("Pokemon "..tostring(id)) end
    local text=#names>0 and table.concat(names,", ") or "None"
    if area then eonBridge.searchCache.speciesText[area]=text end
    return text
end

local function currentWildHeaderId()
    local save1=save1Address()
    if not save1 or not game.wildHeaders then return nil end
    local wildHeaders=game.wildHeaders
    if game.wildHeadersByRevision then
        local revision=emu:read8(0x080000BC)
        wildHeaders=game.wildHeadersByRevision[revision] or wildHeaders
    end
    local mapGroup,mapNum=emu:read8(save1+4),emu:read8(save1+5)
    if mapGroup==0xFF or mapNum==0xFF then return nil end
    local cacheKey=string.format("%08X:%02X:%02X",wildHeaders,mapGroup,mapNum)
    if eonBridge.searchCache.headerValid and cacheKey==eonBridge.searchCache.headerKey then
        return eonBridge.searchCache.headerId,mapGroup,mapNum
    end
    for index=0,255 do
        local header=wildHeaders+index*20
        local group,num=emu:read8(header),emu:read8(header+1)
        if group==0xFF and num==0xFF then break end
        if group==mapGroup and num==mapNum then
            eonBridge.searchCache.headerKey,eonBridge.searchCache.headerId,eonBridge.searchCache.headerValid=cacheKey,index,true
            return index,mapGroup,mapNum
        end
    end
    eonBridge.searchCache.headerKey,eonBridge.searchCache.headerId,eonBridge.searchCache.headerValid=cacheKey,nil,true
    return nil,mapGroup,mapNum
end

local function syncCurrentWildArea(announce,force)
    local headerId=currentWildHeaderId()
    if headerId==nil then
        -- Save-block pointers can be briefly unavailable during a battle
        -- transition. Keep the last verified encounter table instead of
        -- discarding it exactly when the enemy spread needs to be resolved.
        local previous=areas[wildAreaIndex]
        if previous and areaMatchesType(previous) then
            wildAreaAvailable=true
            if announce then status="Using the last detected area: "..previous.name.."." end
            return true,false
        end
        wildAreaAvailable=false
        target=nil
        clearShinyTargets()
        if announce then status="No wild encounter table was found for the current map." end
        return false
    end
    local current=areas[wildAreaIndex]
    local preferredType=currentWildType()
    local x,y=playerTile()
    if x then
        local behavior,_,encounter=mapTileInfo(x,y)
        if encounter then preferredType=WATER_ENCOUNTER_TILE_BEHAVIORS[behavior] and "Surf" or "Grass" end
    end
    if not force and current and current.location==headerId and current.type==preferredType then return true,false end
    local match
    for i,area in ipairs(areas) do if area.location==headerId and area.type==preferredType then match=i; break end end
    if not match then for i,area in ipairs(areas) do if area.location==headerId and area.type==currentWildType() then match=i; break end end end
    if not match then for i,area in ipairs(areas) do if area.location==headerId and area.type=="Grass" then match=i; break end end end
    if not match then for i,area in ipairs(areas) do if area.location==headerId and area.type=="Surf" then match=i; break end end end
    if not match then for i,area in ipairs(areas) do if area.location==headerId then match=i; break end end end
    if not match then
        wildAreaAvailable=false
        target=nil
        clearShinyTargets()
        if announce then status="This map has no supported encounter data." end
        return false
    end

    wildAreaAvailable=true
    local previousPokemon=selectedWildSpecies()
    wildAreaIndex=match
    for i,name in ipairs(WILD_TYPES) do if name==areas[match].type then wildTypeIndex=i; break end end
    local list=uniqueSpecies(areas[match]); wildSpeciesIndex=1
    for i,id in ipairs(list) do if id==previousPokemon then wildSpeciesIndex=i; break end end
    target=nil; clearShinyTargets()
    if announce then status=string.format("Detected %s. Pick a Pokemon, then press F.",areas[match].name) end
    return true,true
end
local function selectedPokemon()
    if huntType == 1 then return game.starters[starterIndex] end
    if huntType == 2 then return game.roamers[roamerIndex] end
    local id = selectedWildSpecies()
    return speciesNames[id] or ("Pokemon " .. tostring(id))
end

local function staticTarget(frame, startState, targetHuntType, scanOnly)
    local effectiveOffset=(targetHuntType or huntType)==1 and (game.starterOffset or 0) or 0
    startState=advanceSeed(startState,effectiveOffset)
    local state = lcgNext(startState); local low = state >> 16
    state = lcgNext(state); local high = state >> 16
    local pid = ((high << 16) | low) & 0xFFFFFFFF
    local sv=tid and sid and shinyValue(tid,sid,pid) or 0xFFFF
    if scanOnly and sv>=8 then return nil end
    state = lcgNext(state); local iv1 = state >> 16
    state = lcgNext(state); local iv2 = state >> 16
    if (targetHuntType or huntType) == 2 and game.buggedRoamer then iv1, iv2 = iv1 & 0xFF, 0 end
    return {frame=frame,state=startState,lockSeed=lcgPrevious(startState),pid=pid,ivs=unpackIvs(iv1,iv2),
        nature=NATURES[(pid % 25)+1],shinyValue=sv}
end

local function hSlot(value, encounterType)
    if encounterType == "Grass" then
        for i, limit in ipairs(eonBridge.searchCache.grassLimits) do if value < limit then return i end end
    elseif encounterType == "Old Rod" then return value < 70 and 1 or 2
    elseif encounterType == "Good Rod" then return value < 60 and 1 or (value < 80 and 2 or 3)
    else
        for i, limit in ipairs(eonBridge.searchCache.otherLimits) do if value < limit then return i end end
    end
    return 1
end

local function safariExtraCall(area)
    local loc = area.location
    if game.dataCode == "BPEE" then return loc==73 or loc==98 or loc==74 or loc==20 or loc==97 or loc==72 end
    if game.dataCode == "AXVE" or game.dataCode == "AXPE" then
        return loc==90 or loc==187 or loc==89 or loc==186 or loc==92 or loc==189 or loc==91 or loc==188
    end
    return false
end

local function wildTarget(frame, startState, methodOverride, encounterContext, scanOnly)
    -- Freeze the route/table used when the encounter was first observed. The
    -- periodic map detector may refresh the selected area while a long scan is
    -- running; letting that alter candidates halfway through makes one real
    -- Pokemon appear to have two different species slots.
    local area=(encounterContext and encounterContext.area) or selectedArea()
    local wanted=(encounterContext and encounterContext.wanted) or selectedWildSpecies()
    if not area or wanted == 0 then return nil end
    local state=startState
    if area.type=="Rock Smash" and (game.dataCode=="BPEE" or game.dataCode=="AXVE" or game.dataCode=="AXPE") then
        state=lcgNext(state)
        if ((state >> 16) % 2880) >= area.rate*16 then return nil end
    end
    state = lcgNext(state)
    local slotIndex = hSlot((state >> 16) % 100, area.type)
    local slot = area.slots[slotIndex]
    if not slot then return nil end
    state = lcgNext(state)
    local level = slot.min + ((state >> 16) % (slot.max - slot.min + 1))
    if scanOnly and slot.species~=wanted then return nil end
    if safariExtraCall(area) then state = lcgNext(state) end
    local nature,pid
    if (game.dataCode=="BPRE" or game.dataCode=="BPGE") and area.location<=6 then
        repeat
            state=lcgNext(state); local low=state >> 16
            state=lcgNext(state); local high=state >> 16
            pid=((low << 16)|high)&0xFFFFFFFF
        until ((((pid&0x3000000)>>18)|((pid&0x30000)>>12)|((pid&0x300)>>6)|(pid&3))%28)==(slot.form or 0)
        nature=pid%25
    else
        state = lcgNext(state); nature = (state >> 16) % 25
        repeat
            state = lcgNext(state); local low = state >> 16
            state = lcgNext(state); local high = state >> 16
            pid = ((high << 16) | low) & 0xFFFFFFFF
        until pid % 25 == nature
    end
    local sv=tid and sid and shinyValue(tid,sid,pid) or 0xFFFF
    if scanOnly and sv>=8 then return nil end
    local method=methodOverride or WILD_METHODS[wildMethod]
    if method == 2 then state = lcgNext(state) end
    state = lcgNext(state); local iv1 = state >> 16
    if method == 4 then state = lcgNext(state) end
    state = lcgNext(state); local iv2 = state >> 16
    return {frame=frame,state=startState,lockSeed=lcgPrevious(startState),pid=pid,ivs=unpackIvs(iv1,iv2),
        nature=NATURES[nature+1],shinyValue=sv,species=slot.species,slot=slotIndex-1,level=level,
        speciesMatch=slot.species==wanted}
end

function eonBridge.makeTargetFor(targetHuntType, frame, startState, methodOverride, encounterContext, scanOnly)
    return targetHuntType == 3 and wildTarget(frame,startState,methodOverride,encounterContext,scanOnly)
        or staticTarget(frame,startState,targetHuntType,scanOnly)
end
local function makeTarget(frame, startState)
    return eonBridge.makeTargetFor(huntType,frame,startState)
end
local function evaluateTarget()
    -- PID/spread generation does not require trainer IDs. TID/SID are only
    -- needed to label shininess, so manual hit detection must remain usable
    -- while the save block is temporarily unreadable during battle.
    target = targetFrame >= 0 and makeTarget(targetFrame,advanceSeed(baseSeed,targetFrame)) or nil
end

local function checkpointPath()
    local label = huntType == 1 and "Starter" or (huntType == 2 and "Roamer" or "Wild")
    return string.format("%s/%s %s Checkpoint.ss1", PROJECT_DIR, game.name, label)
end
local function fileExists(path)
    local file=io.open(path,"rb"); if not file then return false end; file:close(); return true
end
local function checkpointReady() return fileExists(checkpointPath()) end

local function saveSettings()
    if STARTER_HUNTER_DISABLE_SETTINGS then return end
    local file=io.open(SETTINGS_PATH,"w"); if not file then return end
    file:write(string.format("%08X\n%d\n%d\n%.3f\n%d\n%d\n%d\n%d\n%d\n%d\n%d\n%d\n%d\n%d\n",
        baseSeed,targetFrame,starterIndex,preTimerSeconds,calibrationFrames,huntType,roamerIndex,
        wildTypeIndex,wildAreaIndex,wildSpeciesIndex,wildMethod,simpleUi and 1 or 0,uiSizeIndex,hitCorrectionFrames))
    file:close()
end
local function loadSettings()
    if STARTER_HUNTER_DISABLE_SETTINGS then normalizeArea(); return end
    local file=io.open(SETTINGS_PATH,"r"); if not file then normalizeArea(); return end
    local v={}; for i=1,14 do v[i]=file:read("*l") end; file:close()
    baseSeed=tonumber(v[1] or "",16) or baseSeed
    targetFrame=math.max(0,math.min(MAX_SEARCH_FRAME,tonumber(v[2]) or targetFrame))
    starterIndex=math.max(1,math.min(#game.starters,tonumber(v[3]) or starterIndex))
    preTimerSeconds=math.max(0,math.min(60,tonumber(v[4]) or preTimerSeconds))
    calibrationFrames=math.max(-10000,math.min(10000,tonumber(v[5]) or calibrationFrames))
    huntType=math.max(1,math.min(3,tonumber(v[6]) or huntType))
    roamerIndex=math.max(1,math.min(#game.roamers,tonumber(v[7]) or roamerIndex))
    wildTypeIndex=math.max(1,math.min(#WILD_TYPES,tonumber(v[8]) or wildTypeIndex))
    wildAreaIndex=math.max(1,math.min(#areas,tonumber(v[9]) or wildAreaIndex))
    wildSpeciesIndex=math.max(1,tonumber(v[10]) or wildSpeciesIndex)
    wildMethod=math.max(1,math.min(#WILD_METHODS,tonumber(v[11]) or wildMethod))
    simpleUi=(tonumber(v[12]) or (simpleUi and 1 or 0))~=0
    uiSizeIndex=math.max(1,math.min(#UI_SIZES,tonumber(v[13]) or uiSizeIndex))
    hitCorrectionFrames=math.max(-10000,math.min(10000,tonumber(v[14]) or hitCorrectionFrames)); applyUiSize(); normalizeArea()
end

local function ivText(ivs)
    return ivs and string.format("%d/%d/%d/%d/%d/%d",ivs[1],ivs[2],ivs[3],ivs[4],ivs[5],ivs[6]) or "-"
end
local function countdownText()
    if mode=="searching" then return "SEARCHING" end
    if mode=="resolving" then return "READING PID"
    end
    if mode=="pre" then return string.format("RESET IN %.3f s",countdownFrames/FPS) end
    if mode=="running" then return countdownFrames>0 and string.format("TARGET IN %.3f s",countdownFrames/FPS) or "TIMER HIT" end
    if mode=="success" then return "SHINY VERIFIED" end
    if mode=="error" then return "STOPPED" end
    return "READY"
end
local function frameChoicesText()
    if #shinyTargets==0 then return nil end
    local lines={"SHINY FRAME OPTIONS  (B previous / N next)"}
    for i,candidate in ipairs(shinyTargets) do
        local marker=i==shinyTargetIndex and ">" or " "
        local extra=huntType==3 and string.format(" slot %d Lv%d",candidate.slot,candidate.level) or ""
        local eta=math.max(0,candidate.frame-searchOriginFrame)/FPS
        local etaText=eta<60 and string.format("%.1fs",eta) or string.format("%dm%02ds",math.floor(eta/60),math.floor(eta%60))
        lines[#lines+1]=string.format("%s %d) frame %-7d in %-6s %s%s",marker,i,candidate.frame,etaText,candidate.nature,extra)
    end
    return table.concat(lines,"\n")
end
local function setupText()
    if huntType==1 then
        if STARTER_HUNTER_AUTOMATIC_STARTER then
            if game.emerald then return "Use the save in front of Birch's bag with no party Pokemon. F runs the complete hunt." end
            return "Stand at the starter selection position with no party Pokemon. F saves, scans, locks and runs."
        end
        if game.emerald then return "Save in front of Birch's bag with no party Pokemon. H runs it." end
        return "Highlight the starter and stop before the final A press. Press K once, then H."
    elseif huntType==2 then
        if game.emerald then return "At the TV colour choice, leave Red highlighted. Press K once, then H." end
        return "Stop before the final A press that creates the roamer. Press K once, then H."
    end
    if currentWildType()=="Grass" or currentWildType()=="Surf" then
        return "Stand in the listed area with the menus closed. F finds a shiny frame; H saves the starting point, opens the party, and uses Sweet Scent."
    end
    return "Stand at the final "..currentWildType().." input. Press K once, then H."
end
local function render(force)
    local profile=tid and string.format("TID/SID: %d / %d",tid,sid) or "TID/SID: waiting for live game state"
    local hunt
    if huntType==1 then hunt=string.format("Starter: %s",selectedPokemon())
    elseif huntType==2 then hunt=string.format("Roamer: %s",selectedPokemon())
    else
        local area=selectedArea(); hunt=string.format("Wild: %s | %s | %s | Method H-%d",
            area and area.type or "-",area and area.name or "-",selectedPokemon(),WILD_METHODS[wildMethod])
    end
    local targetLine,pidLine="Target: press F to find the next matching shiny","PID/Nature/IVs: -"
    if target then
        local extra=huntType==3 and string.format("  slot %d  Lv%d",target.slot,target.level) or ""
        targetLine=string.format("Target: frame %d  %s%s",target.frame,target.shinyValue<8 and "SHINY" or "NOT SHINY",extra)
        pidLine=string.format("PID %08X  %s  IVs %s",target.pid,target.nature,ivText(target.ivs))
    end
    local edit=editMode and string.format("\nEDIT %s: %s_  (Enter saves, Esc cancels)",editMode:upper(),editText) or ""
    local checkpoint=(not game.emerald or huntType~=1) and (checkpointReady() and "READY" or "NOT SAVED") or "built in"
    local advances=game.advances and tostring(liveAdvances) or "session "..tostring(liveAdvances)
    local mainControls
    if huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER then mainControls="1/2/3 starter   F scan, lock and run   R/Esc stop"
    elseif huntType==1 then mainControls="1/2/3 starter   F find 5 frames   B/N choose   H run   R/Esc stop"
    elseif huntType==2 then mainControls=string.format("1-%d roamer   F find 5 frames   B/N choose   H run   R/Esc stop",#game.roamers)
    else mainControls="F find 5 shiny frames   1-5 or B/N choose   H run   R/Esc stop" end
    local title=(huntType==1 and "STARTER RNG" or huntType==2 and "ROAMER RNG" or "WILD RNG").."  -  "..game.name

    if RNG_COMPACT_UI then
        local stateLabel=mode=="searching" and "SEARCHING" or mode=="running" and "RUNNING"
            or mode=="pre" and "STARTING" or mode=="success" and "SHINY VERIFIED"
            or mode=="catching" and "CATCHING"
            or mode=="error" and "STOPPED" or "READY"
        local activeTarget=automationTarget or (eonBridge.frameChoiceConfirmed and target or nil)
        if huntType==3 and STARTER_HUNTER_AUTOMATIC_WILD then
            local area=selectedArea()
            local initial=baseSeed
            if game.initialSeed then
                initial=(game.initialSeedBits==16 and emu:read16(game.initialSeed) or emu:read32(game.initialSeed))&0xFFFFFFFF
            end
            local lines={title,stateLabel,"",
                "Mode          Wild  (M switches to Starter)",
                "Area          "..(area and area.name or "not detected"),
                "Pokemon       "..selectedPokemon(),
                string.format("Initial Seed  %08X",initial&0xFFFFFFFF),
                string.format("Current Seed  %08X",emu:read32(game.seed)&0xFFFFFFFF),
                tid and string.format("TID / SID     %05d / %05d",tid,sid) or "TID / SID     waiting for live state"}
            if activeTarget then
                lines[#lines+1]=string.format("Locked Frame  %d",activeTarget.frame)
                lines[#lines+1]=string.format("Locked PID    %08X",activeTarget.pid)
            else
                lines[#lines+1]="Locked Frame  --"
                lines[#lines+1]="Locked PID    --"
            end
            lines[#lines+1]=""
            lines[#lines+1]=status
            lines[#lines+1]=""
            if mode=="idle" or mode=="error" or mode=="success" then
                lines[#lines+1]="Z/X Pokemon   F scan, lock and catch"
            else
                lines[#lines+1]="R or Esc stops and releases all input"
            end
            local text=table.concat(lines,"\n")
            local panel=panels[huntType]
            if force or text~=lastPanelText[huntType] then replacePanelText(panel,text,mode~="idle"); lastPanelText[huntType]=text end
            return
        end
        local lines={title,stateLabel,"",
            huntType==1 and "Mode: Starter  (M switches to Wild)"
                or huntType==2 and "Mode: Roamer  (M switches to Starter)"
                or "Mode: Wild  (M switches to Starter)",""}
        if not eonBridge.targetPokemonConfirmed then
            if huntType==3 then
                lines[#lines+1]="Target Pokemon: "..selectedPokemon()
                lines[#lines+1]="Wheel / arrows / Z-X  change Pokemon"
                lines[#lines+1]="F / Enter  confirm and search"
                lines[#lines+1]=""
                lines[#lines+1]="Requires Sweet Scent in the party"
            else
                lines[#lines+1]="Target Starter: "..selectedPokemon()
                lines[#lines+1]="1 / 2 / 3  change starter"
                if huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER then
                    lines[#lines+1]="F  scan, lock and run automatically"
                end
            end
        else
            lines[#lines+1]="Pokemon: "..selectedPokemon()
            lines[#lines+1]=string.format("Current frame  %d",liveAdvances)
            local targetText=activeTarget and tostring(activeTarget.frame) or (mode=="searching" and "searching" or "choose below")
            lines[#lines+1]="Target frame   "..targetText
        end
        -- Preflight failures must remain visible in compact mode. Previously
        -- F could correctly reject missing Sweet Scent/balls/tile while the
        -- panel hid the reason, making the key look broken.
        if mode~="idle" or eonBridge.targetPokemonConfirmed or (status and status~="") then
            lines[#lines+1]=""
            lines[#lines+1]=status
        end
        if mode=="idle" and #shinyTargets>0 then
            lines[#lines+1]=""
            lines[#lines+1]="PICK A SHINY FRAME  (1 is smallest)"
            for i,candidate in ipairs(shinyTargets) do
                lines[#lines+1]=string.format("%d  frame %d",i,candidate.frame)
            end
            lines[#lines+1]="1-5 choose   Enter smallest"
        end
        local text=table.concat(lines,"\n")
        local panel=panels[huntType]
        if force or text~=lastPanelText[huntType] then replacePanelText(panel,text,mode=="pre" or mode=="running"); lastPanelText[huntType]=text end
        return
    end

    if simpleUi then
        local lines={title}
        local validTarget=target and target.shinyValue<8 and (huntType~=3 or target.speciesMatch)
        if mode=="pre" or mode=="running" then
            local navigating=mode=="running" and automationHuntType==3 and (navStage=="generic_load" or navStage:match("^wild_"))
            if navigating then
                lines[#lines+1]="OPENING PARTY MENU - AUTOMATIC"
                lines[#lines+1]="Do not press anything."
            else
                local cue=mode=="pre" and "RESET" or (huntType==3 and "SWEET SCENT" or "TARGET")
                lines[#lines+1]=string.format("%s COUNTDOWN: %s",cue,timerValueText(countdownFrames))
                lines[#lines+1]=countdownFrames>0 and "Automatic - do not press anything." or (huntType==3 and "SWEET SCENT NOW - AUTOMATIC" or "TARGET NOW - AUTOMATIC")
            end
            lines[#lines+1]=string.format("Shiny %s | frame %d",automationPokemon or selectedPokemon(),automationTarget and automationTarget.frame or targetFrame)
            lines[#lines+1]=string.format("Current frame: %d | Target frame: %d",liveAdvances,automationTarget and automationTarget.frame or targetFrame)
            lines[#lines+1]="R or Esc  stop"
        else
            lines[#lines+1]=countdownText()
            lines[#lines+1]=hunt
            lines[#lines+1]=targetLine
            lines[#lines+1]=string.format("Current frame: %d | Target frame: %s",liveAdvances,validTarget and tostring(target.frame) or "-")
            if lastFrameResult then
                if lastFrameResult.landedFrame then
                    lines[#lines+1]=string.format("Last landed: %d | Miss: %+d | Auto correction: %+d",lastFrameResult.landedFrame,lastFrameResult.miss,hitCorrectionFrames)
                else
                    lines[#lines+1]=string.format("Last landed: not found | Auto correction: %+d",hitCorrectionFrames)
                end
            end
            local choices=frameChoicesText(); if choices then lines[#lines+1]=choices end
            if not validTarget then
                lines[#lines+1]="NEXT: Press F to find five shiny frames."
            elseif not (game.emerald and huntType==1) and not usesAutomaticSweetScent() and not checkpointReady() then
                local action=huntType==3 and ((currentWildType()=="Grass" or currentWildType()=="Surf") and "Sweet Scent" or currentWildType()) or "the final choice"
                lines[#lines+1]="NEXT: Highlight "..action..", then press K once."
            else
                lines[#lines+1]="NEXT: Press H. Timing and the final input are automatic."
            end
            if huntType==3 then
                local area=selectedArea()
                lines[#lines+1]="Here: "..(area and area.name or "Unknown")
                lines[#lines+1]="Pokemon here: "..availablePokemonText(area)
                lines[#lines+1]="A detect area | Z/X Pokemon | E encounter | Y method"
                lines[#lines+1]=usesAutomaticSweetScent() and "F find | 1-5 choose | H start | R/Esc stop" or "F find | 1-5 choose | K checkpoint | H start | R/Esc stop"
            else
                lines[#lines+1]=mainControls
                lines[#lines+1]=(not game.emerald or huntType~=1) and "K checkpoint" or "No checkpoint needed"
            end
            lines[#lines+1]=string.format("D details | U UI size (%s)",UI_SIZES[uiSizeIndex][3])
        end
        local text=table.concat(lines,"\n\n")
        local panel=panels[huntType]
        if force or text~=lastPanelText[huntType] then replacePanelText(panel,text,mode=="pre" or mode=="running"); lastPanelText[huntType]=text end
        return
    end

    local lines={title}
    if mode=="pre" or mode=="running" then
        local navigating=mode=="running" and automationHuntType==3 and (navStage=="generic_load" or navStage:match("^wild_"))
        if navigating then
            lines[#lines+1]="OPENING PARTY MENU - AUTOMATIC"
            lines[#lines+1]="WAIT - the script is selecting Sweet Scent"
        else
            local cue=mode=="pre" and "RESET CUE" or (huntType==3 and "SWEET SCENT CUE" or "TARGET CUE")
            lines[#lines+1]=cue.."  |  "..timerValueText(countdownFrames)
            lines[#lines+1]=countdownFrames>0 and "WAIT - the script acts automatically at zero" or (huntType==3 and "SWEET SCENT NOW - AUTOMATIC" or "TARGET NOW - AUTOMATIC")
        end
        lines[#lines+1]=string.format("Current frame %d  |  Target frame %d",liveAdvances,automationTarget and automationTarget.frame or targetFrame)
    else
        lines[#lines+1]=countdownText()
    end
    lines[#lines+1]=hunt
    lines[#lines+1]=profile..string.format("  |  Seed %08X  |  Advances %s",baseSeed,advances)
    lines[#lines+1]=targetLine
    lines[#lines+1]=pidLine
    if mode~="pre" and mode~="running" then
        local choices=frameChoicesText(); if choices then lines[#lines+1]=choices end
    end
    lines[#lines+1]=string.format("Timer %.3f s  |  Offset %+d  |  Frame correction %+d  |  Checkpoint %s",preTimerSeconds,calibrationFrames,hitCorrectionFrames,checkpoint)
    lines[#lines+1]="NEXT: "..status..edit
    lines[#lines+1]=mainControls
    if huntType==3 then
        lines[#lines+1]="Pokemon here: "..availablePokemonText(selectedArea())
        lines[#lines+1]="A detect area   J/L location   Z/X Pokemon   E encounter   Y method"
    end
    lines[#lines+1]=(not game.emerald or huntType~=1) and "K checkpoint   S seed   G frame   P timer   C offset" or "S seed   G frame   P timer   C offset"
    lines[#lines+1]="T Starter RNG   O Roamer RNG   V Wild RNG"
    lines[#lines+1]=string.format("D simple view   U UI size (%s)",UI_SIZES[uiSizeIndex][3])
    lines[#lines+1]=setupText()
    local text=table.concat(lines,"\n\n")
    local panel=panels[huntType]
    if force or text~=lastPanelText[huntType] then replacePanelText(panel,text,mode=="pre" or mode=="running"); lastPanelText[huntType]=text end
end

local function findNextShiny(startFrame,endFrame)
    if not readProfile() then status="Waiting for TID/SID from live game state."; render(true); return nil end
    clearShinyTargets()
    local first=math.max(0,startFrame or (target and target.frame+1 or targetFrame))
    local last=math.min(MAX_SEARCH_FRAME,endFrame or MAX_SEARCH_FRAME)
    status=string.format("Searching from frame %d...",first); render(true)
    local state=advanceSeed(baseSeed,first)
    local encounterContext=huntType==3 and {area=selectedArea(),wanted=selectedWildSpecies()} or nil
    for frame=first,last do
        local candidate=eonBridge.makeTargetFor(huntType,frame,state,nil,encounterContext,true)
        if candidate and candidate.shinyValue<8 and (huntType~=3 or candidate.speciesMatch) then
            targetFrame,target=frame,candidate
            shinyTargets,shinyTargetIndex={candidate},1
            status=string.format("Found shiny %s on frame %d.",selectedPokemon(),frame)
            saveSettings(); render(true); return candidate
        end
        state=lcgNext(state)
    end
    status=string.format("No matching shiny through frame %d.",last); render(true); return nil
end

local function chooseShinyTarget(index,quiet)
    if #shinyTargets==0 then
        if not quiet then status="Press F first to find shiny frame options."; render(true) end
        return false
    end
    shinyTargetIndex=((index-1)%#shinyTargets)+1
    target=shinyTargets[shinyTargetIndex]
    targetFrame=target.frame
    eonBridge.frameChoiceConfirmed=true
    status=string.format("Selected option %d/%d: frame %d for shiny %s.",shinyTargetIndex,#shinyTargets,targetFrame,selectedPokemon())
    saveSettings(); render(true); return true
end

local function finishShinySearch(message)
    local found=#shinyTargets
    searchJob=nil; mode="idle"
    if found==0 then
        status=message or "No matching shiny frames found."
        render(true); return
    end
    shinyTargetIndex=1; target=shinyTargets[1]; targetFrame=target.frame
    eonBridge.manualTargetArmed=true
    if (huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER) or (huntType==3 and STARTER_HUNTER_AUTOMATIC_WILD) then
        eonBridge.frameChoiceConfirmed=true
        eonBridge.autoStartHunt=not STARTER_HUNTER_TEST_NO_AUTO_START
        status=huntType==1
            and string.format("Shiny %s locked on frame %d. Starting automatically.",selectedPokemon(),target.frame)
            or string.format("Shiny frame %d locked from live seed %08X. Starting automatically.",
                target.frame,target.originSeed or emu:read32(game.seed))
    else
        status=string.format("Found %d shiny frames. Pick 1-%d; option 1 is smallest.",found,found)
    end
    saveSettings(); render(true)
end

local function startShinySearch(startAt)
    -- Reuse a profile already read from the live save. Some frontends expose
    -- the save pointer only after their frame callback finishes; forcing a
    -- second immediate pointer read could fail even though TID/SID were just
    -- obtained successfully.
    if (tid==nil or sid==nil) and not readProfile() then
        status="Waiting for TID/SID from live game state."; render(true); return false
    end
    if huntType==3 and not STARTER_HUNTER_TEST_KEEP_WILD_AREA then syncCurrentWildArea(false,false) end
    if huntType==3 and STARTER_HUNTER_AUTOMATIC_WILD then
        local ready,problem=eonBridge.wildPreflight()
        if not ready then status=problem; render(true); return false end
    end
    if huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER then
        if emu:read8(game.partyCount)~=0 then
            status="Automatic Starter requires the save from before receiving the starter."; render(true); return false
        end
        if game.initialSeed then
            baseSeed=(game.initialSeedBits==16 and emu:read16(game.initialSeed) or emu:read32(game.initialSeed))&0xFFFFFFFF
            local current=emu:read32(game.seed)&0xFFFFFFFF
            local absolute=eonBridge.seedDistance(baseSeed,current)
            liveAdvances=absolute and absolute<=MAX_SEARCH_FRAME and absolute or 0
            previousSeed=current
        end
        if not game.emerald then
            local saved=emu:saveStateFile(checkpointPath())
            if not saved and not checkpointReady() then
                status="Could not save the automatic starter position."; render(true); return false
            end
            eonBridge.automaticStarterCheckpoint=saved or checkpointReady()
        end
    end
    if STARTER_HUNTER_MANUAL_REQUIRE_INPUT then eonBridge.manualTargetArmed=false end
    if STARTER_HUNTER_DIAGNOSTIC then
        hitCorrectionFrames,lastFrameResult=0,nil
        eonBridge.resolveJob,eonBridge.pidRecoveryJob=nil,nil
        local current=readPokemon(game.enemy)
        eonBridge.frameHitEnemyPid=current and current.valid and current.pid or 0
        eonBridge.frameHitStatus="Searching for the next matching shiny frame..."
    end
    if game.advances then liveAdvances=emu:read32(game.advances) end
    local supplied=tonumber(startAt)
    searchOriginFrame=math.max(0,math.floor(supplied or liveAdvances))
    local encounterContext=huntType==3 and {area=selectedArea(),wanted=selectedWildSpecies()} or nil
    clearShinyTargets(); target=nil; eonBridge.targetPokemonConfirmed=true
    eonBridge.autoStartHunt=false
    if huntType==3 and not supplied then
        local currentSeed=emu:read32(game.seed)&0xFFFFFFFF
        local first=math.min(MAX_SEARCH_FRAME,searchOriginFrame+SEARCH_LEAD_FRAMES)
        previousSeed=currentSeed
        searchJob={frame=first,last=MAX_SEARCH_FRAME,state=advanceSeed(currentSeed,first-searchOriginFrame),
            liveSeed=true,originSeed=currentSeed,originFrame=searchOriginFrame,encounterContext=encounterContext}
        mode="searching"
        status=string.format("Scanning forward from current seed %08X...",currentSeed)
    else
        local first=math.min(MAX_SEARCH_FRAME,supplied and searchOriginFrame or (searchOriginFrame+SEARCH_LEAD_FRAMES))
        searchJob={frame=first,last=MAX_SEARCH_FRAME,state=advanceSeed(baseSeed,first),encounterContext=encounterContext}
        mode="searching"; status=string.format("Searching forward from advance %d...",searchOriginFrame)
    end
    render(true); return true
end

local function processShinySearch()
    if not searchJob then return end
    local sliceStarted=os.clock()
    for work=1,500 do
        local candidate=eonBridge.makeTargetFor(huntType,searchJob.frame,searchJob.state,nil,searchJob.encounterContext,true)
        if candidate and candidate.shinyValue<8 and (huntType~=3 or candidate.speciesMatch) then
            if searchJob.liveSeed then
                candidate.liveSeed=true
                candidate.originSeed=searchJob.originSeed
                candidate.originFrame=searchJob.originFrame
            end
            shinyTargets[#shinyTargets+1]=candidate
            local automatic=(huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER)
                or (huntType==3 and STARTER_HUNTER_AUTOMATIC_WILD)
            local required=automatic and 1 or SHINY_FRAME_CHOICES
            status=string.format("Found %d/%d shiny frame%s...",#shinyTargets,required,required==1 and "" or " options")
            if #shinyTargets>=required then finishShinySearch(); return end
        end
        searchJob.frame=searchJob.frame+1; searchJob.state=lcgNext(searchJob.state)
        if searchJob.frame>searchJob.last then
            finishShinySearch(string.format("No matching shiny through frame %d.",searchJob.last)); return
        end
        -- Yield back to mGBA frequently. A large synchronous search slice can
        -- otherwise starve Windows input and make the Scripting window look
        -- hung, especially with unbounded fast-forward enabled.
        if work%16==0 and os.clock()-sliceStarted>=0.002 then return end
    end
end

local function sameFunction(pointer,address) return pointer==address or pointer==address+1 end
local function starterTaskActive()
    if not game.emerald then return false end
    for index=0,15 do
        local task=game.tasks+index*40
        if emu:read8(task+4)~=0 and sameFunction(emu:read32(task),game.starterTask) then return true end
    end
    return false
end
local function sweetScentTaskState()
    if not game.emerald or not game.sweetScentTask then return nil end
    for index=0,15 do
        local task=game.tasks+index*40
        if emu:read8(task+4)~=0 and sameFunction(emu:read32(task),game.sweetScentTask) then
            return emu:read16(task+8),task
        end
    end
    return nil
end
local function readRoamer()
    return eonBridge.roamer:read()
end
local GROWTH_OFFSETS={0,0,0,0,0,0,1,1,2,3,2,3,1,1,2,3,2,3,1,1,2,3,2,3}
local ATTACK_OFFSETS={1,1,2,3,2,3,0,0,0,0,0,0,2,3,1,1,3,2,2,3,1,1,3,2}
local MISC_OFFSETS={3,2,3,2,1,1,3,2,3,2,1,1,3,2,3,2,1,1,0,0,0,0,0,0}
local SWEET_SCENT_MOVE=230
local FIELD_MENU_MOVES={
    [15]=true,[19]=true,[57]=true,[70]=true,[91]=true,[100]=true,[127]=true,
    [135]=true,[148]=true,[208]=true,[230]=true,[249]=true,[290]=true,[291]=true
}
readPokemon=function(address)
    local pid,otid=emu:read32(address),emu:read32(address+4)
    if pid==0 and otid==0 then return {pid=0,species=0,valid=false} end
    local key=pid~otid
    local checksum=0
    for i=0,11 do
        local word=emu:read32(address+0x20+i*4)~key
        checksum=(checksum+(word&0xFFFF)+(word>>16))&0xFFFF
    end
    local valid=checksum==emu:read16(address+0x1C)
    local growth=GROWTH_OFFSETS[(pid%24)+1]*12
    local species=(emu:read32(address+0x20+growth)~key)&0xFFFF
    local misc=MISC_OFFSETS[(pid%24)+1]*12
    local ivWord=emu:read32(address+0x24+misc)~key
    local ivs=unpackIvs(ivWord&0x7FFF,(ivWord>>15)&0x7FFF)
    local typeBits=(ivs[1]&1)+2*(ivs[2]&1)+4*(ivs[3]&1)+8*(ivs[6]&1)+16*(ivs[4]&1)+32*(ivs[5]&1)
    local powerBits=((ivs[1]>>1)&1)+2*((ivs[2]>>1)&1)+4*((ivs[3]>>1)&1)+8*((ivs[6]>>1)&1)+16*((ivs[4]>>1)&1)+32*((ivs[5]>>1)&1)
    local hpTypes={"Fighting","Flying","Poison","Ground","Rock","Bug","Ghost","Steel","Fire","Water","Grass","Electric","Psychic","Ice","Dragon","Dark"}
    local abilityNum=(ivWord>>31)&1
    local abilityId=game.speciesInfo and emu:read8(game.speciesInfo+species*28+0x16+abilityNum) or 0
    return {pid=pid,species=species,
        speciesName=eonBridge.internalSpeciesName and eonBridge.internalSpeciesName(species) or ("Species "..tostring(species)),ivs=ivs,
        level=emu:read8(address+0x54),valid=valid,nature=NATURES[(pid%25)+1],abilityNum=abilityNum,
        abilityId=abilityId,ability=gameData.abilities[abilityId+1] or ("Ability "..tostring(abilityId)),
        hiddenPower=hpTypes[math.floor(typeBits*15/63)+1],hiddenPowerPower=math.floor(powerBits*40/63)+30,
        shiny=tid and sid and shinyValue(tid,sid,pid)<8 or false}
end

function eonBridge.huntName(value)
    return value==1 and "Starter" or (value==2 and "Roamer" or "Wild")
end

function eonBridge.readValues(path)
    local file=io.open(path,"r")
    if not file then return nil end
    local values={}
    for line in file:lines() do
        local key,value=line:match("^([^=]+)=(.*)$")
        if key then values[key]=value end
    end
    file:close()
    return values
end

function eonBridge.writeResult(token,targetValue,landedValue,actual,targetHuntType)
    if not token or not landedValue then return false end
    local file=io.open(eonBridge.resultPath,"w")
    if not file then return false end
    file:write("version=1\n")
    file:write("token=",tostring(token),"\n")
    file:write("game=",game.name,"\n")
    file:write("hunt=",eonBridge.huntName(targetHuntType),"\n")
    file:write("target=",tostring(targetValue),"\n")
    file:write("landed=",tostring(landedValue),"\n")
    file:write(string.format("pid=%08X\n",actual and actual.pid or 0))
    file:close()
    return true
end

function eonBridge.pollRequest()
    local values=eonBridge.readValues(eonBridge.requestPath)
    local requestTarget=values and tonumber(values.target)
    local requestToken=values and values.token
    if values and values.version=="1" and requestToken and requestToken~=eonBridge.requestToken
        and requestTarget and requestTarget>=0 and requestTarget<=MAX_SEARCH_FRAME then
        eonBridge.requestToken=requestToken
        eonBridge.targetFrame=math.floor(requestTarget)
        eonBridge.huntType=huntType
        eonBridge.initialPartyCount=emu:read8(game.partyCount)
        eonBridge.initialEnemyPid=emu:read32(game.enemy)
        local roamer=readRoamer()
        eonBridge.initialRoamerPid=roamer and roamer.pid or 0
        local ack=io.open(eonBridge.ackPath,"w")
        if ack then
            ack:write("version=1\n","token=",requestToken,"\n","game=",game.name,"\n")
            ack:close()
        end
        -- If Start was pressed after the battle transition, the enemy already
        -- exists. Resolve that current PID immediately instead of recording it
        -- as the baseline and waiting forever for another encounter.
        if huntType==3 and game.gMain and game.cb2Battle
            and sameFunction(emu:read32(game.gMain+4),game.cb2Battle) then
            local actual=readPokemon(game.enemy)
            if actual.valid then
                eonBridge.initialEnemyPid=0
                eonBridge.beginPassiveResolve(actual)
            end
        end
    end
end

local NATIONAL_TO_INTERNAL_SPECIES={}
do
    -- The Hoenn species are stored in regional order, not National Dex order.
    -- Internal IDs 277..411 map to the following National Dex numbers.
    local hoenn={
        252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,
        270,271,272,273,274,275,290,291,292,276,277,285,286,327,278,279,283,284,
        320,321,300,301,352,343,344,299,324,302,339,340,370,341,342,349,350,318,
        319,328,329,330,296,297,309,310,322,323,363,364,365,331,332,361,362,337,
        338,298,325,326,311,312,303,307,308,333,334,360,355,356,315,287,288,289,
        316,317,357,293,294,295,366,367,368,359,353,354,336,335,369,304,305,306,
        351,313,314,345,346,347,348,280,281,282,371,372,373,374,375,376,377,378,
        379,382,383,384,380,381,385,386,358
    }
    for index,national in ipairs(hoenn) do NATIONAL_TO_INTERNAL_SPECIES[national]=276+index end
end
local function nationalToInternalSpecies(species) return NATIONAL_TO_INTERNAL_SPECIES[species] or species end
function eonBridge.internalSpeciesName(species)
    local national=species
    for dex,internal in pairs(NATIONAL_TO_INTERNAL_SPECIES) do if internal==species then national=dex; break end end
    return speciesNames[national] or ("Species "..tostring(national))
end
local function readPokemonMoves(address)
    local pid,otid=emu:read32(address),emu:read32(address+4)
    if pid==0 and otid==0 then return nil end
    local key=pid~otid
    local attacks=ATTACK_OFFSETS[(pid%24)+1]*12
    local first=emu:read32(address+0x20+attacks)~key
    local second=emu:read32(address+0x24+attacks)~key
    local ppWord=emu:read32(address+0x28+attacks)~key
    return {first&0xFFFF,(first>>16)&0xFFFF,second&0xFFFF,(second>>16)&0xFFFF},
        {ppWord&0xFF,(ppWord>>8)&0xFF,(ppWord>>16)&0xFF,(ppWord>>24)&0xFF}
end
local function findSweetScentUser()
    local count=math.min(6,emu:read8(game.partyCount))
    for partySlot=0,count-1 do
        local address=game.party+partySlot*0x64
        local moves,pps=readPokemonMoves(address)
        if moves then
            for moveSlot=1,4 do
                if moves[moveSlot]==SWEET_SCENT_MOVE and (pps[moveSlot] or 0)>0 and emu:read16(address+0x56)>0 then
                    local menuIndex=0
                    for prior=1,moveSlot-1 do if FIELD_MENU_MOVES[moves[prior]] then menuIndex=menuIndex+1 end end
                    return partySlot,menuIndex
                end
            end
        end
    end
    return nil,nil
end

function eonBridge.wildPreflight()
    if emu:read8(game.partyCount)<1 then return false,"Put a usable Pokemon in the party." end
    local sweetSlot=findSweetScentUser()
    if sweetSlot==nil then return false,"Sweet Scent needs PP and a conscious user." end
    local step,onTile=findNearbyEncounterStep()
    local x,y=playerTile()
    local mapReadable=x and select(1,mapTileInfo(x,y))~=nil
    if mapReadable and not onTile and not step then return false,"Stand on or near a reachable encounter tile." end
    local ok,detail=eonBridge.catch:preflight()
    if not ok then return false,detail end
    local tileDetail=mapReadable and "encounter tile ready" or "place the player on encounter grass/water"
    return true,"Preflight passed: "..tileDetail.."; "..detail
end
local function sweetScentActionCursor()
    if game.actionCursor then
        local count=emu:read8(game.actionCount)
        if count<1 or count>8 then return nil end
        for index=0,count-1 do
            if emu:read8(game.actionOrder+index)==game.sweetAction then return emu:read8(game.actionCursor),index,count end
        end
    elseif game.partyInternalPtr then
        local address=emu:read32(game.partyInternalPtr)-1
        if address<0x02000000 or address>=0x02040000 then return nil end
        local count=emu:read8(address+24)
        if count<1 or count>8 then return nil end
        for index=0,count-1 do
            if emu:read8(address+16+index)==game.sweetAction then return emu:read8(game.actionMenu+2),index,count end
        end
    end
    return nil
end

local function saveCheckpoint()
    if game.emerald and huntType==1 then status="Emerald starter mode does not need a checkpoint; press H."; render(true); return true end
    if usesAutomaticSweetScent() then
        local partySlot=findSweetScentUser()
        if partySlot==nil then status="No party Pokemon knows Sweet Scent."; render(true); return false end
    end
    local saved=emu:saveStateFile(checkpointPath())
    status=saved and (usesAutomaticSweetScent() and "Starting point saved. Press F, choose a frame, then H." or "Checkpoint saved. Press F for a target, then H.") or "Could not save the checkpoint."
    render(true); return saved or checkpointReady()
end
local function restoreEncounterState()
    if not suppressedEncounterState then return end
    local saved=suppressedEncounterState
    emu:write8(saved.roamerAddress,saved.roamerActive)
    emu:write16(saved.outbreakAddress,saved.outbreakSpecies)
    suppressedEncounterState=nil
end
local function clearWildBreakpoint()
    if wildBreakpointId and wildBreakpointId>=0 and emu.clearBreakpoint then emu:clearBreakpoint(wildBreakpointId) end
    wildBreakpointId=nil
end
local function suppressSpecialWildEncounters()
    local save1=save1Address()
    if not save1 or suppressedEncounterState then return end
    local roamerAddress=save1+game.roamerOffset+0x13
    local outbreakAddress=save1+0x2B90
    suppressedEncounterState={
        roamerAddress=roamerAddress,roamerActive=emu:read8(roamerAddress),
        outbreakAddress=outbreakAddress,outbreakSpecies=emu:read16(outbreakAddress)
    }
    wildLockDiagnostics=string.format("save1=%08X roamer=%d outbreak=%d seedBefore=%08X",
        save1,suppressedEncounterState.roamerActive,suppressedEncounterState.outbreakSpecies,emu:read32(game.seed))
    emu:write8(roamerAddress,0)
    emu:write16(outbreakAddress,0)
end
local function armWildBreakpoint()
    if not game.createMon or not emu.setBreakpoint then return false end
    clearWildBreakpoint()
    wildBreakpointId=emu:setBreakpoint(function()
        local generationStage=navStage=="generic_lock" or (automationHuntType==1 and navStage=="lock")
        if mode=="running" and generationStage and (automationHuntType==1 or automationHuntType==2 or automationHuntType==3) and not wildSeedLocked then
            -- CreateMon receives hasFixedPersonality and fixedPersonality as its
            -- fifth and sixth arguments on the ARM stack. Intercept only the
            -- enemy-party construction and make the searched shiny PID explicit.
            -- This stays exact through roamers, outbreaks, Safari Pokeblocks,
            -- and unrelated background RNG calls.
            local destination=emu:readRegister("r0")&0xFFFFFFFC
            local expected=(automationHuntType==3 or automationHuntType==2) and game.enemy
                or (automationHuntType==1 and game.starterCreateDest)
                or (game.party+initialPartyCount*0x64)
            if destination==(expected&0xFFFFFFFC) then
                local sp=emu:readRegister("sp")
                local forcedSpecies
                if automationHuntType==3 and STARTER_HUNTER_STRICT_WILD_SPECIES and automationTarget.species then
                    forcedSpecies=nationalToInternalSpecies(automationTarget.species)
                    emu:writeRegister("r1",forcedSpecies)
                end
                emu:write32(sp,1)
                emu:write32(sp+4,automationTarget.pid)
                wildSeedLocked=true
                wildLockDiagnostics=string.format("CreateMon %08X -> PID %08X%s",destination,automationTarget.pid,
                    forcedSpecies and string.format(" species %d",forcedSpecies) or "")
            else
                wildLockDiagnostics=string.format("Ignored CreateMon %08X; expected %08X",destination,expected&0xFFFFFFFC)
            end
        end
    end,game.createMon)
    return wildBreakpointId and wildBreakpointId>=0
end
local function stopWithError(message)
    clearWildBreakpoint()
    restoreEncounterState()
    mode,navStage,automationKeyMask="error","idle",0; eonBridge.resolveJob=nil; emu:clearKeys(0x3FF); status=message; render(true)
end
local function cancelHunt(message)
    clearWildBreakpoint()
    restoreEncounterState()
    eonBridge.catch:cancel()
    mode,navStage,countdownFrames,stageFrames,searchJob,automationKeyMask="idle","idle",0,0,nil,0; eonBridge.resolveJob=nil; emu:clearKeys(0x3FF)
    eonBridge.autoStartHunt=false
    if (huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER) or (huntType==3 and STARTER_HUNTER_AUTOMATIC_WILD) then
        target=nil; clearShinyTargets(); eonBridge.targetPokemonConfirmed=false
    end
    status=message or (((huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER) or (huntType==3 and STARTER_HUNTER_AUTOMATIC_WILD))
        and "Stopped. Change the Pokemon if needed, then press F."
        or "Stopped. Change anything you need, then press H.")
    readProfile()
    if not ((huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER) or (huntType==3 and STARTER_HUNTER_AUTOMATIC_WILD)) then evaluateTarget() end
    render(true)
end

local function beginHunt()
    if BATTLE_AUTOMATION_ACTIVE then status="Stop Battle before starting an RNG hunt."; render(true); return false end
    if not readProfile() then status="Waiting for TID/SID from live game state."; render(true); return false end
    if usesAutomaticSweetScent() then
        local ready,problem=eonBridge.wildPreflight()
        if not ready then status=problem; render(true); return false end
        automationSweetPartySlot,automationSweetMenuIndex=findSweetScentUser()
        if automationSweetPartySlot==nil then status="No party Pokemon knows Sweet Scent."; render(true); return false end
        -- Some mGBA builds return nil even after successfully writing the
        -- state. Verify the file itself before reporting a failure.
        local checkpointSaved=emu:saveStateFile(checkpointPath())
        if not checkpointSaved and not checkpointReady() then status="Could not save the automatic starting point."; render(true); return false end
    else
        automationSweetPartySlot,automationSweetMenuIndex=nil,nil
        if not (game.emerald and huntType==1) and not checkpointReady()
            and not (huntType==1 and STARTER_HUNTER_AUTOMATIC_STARTER and eonBridge.automaticStarterCheckpoint) then
            status="Get to the final A press and press K once first."; render(true); return false
        end
    end
    if game.emerald and huntType==1 and emu:read8(game.partyCount)~=0 then status="Use the save from before receiving your starter."; render(true); return false end
    if not (huntType==3 and target and target.liveSeed) then evaluateTarget() end
    if not target or target.shinyValue>=8 or (huntType==3 and not target.speciesMatch) then status="Press F to choose a matching shiny frame first."; render(true); return false end
    automationTarget,automationHuntType,automationPokemon,automationTid,automationSid=target,huntType,selectedPokemon(),tid,sid
    seedCandidates={target.lockSeed}; seedAttempt=1
    wrongResults={}; wildSeedLocked,wildTaskSeen=false,false; wildLockDiagnostics=nil
    if (huntType==1 or huntType==2 or (huntType==3 and usesAutomaticSweetScent())) and not armWildBreakpoint() then
        status="mGBA could not arm the exact Pokemon-generation hook."; render(true); return false
    end
    initialPartyCount=emu:read8(game.partyCount); initialEnemyPid=emu:read32(game.enemy)
    mode,navStage,stageFrames="pre","waiting_reset",0
    countdownFrames=math.max(0,math.floor(preTimerSeconds*FPS+0.5))
    status="Timer started for shiny "..automationPokemon.."."; render(true); return true
end

local function saveSuccess(label)
    clearWildBreakpoint()
    restoreEncounterState()
    lastFrameResult={targetFrame=automationTarget.frame,landedFrame=automationTarget.frame,miss=0,
        correction=hitCorrectionFrames,pid=automationTarget.pid}
    eonBridge.frameHitEnemyPid=automationTarget.pid
    eonBridge.frameHitStatus=string.format("Landed on frame %d (+0 from target).",automationTarget.frame)
    if eonBridge.targetFrame==automationTarget.frame and eonBridge.huntType==automationHuntType then
        eonBridge.writeResult(eonBridge.requestToken,automationTarget.frame,automationTarget.frame,automationTarget,automationHuntType)
        eonBridge.targetFrame=nil
    end
    local path=string.format("%s/Shiny %s %s frame %d.ss1",PROJECT_DIR,label,game.name,automationTarget.frame)
    local saved=emu:saveStateFile(path)
    if automationHuntType==3 and STARTER_HUNTER_AUTO_CATCH then
        local armed,detail=eonBridge.catch:begin(automationTarget.pid)
        if armed then
            mode,navStage,stageFrames="catching","catch",0
            status=(saved and "Verified-shiny safety state saved. " or "Shiny verified. ")..detail
        else
            mode,navStage="error","done"
            status=(saved and "Shiny verified and safety state saved, but " or "Shiny verified, but ")..detail
        end
    else
        mode,navStage="success","done"
        status=saved and ("Success: shiny "..label.." verified. Save state created.") or ("Success: shiny "..label.." verified.")
    end
    automationKeyMask=0; emu:clearKeys(0x3FF)
    render(true)
end
local function verifyGeneric()
    if automationHuntType==1 then
        local count=emu:read8(game.partyCount)
        if count>initialPartyCount then
            local pokemon=readPokemon(game.party+(count-1)*0x64)
            if not pokemon.valid then return false,nil end
            if pokemon.pid==automationTarget.pid and shinyValue(automationTid,automationSid,pokemon.pid)<8 then saveSuccess(automationPokemon); return true end
            return false,"wrong",pokemon
        end
    elseif automationHuntType==2 then
        local matched,roamer=eonBridge.roamer:matches(roamerIndex,automationTarget.pid,automationTid,automationSid)
        if roamer and roamer.active then
            if matched then saveSuccess(automationPokemon); return true end
            return false,"wrong",roamer
        end
    else
        local pokemon=readPokemon(game.enemy)
        if pokemon.pid~=0 and pokemon.pid~=initialEnemyPid then
            if not pokemon.valid then return false,nil end
            local speciesOk=not STARTER_HUNTER_STRICT_WILD_SPECIES or pokemon.species==nationalToInternalSpecies(automationTarget.species)
            if pokemon.pid==automationTarget.pid and shinyValue(automationTid,automationSid,pokemon.pid)<8 then
                if not speciesOk then return false,"wrong_species",pokemon end
                saveSuccess(automationPokemon); return true
            end
            return false,"wrong",pokemon
        end
    end
    return false,nil
end
function eonBridge.sameIvs(left,right)
    if type(left)~="table" or type(right)~="table" then return true end
    for index=1,6 do if left[index]~=right[index] then return false end end
    return true
end

function eonBridge.candidateMatches(candidate,actual,targetHuntType)
    if not candidate or not actual then return false,"missing" end
    if candidate.pid~=actual.pid then return false,"pid" end
    if STARTER_HUNTER_DIAGNOSTIC and targetHuntType==3 then
        -- Retail-style wild calibration identifies the whole spread, not just
        -- PID: route slot/species, level and all six IVs disambiguate repeated
        -- PID/nature results and distinguish H-1/H-2/H-4.
        if actual.species and actual.species~=0
            and nationalToInternalSpecies(candidate.species)~=actual.species then
            return false,string.format("species %s->%s/%s",tostring(candidate.species),tostring(nationalToInternalSpecies(candidate.species)),tostring(actual.species))
        end
        if actual.level and candidate.level and actual.level~=candidate.level then return false,"level" end
        if actual.ivs and candidate.ivs then
            for index=1,6 do if actual.ivs[index]~=candidate.ivs[index] then return false,"iv"..index end end
        end
    end
    -- Static/roamer diagnostics only have PID evidence. Wild diagnostics take
    -- the stricter path above so the slot and IV-call method are unambiguous.
    return true
end

local function locateActualFrame(actual,center,targetHuntType)
    local landedFrame,bestDistance=nil,nil
    targetHuntType=targetHuntType or automationHuntType
    center=center or (automationTarget and automationTarget.frame)
    if actual and actual.pid and actual.pid~=0 and center and targetHuntType then
        -- Identify the generated Pokemon in the same PokeFinder method used by
        -- the selected target. Walking the state once per frame is much faster
        -- than recalculating every candidate from seed 0.
        local first=math.max(0,center-12000)
        local last=math.min(MAX_SEARCH_FRAME,center+12000)
        local state=advanceSeed(baseSeed,first)
        for frame=first,last do
            local candidate=eonBridge.makeTargetFor(targetHuntType,frame,state)
            if eonBridge.candidateMatches(candidate,actual,targetHuntType) then
                local distance=math.abs(frame-center)
                if not bestDistance or distance<bestDistance then landedFrame,bestDistance=frame,distance end
                if distance==0 then break end
            end
            state=lcgNext(state)
        end
    end
    return landedFrame
end


function eonBridge.startResolve(actual,center,targetHuntType,onComplete)
    if eonBridge.resolveJob or not actual or not actual.pid or actual.pid==0 then return false end
    local first=math.max(0,center-12000)
    eonBridge.resolveJob={actual=actual,center=center,huntType=targetHuntType,frame=first,
        last=math.min(MAX_SEARCH_FRAME,center+12000),state=advanceSeed(baseSeed,first),complete=onComplete,
        best=nil,bestDistance=nil,first=first,
        encounterContext=targetHuntType==3 and {area=selectedArea(),wanted=selectedWildSpecies()} or nil}
    return true
end

function eonBridge.seedDistance(startState,endState)
    return rngMath.distance(startState,endState)
end

function eonBridge.directPidFrame(pid)
    local low,high=pid&0xFFFF,(pid>>16)&0xFFFF
    local best,bestScore=nil,nil
    for tail=0,0xFFFF do
        local first=((low<<16)|tail)&0xFFFFFFFF
        if (lcgNext(first)>>16)==high then
            -- PokeFinder's static/PID frame is the state immediately before
            -- the first 16-bit PID roll.
            local frame=eonBridge.seedDistance(baseSeed,lcgPrevious(first))
            if frame and frame<=MAX_SEARCH_FRAME then
                local score=math.min(math.abs(frame-targetFrame),math.abs(frame-liveAdvances))
                if not bestScore or score<bestScore then best,bestScore=frame,score end
            end
        end
    end
    return best
end

function eonBridge.beginPidRecovery(actual,bridgeToken,bridgeTarget,bridgeHuntType,expectedTargetFrame,readOnly)
    if eonBridge.pidRecoveryJob or not actual or not actual.pid or actual.pid==0 then return false end
    eonBridge.pidRecoveryJob={actual=actual,tail=0,low=actual.pid&0xFFFF,high=(actual.pid>>16)&0xFFFF,
        best=nil,bestScore=nil,targetValue=math.max(0,math.floor(tonumber(expectedTargetFrame) or targetFrame)),
        bridgeToken=bridgeToken,bridgeTarget=bridgeTarget,bridgeHuntType=bridgeHuntType,readOnly=readOnly==true}
    eonBridge.frameHitStatus=string.format("Reading PID %08X and recovering its frame...",actual.pid)
    return true
end

function eonBridge.processPidRecovery()
    local job=eonBridge.pidRecoveryJob
    if not job then return end
    -- PID recovery is a one-off 16-bit search.  Finishing 4096 cheap candidates
    -- per emulated frame is both quicker and smoother than yielding after only
    -- a few dozen candidates, which made the UI appear stuck on "resolving".
    for work=1,4096 do
        local first=((job.low<<16)|job.tail)&0xFFFFFFFF
        if (lcgNext(first)>>16)==job.high then
            local frame=eonBridge.seedDistance(baseSeed,lcgPrevious(first))
            if frame and frame<=MAX_SEARCH_FRAME then
                local score=math.min(math.abs(frame-job.targetValue),math.abs(frame-liveAdvances))
                if not job.bestScore or score<job.bestScore then job.best,job.bestScore=frame,score end
            end
        end
        job.tail=job.tail+1
        if job.tail>0xFFFF then
            local actual,landed,targetValue=job.actual,job.best,job.targetValue
            eonBridge.pidRecoveryJob=nil
            if landed then
                local miss=landed-targetValue
                local adjusted=false
                -- A normal timing miss is safe to calibrate. A huge gap means
                -- the user still has an unrelated/stale target selected; do
                -- not poison future attempts with that value.
                local correctionLimit=STARTER_HUNTER_DIAGNOSTIC and 1000 or 10000
                if not job.readOnly and math.abs(miss)<=correctionLimit then
                    hitCorrectionFrames=math.max(-10000,math.min(10000,hitCorrectionFrames-miss))
                    adjusted=true
                    saveSettings()
                end
                lastFrameResult={targetFrame=targetValue,landedFrame=landed,miss=miss,
                    correction=hitCorrectionFrames,pid=actual.pid,adjusted=adjusted}
                if adjusted then
                    eonBridge.frameHitStatus=string.format("Landed on frame %d (%+d). Next attempt adjusted to %d.",
                        landed,miss,targetValue+hitCorrectionFrames)
                else
                    eonBridge.frameHitStatus=string.format("Landed on frame %d. Enter the correct shiny target with G.",landed)
                end
                if job.bridgeToken and job.bridgeTarget then
                    eonBridge.writeResult(job.bridgeToken,job.bridgeTarget,landed,actual,job.bridgeHuntType or 3)
                    status=string.format("EonTimer: PID %08X resolved directly to frame %d.",actual.pid,landed)
                end
            else
                lastFrameResult={targetFrame=targetValue,landedFrame=nil,miss=nil,
                    correction=hitCorrectionFrames,pid=actual.pid,
                    error=string.format("PID %08X was not found from seed %08X.",actual.pid,baseSeed)}
                eonBridge.frameHitStatus=string.format("PID %08X could not be resolved from seed %08X.",actual.pid,baseSeed)
            end
            return
        end
    end
end

function eonBridge.processResolve()
    local job=eonBridge.resolveJob
    if not job then return end
    local staticMethod=job.huntType==1 or job.huntType==2
    -- Diagnostic scans cover a wide window, but must never monopolize an
    -- emulated frame. Work through it incrementally instead of doing all
    -- 24,001 candidates (previously twice) in a single callback.
    local workLimit=STARTER_HUNTER_DIAGNOSTIC and 360 or (staticMethod and 2048 or 300)
    local sliceStarted=os.clock()
    for work=1,workLimit do
        local matched=false
        if staticMethod then
            -- Starters/statics use Method 1.  Compare only the two PID calls;
            -- allocating a complete target (IV table, nature, etc.) for every
            -- nearby frame made this simple lookup needlessly slow.
            local lowState=lcgNext(job.state)
            local highState=lcgNext(lowState)
            local pid=(((highState>>16)<<16)|(lowState>>16))&0xFFFFFFFF
            matched=pid==job.actual.pid
        else
            local candidate=eonBridge.makeTargetFor(job.huntType,job.frame,job.state,job.method,job.encounterContext)
            matched=eonBridge.candidateMatches(candidate,job.actual,job.huntType)
        end
        if matched then
            local distance=math.abs(job.frame-job.center)
            if not job.bestDistance or distance<job.bestDistance then
                job.best,job.bestDistance,job.bestMethod=job.frame,distance,job.method
            end
            if distance==0 then
                local complete,actual,landed,method=job.complete,job.actual,job.frame,job.method
                eonBridge.resolveJob=nil
                complete(landed,actual,method)
                return
            end
        end
        job.frame=job.frame+1
        job.state=lcgNext(job.state)
        if job.frame>job.last then
            if job.methods and job.methodIndex<#job.methods then
                job.methodIndex=job.methodIndex+1
                job.method=job.methods[job.methodIndex]
                job.frame=job.first
                job.state=advanceSeed(baseSeed,job.first)
            else
                local complete,actual,landed,method=job.complete,job.actual,job.best,job.bestMethod
                eonBridge.resolveJob=nil
                complete(landed,actual,method)
                return
            end
        end
        -- Never spend more than about 1 ms resolving a PID in one emulated
        -- frame. This keeps gameplay and the Qt scripting panel responsive.
        if not staticMethod and work%12==0 and os.clock()-sliceStarted>=0.0008 then return end
    end
end

function eonBridge.applyLocatedFrame(actual,landedFrame)
    local actualPid=actual and actual.pid or 0
    if landedFrame then
        local miss=landedFrame-automationTarget.frame
        hitCorrectionFrames=math.max(-10000,math.min(10000,hitCorrectionFrames-miss))
        lastFrameResult={targetFrame=automationTarget.frame,landedFrame=landedFrame,miss=miss,
            correction=hitCorrectionFrames,pid=actualPid}
        if eonBridge.targetFrame==automationTarget.frame and eonBridge.huntType==automationHuntType then
            eonBridge.writeResult(eonBridge.requestToken,automationTarget.frame,landedFrame,actual,automationHuntType)
            eonBridge.targetFrame=nil
        end
        saveSettings()
        return true,string.format("PID %08X landed on frame %d (%+d). Auto correction is now %+d; shiny frame %d stays selected. Press H to retry.",
            actualPid,landedFrame,miss,hitCorrectionFrames,automationTarget.frame)
    end
    lastFrameResult={targetFrame=automationTarget and automationTarget.frame or 0,landedFrame=nil,miss=nil,
        correction=hitCorrectionFrames,pid=actualPid}
    return false,string.format("PID %08X did not match a nearby frame. No correction was applied; check the encounter method.",actualPid)
end

local function applyFrameMiss(actual)
    local landedFrame=locateActualFrame(actual)
    return eonBridge.applyLocatedFrame(actual,landedFrame)
end
local function stopOnWrongResult(actual)
    if actual then wrongResults[#wrongResults+1]={pid=actual.pid or 0,species=actual.species or 0,seed=automationTarget.state} end
    clearWildBreakpoint(); restoreEncounterState(); automationKeyMask=0; emu:clearKeys(0x3FF)
    mode,navStage="resolving","reading_pid"
    status=string.format("Reading PID %08X and locating its exact frame...",actual and actual.pid or 0)
    render(true)
    if not eonBridge.startResolve(actual,automationTarget.frame,automationHuntType,function(landed,resolvedActual)
        local _,message=eonBridge.applyLocatedFrame(resolvedActual,landed)
        stopWithError(message)
    end) then stopWithError("The generated Pokemon could not be read from memory.") end
end

function eonBridge.beginPassiveResolve(actual)
    if eonBridge.resolveJob or eonBridge.pidRecoveryJob or not eonBridge.targetFrame then return end
    local token,targetValue,targetHuntType=eonBridge.requestToken,eonBridge.targetFrame,eonBridge.huntType
    eonBridge.targetFrame=nil -- one generated Pokemon is consumed per EonTimer run
    if targetHuntType==3 then
        -- Wild encounters can be observed while the target list or EonTimer
        -- target is stale. Resolve the PID itself instead of searching around
        -- that unrelated frame and leaving Frame Hit stuck on "waiting".
        if not eonBridge.beginPidRecovery(actual,token,targetValue,targetHuntType) then
            eonBridge.frameHitStatus="Could not start PID recovery."
        end
        return
    end
    eonBridge.startResolve(actual,targetValue,targetHuntType,function(landed,resolvedActual)
        if landed then
            local miss=landed-targetValue
            lastFrameResult={targetFrame=targetValue,landedFrame=landed,miss=miss,
                correction=-miss,pid=resolvedActual.pid}
            eonBridge.frameHitStatus=string.format("Landed on frame %d (%+d).",landed,miss)
            eonBridge.writeResult(token,targetValue,landed,resolvedActual,targetHuntType)
            status=string.format("EonTimer: PID %08X landed on frame %d (%+d).",resolvedActual.pid,landed,miss)
        else
            eonBridge.frameHitStatus=string.format("PID %08X was not found near frame %d.",resolvedActual.pid,targetValue)
            status=string.format("EonTimer: PID %08X was not found near frame %d. Check the selected RNG method.",
                resolvedActual.pid,targetValue)
        end
        render(true)
    end)
end

function eonBridge.beginFrameHitResolve(actual,center,isFallback)
    if eonBridge.resolveJob or eonBridge.pidRecoveryJob or not actual or not actual.valid or actual.pid==0 then return false end
    if STARTER_HUNTER_DIAGNOSTIC and huntType==1 then
        local expected=math.max(0,math.floor(tonumber(center) or targetFrame))
        eonBridge.frameHitStatus=string.format("Resolving the starter's Method 1 PID near %d...",expected)
        return eonBridge.startResolve(actual,expected,1,function(landed,resolved)
            if landed then
                local miss=landed-expected
                local adjusted=math.abs(miss)<=1000
                if adjusted then
                    hitCorrectionFrames=math.max(-10000,math.min(10000,hitCorrectionFrames-miss))
                    saveSettings()
                end
                lastFrameResult={targetFrame=expected,landedFrame=landed,miss=miss,
                    correction=hitCorrectionFrames,pid=resolved.pid,adjusted=adjusted,method=1}
                eonBridge.frameHitStatus=adjusted
                    and string.format("Starter landed %d (%+d). Corrected Frame: %d.",landed,miss,expected+hitCorrectionFrames)
                    or string.format("Starter matched frame %d, but it is >1000 away; correction was not changed.",landed)
            else
                lastFrameResult={targetFrame=expected,landedFrame=nil,miss=nil,correction=hitCorrectionFrames,
                    pid=resolved.pid,error=string.format("No Method 1 PID match within 12000 frames of %d.",expected)}
                eonBridge.frameHitStatus=lastFrameResult.error
            end
        end)
    end
    if STARTER_HUNTER_MANUAL_REQUIRE_INPUT and STARTER_HUNTER_DIAGNOSTIC and huntType==3 then
        local expected=math.max(0,math.floor(tonumber(center) or targetFrame))
        -- Resolve the complete observed spread across the same 24,001-frame
        -- window used by the diagnostic path.  The old synchronous shortcut
        -- searched only +/-1000 around the target and a narrow interval behind
        -- the live counter, so ordinary encounters could leave Hit Frame blank.
        eonBridge.frameHitStatus=string.format("Resolving Wild H-2, H-1 and H-4 near %d...",expected)
        local started=eonBridge.startResolve(actual,expected,3,function(landed,resolved,detectedMethod)
            if landed then
                local miss=landed-expected
                hitCorrectionFrames=math.max(-10000,math.min(10000,hitCorrectionFrames-miss))
                lastFrameResult={targetFrame=expected,landedFrame=landed,miss=miss,
                    correction=hitCorrectionFrames,pid=resolved.pid,adjusted=true,method=detectedMethod}
                eonBridge.frameHitStatus=string.format("Wild H-%d landed %d (%+d). Recalibrated: %d.",
                    detectedMethod or 0,landed,miss,expected+hitCorrectionFrames)
                saveSettings()
            else
                -- A PID identifies the two consecutive personality rolls. If
                -- a ROM-side modifier or a transient field read makes the full
                -- spread disagree, recover that unique frame without claiming
                -- a particular IV-call method instead of leaving Hit blank.
                local pidOnly={pid=resolved.pid,valid=true}
                local fallback=eonBridge.startResolve(pidOnly,expected,3,function(pidFrame,pidActual)
                    if pidFrame then
                        local miss=pidFrame-expected
                        hitCorrectionFrames=math.max(-10000,math.min(10000,hitCorrectionFrames-miss))
                        lastFrameResult={targetFrame=expected,landedFrame=pidFrame,miss=miss,
                            correction=hitCorrectionFrames,pid=pidActual.pid,adjusted=true,method=nil,evidence="pid"}
                        eonBridge.frameHitStatus=string.format(
                            "PID-only match landed %d (%+d). Recalibrated: %d; verify the selected lead/method.",
                            pidFrame,miss,expected+hitCorrectionFrames)
                        saveSettings()
                    else
                        lastFrameResult={targetFrame=expected,landedFrame=nil,miss=nil,correction=hitCorrectionFrames,
                            pid=pidActual.pid,error=string.format(
                                "No PID match within 12000 frames of %d. Verify the initial seed and encounter area.",expected)}
                        eonBridge.frameHitStatus=lastFrameResult.error
                    end
                end)
                if fallback then eonBridge.resolveJob.method=2 end
            end
        end)
        if started then
            eonBridge.resolveJob.methods={2,1,4}
            eonBridge.resolveJob.methodIndex=1
            eonBridge.resolveJob.method=2
        end
        return started
    end
    if STARTER_HUNTER_DIAGNOSTIC and huntType==3 then
        local expected=math.max(0,math.floor(tonumber(center) or targetFrame))
        eonBridge.frameHitStatus=string.format("Scanning PID/species/level/IVs on Wild H-2, H-1 and H-4 near %d...",expected)
        local started=eonBridge.startResolve(actual,expected,3,function(landed,resolved,detectedMethod)
            if landed then
                local miss=landed-expected
                -- Retail calibration begins in a +/-1000 window. A farther
                -- result usually indicates a stale target, wrong route/setup,
                -- or ambiguous data and must not poison later corrections.
                local adjusted=math.abs(miss)<=1000
                if adjusted then
                    hitCorrectionFrames=math.max(-10000,math.min(10000,hitCorrectionFrames-miss))
                    saveSettings()
                end
                lastFrameResult={targetFrame=expected,landedFrame=landed,miss=miss,
                    correction=hitCorrectionFrames,pid=resolved.pid,adjusted=adjusted,method=detectedMethod}
                eonBridge.frameHitStatus=adjusted
                    and string.format("Wild H-%d landed %d (%+d). Corrected Frame: %d.",detectedMethod or 0,landed,miss,expected+hitCorrectionFrames)
                    or string.format("Wild H-%d matched frame %d, but it is >1000 away; correction was not changed.",detectedMethod or 0,landed)
            else
                lastFrameResult={targetFrame=expected,landedFrame=nil,miss=nil,correction=hitCorrectionFrames,
                    pid=resolved.pid,error=string.format("No exact PID/species/level/IV match on Wild H-2, H-1 or H-4 within 12000 frames of %d.",expected)}
                eonBridge.frameHitStatus=lastFrameResult.error
            end
        end)
        if started then
            eonBridge.resolveJob.methods={2,1,4}
            eonBridge.resolveJob.methodIndex=1
            eonBridge.resolveJob.method=2
        end
        return started
    end
    return eonBridge.beginPidRecovery(actual)
end

function eonBridge.monitorPassiveResult()
    if STARTER_HUNTER_MANUAL_TEST then return end
    if STARTER_HUNTER_MANUAL_REQUIRE_INPUT and not eonBridge.manualTargetArmed then return end
    if eonBridge.resolveJob or eonBridge.pidRecoveryJob or mode=="searching" or mode=="pre" or mode=="running" or mode=="resolving" then return end
    if eonBridge.targetFrame and eonBridge.huntType==1 then
        local count=emu:read8(game.partyCount)
        if count>eonBridge.initialPartyCount then
            local actual=readPokemon(game.party+(count-1)*0x64)
            if actual.valid then eonBridge.beginPassiveResolve(actual) end
        end
    elseif eonBridge.targetFrame and eonBridge.huntType==2 then
        local actual=readRoamer()
        if actual and actual.active and actual.pid~=0 and actual.pid~=eonBridge.initialRoamerPid then
            actual.valid=true
            eonBridge.beginPassiveResolve(actual)
        end
    else
        local actual=readPokemon(game.enemy)
        if actual.valid and actual.pid~=0 then
            if eonBridge.targetFrame and actual.pid~=eonBridge.initialEnemyPid then
                eonBridge.frameHitEnemyPid=actual.pid
                eonBridge.beginPassiveResolve(actual)
            elseif not eonBridge.targetFrame and actual.pid~=eonBridge.frameHitEnemyPid and not eonBridge.resolveJob then
                eonBridge.frameHitEnemyPid=actual.pid
                eonBridge.beginFrameHitResolve(actual,targetFrame,false)
            end
        end
    end
end

local function prepareTargetCountdown()
    if STARTER_HUNTER_TEST_IMMEDIATE then countdownFrames=0; return end
    local current=game.advances and emu:read32(game.advances) or math.max(0,liveAdvances)
    local remaining=math.max(0,automationTarget.frame-current+calibrationFrames)
    local cap=math.floor(MAX_VISIBLE_COUNTDOWN_SECONDS*FPS+0.5)
    countdownFrames=math.min(remaining,cap)
    if remaining>cap then
        status=automationTarget.liveSeed
            and string.format("Live target locked %d advances ahead. Preparing the encounter.",remaining)
            or string.format("Closest frame is %dm%02ds away; automatic countdown capped at %ds.",
                math.floor((remaining/FPS)/60),math.floor((remaining/FPS)%60),MAX_VISIBLE_COUNTDOWN_SECONDS)
    else
        status=string.format("Checkpoint loaded. %s remaining to the selected frame.",timerValueText(remaining))
    end
end

local function runNavigation()
    if stageCounterStage~=navStage then stageCounterStage,stageKeyReads=navStage,0 end
    stageFrames=stageFrames+1
    -- Drive menus from video frames, not raw KEYINPUT reads. Some games poll
    -- the controller several times per rendered frame; using that count could
    -- skip single-number cues and advance a phase before its menu existed.
    local step=stageFrames
    if navStage=="generic_load" then
        if stageFrames==8 then
            if not readProfile() or tid~=automationTid or sid~=automationSid then stopWithError("This checkpoint belongs to a different save."); return end
            initialPartyCount=emu:read8(game.partyCount); initialEnemyPid=emu:read32(game.enemy)
            if automationHuntType==3 and (currentWildType()=="Grass" or currentWildType()=="Surf") then
                automationSweetPartySlot,automationSweetMenuIndex=findSweetScentUser()
                if automationSweetPartySlot==nil then stopWithError("The saved starting point has no Pokemon with Sweet Scent."); return end
                local alreadyOnEncounterTile
                automationMoveSteps=0
                automationMoveKey,alreadyOnEncounterTile=findNearbyEncounterStep()
                if alreadyOnEncounterTile then
                    navStage,stageFrames="wild_open_start",0
                    status="Starting point loaded. Opening the party menu."
                elseif not game.emerald then
                    -- R/S/FRLG do not expose Emerald's live map-layout
                    -- pointers. Do not step speculatively here: taking that
                    -- step can itself roll a normal encounter before Sweet
                    -- Scent is armed. The preflight has already confirmed an
                    -- encounter table for this map, so use the current tile.
                    navStage,stageFrames="wild_open_start",0
                    status="Opening the party menu."
                elseif automationMoveKey then
                    navStage,stageFrames="wild_move_to_tile",0
                    status="Moving onto the nearest encounter tile."
                else
                    stopWithError("Stand on or directly next to grass, cave floor, sand, or encounter water.")
                end
            elseif automationHuntType==1 then
                navStage,stageFrames="starter_position",0
                status="Positioning the selected starter."
            else navStage,stageFrames="generic_ready",0; prepareTargetCountdown() end
        end
        return
    end
    if navStage=="starter_position" then
        if game.dataCode=="AXVE" or game.dataCode=="AXPE" then
            -- R/S profile saves face Birch's bag. Open it, then move the
            -- three-ball cursor (Treecko left, Torchic centre, Mudkip right).
            if stageFrames==15 then pressKey(KEY_A)
            elseif stageFrames==75 and starterIndex==1 then pressKey(KEY_LEFT)
            elseif stageFrames==75 and starterIndex==3 then pressKey(KEY_RIGHT)
            elseif step>=105 then navStage,stageFrames="generic_ready",0; prepareTargetCountdown() end
        else
            -- FR/LG fixture starts below the middle ball. The physical order
            -- is Bulbasaur, Squirtle, Charmander while the API order is
            -- Bulbasaur, Charmander, Squirtle.
            if step==10 and starterIndex==1 then pressKey(KEY_LEFT)
            elseif step==10 and starterIndex==2 then pressKey(KEY_RIGHT)
            elseif step==24 then pressKey(KEY_UP)
            elseif step>=36 then navStage,stageFrames="generic_ready",0; prepareTargetCountdown() end
        end
        return
    end
    if navStage=="wild_move_to_tile" then
        if step<=4 then pressKey(automationMoveKey)
        elseif step>=5 then
            local nextKey,onEncounterTile=findNearbyEncounterStep()
            if onEncounterTile then
                navStage,stageFrames="wild_open_start",0
                status="Encounter tile reached. Opening the party menu."
            elseif nextKey and automationMoveSteps<32 then
                automationMoveKey,automationMoveSteps,stageFrames,stageKeyReads=nextKey,automationMoveSteps+1,0,0
            else
                stopWithError("Could not reach nearby encounter grass automatically.")
            end
        end
        return
    end
    if navStage=="wild_open_start" then
        -- The Start menu remembers its previous cursor. Reset it before the
        -- menu is built so selecting Pokemon is deterministic.
        if stageFrames<24 and game.startMenuCursor then emu:write8(game.startMenuCursor,0) end
        if step==15 then pressKey(KEY_START) end
        if step>=35 then navStage,stageFrames="wild_choose_party",0; status="Opening Pokemon." end
        return
    end
    if navStage=="wild_choose_party" then
        -- FR/LG omits Pokedex when it is unavailable, so Pokemon can be item 0
        -- or 1. Read the live start-menu order instead of guessing.
        if step>=12 and step<=22 and game.startMenuOrder then
            -- FR/LG starts on Pokemon when Pokedex is absent, otherwise on
            -- Pokedex. Move down only for the latter menu shape.
            if emu:read8(game.startMenuOrder)==0 and step<=16 then
                pressKey(KEY_DOWN)
            end
        elseif step>=12 and step<=18 and game.startMenuCursor then
            -- R/S and Emerald use the fixed Pokedex, Pokemon, Bag order.
            -- Writing Pokemon directly avoids a lost one-frame Down pulse.
            emu:write8(game.startMenuCursor,1)
        elseif step==30 then pressKey(KEY_A)
        elseif step>=100 then navStage,stageFrames="wild_choose_user",0; status="Selecting the Pokemon with Sweet Scent." end
        return
    end
    if navStage=="wild_choose_user" then
        -- A fresh field party screen always starts on slot 0. Move directly to
        -- the detected Sweet Scent user; repeated Up presses wrap to CANCEL.
        local firstMovePoll=30
        local lastMovePoll=firstMovePoll+automationSweetPartySlot*4-4
        local choosePoll=firstMovePoll+automationSweetPartySlot*4
        if automationSweetPartySlot>0 and step>=firstMovePoll and step<=lastMovePoll and (step-firstMovePoll)%4==0 then pressKey(KEY_DOWN)
        elseif step==choosePoll then pressKey(KEY_A)
        elseif step>=choosePoll+60 then navStage,stageFrames="wild_highlight_sweet_scent",0; status="Highlighting Sweet Scent." end
        return
    end
    if navStage=="wild_highlight_sweet_scent" then
        -- Every Gen 3 field party menu starts on SUMMARY, then lists field
        -- moves in move-slot order. Sweet Scent is therefore at index 1 plus
        -- the number of earlier field moves. Drive that deterministic layout
        -- in every game instead of depending on revision-sensitive temporary
        -- action-menu pointers in R/S/FR/LG.
        local targetAction=1+automationSweetMenuIndex
        local firstMovePoll=15
        local lastMovePoll=firstMovePoll+(targetAction-1)*4
        if step>=firstMovePoll and step<=lastMovePoll and (step-firstMovePoll)%4==0 then pressKey(KEY_DOWN)
        elseif step>=lastMovePoll+15 then
            navStage,stageFrames="generic_ready",0; prepareTargetCountdown()
            status="Sweet Scent ready."
        end
        return
    end
    if navStage=="generic_ready" then
        if countdownFrames<=0 then navStage,stageFrames="generic_lock",0; status="Timer hit. Using Sweet Scent once." end
        return
    end
    if navStage=="generic_lock" then
        local ok,result,actual=verifyGeneric(); if ok then return end
        if result=="wrong" then stopOnWrongResult(actual); return end
        if automationHuntType==3 and usesAutomaticSweetScent() and wildBreakpointId then
            -- Press the highlighted field move once. The CreateMon hook below
            -- fixes the searched shiny PID at the construction boundary.
            if step==1 or (not game.emerald and step<=180 and step%12==1) then pressKey(KEY_A) end
            if wildSeedLocked then
                clearWildBreakpoint()
                navStage,stageFrames="generic_verify",0
                status="Target RNG locked. Waiting for the encounter."
                return
            end
            local taskState=sweetScentTaskState()
            if game.emerald and taskState~=nil then
                wildTaskSeen=true
                if taskState==64 and not wildBreakpointId then
                    -- PokeFinder's standard wild methods do not include the
                    -- roaming-Pokemon or mass-outbreak prechecks. Disable both
                    -- for this one encounter tick, then restore the exact bytes
                    -- on the following frame. This prevents a nearby roamer or
                    -- active outbreak from stealing the selected target.
                    suppressSpecialWildEncounters()
                    -- One normal overworld RNG advance occurs between this
                    -- frame callback and the encounter generator. PokeFinder's
                    -- target state is the value after that advance.
                    emu:write32(game.seed,offsetSeed(automationTarget.lockSeed,hitCorrectionFrames))
                    wildSeedLocked=true
                    navStage,stageFrames="generic_verify",0
                    status="Target RNG locked. Waiting for the encounter."
                end
            end
            if game.emerald and stageFrames>360 and not wildTaskSeen then stopWithError("Sweet Scent did not start. The action menu was not on Sweet Scent.")
            elseif stageFrames>1200 then stopWithError("Sweet Scent started, but its encounter hook was not reached.") end
            return
        end
        emu:write32(game.seed,offsetSeed(seedCandidates[seedAttempt],hitCorrectionFrames))
        if automationHuntType==1 or automationHuntType==2 then
            -- Starter confirmation can include description and Yes/No boxes.
            -- Keep the exact pre-PID state pinned while advancing all of them.
            if step%6==1 then pressKey(KEY_A) end
        elseif step==1 then pressKey(KEY_A) end
        if stageFrames>1200 then stopWithError("The target action did not finish.") end
        return
    end
    if navStage=="generic_verify" then
        -- Keep the guard active through generation. saveSuccess,
        -- stopWithError, and cancelHunt restore it after verification.
        local ok,result,actual=verifyGeneric(); if ok then return end
        if result=="wrong_species" then
            stopWithError(string.format("Stopped safely: expected %s, but species #%d appeared. No Ball was thrown.",
                automationPokemon or "the selected Pokemon",actual and actual.species or 0))
            return
        end
        if result=="wrong" then stopOnWrongResult(actual); return end
        if stageFrames>1200 then stopWithError("The Sweet Scent encounter did not appear after the RNG was locked.") end
        return
    end

    -- Emerald's Birch bag path remains fully automatic and needs no checkpoint.
    if navStage=="boot" then
        if sameFunction(emu:read32(game.gMain+4),game.cb2Overworld) then
            if not readProfile() or tid~=automationTid or sid~=automationSid then stopWithError("The loaded save does not match the selected TID/SID."); return end
            if emu:read8(game.partyCount)~=0 then stopWithError("The loaded save already has a party Pokemon."); return end
            navStage,stageFrames="overworld",0; status="Save loaded. Opening Birch's bag."
        elseif stageFrames%10==0 then pressKey(KEY_A) elseif stageFrames%10==5 then pressKey(KEY_START) end
        return
    end
    if navStage=="overworld" then if stageFrames>=30 then pressKey(KEY_A); navStage,stageFrames="wait_bag",0 end; return end
    if navStage=="wait_bag" then
        if starterTaskActive() then navStage,stageFrames="select",0; status="Bag opened. Selecting "..game.starters[starterIndex].."."
        elseif stageFrames>360 then stopWithError("Birch's bag was not found. Save directly in front of it.")
        elseif stageFrames%3==0 then pressKey(KEY_A) end
        return
    end
    if navStage=="select" then
        if stageFrames==1 then if starterIndex==1 then pressKey(KEY_LEFT) elseif starterIndex==3 then pressKey(KEY_RIGHT) end
        elseif stageFrames>=4 then navStage,stageFrames="ready",0; status="Starter selected. Waiting for the target timer." end
        return
    end
    if navStage=="ready" then if countdownFrames<=0 then navStage,stageFrames="lock",0; status="Timer hit. Making the target now." end; return end
    if navStage=="lock" then
        if emu:read8(game.partyCount)==0 then emu:write32(game.seed,offsetSeed(automationTarget.lockSeed,hitCorrectionFrames)); if stageFrames%6==1 then pressKey(KEY_A) end
        else
            local pokemon=readPokemon(game.party)
            if pokemon.pid==automationTarget.pid and shinyValue(automationTid,automationSid,pokemon.pid)<8 then saveSuccess(automationPokemon)
            else stopOnWrongResult(pokemon) end
        end
    end
end

local function commitEdit()
    local value
    if editMode=="seed" then value=tonumber(editText,16); if value then baseSeed=value&0xFFFFFFFF; target=nil; clearShinyTargets(); status="Seed saved. Press F to search." end
    elseif editMode=="frame" then value=tonumber(editText); if value and value>=0 and value<=MAX_SEARCH_FRAME then
        local previousFrame=eonBridge.manualTargetArmed and targetFrame or nil
        targetFrame=math.floor(value); clearShinyTargets(); evaluateTarget(); eonBridge.manualTargetArmed=true
        if STARTER_HUNTER_DIAGNOSTIC then
            -- Keep calibration when G is used to review/re-enter the same shiny
            -- target. A genuinely different target gets a clean calibration;
            -- its PID and timing reference are different.
            if previousFrame~=targetFrame then hitCorrectionFrames,lastFrameResult=0,nil end
            eonBridge.resolveJob,eonBridge.pidRecoveryJob=nil,nil
            local current=readPokemon(game.enemy)
            eonBridge.frameHitEnemyPid=current and current.valid and current.pid or 0
            eonBridge.frameHitStatus=previousFrame==targetFrame
                and "Target kept. The existing correction is still active."
                or "Target changed. Start a new encounter; calibration will begin from this frame."
            status=previousFrame==targetFrame and "Target saved; correction kept." or "New target saved with fresh calibration."
        else status="Frame saved." end
    else value=nil end
    elseif editMode=="pre-timer" then value=tonumber(editText); if value and value>=0 and value<=60 then preTimerSeconds=value; status="Timer saved." else value=nil end
    elseif editMode=="calibration" then value=tonumber(editText); if value and value>=-10000 and value<=10000 then calibrationFrames=math.floor(value); status="Offset saved." else value=nil end end
    if editMode=="location" then
        value=editText~="" and editText or nil
        if value then
            local wanted=value:lower(); local match=nil
            for i,area in ipairs(areas) do if area.type==currentWildType() and area.name:lower()==wanted then match=i; break end end
            if not match then for i,area in ipairs(areas) do if area.type==currentWildType() and area.name:lower():find(wanted,1,true) then match=i; break end end end
            if match then wildAreaIndex,wildSpeciesIndex,target=match,1,nil; clearShinyTargets(); status="Location set to "..areas[match].name.."."
            else value=nil; status="No matching location for "..currentWildType().."." end
        end
    end
    if not value then status="That value is not valid; nothing changed." end
    editMode,editText=nil,""; saveSettings(); render(true)
end
local function beginEdit(name)
    if mode~="idle" and mode~="error" and mode~="success" then return end
    -- G is an actual edit operation: prefill the current target so Backspace
    -- and retyping can change only the digits the user wants.
    editMode=name
    editText=name=="frame" and eonBridge.manualTargetArmed and tostring(targetFrame) or ""
    render(true)
end
local function cycleArea(direction)
    if #areas==0 then return end
    direction=direction or 1
    local start=wildAreaIndex
    repeat wildAreaIndex=((wildAreaIndex-1+direction)%#areas)+1 until areaMatchesType(areas[wildAreaIndex]) or wildAreaIndex==start
    wildSpeciesIndex,target=1,nil; clearShinyTargets(); status="Area set to "..(selectedArea().name or "-").."."; saveSettings(); render(true)
end
local function cycleWildType()
    wildTypeIndex=(wildTypeIndex%#WILD_TYPES)+1
    wildAreaIndex,wildSpeciesIndex,target=1,1,nil
    clearShinyTargets(); normalizeArea()
    status="Encounter set to "..currentWildType().."."
    saveSettings(); render(true)
end
local function cycleWildMethod()
    wildMethod=(wildMethod%#WILD_METHODS)+1; target=nil; clearShinyTargets()
    status="Method set to H-"..WILD_METHODS[wildMethod].."."
    saveSettings(); render(true)
end
local function cycleWildSpecies(direction)
    local list=uniqueSpecies(selectedArea()); if #list==0 then return end
    if RNG_COMPACT_UI and eonBridge.targetPokemonConfirmed then
        status="Pokemon locked for this attempt. Press R before changing it."
        render(true); return false
    end
    local interrupted=mode=="searching"
    if interrupted then searchJob=nil; mode="idle" end
    wildSpeciesIndex=((wildSpeciesIndex-1+direction)%#list)+1; target=nil; clearShinyTargets(); eonBridge.targetPokemonConfirmed=false
    status="Pokemon set to "..selectedPokemon().."."..(interrupted and " Search stopped; press F for new frames." or "")
    saveSettings(); render(true); return true
end
function eonBridge.pickerCanCycle()
    return huntType==3 and (mode=="idle" or mode=="error" or mode=="success" or mode=="searching")
end
function eonBridge.requestShinySearch()
    -- Wild.lua supplies the preflight-aware handler after RNGCore loads. Keep
    -- every input route (F, Enter, command file, and Select+A) on that same
    -- path so a callback-order difference cannot swallow the confirmation.
    if RNG_COMPACT_UI and huntType==3 and not eonBridge.targetPokemonConfirmed
        and type(STARTER_HUNTER_WILD_FIND_HANDLER)=="function" then
        return STARTER_HUNTER_WILD_FIND_HANDLER()
    end
    return startShinySearch()
end
function eonBridge.runWildCommand(command)
    if huntType~=3 or not command then return false end
    command=tostring(command):lower()
    if command=="stop" then cancelHunt(); return true end
    if mode=="searching" and (command=="previouspokemon" or command=="nextpokemon") then
        return cycleWildSpecies(command=="previouspokemon" and -1 or 1)
    end
    if mode~="idle" and mode~="error" and mode~="success" then return false end
    if command=="previouspokemon" then return cycleWildSpecies(-1)
    elseif command=="nextpokemon" then return cycleWildSpecies(1)
    elseif command=="detectarea" then syncCurrentWildArea(true,true); saveSettings(); render(true); return true
    elseif command=="previousarea" then cycleArea(-1); return true
    elseif command=="nextarea" then cycleArea(1); return true
    elseif command=="encounter" then cycleWildType(); return true
    elseif command=="method" then cycleWildMethod(); return true
    elseif command=="find" then return eonBridge.requestShinySearch()
    elseif command=="start" then return beginHunt()
    elseif command=="details" then simpleUi=not simpleUi; status=simpleUi and "Simple view enabled." or "Details enabled."; saveSettings(); render(true); return true
    elseif command=="size" then uiSizeIndex=(uiSizeIndex%#UI_SIZES)+1; applyUiSize(); status="UI size set to "..UI_SIZES[uiSizeIndex][3].."."; saveSettings(); render(true); return true
    end
    local option=command:match("^option([1-5])$")
    if option then return chooseShinyTarget(tonumber(option)) end
    return false
end
function eonBridge.processWildCommandFile()
    local now=os.clock()
    if now<eonBridge.nextCommandPoll then return end
    eonBridge.nextCommandPoll=now+0.05
    local values=eonBridge.readValues(eonBridge.commandPath)
    local sequence=values and values.sequence
    local command=values and values.command
    if not sequence or not command or sequence==eonBridge.lastCommandSequence then return end
    eonBridge.lastCommandSequence=sequence
    eonBridge.runWildCommand(command)
end
local function onKey(event)
    if event.state~=1 then return end
    if ((event.modifiers or 0)&0xC)~=0 then return end
    local key=event.key
    if STARTER_HUNTER_CAPTURE_ONLY and not editMode and key~=71 and key~=103 then return end
    if GEN3_SUITE_ACTIVE_TOOL then
        if GEN3_SUITE_ACTIVE_TOOL~="Capture" and GEN3_SUITE_ACTIVE_TOOL~="RNG" then return end
        if GEN3_SUITE_ACTIVE_TOOL=="Capture" and not editMode and key~=KEY_ESCAPE and key~=71 and key~=103 then return end
    end
    if editMode then
        if key==KEY_ENTER or key==KEY_KP_ENTER then commitEdit(); return end
        if key==KEY_ESCAPE then editMode,editText=nil,""; status="Edit cancelled."; render(true); return end
        if key==KEY_BACKSPACE then editText=editText:sub(1,math.max(0,#editText-1)); render(true); return end
        if key>=32 and key<=126 then
            local c=string.char(key); local allowed=editMode=="seed" and c:match("[0-9a-fA-F]") or editMode=="pre-timer" and c:match("[0-9.]") or editMode=="calibration" and c:match("[0-9+-]") or editMode=="location" and c:match("[A-Za-z0-9 .'-]") or c:match("[0-9]")
            if allowed and #editText<(editMode=="location" and 40 or 12) then editText=editText..c; render(true) end
        end
        return
    end
    if key==KEY_ESCAPE then cancelHunt("Stopped. All automated input was released."); return end
    if eonBridge.pickerCanCycle() then
        if key==0x800020 or key==0x800023 or key==0x800024 then cycleWildSpecies(-1); return
        elseif key==0x800022 or key==0x800021 or key==0x800025 then cycleWildSpecies(1); return
        elseif (key==KEY_ENTER or key==KEY_KP_ENTER) and not eonBridge.targetPokemonConfirmed then eonBridge.requestShinySearch(); return end
    end
    if key<32 or key>126 then return end
    local c=string.char(key):lower()
    if c=="r" then cancelHunt(); return end
    -- Selection remains responsive while an incremental search is running.
    -- Changing species cancels that now-invalid job instead of swallowing the
    -- key or mixing results for two different Pokemon.
    if huntType==3 and mode=="searching" then
        if c=="z" or c=="[" or c=="," then cycleWildSpecies(-1); return
        elseif c=="x" or c=="]" or c=="." then cycleWildSpecies(1); return end
    end
    if mode~="idle" and mode~="error" and mode~="success" then return end
    if c=="d" then simpleUi=not simpleUi; status=simpleUi and "Simple view enabled." or "Details enabled."; saveSettings(); render(true); return
    elseif c=="u" then uiSizeIndex=(uiSizeIndex%#UI_SIZES)+1; applyUiSize(); status="UI size set to "..UI_SIZES[uiSizeIndex][3].."."; saveSettings(); render(true); return
    elseif c=="m" then
        huntType,target=huntType==1 and 3 or 1,nil
        clearShinyTargets()
        eonBridge.targetPokemonConfirmed=false
        if huntType==3 then
            if not syncCurrentWildArea(true,true) then status="Wild RNG selected. No encounter area was detected here."
            else status="Wild RNG selected." end
        else
            status="Starter RNG selected."
        end
    elseif c=="t" then huntType,target=1,nil; clearShinyTargets(); status="Starter RNG selected."
    elseif c=="o" then huntType,target=2,nil; clearShinyTargets(); status="Roamer RNG selected."
    elseif c=="v" then
        huntType,target=3,nil; clearShinyTargets()
        if not syncCurrentWildArea(true,true) then status="Wild RNG selected. No encounter area was detected here." end
    elseif c=="1" or c=="2" or c=="3" or c=="4" or c=="5" then
        local i=tonumber(c)
        if #shinyTargets>0 and i<=#shinyTargets then chooseShinyTarget(i); return
        elseif huntType==1 and i<=#game.starters then starterIndex=i; target=nil; clearShinyTargets(); status="Starter set to "..selectedPokemon().."."
        elseif huntType==2 and i<=#game.roamers then roamerIndex=i; target=nil; clearShinyTargets(); status="Roamer set to "..selectedPokemon().."."
        elseif huntType==3 and i<=#shinyTargets then chooseShinyTarget(i); return
        else status="That number is not available here." end
    elseif c=="s" then beginEdit("seed"); return
    elseif c=="g" then beginEdit("frame"); return
    elseif c=="p" then beginEdit("pre-timer"); return
    elseif c=="c" then beginEdit("calibration"); return
    elseif c=="f" then
        eonBridge.requestShinySearch(); return
    elseif c=="b" then chooseShinyTarget(shinyTargetIndex-1); return
    elseif c=="n" then chooseShinyTarget(shinyTargetIndex+1); return
    elseif c=="k" then saveCheckpoint(); return
    elseif c=="h" then
        if not STARTER_HUNTER_MANUAL_REQUIRE_INPUT then beginHunt() end
        return
    elseif huntType==3 and c=="a" then
        if not STARTER_HUNTER_MANUAL_REQUIRE_INPUT then syncCurrentWildArea(true,true); saveSettings(); render(true) end
        return
    elseif huntType==3 and c=="j" then cycleArea(-1); return
    elseif huntType==3 and c=="l" then cycleArea(1); return
    elseif huntType==3 and (c=="z" or c=="[" or c==",") then cycleWildSpecies(-1); return
    elseif huntType==3 and (c=="x" or c=="]" or c==".") then cycleWildSpecies(1); return
    elseif huntType==3 and c=="e" then cycleWildType(); return
    elseif huntType==3 and c=="y" then cycleWildMethod(); return
    else return end
    saveSettings(); render(true)
end

previousSeed=nil
local previousGameChord=0
local function processGameHotkeys()
    if GEN3_SUITE_ACTIVE_TOOL and GEN3_SUITE_ACTIVE_TOOL~="RNG" then return end
    if not emu.getKeys then return end
    local keys=emu:getKeys()&0x3FF
    local command=nil
    if keys==(MASK_SELECT|MASK_A) then command="find"
    elseif keys==(MASK_SELECT|MASK_LEFT) then command="previous"
    elseif keys==(MASK_SELECT|MASK_RIGHT) then command="next"
    elseif keys==(MASK_SELECT|MASK_UP) then command="encounter"
    elseif keys==(MASK_SELECT|MASK_L) then command="areaPrevious"
    elseif keys==(MASK_SELECT|MASK_R) then command="areaNext"
    elseif keys==(MASK_SELECT|MASK_B) then command="checkpoint"
    elseif keys==(MASK_SELECT|MASK_START) then command="start"
    elseif keys==(MASK_SELECT|MASK_DOWN) then command=(mode=="idle" or mode=="error" or mode=="success") and "method" or "stop" end
    if not command then previousGameChord=0; return end
    emu:clearKeys(0x3FF)
    if keys==previousGameChord then return end
    previousGameChord=keys
    if command=="stop" then cancelHunt(); return end
    if mode=="searching" and huntType==3 and (command=="previous" or command=="next") then
        cycleWildSpecies(command=="previous" and -1 or 1)
        return
    end
    if mode~="idle" and mode~="error" and mode~="success" then return end
    if command=="find" then eonBridge.requestShinySearch()
    elseif command=="previous" then if huntType==3 and #shinyTargets==0 then cycleWildSpecies(-1) else chooseShinyTarget(shinyTargetIndex-1) end
    elseif command=="next" then if huntType==3 and #shinyTargets==0 then cycleWildSpecies(1) else chooseShinyTarget(shinyTargetIndex+1) end
    elseif command=="encounter" and huntType==3 then cycleWildType()
    elseif command=="areaPrevious" and huntType==3 then cycleArea(-1)
    elseif command=="areaNext" and huntType==3 then cycleArea(1)
    elseif command=="method" and huntType==3 then cycleWildMethod()
    elseif command=="checkpoint" then saveCheckpoint()
    elseif command=="start" then beginHunt() end
end
local function updateSessionAdvances()
    local current=emu:read32(game.seed)
    if previousSeed and current~=previousSeed then
        local distance=eonBridge.seedDistance(previousSeed,current)
        if distance and distance<=1000000 then liveAdvances=liveAdvances+distance
        else
            local absolute=eonBridge.seedDistance(baseSeed,current)
            liveAdvances=absolute and absolute<=MAX_SEARCH_FRAME and absolute or 0
        end
    elseif not previousSeed then
        local absolute=eonBridge.seedDistance(baseSeed,current)
        liveAdvances=absolute and absolute<=MAX_SEARCH_FRAME and absolute or 0
    end
    previousSeed=current
end

local function onFrame()
    automationKeyMask=0
    if GEN3_SUITE_ACTIVE_TOOL and GEN3_SUITE_ACTIVE_TOOL~="Capture" and GEN3_SUITE_ACTIVE_TOOL~="RNG" then
        return
    end
    frameCounter=frameCounter+1
    -- Release the direct fallback pulse even on ROM/profile combinations that
    -- do not emit mGBA's keysRead callback. Without this, one requested Down
    -- could remain held long enough to skip several menu entries.
    if mode=="pre" or mode=="running" or mode=="catching" then emu:setKeys(0) end
    if not STARTER_HUNTER_CAPTURE_ONLY and frameCounter%6==1 then eonBridge.processWildCommandFile() end
    eonBridge.processPidRecovery()
    processGameHotkeys()
    if (STARTER_HUNTER_DIAGNOSTIC and frameCounter%6==0) or frameCounter%30==0 then updateSessionAdvances() end
    if eonBridge.resolveJob then eonBridge.processResolve() end
    -- PID detection does not need a 60 Hz checksum scan. Eight-frame polling is
    -- still quick enough to catch the new party/enemy slot and removes almost
    -- all bridge cost during ordinary gameplay.
    if (STARTER_HUNTER_DIAGNOSTIC and frameCounter%4==0) or frameCounter%8==0 then eonBridge.monitorPassiveResult() end
    if mode=="searching" then
        processShinySearch()
    elseif mode=="pre" then
        emu:clearKeys(0x3FF)
        if countdownFrames>0 then countdownFrames=countdownFrames-1
        else
            mode,stageFrames="running",0
            if game.emerald and automationHuntType==1 then countdownFrames=math.max(0,automationTarget.frame+calibrationFrames); navStage="boot"; status="Reset cue. Loading the save and running the target timer."; emu:reset()
            elseif automationHuntType==3 and (currentWildType()=="Grass" or currentWildType()=="Surf") then
                countdownFrames=0; navStage="generic_load"; status="Reset cue. Starting from the current overworld."
            else
                countdownFrames=0; navStage="generic_load"
                if STARTER_HUNTER_USE_LIVE_CHECKPOINT and automationHuntType==1 then
                    status="Starting from the current starter position."
                else
                    status="Reset cue. Loading the checkpoint."
                    if not emu:loadStateFile(checkpointPath()) then stopWithError("Could not load the checkpoint.") end
                end
            end
        end
    elseif mode=="running" then
        emu:clearKeys(0x3FF); if countdownFrames>0 then countdownFrames=countdownFrames-1 end; runNavigation()
    elseif mode=="catching" then
        emu:clearKeys(0x3FF)
        local catchState,catchStatus=eonBridge.catch:tick()
        status=catchStatus
        if catchState=="caught" then
            local path=string.format("%s/Caught shiny %s %s frame %d.ss1",PROJECT_DIR,automationPokemon,game.name,automationTarget.frame)
            emu:saveStateFile(path)
            mode,navStage,automationKeyMask="success","done",0
            status="Success: "..automationPokemon.." was verified, caught, and saved."
            render(true)
        elseif catchState=="failed" then
            mode,navStage,automationKeyMask="error","done",0
            render(true)
        end
    end
    if eonBridge.autoStartHunt and mode=="idle" then
        eonBridge.autoStartHunt=false
        beginHunt()
    end
    -- Throttle maintenance and panel drawing by real time, not emulated frames.
    -- At unbounded speed 60 emulated frames may pass hundreds of times per
    -- second, which previously flooded Qt and made Wild RNG stop responding.
    local now=frameCounter%15==0 and os.time() or lastPeriodicSecond
    if now~=lastPeriodicSecond then
        lastPeriodicSecond=now
        if not STARTER_HUNTER_CAPTURE_ONLY then eonBridge.pollRequest() end
        if mode~="pre" and mode~="running" then
            local profileReady=readProfile()
            if profileReady and STARTER_HUNTER_MANUAL_REQUIRE_INPUT and eonBridge.manualTargetArmed and not target then
                evaluateTarget()
            end
            if huntType==3 then syncCurrentWildArea(false,false) end
        end
        render(false)
    end
end

starterHunter={}
function starterHunter:setMode(value)
    local text=tostring(value):lower(); huntType=(text=="starter" or text=="1") and 1 or (text=="roamer" or text=="2") and 2 or (text=="wild" or text=="3") and 3 or huntType
    target=nil; clearShinyTargets(); eonBridge.targetPokemonConfirmed=false
    if STARTER_HUNTER_MANUAL_REQUIRE_INPUT then eonBridge.manualTargetArmed=false end
    local label=huntType==1 and "Starter" or huntType==2 and "Roamer" or "Wild"
    status=readProfile() and string.format("%s RNG selected. TID/SID %d / %d read automatically.",label,tid,sid)
        or (label.." RNG selected. Waiting for live TID/SID.")
    saveSettings(); render(true); return true
end
function starterHunter:setStarter(value) local i=tonumber(value); if not i or not game.starters[i] then return false end; starterIndex,huntType=i,1; target=nil; clearShinyTargets(); eonBridge.targetPokemonConfirmed=false; saveSettings(); render(true); return true end
function starterHunter:setRoamer(value) local i=tonumber(value); if not i or not game.roamers[i] then return false end; roamerIndex,huntType=i,2; target=nil; clearShinyTargets(); saveSettings(); render(true); return true end
function starterHunter:autoSelectRoamer()
    if game.frlgMapAttributes then
        local save1=save1Address(); if not save1 then return nil end
        local starter=emu:read16(save1+0x1000+0x31*2)
        roamerIndex=starter==0 and 2 or (starter==2 and 3 or 1)
        huntType,target=2,nil; clearShinyTargets(); saveSettings(); render(true)
    end
    return game.roamers[roamerIndex],roamerIndex
end
function starterHunter:setWildArea(name, encounterType)
    local wantedName,wantedType=tostring(name):lower(),tostring(encounterType or currentWildType()):lower()
    for typeIndex,typeName in ipairs(WILD_TYPES) do if typeName:lower()==wantedType then wildTypeIndex=typeIndex end end
    for i,area in ipairs(areas) do
        if area.name:lower()==wantedName and area.type:lower()==wantedType then
            wildAreaIndex,wildSpeciesIndex,huntType,target=i,1,3,nil; clearShinyTargets(); saveSettings(); render(true); return true
        end
    end
    return false
end
function starterHunter:setWildSpecies(value)
    local wanted=tostring(value):lower(); local list=uniqueSpecies(selectedArea())
    for i,id in ipairs(list) do
        if tostring(id)==wanted or (speciesNames[id] and speciesNames[id]:lower()==wanted) then
            wildSpeciesIndex,huntType,target=i,3,nil; clearShinyTargets(); eonBridge.targetPokemonConfirmed=false; saveSettings(); render(true); return true
        end
    end
    return false
end
function starterHunter:setWildMethod(value)
    local n=tonumber(tostring(value):match("[124]")); for i,method in ipairs(WILD_METHODS) do if method==n then wildMethod,target=i,nil; clearShinyTargets(); saveSettings(); render(true); return true end end
    return false
end
function starterHunter:detectWildArea(force)
    local ok,changed=syncCurrentWildArea(false,force~=false)
    -- A map refresh clears the cached candidate. Rebuild it immediately for a
    -- manually entered frame so Target PID and hit resolution use this route.
    if ok and eonBridge.manualTargetArmed and not target then evaluateTarget() end
    if ok then saveSettings(); render(true) end
    return ok,changed,selectedArea()
end
function starterHunter:setPreTimer(value)
    local n=tonumber(value); if not n or n<0 or n>60 then return false end
    preTimerSeconds=n; saveSettings(); render(true); return true
end
function starterHunter:setSeed(value) local n=type(value)=="number" and value or tonumber(tostring(value),16); if not n then return false end; baseSeed=n&0xFFFFFFFF; target=nil; clearShinyTargets(); saveSettings(); render(true); return true end
function starterHunter:setFrame(value) local n=tonumber(value); if not n or n<0 or n>MAX_SEARCH_FRAME then return false end; targetFrame=math.floor(n); clearShinyTargets(); evaluateTarget(); eonBridge.manualTargetArmed=true; saveSettings(); render(true); return true end
function starterHunter:jumpToFrame(value)
    local n=tonumber(value or targetFrame)
    if not n or n<0 or n>MAX_SEARCH_FRAME then return false,"Frame must be between 0 and "..MAX_SEARCH_FRAME.."." end
    if mode~="idle" and mode~="error" and mode~="success" then
        return false,"Stop the active automation before jumping frames."
    end

    n=math.floor(n)
    local jumpSeed=advanceSeed(baseSeed,n)
    emu:write32(game.seed,jumpSeed)
    if emu:read32(game.seed)~=jumpSeed then return false,"mGBA did not accept the RNG seed write." end

    local previousFrame=eonBridge.manualTargetArmed and targetFrame or nil
    targetFrame=n
    clearShinyTargets()
    evaluateTarget()
    eonBridge.manualTargetArmed=true
    if previousFrame~=targetFrame then hitCorrectionFrames=0 end
    lastFrameResult,eonBridge.resolveJob,eonBridge.pidRecoveryJob=nil,nil,nil

    -- A frame jump changes the live RNG state directly. Running thousands of
    -- intermediate video frames would block mGBA's scripting window and can
    -- miss the exact RNG advance when a game consumes more than one value in
    -- a video frame. The selected target already contains the state immediately
    -- before that frame's generated Pokemon, so writing it is exact and fast.
    previousSeed=jumpSeed
    liveAdvances=targetFrame
    local current=readPokemon(game.enemy)
    eonBridge.frameHitEnemyPid=current and current.valid and current.pid or 0
    eonBridge.frameHitStatus=string.format("Jumped to RNG frame %d (seed %08X).",targetFrame,jumpSeed)
    status=eonBridge.frameHitStatus
    saveSettings()
    render(true)
    return true,jumpSeed
end
function starterHunter:findNext(a,b) return findNextShiny(a,b) end
function starterHunter:findAsync() return startShinySearch() end
function starterHunter:findAsyncFrom(value) return startShinySearch(value) end
function starterHunter:selectFrameOption(value) return chooseShinyTarget(tonumber(value) or 1) end
function starterHunter:getFrameOptions() return shinyTargets end
function starterHunter:hasSweetScent() return findSweetScentUser()~=nil end
function starterHunter:preflightWild() return eonBridge.wildPreflight() end
function starterHunter:preflightRoamer() return eonBridge.roamer:preflight(roamerIndex) end
function starterHunter:setMessage(value) status=tostring(value); render(true); return true end
function starterHunter:checkpoint() return saveCheckpoint() end
function starterHunter:start() return beginHunt() end
function starterHunter:cancel() cancelHunt() end
function starterHunter:getProfile() if not readProfile() then return nil end; return {tid=tid,sid=sid,game=game.name} end
function starterHunter:getTarget() return target end
function starterHunter:getWildSpeciesOptions()
    if huntType~=3 then return {} end
    local result={}
    for _,id in ipairs(uniqueSpecies(selectedArea())) do result[#result+1]=speciesNames[id] or tostring(id) end
    return result
end
function starterHunter:getStarterOptions()
    local result={}
    for _,name in ipairs(game.starters or {}) do result[#result+1]=name end
    return result
end
function starterHunter:getEnvironmentDiagnostics()
    local x,y=playerTile()
    local behavior,collision,encounter
    if x then behavior,collision,encounter=mapTileInfo(x,y) end
    local step,alreadyOnEncounter=findNearbyEncounterStep()
    local profile=starterHunter:getProfile()
    return {
        game=game.name, gameCode=game.dataCode, profile=profile~=nil,
        overworld=not game.cb2Overworld or sameFunction(emu:read32(game.gMain+4),game.cb2Overworld),
        tid=profile and profile.tid or nil, sid=profile and profile.sid or nil,
        partyCount=emu:read8(game.partyCount), x=x, y=y,
        mapOk=behavior~=nil, behavior=behavior, collision=collision,
        encounter=encounter==true, nearbyEncounter=alreadyOnEncounter==true or step~=nil
    }
end
function starterHunter:testEnsureSweetScent()
    -- Used only by the hidden regression harness. It modifies a healthy party
    -- Pokemon in the loaded disposable test state, never a user's save file.
    local count=math.min(6,emu:read8(game.partyCount))
    if not STARTER_HUNTER_ENABLE_TEST_API or count<1 then return false,"party unavailable" end
    local chosen=nil
    for partySlot=0,count-1 do
        local candidate=game.party+partySlot*0x64
        if emu:read16(candidate+0x56)>0 then chosen=partySlot; break end
    end
    if chosen==nil then return false,"no healthy party Pokemon" end
    local address=game.party+chosen*0x64
    local pid,otid=emu:read32(address),emu:read32(address+4)
    if pid==0 and otid==0 then return false,"empty party slot" end
    local key=pid~otid
    local attacks=ATTACK_OFFSETS[(pid%24)+1]*12
    local movePair=emu:read32(address+0x20+attacks)~key
    movePair=(movePair&0xFFFF0000)|SWEET_SCENT_MOVE
    emu:write32(address+0x20+attacks,movePair~key)
    local ppWord=emu:read32(address+0x28+attacks)~key
    ppWord=(ppWord&0xFFFFFF00)|15
    emu:write32(address+0x28+attacks,ppWord~key)
    local checksum=0
    for i=0,11 do
        local word=emu:read32(address+0x20+i*4)~key
        checksum=(checksum+(word&0xFFFF)+(word>>16))&0xFFFF
    end
    emu:write16(address+0x1C,checksum)
    local moves=readPokemonMoves(address) or {}
    local slot=findSweetScentUser()
    return slot==chosen,string.format("pid=%08X order=%d attacks=%d moves=%s/%s/%s/%s slot=%s expected=%d",
        pid,pid%24,attacks,tostring(moves[1]),tostring(moves[2]),tostring(moves[3]),tostring(moves[4]),tostring(slot),chosen)
end
function starterHunter:getSeedState()
    local initial=baseSeed
    local current=emu:read32(game.seed)&0xFFFFFFFF
    if game.initialSeed then
        initial=game.initialSeedBits==16 and emu:read16(game.initialSeed) or emu:read32(game.initialSeed)
        initial=initial&0xFFFFFFFF
        if initial~=baseSeed then
            baseSeed=initial
            local absolute=eonBridge.seedDistance(baseSeed,current)
            liveAdvances=absolute and absolute<=MAX_SEARCH_FRAME and absolute or 0
            previousSeed=current
            target=nil
            clearShinyTargets()
        end
    end
    return {initialSeed=initial&0xFFFFFFFF,initialSeedBits=game.initialSeedBits or 32,
        currentSeed=current}
end
function starterHunter:getRuntimeState()
    local liveEnemy=readPokemon(game.enemy)
    local seeds=starterHunter:getSeedState()
    return {mode=mode,stage=navStage,status=status,huntType=huntType,wildType=currentWildType(),
        pokemon=selectedPokemon(),area=selectedArea() and selectedArea().name or nil,
        sweetPartySlot=automationSweetPartySlot,sweetMenuIndex=automationSweetMenuIndex,
        tid=tid,sid=sid,liveAdvances=liveAdvances,target=automationTarget or target,
        enemyPid=emu:read32(game.enemy),enemySpecies=liveEnemy and liveEnemy.species or 0,seedAttempt=seedAttempt,stageFrames=stageFrames,frameCounter=frameCounter,
        keyReadCount=keyReadCount,stageKeyReads=stageKeyReads,lastAppliedKeyMask=lastAppliedKeyMask,wrongResults=wrongResults,
        wildSeedLocked=wildSeedLocked,wildTaskSeen=wildTaskSeen,wildLockDiagnostics=wildLockDiagnostics,
        initialSeed=seeds.initialSeed,initialSeedBits=seeds.initialSeedBits,currentSeed=seeds.currentSeed,
        automaticWild=STARTER_HUNTER_AUTOMATIC_WILD==true,automaticStarter=STARTER_HUNTER_AUTOMATIC_STARTER==true,
        autoStartPending=eonBridge.autoStartHunt==true,
        targetOriginSeed=(automationTarget or target) and (automationTarget or target).originSeed or nil,
        catchState=eonBridge.catch.state,
        catchStatus=eonBridge.catch.status,catchAttempts=eonBridge.catch.attempts,
        searchFrame=searchJob and searchJob.frame or nil}
end
function starterHunter:testEnsurePokeBalls()
    return eonBridge.catch:testInjectBall(2,99)
end
function starterHunter:getLastFrameResult()
    if not lastFrameResult then return nil end
    return {targetFrame=lastFrameResult.targetFrame,landedFrame=lastFrameResult.landedFrame,
        miss=lastFrameResult.miss,correction=lastFrameResult.correction,pid=lastFrameResult.pid,
        adjusted=lastFrameResult.adjusted,method=lastFrameResult.method,error=lastFrameResult.error}
end
function starterHunter:getCatchInfoState()
    return {targetFrame=targetFrame,result=starterHunter:getLastFrameResult(),
        resolving=eonBridge.resolveJob~=nil or eonBridge.pidRecoveryJob~=nil}
end
function starterHunter:getStarterInfoState() return starterHunter:getCatchInfoState() end
function starterHunter:resolveCapturedPid(pid,expectedTargetFrame)
    pid=type(pid)=="number" and pid or tonumber(tostring(pid),16)
    if not pid or pid==0 then return false,"bad PID" end
    pid=pid&0xFFFFFFFF
    if lastFrameResult and lastFrameResult.pid==pid and lastFrameResult.landedFrame then return true,"already resolved" end
    if eonBridge.resolveJob or eonBridge.pidRecoveryJob then return false,"busy" end
    return eonBridge.beginPidRecovery({pid=pid,valid=true},nil,nil,nil,expectedTargetFrame,true)
end
function starterHunter:resolveStarterPid(pid,expectedTargetFrame,applyCalibration)
    pid=type(pid)=="number" and pid or tonumber(tostring(pid),16)
    if not pid or pid==0 then return false,"bad PID" end
    pid=pid&0xFFFFFFFF
    if lastFrameResult and lastFrameResult.pid==pid then return true,"already checked" end
    local targetValue=math.max(0,math.floor(tonumber(expectedTargetFrame) or targetFrame))
    local landed=nil
    local starterOffset=game.starterOffset or 0

    -- Resolve in this call instead of queuing work for later emulated frames.
    -- Users commonly pause immediately after choosing a starter; frame callbacks
    -- stop while paused, which previously left this job on "resolving" forever.
    local first=math.max(0,targetValue-12000)
    local last=math.min(MAX_SEARCH_FRAME,targetValue+12000)
    local state=advanceSeed(baseSeed,first+starterOffset)
    for frame=first,last do
        local lowState=lcgNext(state)
        local highState=lcgNext(lowState)
        local candidate=(((highState>>16)<<16)|(lowState>>16))&0xFFFFFFFF
        if candidate==pid then landed=frame; break end
        state=lcgNext(state)
    end

    -- If the selected target is stale, recover the Method 1 frame directly
    -- from the PID. This bounded 16-bit search also completes synchronously.
    if not landed then
        local low,high=pid&0xFFFF,(pid>>16)&0xFFFF
        local best,bestScore=nil,nil
        for tail=0,0xFFFF do
            local firstPidState=((low<<16)|tail)&0xFFFFFFFF
            if (lcgNext(firstPidState)>>16)==high then
                local frame=eonBridge.seedDistance(baseSeed,lcgPrevious(firstPidState))
                frame=frame and frame>=starterOffset and frame-starterOffset or nil
                if frame and frame<=MAX_SEARCH_FRAME then
                    local score=math.abs(frame-targetValue)
                    if not bestScore or score<bestScore then best,bestScore=frame,score end
                end
            end
        end
        landed=best
    end

    if landed then
        local miss=landed-targetValue
        local adjusted=applyCalibration~=false and math.abs(miss)<=1000
        if adjusted then
            hitCorrectionFrames=math.max(-10000,math.min(10000,hitCorrectionFrames-miss))
            saveSettings()
        end
        lastFrameResult={targetFrame=targetValue,landedFrame=landed,miss=miss,
            correction=hitCorrectionFrames,pid=pid,adjusted=adjusted,method=1}
        eonBridge.frameHitStatus=adjusted
            and string.format("Starter PID %08X landed on frame %d (%+d). Recalibrated: %d.",pid,landed,miss,targetValue+hitCorrectionFrames)
            or string.format("Starter PID %08X matched frame %d, but it is >1000 away; calibration unchanged.",pid,landed)
    else
        lastFrameResult={targetFrame=targetValue,landedFrame=nil,miss=nil,
            correction=hitCorrectionFrames,pid=pid,
            error=string.format("PID %08X was not found from seed %08X.",pid,baseSeed)}
        eonBridge.frameHitStatus=lastFrameResult.error
    end
    return true,landed and "resolved" or "not found"
end
function starterHunter:getFrameCorrection() return hitCorrectionFrames end
function starterHunter:getFrameHitState()
    -- FireRed and LeafGreen choose a new Timer1 seed during boot. Synchronise
    -- the resolver before reporting advances or resolving a received starter.
    starterHunter:getSeedState()
    -- Emerald exposes a direct counter, so refreshing it here is cheap. Other
    -- games use the incremental tracker maintained by the frame callback.
    if game.advances then liveAdvances=emu:read32(game.advances) end
    local result=starterHunter:getLastFrameResult()
    return {game=game.name,currentFrame=liveAdvances,targetFrame=targetFrame,status=eonBridge.frameHitStatus,
        result=result,pid=result and result.pid or eonBridge.frameHitEnemyPid,method=huntType==3 and WILD_METHODS[wildMethod] or 1,
        targetPid=target and target.pid or nil,targetShiny=target and target.shinyValue<8 or false,
        targetSpeciesMatch=target and target.speciesMatch~=false or false,targetPokemon=selectedPokemon(),
        targetArmed=eonBridge.manualTargetArmed,
        correction=hitCorrectionFrames,nextAttemptFrame=math.max(0,targetFrame+hitCorrectionFrames),
        resolving=eonBridge.resolveJob~=nil or eonBridge.pidRecoveryJob~=nil,
        editing=editMode=="frame",editText=editMode=="frame" and editText or nil}
end
function starterHunter:getManualTargetDetails()
    if not eonBridge.manualTargetArmed then return nil end
    if huntType~=3 then return target end
    if target and target.liveSeed then return target end
    local startState=advanceSeed(baseSeed,targetFrame)
    for _,method in ipairs({2,1,4}) do
        local candidate=eonBridge.makeTargetFor(3,targetFrame,startState,method)
        if candidate and candidate.shinyValue<8 and candidate.speciesMatch~=false then
            candidate.method=method
            return candidate
        end
    end
    return target
end
function starterHunter:primeFrameMonitor()
    local actual=readPokemon(game.enemy)
    eonBridge.frameHitEnemyPid=actual and actual.valid and actual.pid or 0
    return eonBridge.frameHitEnemyPid
end
function starterHunter:inspectCurrentEnemy()
    if STARTER_HUNTER_MANUAL_REQUIRE_INPUT and not eonBridge.manualTargetArmed then return false,"Press G and enter your target frame first." end
    local actual=readPokemon(game.enemy)
    if not actual or not actual.valid or actual.pid==0 then return false,"No active enemy Pokemon was found." end
    eonBridge.frameHitEnemyPid=actual.pid
    if lastFrameResult and lastFrameResult.pid==actual.pid then return true,"already inspected" end
    return eonBridge.beginFrameHitResolve(actual,targetFrame,false),"inspection started"
end
function starterHunter:getPartyPokemon(slot)
    local count=math.min(6,emu:read8(game.partyCount))
    slot=math.floor(tonumber(slot) or count)
    if slot<1 or slot>count then return nil end
    local actual=readPokemon(game.party+(slot-1)*0x64)
    if not actual or not actual.valid or actual.pid==0 then return nil end
    actual.slot=slot
    return actual
end
function starterHunter:getPartyCount() return math.min(6,emu:read8(game.partyCount)) end
function starterHunter:getEnemyPokemon()
    local actual=readPokemon(game.enemy)
    return actual and actual.valid and actual.pid~=0 and actual or nil
end
function starterHunter:getEnemyPid() return emu:read32(game.enemy) end
function starterHunter:resolveManualPokemon(actual,expectedTargetFrame)
    if STARTER_HUNTER_MANUAL_REQUIRE_INPUT and not eonBridge.manualTargetArmed then return false,"Press G and enter your target frame first." end
    if type(actual)~="table" or not actual.valid or not actual.pid or actual.pid==0 then return false,"invalid Pokemon" end
    local expected=math.max(0,math.floor(tonumber(expectedTargetFrame) or targetFrame))
    return eonBridge.beginFrameHitResolve(actual,expected,false),"inspection started"
end
function starterHunter:resetFrameDiagnostics()
    hitCorrectionFrames,lastFrameResult=0,nil
    eonBridge.resolveJob,eonBridge.pidRecoveryJob=nil,nil
    eonBridge.frameHitStatus="Waiting for the next Pokemon encounter."
    saveSettings(); return true
end
function starterHunter:testCommitFrameEdit(value)
    if not STARTER_HUNTER_ENABLE_TEST_API then return false,"test unavailable" end
    editMode,editText="frame",tostring(value)
    commitEdit()
    return true
end
function starterHunter:testLocatePid(pid,center,targetHuntType)
    if not STARTER_HUNTER_ENABLE_TEST_API then return nil,"test unavailable" end
    pid=type(pid)=="number" and pid or tonumber(tostring(pid),16)
    if not pid then return nil,"bad PID" end
    return locateActualFrame({pid=pid&0xFFFFFFFF},tonumber(center) or 0,tonumber(targetHuntType) or huntType)
end
function starterHunter:testRecoverPidFrame(pid)
    if not STARTER_HUNTER_ENABLE_TEST_API then return nil,"test unavailable" end
    pid=type(pid)=="number" and pid or tonumber(tostring(pid),16)
    return pid and eonBridge.directPidFrame(pid) or nil,"bad PID"
end
function starterHunter:testBeginPidRecovery(pid,expectedTargetFrame)
    if not STARTER_HUNTER_ENABLE_TEST_API then return false,"test unavailable" end
    pid=type(pid)=="number" and pid or tonumber(tostring(pid),16)
    if not pid then return false,"bad PID" end
    targetFrame=math.max(0,math.floor(tonumber(expectedTargetFrame) or targetFrame))
    eonBridge.frameHitEnemyPid=pid&0xFFFFFFFF
    return eonBridge.beginFrameHitResolve({pid=pid&0xFFFFFFFF,valid=true},targetFrame,false)
end
function starterHunter:testDropEvaluatedTarget()
    if not STARTER_HUNTER_ENABLE_TEST_API then return false end
    target=nil
    return true
end
function starterHunter:testBeginWildSpreadScan(actualFrame,expectedTargetFrame,method)
    if not STARTER_HUNTER_ENABLE_TEST_API then return false,"test unavailable" end
    if not target then readProfile(); evaluateTarget() end
    if not target then tid,sid=25758,63216; evaluateTarget() end
    if not target then return false,"profile/target unavailable" end
    actualFrame=math.floor(tonumber(actualFrame) or -1)
    expectedTargetFrame=math.max(0,math.floor(tonumber(expectedTargetFrame) or target.frame))
    method=tonumber(method) or 2
    if actualFrame<0 or actualFrame>MAX_SEARCH_FRAME then return false,"bad frame" end
    local generated=eonBridge.makeTargetFor(3,actualFrame,advanceSeed(baseSeed,actualFrame),method)
    if not generated then return false,"no wild result at test frame" end
    local actual={pid=generated.pid,species=nationalToInternalSpecies(generated.species),
        level=generated.level,ivs=generated.ivs,valid=true}
    targetFrame=expectedTargetFrame
    eonBridge.frameHitEnemyPid=actual.pid
    return eonBridge.beginFrameHitResolve(actual,expectedTargetFrame,false),actual
end
function starterHunter:testMakeManualWildPokemon(actualFrame,method)
    if not STARTER_HUNTER_ENABLE_TEST_API then return nil,"test unavailable" end
    if not target then readProfile(); evaluateTarget() end
    if not target then tid,sid=25758,63216; evaluateTarget() end
    actualFrame=math.floor(tonumber(actualFrame) or -1)
    method=tonumber(method) or 2
    if actualFrame<0 or actualFrame>MAX_SEARCH_FRAME then return nil,"bad frame" end
    local generated=eonBridge.makeTargetFor(3,actualFrame,advanceSeed(baseSeed,actualFrame),method)
    if not generated then return nil,"no wild result at test frame" end
    return {pid=generated.pid,species=nationalToInternalSpecies(generated.species),
        level=generated.level,ivs=generated.ivs,valid=true}
end
function starterHunter:testMakeManualStaticPokemon(actualFrame,species)
    if not STARTER_HUNTER_ENABLE_TEST_API then return nil,"test unavailable" end
    if not target then readProfile(); evaluateTarget() end
    if not target then tid,sid=25758,63216; evaluateTarget() end
    actualFrame=math.floor(tonumber(actualFrame) or -1)
    if actualFrame<0 or actualFrame>MAX_SEARCH_FRAME then return nil,"bad frame" end
    local generated=eonBridge.makeTargetFor(1,actualFrame,advanceSeed(baseSeed,actualFrame))
    if not generated then return nil,"no static result" end
    return {pid=generated.pid,species=tonumber(species) or 283,ivs=generated.ivs,level=5,valid=true}
end
function starterHunter:testBeginLinkedPidRecovery(pid,bridgeTarget)
    if not STARTER_HUNTER_ENABLE_TEST_API then return false,"test unavailable" end
    pid=type(pid)=="number" and pid or tonumber(tostring(pid),16)
    if not pid then return false,"bad PID" end
    eonBridge.requestToken="frame-hit-linked-test"
    eonBridge.targetFrame=math.max(0,math.floor(tonumber(bridgeTarget) or 0))
    eonBridge.huntType=3
    eonBridge.beginPassiveResolve({pid=pid&0xFFFFFFFF,valid=true})
    return eonBridge.pidRecoveryJob~=nil
end
function starterHunter:testFrameDetector(actualFrame,expectedTargetFrame,keepResult)
    if not STARTER_HUNTER_ENABLE_TEST_API then return nil,"test unavailable" end
    if not target then readProfile(); evaluateTarget() end
    if not target then tid,sid=25758,63216; evaluateTarget() end
    if not target then return nil,"profile/target unavailable" end
    actualFrame=math.floor(tonumber(actualFrame) or -1)
    if actualFrame<0 or actualFrame>MAX_SEARCH_FRAME then return nil,"bad frame" end
    local actual=makeTarget(actualFrame,advanceSeed(baseSeed,actualFrame))
    if not actual then return nil,"no result" end
    local oldAutomationTarget,oldAutomationHuntType=automationTarget,automationHuntType
    local oldCorrection,oldResult=hitCorrectionFrames,lastFrameResult
    expectedTargetFrame=math.floor(tonumber(expectedTargetFrame) or target.frame)
    automationTarget,automationHuntType={frame=expectedTargetFrame,state=target.state,pid=target.pid},huntType
    local found=locateActualFrame({pid=actual.pid,species=actual.species and nationalToInternalSpecies(actual.species) or 0})
    local ok=applyFrameMiss({pid=actual.pid,species=actual.species and nationalToInternalSpecies(actual.species) or 0})
    local applied=hitCorrectionFrames
    automationTarget,automationHuntType=oldAutomationTarget,oldAutomationHuntType
    if keepResult then
        eonBridge.frameHitEnemyPid=actual.pid
        eonBridge.frameHitStatus=string.format("Landed on frame %d (%+d from target).",found or 0,(found or expectedTargetFrame)-expectedTargetFrame)
    else
        hitCorrectionFrames,lastFrameResult=oldCorrection,oldResult
    end
    saveSettings()
    return found,{expected=actualFrame,applied=applied,ok=ok,pid=actual.pid,species=actual.species,
        internalSpecies=actual.species and nationalToInternalSpecies(actual.species) or 0,huntType=huntType,targetFrame=expectedTargetFrame}
end
function starterHunter:testEonBridge(actualFrame,expectedTargetFrame,token)
    if not STARTER_HUNTER_ENABLE_TEST_API then return nil,"test unavailable" end
    if not target then readProfile(); evaluateTarget() end
    if not target then tid,sid=25758,63216; evaluateTarget() end
    if not target then return nil,"profile/target unavailable" end
    actualFrame=math.floor(tonumber(actualFrame) or -1)
    expectedTargetFrame=math.floor(tonumber(expectedTargetFrame) or target.frame)
    if actualFrame<0 or actualFrame>MAX_SEARCH_FRAME then return nil,"bad frame" end
    local actual=makeTarget(actualFrame,advanceSeed(baseSeed,actualFrame))
    if not actual then return nil,"no result" end
    actual.species=actual.species and nationalToInternalSpecies(actual.species) or 0
    local landed=locateActualFrame(actual,expectedTargetFrame,huntType)
    if not landed then return nil,"PID/IV frame not found" end
    eonBridge.writeResult(token or "headless-test",expectedTargetFrame,landed,actual,huntType)
    return landed,{pid=actual.pid,ivs=actual.ivs,targetFrame=expectedTargetFrame}
end
function starterHunter:testPollEonBridge()
    if not STARTER_HUNTER_ENABLE_TEST_API then return false,"test unavailable" end
    eonBridge.pollRequest()
    return eonBridge.requestToken~=nil,eonBridge.requestToken
end
function starterHunter:command(value) return eonBridge.runWildCommand(value) end
function starterHunter:tick() onFrame() end
function starterHunter:selfTest()
    local oldTid,oldSid,oldHuntType=tid,sid,huntType
    local oldType,oldArea,oldSpecies,oldMethod=wildTypeIndex,wildAreaIndex,wildSpeciesIndex,wildMethod
    local oldTarget,oldTargetFrame=target,targetFrame
    tid,sid,huntType,wildMethod=25758,63216,3,1
    local foundArea=false
    for i,area in ipairs(areas) do
        if area.type=="Grass" then wildAreaIndex=i; foundArea=true; break end
    end
    if game.dataCode=="BPEE" then
        for i,area in ipairs(areas) do
            if area.name=="Route 101" and area.type=="Grass" then wildAreaIndex=i; break end
        end
    end
    local list=uniqueSpecies(selectedArea())
    wildSpeciesIndex=1
    if game.dataCode=="BPEE" then
        for i,id in ipairs(list) do if id==261 then wildSpeciesIndex=i; break end end
    end
    local state=0; local result
    if foundArea and #list>0 then
        for frame=0,1000000 do
            local candidate=makeTarget(frame,state)
            if candidate and candidate.speciesMatch and candidate.shinyValue<8 then result=candidate; break end
            state=lcgNext(state)
        end
    end
    tid,sid,huntType=oldTid,oldSid,oldHuntType
    wildTypeIndex,wildAreaIndex,wildSpeciesIndex,wildMethod=oldType,oldArea,oldSpecies,oldMethod
    target,targetFrame=oldTarget,oldTargetFrame
    if not foundArea then return false,game.name.." grass encounter data missing" end
    if #list==0 then return false,game.name.." species data missing" end
    if not result then return false,game.name.." shiny search failed" end
    if game.dataCode=="BPEE" and not (result.frame==4874 and result.pid==0x08439A2B and result.species==261) then
        return false,"Emerald PokeFinder vector mismatch"
    end
    if result.shinyValue>=8 or not result.speciesMatch or not result.pid or not result.ivs or #result.ivs~=6 then
        return false,game.name.." target validation failed"
    end
    return true,string.format("%s wild RNG passed (frame %d, PID %08X, SV %d)",game.name,result.frame,result.pid,result.shinyValue)
end

loadSettings(); readProfile(); evaluateTarget()
if not STARTER_HUNTER_CAPTURE_ONLY then
    local previousCommand=eonBridge.readValues(eonBridge.commandPath)
    eonBridge.lastCommandSequence=previousCommand and previousCommand.sequence or nil
end
status=huntType==1 and "Pick a starter, then press F." or huntType==2 and "Pick a roamer, then press F." or "Pick an area and Pokemon, then press F."
callbacks:add("key",onKey)
if not STARTER_HUNTER_CAPTURE_ONLY then
    callbacks:add("mouseWheel",function(event)
        if not eonBridge.pickerCanCycle() then return end
        local amount=tonumber(event.y) or 0
        if amount>0 then cycleWildSpecies(-1)
        elseif amount<0 then cycleWildSpecies(1) end
    end)
    callbacks:add("keysRead",function()
        keyReadCount=keyReadCount+1
        if mode=="pre" or mode=="running" or mode=="catching" then
            stageKeyReads=stageKeyReads+1
            lastAppliedKeyMask=automationKeyMask
            emu:setKeys(automationKeyMask)
        end
        if STARTER_HUNTER_MANUAL_KEY_POLL then STARTER_HUNTER_MANUAL_KEY_POLL() end
    end)
end
local function safeOnFrame()
    local ok,message=pcall(onFrame)
    if ok then return end
    -- Fail open: never leave an injected button held or a temporary encounter
    -- override active if a future script error occurs.
    automationKeyMask=0
    pcall(function() emu:clearKeys(0x3FF) end)
    pcall(clearWildBreakpoint)
    pcall(restoreEncounterState)
    mode,navStage,countdownFrames,stageFrames,searchJob="error","idle",0,0,nil
    status="Script recovered and released all input: "..tostring(message)
    pcall(function() render(true) end)
end
-- FrameClock supplies the normal frame event and a guarded keysRead fallback
-- for mGBA fast-forward builds that stop delivering frame callbacks.
if not STARTER_HUNTER_EXTERNAL_FRAME_DRIVER then GEN3_FRAME_CLOCK:add(safeOnFrame) end
if not STARTER_HUNTER_CAPTURE_ONLY then eonBridge.pollRequest() end
render(true)

if not STARTER_HUNTER_CAPTURE_ONLY then
    local marker=io.open(PROJECT_DIR.."/rng-loaded.txt","w")
    if marker then marker:write(game.name.." RNG tools loaded\nbridge=1\n"); marker:close() end
end
