-- Disposable real-mGBA load/transition smoke test. The PowerShell runner sets
-- GEN3_TEST_ROOT and GEN3_TEST_RESULT and terminates mGBA after this reports.
local root=os.getenv("GEN3_TEST_ROOT")
local resultPath=os.getenv("GEN3_TEST_RESULT")
local names={BPEE="Emerald",AXVE="Ruby",AXPE="Sapphire",BPRE="FireRed",BPGE="LeafGreen"}
local finished=false
local function finish(text)
    if finished then return end
    local file=io.open(resultPath,"w")
    if file then file:write(text.."\n"); file:close() end
    finished=true
end

local code=emu:getGameCode()
local gameName=names[code]
if not root or not resultPath or not gameName then
    finish("FAIL invalid test environment or unsupported code "..tostring(code))
    return
end
GEN3_SUITE_GAME=code
GEN3_SUITE_NAME=gameName
GEN3_SUITE_DIR=root
STARTER_HUNTER_DIR=root
local ok,problem=xpcall(function() dofile(root.."/lib/GameSuite.lua") end,debug.traceback)
if not ok then finish("FAIL load "..tostring(problem)); return end

local frames=0
callbacks:add("frame",function()
    if finished then return end
    frames=frames+1
    local okStep,stepProblem=xpcall(function()
        if frames==30 then
            assert(Gen3Suite and Gen3Suite:getState().tool=="Capture")
        elseif frames==42 then
            Gen3Suite.selectTool("Battle"); Battle:start(); Battle:stop()
        elseif frames==54 then
            Gen3Suite.selectTool("Pickup"); Pickup:start(); Pickup:stop()
        elseif frames==66 then
            Gen3Suite.selectTool("Hunter"); Hunter:start(); Hunter:stop()
        elseif frames==78 then
            Gen3Suite.selectTool("Capture")
        elseif frames>=100 then
            local suite=Gen3Suite:getState()
            assert(suite.tool=="Capture" and not suite.battle and not suite.pickup and not suite.hunter)
            finish(string.format("PASS code=%s rev=%d tool=%s transitions=4",
                code,emu:read8(0x080000BC),suite.tool))
        end
    end,debug.traceback)
    if not okStep then finish("FAIL transition "..tostring(stepProblem)) end
end)
