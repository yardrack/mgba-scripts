-- Shared Pickup keep filters. Item identifiers are the Generation III item
-- constants used by all five English games supported by the bot.

local presets={
    {name="All",accept=function() return true end},
    {name="Rare Candy",accept=function(itemId) return itemId==68 end},
    {name="Candy + PP",accept=function(itemId) return itemId==68 or itemId==69 end},
    {name="Valuable",items={
        [68]=true,  -- Rare Candy
        [69]=true,  -- PP Up
        [110]=true, -- Nugget
        [180]=true, -- White Herb
        [187]=true, -- King's Rock
        [200]=true, -- Leftovers
        [289]=true, -- TM01 Focus Punch
        [314]=true, -- TM26 Earthquake
        [332]=true, -- TM44 Rest
    }},
    {name="Recovery",accept=function(itemId)
        return (itemId>=13 and itemId<=25) or (itemId>=34 and itemId<=37)
    end},
    {name="Poke Balls",accept=function(itemId) return itemId>=1 and itemId<=12 end},
    {name="TMs",accept=function(itemId) return itemId>=289 and itemId<=338 end},
}

local aliases={
    ["all"]="All",["rare candy"]="Rare Candy",["candy"]="Rare Candy",
    ["candy + pp"]="Candy + PP",["candy pp"]="Candy + PP",["pp"]="Candy + PP",
    ["valuable"]="Valuable",["recovery"]="Recovery",["medicine"]="Recovery",
    ["poke balls"]="Poke Balls",["pokeballs"]="Poke Balls",["balls"]="Poke Balls",
    ["tms"]="TMs",["tm"]="TMs",
}

local function accepts(preset,itemId)
    itemId=tonumber(itemId) or 0
    if preset.accept then return preset.accept(itemId) end
    return preset.items[itemId]==true
end

local Filter={}
Filter.__index=Filter

function Filter:name()
    return presets[self.index].name
end

function Filter:accepts(itemId)
    return accepts(presets[self.index],itemId)
end

function Filter:set(value)
    local target=nil
    if type(value)=="number" then
        target=math.max(1,math.min(#presets,math.floor(value)))
    elseif type(value)=="string" then
        local requested=aliases[value:lower()] or value
        for index,preset in ipairs(presets) do
            if preset.name:lower()==requested:lower() then target=index; break end
        end
    end
    if not target then return false,self:name() end
    self.index=target
    return true,self:name()
end

function Filter:cycle()
    self.index=self.index%#presets+1
    return self:name()
end

function Filter:names()
    local names={}
    for index,preset in ipairs(presets) do names[index]=preset.name end
    return names
end

local M={}
function M.new(initial)
    local filter=setmetatable({index=1},Filter)
    if initial~=nil then filter:set(initial) end
    return filter
end

return M
