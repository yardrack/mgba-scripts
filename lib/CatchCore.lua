-- Automatic post-verification catching for English Gen 3 games.
-- This module only drives the game's real battle/bag UI; it does not create
-- items, force the catch flag, or edit the encountered Pokemon.

local Catch={}
Catch.__index=Catch

local BALL_NAMES={
    [1]="Master Ball",[2]="Ultra Ball",[3]="Great Ball",[4]="Poke Ball",
    [5]="Safari Ball",[6]="Net Ball",[7]="Dive Ball",[8]="Nest Ball",
    [9]="Repeat Ball",[10]="Timer Ball",[11]="Luxury Ball",[12]="Premier Ball"
}
-- Avoid spending the Master Ball while any ordinary Ball remains.
local BALL_PRIORITY={2,9,10,6,7,8,3,11,12,4,1}

local function validPointer(value)
    return value and value>=0x02000000 and value<0x02040000
end

function Catch.new(options)
    local self=setmetatable({},Catch)
    self.emu,self.game,self.press=options.emu,options.game,options.press
    self.save1,self.save2=options.save1,options.save2
    self.state,self.frames,self.status="idle",0,"Catch automation idle."
    self.expectedPid,self.initialParty,self.initialStorage=nil,0,0
    self.ball,self.attempts,self.maxAttempts=nil,0,100
    self.pocketStable=0
    return self
end

function Catch:_save1() return self.save1() end
function Catch:_save2() return self.save2() end
function Catch:_bagKey()
    if self.game.bagKey~=nil then return self.game.bagKey&0xFFFF end
    local save2=self:_save2()
    return save2 and self.emu:read16(save2+self.game.bagKeyOffset) or 0
end
function Catch:_ballBase()
    local save1=self:_save1()
    if not save1 then return nil end
    return save1+self.game.bagOffset+4*(self.game.itemsCount+self.game.keyItemsCount)
