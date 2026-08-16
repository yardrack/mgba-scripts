-- Full-suite fast-forward stress probe. The runner launches mGBA with audio
-- and video sync disabled while retaining the real scripting text buffers.

local root=os.getenv("GEN3_TEST_ROOT")
local resultPath=os.getenv("GEN3_TEST_RESULT")
local names={BPEE="Emerald",AXVE="Ruby",AXPE="Sapphire",BPRE="FireRed",BPGE="LeafGreen"}
local target=tonumber(os.getenv("GEN3_TEST_FRAMES")) or 50000
local finished=false

local function write(path,text)
    local file=path and io.open(path,"w")
    if file then file:write(text.."\n"); file:close() end
end

local function finish(text)
    if finished then return end
    finished=true
    write(resultPath,text)
end

local code=emu:getGameCode()
if not root or not resultPath or not names[code] then
    finish("FAIL invalid environment or unsupported game")
    return
end

GEN3_SUITE_GAME=code
GEN3_SUITE_NAME=names[code]
GEN3_SUITE_DIR=root
STARTER_HUNTER_DIR=root
STARTER_HUNTER_HEADLESS=os.getenv("GEN3_TEST_NO_UI")=="1"

local ok,problem=xpcall(function() dofile(root.."/lib/GameSuite.lua") end,debug.traceback)
if not ok then finish("FAIL load "..tostring(problem)); return end

local started=os.clock()
local initialFrame=emu:currentFrame()
local frameEvents,keyEvents=0,0

local function snapshot(label)
    local capture=ManualMonitor:snapshot()
    return string.format(
        "%s code=%s frameEvents=%d keyEvents=%d coreDelta=%d clock=%d capture=%d monitor=%d elapsed=%.3f",
        label,code,frameEvents,keyEvents,emu:currentFrame()-initialFrame,
        GEN3_FRAME_CLOCK:frameCount(),capture.videoFrame,ManualMonitor:testSearchState(),os.clock()-started)
end

callbacks:add("frame",function()
    frameEvents=frameEvents+1
    if frameEvents%5000==0 then write(resultPath..".progress",snapshot("RUN")) end
    if frameEvents>=target then finish(snapshot("PASS")) end
end)

callbacks:add("keysRead",function()
    keyEvents=keyEvents+1
    if keyEvents>=target*2 and frameEvents<target then
        finish(snapshot("FAIL frame callbacks stalled"))
    end
end)
