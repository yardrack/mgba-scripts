local shared={
    family="FRLG",
    -- PokéFinder's Gen 3 Static "Advances" value points directly at the
    -- first Method 1 PID call. Keep the displayed/entered frame in that same
    -- convention; the former hidden +3 made an exact PokéFinder hit generate
    -- a different PID.
    seed=0x03005000,initialSeed=0x02020000,initialSeedBits=16,starterOffset=0,
    partyCount=0x02024029,party=0x02024284,enemy=0x0202402C,
    save1Ptr=0x03005008,save2Ptr=0x0300500C,storagePtr=0x03005010,roamerOffset=0x30D0,buggedRoamer=true,
    startMenuCursor=0x020370F4,startMenuCount=0x020370F5,startMenuOrder=0x020370F6,
    mapHeader=0x02036DFC,objectEvents=0x02036E38,playerAvatar=0x02037078,backupMapLayout=0x03005040,
    frlgMapAttributes=true,createMon=0x0803DA68,actionMenu=0x0203ADE4,partyInternalPtr=0x0203B09C,sweetAction=29,
    gMain=0x030030F0,cb2Battle=0x08011114,actionSelectionCursor=0x02023FF8,battlerControllerFuncs=0x03004FE0,chooseAction=0x0802E44C,
    paletteFade=0x02037AB8,bagState=0x0203ACFC,bagPocketOffset=6,bagCursorOffset=8,bagScrollOffset=14,
    bagOffset=0x310,itemsCount=42,keyItemsCount=30,ballsCount=13,bagKeyOffset=0xF20,storage=0x02029314,specialVar8004=0x020370C0,
    battleType=0x02022B4C,battleMons=0x02023BE4,battleOutcome=0x02023E8A,
    battleActionCursor=0x02023FF8,battleMoveCursor=0x02023FFC,moveToLearn=0x02024022,
    activeBattler=0x02023BC4,battlerPartyIndexes=0x02023BCE,battleTasks=0x03005090,
    fieldLocked=0x03000F9C,inBattleOffset=0x439,partyStructSize=100,battleMonSize=88,speciesInfoSize=28,
    pcItemsOffset=0x298,pcItemsCapacity=30,pcSplitStacks=false,maxItemId=376,
    bagPockets={
        [1]={name="Items",offset=0x310,capacity=42,stack=999},
        [2]={name="Key Items",offset=0x3B8,capacity=30,stack=999,protected=true},
        [3]={name="Poke Balls",offset=0x430,capacity=13,stack=999},
        [4]={name="TM Case",offset=0x464,capacity=58,stack=999,containerItem=364},
        [5]={name="Berry Pouch",offset=0x54C,capacity=43,stack=999,containerItem=365},
    }
}
local function profile(extra)
    local result={}; for key,value in pairs(shared) do result[key]=value end
    for key,value in pairs(extra) do result[key]=value end
    return result
end
return {
    BPR=profile({name="FireRed",dataCode="BPRE",speciesInfo=0x082547F4,speciesNames=0x08245F50,moveNames=0x08247104,battleMoves=0x08250C74,items=0x083DB098,chooseMove=0x0802EA24,evolutionTask=0x080CE8F0,replaceMoveTask=0x0813944C,endScriptedWild=0x0807FBB4,starters={"Bulbasaur","Charmander","Squirtle"},roamers={"Raikou","Entei","Suicune"},cb2Overworld=0x080565C8,wildHeaders=0x083C9D28,wildHeadersByRevision={[0]=0x083C9CB8,[1]=0x083C9D28},sweetScentEncounter=0x08082ED4,bagMenuCallbacks={0x08107F44,0x08107F58},initRoamer=0x08141E14,revisionOverrides={[0]={speciesInfo=0x08254784,speciesNames=0x08245EE0,moveNames=0x08247094,battleMoves=0x08250C04,items=0x083DB028,cb2Overworld=0x080565B4,cb2Battle=0x08011100,createMon=0x0803DA54,wildHeaders=0x083C9CB8,sweetScentEncounter=0x08082EC0,chooseAction=0x0802E438,chooseMove=0x0802EA10,evolutionTask=0x080CE8DC,replaceMoveTask=0x081393D4,endScriptedWild=0x0807FBA0,bagMenuCallbacks={0x08107ECC,0x08107EE0},initRoamer=0x08141D9C}}}),
    BPG=profile({name="LeafGreen",dataCode="BPGE",speciesInfo=0x082547D0,speciesNames=0x08245F2C,moveNames=0x082470E0,battleMoves=0x08250C50,items=0x083DAED4,chooseMove=0x0802EA24,evolutionTask=0x080CE8C4,replaceMoveTask=0x08139424,endScriptedWild=0x0807FB88,starters={"Bulbasaur","Charmander","Squirtle"},roamers={"Raikou","Entei","Suicune"},cb2Overworld=0x080565C8,wildHeaders=0x083C9B64,wildHeadersByRevision={[0]=0x083C9AF4,[1]=0x083C9B64},sweetScentEncounter=0x08082EA8,bagMenuCallbacks={0x08107F1C,0x08107F30},initRoamer=0x08141DEC,revisionOverrides={[0]={speciesInfo=0x08254760,speciesNames=0x08245EBC,moveNames=0x08247070,battleMoves=0x08250BE0,items=0x083DAE64,cb2Overworld=0x080565B4,cb2Battle=0x08011100,createMon=0x0803DA54,wildHeaders=0x083C9AF4,sweetScentEncounter=0x08082E94,chooseAction=0x0802E438,chooseMove=0x0802EA10,evolutionTask=0x080CE8B0,replaceMoveTask=0x081393AC,endScriptedWild=0x0807FB74,bagMenuCallbacks={0x08107EA4,0x08107EB8},initRoamer=0x08141D74}}})
}
