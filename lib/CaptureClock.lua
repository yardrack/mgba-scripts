-- Capture's logical frame counter.
--
-- mGBA's Qt shortcut is a repeating QAction. On affected builds, holding
-- Ctrl+N long enough for Windows to emit repeat events can execute several
-- VBlanks for one intended step. The key callback distinguishes the first
-- physical key-down from HELD repeats, so Capture advances exactly once.

local CaptureClock={}
CaptureClock.__index=CaptureClock

function CaptureClock.new(initial)
    local value=tonumber(initial) or 0
    return setmetatable({
        raw=value,display=value,stepHeld=false,pendingStep=false,
        suppressStepFrames=false
    },CaptureClock)
end

function CaptureClock:update(value)
    local raw=tonumber(value)
    if not raw then return self.display end
    raw=raw&0xFFFFFFFF
    local delta=(raw-self.raw)&0xFFFFFFFF
    if delta==0 then return self.display end

    -- Reset/savestate loads can move the game's counter backwards. Re-anchor
    -- instead of interpreting the wrapped delta as billions of frames.
    if delta>1000000 then
        self.raw,self.display=raw,raw
        self.pendingStep,self.suppressStepFrames=false,false
        return self.display
    end

    if self.suppressStepFrames then
        if self.pendingStep then
            self.display=self.display+1
            self.pendingStep=false
        end
    else
        self.display=self.display+delta
    end
    self.raw=raw
    return self.display
end

-- state is one of mGBA's C.INPUT_STATE values. Only DOWN starts a logical
-- step; HELD is Windows keyboard repeat and UP merely releases the latch.
function CaptureClock:frameAdvanceKey(state,down,up)
    if state==down then
        if not self.stepHeld then
            self.stepHeld=true
            self.pendingStep=true
            self.suppressStepFrames=true
        end
    elseif state==up then
        self.stepHeld=false
    end
    return self.display
end

-- Ctrl+P resumes ordinary execution after stepping. Re-anchor the raw clock
-- so frames already absorbed from Qt's repeat burst are not added later.
function CaptureClock:resume(value)
    local raw=tonumber(value)
    if raw then self.raw=raw&0xFFFFFFFF end
    self.stepHeld,self.pendingStep,self.suppressStepFrames=false,false,false
    return self.display
end

function CaptureClock:value() return self.display end

return CaptureClock
