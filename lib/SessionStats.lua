-- Shared per-game session and lifetime statistics.
-- Session time is based on emulated frames. Lifetime counters use mGBA's
-- storage API when it is available.

local FPS=59.727500569606
local registry=rawget(_G,"GEN3_SESSION_STATS_REGISTRY") or {}
_G.GEN3_SESSION_STATS_REGISTRY=registry

local Stats={}
Stats.__index=Stats

local function blankSession(frame)
    return {active=false,frames=0,lastFrame=frame or 0,counters={}}
end

local function safeFrame(emu)
    local ok,value=pcall(function() return emu:currentFrame() end)
    return ok and tonumber(value) or 0
end

local function storageBucket(code)
    if not storage or not storage.getBucket then return nil end
    local ok,bucket=pcall(function() return storage:getBucket("gen3_suite_stats_"..code:lower()) end)
    return ok and bucket or nil
end

function Stats.new(emu,code)
    return setmetatable({emu=emu,code=code,sessions={},bucket=storageBucket(code)},Stats)
end

function Stats:_session(mode)
    local key=tostring(mode or "General")
    if not self.sessions[key] then self.sessions[key]=blankSession(safeFrame(self.emu)) end
    return self.sessions[key],key
end

function Stats:_advance(session)
    local frame=safeFrame(self.emu)
    local delta=frame-(session.lastFrame or frame)
    -- Resets and loaded savestates can move the core frame backwards. Re-anchor
    -- without subtracting time; very large jumps are also treated as a reload.
    if session.active and delta>=0 and delta<10000000 then session.frames=session.frames+delta end
    session.lastFrame=frame
end

function Stats:start(mode,reset)
    local session=self:_session(mode)
    self:_advance(session)
    if reset then session.frames,session.counters=0,{} end
    session.active=true
    session.lastFrame=safeFrame(self.emu)
    return self:snapshot(mode)
end

function Stats:stop(mode)
    local session=self:_session(mode)
    self:_advance(session)
    session.active=false
    return self:snapshot(mode)
end

function Stats:reset(mode)
    local _,key=self:_session(mode)
    self.sessions[key]=blankSession(safeFrame(self.emu))
    return self:snapshot(mode)
end

function Stats:inc(mode,name,amount)
    local session,key=self:_session(mode)
    self:_advance(session)
    amount=tonumber(amount) or 1
    session.counters[name]=(session.counters[name] or 0)+amount
    if self.bucket then
        local bucketKey=(key.."_"..tostring(name)):gsub("[^%w_]","_"):lower()
        self.bucket[bucketKey]=(tonumber(self.bucket[bucketKey]) or 0)+amount
    end
    return session.counters[name]
end

function Stats:snapshot(mode)
    local session,key=self:_session(mode)
    self:_advance(session)
    local counters,lifetime={},{}
    for name,value in pairs(session.counters) do counters[name]=value end
    if self.bucket then
        for name in pairs(counters) do
            local bucketKey=(key.."_"..tostring(name)):gsub("[^%w_]","_"):lower()
            lifetime[name]=tonumber(self.bucket[bucketKey]) or 0
        end
    end
    local seconds=session.frames/FPS
    return {mode=key,active=session.active,frames=session.frames,seconds=seconds,counters=counters,lifetime=lifetime}
end

function Stats:rate(mode,name)
    local snap=self:snapshot(mode)
    local value=snap.counters[name] or 0
    return snap.seconds>0 and value*3600/snap.seconds or 0
end

function Stats:formatElapsed(mode)
    local seconds=math.floor(self:snapshot(mode).seconds)
    local hours=math.floor(seconds/3600)
    local minutes=math.floor((seconds%3600)/60)
    return string.format("%02d:%02d:%02d",hours,minutes,seconds%60)
end

function Stats:all()
    local result={}
    for mode in pairs(self.sessions) do result[mode]=self:snapshot(mode) end
    return result
end

local M={}
function M.forGame(emu,code)
    local key=tostring(code or "unknown")
    if not registry[key] then registry[key]=Stats.new(emu,key) end
    return registry[key]
end

return M
