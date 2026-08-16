local root=assert(arg[1],"suite root argument required"):gsub("\\","/")
local frame=0
local emu={currentFrame=function() return frame end}
local buckets={}
storage={}
function storage:getBucket(name)
    buckets[name]=buckets[name] or {}
    return buckets[name]
end

local Stats=dofile(root.."/lib/SessionStats.lua")
local stats=Stats.forGame(emu,"BPEE_STATS_TEST")
stats:start("Pickup",true)
frame=598
stats:inc("Pickup","items",3)
stats:inc("Pickup","wins",2)
local snapshot=stats:snapshot("Pickup")
assert(snapshot.frames==598 and snapshot.counters.items==3 and snapshot.counters.wins==2)
assert(stats:rate("Pickup","items")>1000 and stats:rate("Pickup","wins")>700)
frame=300
assert(stats:snapshot("Pickup").frames==598,"rewound frames subtracted elapsed time")
frame=400
assert(stats:snapshot("Pickup").frames==698,"stats did not resume after a rewind")
stats:stop("Pickup")
assert(buckets.gen3_suite_stats_bpee_stats_test.pickup_items==3,"lifetime count was not persisted")
print("PASS session stats: timing, rates, rewind handling, and persistence")
