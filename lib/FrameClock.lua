-- One frame dispatcher for the Gen 3 suite.
--
-- mGBA normally emits a `frame` event after every emulated frame. During
-- fast-forward, some Qt builds can spend long stretches delivering only the
-- `keysRead` event. One dispatcher lets the suite recover without running
-- every tool twice when both events are healthy.

if GEN3_FRAME_CLOCK then return GEN3_FRAME_CLOCK end

local clock={
    callbacks={},count=0,lastFrameAt=os.clock(),lastFallbackAt=-math.huge,
    displayFrame=nil,observedFrame=nil,fallbackObserved=nil,
    fallbackDisplayBefore=nil,corrected=false
}
local FALLBACK_AFTER=0.050
local FALLBACK_INTERVAL=1/120

local function currentFrame()
    local ok,value=pcall(function() return emu:currentFrame() end)
    return ok and tonumber(value) or nil
end

local function updateDisplayFrame(observed,singleStep)
    observed=observed or currentFrame()
    if clock.displayFrame==nil then
        clock.displayFrame=observed or 0
    elseif singleStep then
        -- A frontend frame event represents one displayed frame. Some mGBA
        -- Qt builds advance their internal counter by 4-5 around Ctrl+N, so
        -- consuming that raw delta makes paused stepping visibly skip. The
        -- keysRead fallback below still consumes full deltas during fast-forward.
        if observed and clock.observedFrame and observed<clock.observedFrame then
            clock.displayFrame=observed
        else
            clock.displayFrame=clock.displayFrame+1
        end
    elseif observed and clock.observedFrame and observed>=clock.observedFrame then
        local delta=observed-clock.observedFrame
        clock.displayFrame=delta>100000 and observed or clock.displayFrame+delta
    elseif observed and clock.observedFrame and observed<clock.observedFrame then
        clock.displayFrame=observed
    else
        -- A reset or savestate can move mGBA's counter backwards. Keep the
        -- display moving until the next observed counter is available.
        clock.displayFrame=clock.displayFrame+1
    end
    clock.observedFrame=observed
end

local function dispatch(observed,singleStep)
    clock.count=clock.count+1
    updateDisplayFrame(observed,singleStep)
    for _,callback in ipairs(clock.callbacks) do callback(clock.count) end
end

function clock:add(callback)
    assert(type(callback)=="function","FrameClock callback must be a function")
    self.callbacks[#self.callbacks+1]=callback
    return #self.callbacks
end

function clock:frameCount() return self.count end
function clock:currentFrame() return self.displayFrame or currentFrame() or 0 end
function clock:consumeCorrection() local value=self.corrected; self.corrected=false; return value end

callbacks:add("frame",function()
    clock.lastFrameAt=os.clock()
    local observed=currentFrame()
    -- A paused frame advance can emit keysRead fallback work followed by one
    -- or more real frame callbacks for the same core frame. Never dispatch
    -- that observed frame twice; doing so made one Ctrl+N appear as +4/+5.
    if observed~=nil and clock.fallbackObserved~=nil and observed==clock.fallbackObserved then
        -- keysRead speculatively consumed the raw delta because no frame event
        -- had arrived yet. The real event proves it was one frontend step.
        clock.displayFrame=(clock.fallbackDisplayBefore or clock.displayFrame or observed)+1
        clock.observedFrame=observed
        clock.fallbackObserved,clock.fallbackDisplayBefore=nil,nil
        clock.corrected=true
        clock.count=clock.count+1
        for _,callback in ipairs(clock.callbacks) do callback(clock.count) end
        return
    end
    clock.fallbackObserved,clock.fallbackDisplayBefore=nil,nil
    if observed~=nil and clock.observedFrame~=nil and observed==clock.observedFrame then return end
    dispatch(observed,true)
end)

callbacks:add("keysRead",function()
    local now=os.clock()
    if now-clock.lastFrameAt<FALLBACK_AFTER then return end
    local observed=currentFrame()
    local frameChanged=observed and clock.observedFrame and observed~=clock.observedFrame
    if not frameChanged and now-clock.lastFallbackAt<FALLBACK_INTERVAL then return end
    clock.lastFallbackAt=now
    clock.fallbackObserved=observed
    clock.fallbackDisplayBefore=clock.displayFrame
    dispatch(observed,false)
end)

GEN3_FRAME_CLOCK=clock
return clock