end
function Catch:balls()
    local base=self:_ballBase(); if not base then return {} end
    local key,result=self:_bagKey(),{}
    for slot=0,self.game.ballsCount-1 do
        local address=base+slot*4
        local item=self.emu:read16(address)
        local quantity=(self.emu:read16(address+2)~key)&0xFFFF
        if BALL_NAMES[item] and quantity>0 then
            result[#result+1]={id=item,name=BALL_NAMES[item],quantity=quantity,slot=slot,address=address}
        end
    end
    return result
end
function Catch:bestBall()
    local byId={}
    for _,ball in ipairs(self:balls()) do byId[ball.id]=ball end
    for _,id in ipairs(BALL_PRIORITY) do if byId[id] then return byId[id] end end
    return nil
end

function Catch:_storageAddress()
    if self.game.storagePtr then
        local pointer=self.emu:read32(self.game.storagePtr)
        if validPointer(pointer) then return pointer end
    end
    return self.game.storage
end
function Catch:storageCount()
    local base=self:_storageAddress(); if not validPointer(base) then return nil end
    local used=0
    -- PokemonStorage begins with currentBox + padding, followed by
    -- 14 boxes * 30 BoxPokemon records of 80 bytes.
    for slot=0,14*30-1 do
        local address=base+4+slot*80
        if self.emu:read32(address)~=0 or self.emu:read32(address+4)~=0 then used=used+1 end
    end
    return used
end
function Catch:hasStorageSpace()
    if self.emu:read8(self.game.partyCount)<6 then return true,"party" end
    local count=self:storageCount()
    if count==nil then return false,"Pokemon storage could not be read" end
    return count<420,count<420 and "PC" or "party and PC are full"
end
function Catch:preflight()
    local ball=self:bestBall()
    if not ball then return false,"No usable Poke Balls are in the Ball pocket." end
    local space,where=self:hasStorageSpace()
    if not space then return false,"No capture space: "..where.."." end
    return true,string.format("%s x%d; capture goes to %s",ball.name,ball.quantity,where),ball
end

function Catch:_chooseActionActive()
    local pointer=self.emu:read32(self.game.battlerControllerFuncs)
    return pointer==self.game.chooseAction or pointer==self.game.chooseAction+1
end
function Catch:_bagOpen()
    if not self.game.bagMenuCallbacks then return self.frames>=90 end
    local callback=self.emu:read32(self.game.gMain+4)
    for _,address in ipairs(self.game.bagMenuCallbacks) do
        if callback==address or callback==address+1 then
            return (self.emu:read8(self.game.paletteFade+7)&0x80)==0
        end
    end
    return false
end
function Catch:_setBagSelection(slot)
    local pocket=self.game.frlgMapAttributes and 2 or 1
    local visible=math.min(slot,7)
    local scroll=math.max(0,slot-visible)
    if self.game.bagPocket then
        self.emu:write8(self.game.bagScrollStates+pocket*4,visible)
        self.emu:write8(self.game.bagScrollStates+pocket*4+1,scroll)
    elseif self.game.bagState then
        self.emu:write16(self.game.bagState+self.game.bagCursorOffset+pocket*2,visible)
        self.emu:write16(self.game.bagState+self.game.bagScrollOffset+pocket*2,scroll)
    end
end
function Catch:_bagPocket()
    if self.game.bagPocket then return self.emu:read8(self.game.bagPocket) end
    return self.emu:read8(self.game.bagState+self.game.bagPocketOffset)
end
function Catch:_captured()
    if self.emu:read8(self.game.partyCount)>self.initialParty then return true,"party" end
    local count=self:storageCount()
    if count and self.initialStorage and count>self.initialStorage then return true,"PC" end
    return false
end
function Catch:begin(expectedPid)
    local ok,detail,ball=self:preflight()
    if not ok then return false,detail end
    local enemyPid=self.emu:read32(self.game.enemy)
    if expectedPid and enemyPid~=expectedPid then
        return false,string.format("Catch refused: enemy PID %08X is not verified PID %08X.",enemyPid,expectedPid)
    end
    self.expectedPid=expectedPid
    self.initialParty=self.emu:read8(self.game.partyCount)
    self.initialStorage=self:storageCount() or 0
    self.ball,self.attempts=ball,0
    self.state,self.frames,self.status="wait_action",0,"Waiting for the battle menu."
    return true,"Automatic catch armed with "..ball.name.."."
end
function Catch:cancel()
    self.state,self.frames="idle",0
end
function Catch:_retryOrFail()
    local ball=self:bestBall()
    if not ball then
        self.state,self.status="failed","The shiny is safe in the verification state, but all Poke Balls were used."
        return
    end
    self.ball,self.frames,self.state=ball,0,"choose_bag"
    self.status=string.format("Catch attempt %d failed; trying %s x%d.",self.attempts,ball.name,ball.quantity)
end
function Catch:tick()
    if self.state=="idle" or self.state=="caught" or self.state=="failed" then return self.state,self.status end
    self.frames=self.frames+1
    local captured,where=self:_captured()
    if self.state~="caught_cleanup" and captured then
        self.state,self.frames,self.capturedWhere="caught_cleanup",0,where
        self.status="Shiny caught; declining the nickname prompt and finishing text."
        return self.state,self.status
    end
    if self.frames>3600 or self.attempts>=self.maxAttempts then
        self.state,self.status="failed","Catch automation timed out; the verified-shiny save state is still available."
        return self.state,self.status
    end
    if self.state=="caught_cleanup" then
        if self.frames%15==1 then self.press(1) end
        if self.frames>=180 then
            self.state,self.status="caught","Shiny caught and stored in the "..self.capturedWhere.."."
        end
    elseif self.state=="wait_action" then
        if self:_chooseActionActive() then self.state,self.frames="choose_bag",0
        -- Battle introductions and ability text can consume several presses.
        -- A short pulse cadence clears them without holding A into the action
        -- menu; the live controller callback still gates the Bag selection.
        elseif self.frames%6==1 then self.press(0) end
    elseif self.state=="choose_bag" then
        if not self:_chooseActionActive() then
            self.state,self.frames="wait_bag",0
        else
            self.emu:write8(self.game.actionSelectionCursor,1)
            if self.frames%6==1 then self.press(0) end
        end
    elseif self.state=="wait_bag" then
        if self:_bagOpen() then
            local targetPocket=self.game.frlgMapAttributes and 2 or 1
            local pocket=self:_bagPocket()
            if pocket==targetPocket then
                self.pocketStable=self.pocketStable+1
                self:_setBagSelection(self.ball.slot)
                if self.pocketStable>=40 then self.state,self.frames,self.pocketStable="select_ball",0,0 end
            elseif self.frames%30==1 then
                self.pocketStable=0
                self.press(pocket>targetPocket and 5 or 4)
            end
        end
    elseif self.state=="select_ball" then
        self:_setBagSelection(self.ball.slot)
        if self.frames==1 then self.press(0)
        elseif self.frames>=12 then self.state,self.frames="confirm_ball",0 end
    elseif self.state=="confirm_ball" then
        if self.frames==1 then self.press(0)
        elseif self.frames>=20 then
            self.attempts=self.attempts+1
            self.state,self.frames="resolve_throw",0
            self.status=string.format("Throwing %s (attempt %d).",self.ball.name,self.attempts)
        end
    elseif self.state=="resolve_throw" then
        if self:_chooseActionActive() then self:_retryOrFail()
        elseif self.frames%30==1 then
            -- Advance capture/nickname text without choosing a nickname.
            self.press(1)
        end
    end
    return self.state,self.status
end

-- Disposable test-state helper; unavailable unless explicitly enabled.
function Catch:testInjectBall(item,quantity)
    if not STARTER_HUNTER_ENABLE_TEST_API then return false end
    local base=self:_ballBase(); if not base then return false end
    local key=self:_bagKey()
    self.emu:write16(base,item or 2)
    self.emu:write16(base+2,((quantity or 20)~key)&0xFFFF)
    return true
end

return Catch
