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
        raw=value,display=value,stepBase=value,stepHeld=false,paused=false
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
        self.raw,self.display,self.stepBase=raw,raw,raw
        self.stepHeld,self.paused=false,false
        return self.display
    end

    if not self.paused then
        self.display=self.display+delta
        self.stepBase=self.display
    end
    self.raw=raw
    return self.display
end

-- state is one of mGBA's C.INPUT_STATE values. Only DOWN starts a logical
-- step; HELD is Windows keyboard repeat and UP merely releases the latch.
function CaptureClock:frameAdvanceKey(state,down,up,value)
    if state==down then
        if not self.stepHeld then
            self.stepHeld=true
            -- Count the user's physical command, not mGBA's raw frame delta.
            -- This is deliberately immediate: some Qt builds deliver the Lua
            -- key event after their frame callback has already jumped by 4-6.
            if not self.paused then
                self.paused=true
                self.stepBase=self.display
            end
            self.display=self.stepBase+1
            self.stepBase=self.display
            local raw=tonumber(value)
            if raw then self.raw=raw&0xFFFFFFFF end
        end
    elseif state==up then
        self.stepHeld=false
    end
    return self.display
end

-- Ctrl+P toggles the frontend pause state. While paused, all raw VBlank/frame
-- changes are absorbed; only a fresh Ctrl+N DOWN changes the logical display.
function CaptureClock:togglePause(value)
    local raw=tonumber(value)
    if raw then self.raw=raw&0xFFFFFFFF end
    self.paused=not self.paused
    self.stepHeld=false
    self.stepBase=self.display
    return self.display
end

-- Ctrl+P resumes ordinary execution after stepping. Re-anchor the raw clock
-- so frames already absorbed from Qt's repeat burst are not added later.
function CaptureClock:resume(value)
    local raw=tonumber(value)
    if raw then self.raw=raw&0xFFFFFFFF end
    self.stepHeld,self.paused=false,false
    self.stepBase=self.display
    return self.display
end

function CaptureClock:value() return self.display end
function CaptureClock:isStepping() return self.paused end

return CaptureClock
