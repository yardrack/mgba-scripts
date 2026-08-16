local root=arg[1] or "."

local now=0
local emulatedFrame=100
local registered={}
local ticks=0

os.clock=function() return now end
callbacks={
    add=function(_,event,callback)
        registered[event]=callback
    end
}
emu={
    currentFrame=function() return emulatedFrame end
}

local clock=dofile(root.."/lib/FrameClock.lua")
clock:add(function() ticks=ticks+1 end)

registered.frame()
assert(clock:frameCount()==1,"normal frame was not dispatched")
assert(clock:currentFrame()==100,"normal frame was not displayed")
assert(ticks==1,"subscriber missed normal frame")

-- A healthy frame callback suppresses the input-poll fallback.
now=0.010
emulatedFrame=101
registered.keysRead()
assert(clock:frameCount()==1,"keysRead duplicated a healthy frame callback")

-- Once frame callbacks go quiet, keysRead becomes the frame source. A changing
-- emulator counter bypasses the display throttle so fast-forward stays exact.
now=0.100
registered.keysRead()
assert(clock:frameCount()==2,"keysRead did not recover a stalled frame callback")
assert(clock:currentFrame()==101,"fallback did not update the displayed frame")
assert(ticks==2,"subscriber missed fallback frame")

now=0.101
emulatedFrame=108
registered.keysRead()
assert(clock:frameCount()==3,"fast-forward frame change was throttled")
assert(clock:currentFrame()==108,"fast-forward frame jump was not preserved")

-- Loading a savestate may move mGBA's counter backwards.
now=0.102
emulatedFrame=12
registered.keysRead()
assert(clock:currentFrame()==12,"savestate rewind did not re-anchor the display")

print("PASS frame clock: normal, fast-forward fallback, and rewind")
