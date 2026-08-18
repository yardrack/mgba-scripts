local shared={
    family="RS",
    seed=0x03004818,partyCount=0x03004350,party=0x03004360,enemy=0x030045C0,
    sessionSeed=true,
    save1=0x02025734,save2=0x02024EA4,storage=0x020300A0,roamerOffset=0x3144,buggedRoamer=true,
    gMain=0x03001770,cb2Battle=0x0800F808,startMenuCursor=0x0202E8FC,mapHeader=0x0202E828,objectEvents=0x030048A0,
    playerAvatar=0x0202E858,backupMapLayout=0x03004870,sweetScentEncounter=0x0808531C,createMon=0x0803A798,starterCreateDest=0x03007DB4,
    actionCursor=0x0202FFA8,actionCount=0x0202FFA9,actionOrder=0x0202FFAA,sweetAction=23,
    actionSelectionCursor=0x02024E60,battlerControllerFuncs=0x03004330,chooseAction=0x0802C098,
    paletteFade=0x0202F388,bagPocket=0x02038559,bagScrollStates=0x03005D10,
    bagOffset=0x560,itemsCount=20,keyItemsCount=20,ballsCount=16,bagKey=0,
    initRoamer=0x0813432C,specialVar8004=0x0202E8CC,
    battleType=0x020239F8,battleMons=0x02024A80,battleOutcome=0x02024D26,
    battleActionCursor=0x02024E60,battleMoveCursor=0x02024E64,moveToLearn=0x02024E82,
    activeBattler=0x02024A60,battlerPartyIndexes=0x02024A6A,chooseMove=0x0802C68C,
    battleTasks=0x03004B20,fieldLocked=0x030006A4,inBattleOffset=0x43D,
    partyStructSize=100,battleMonSize=88,speciesInfoSize=28,
    pcItemsOffset=0x498,pcItemsCapacity=50,pcSplitStacks=true,maxItemId=376,
    bagPockets={
        [1]={name="Items",offset=0x560,capacity=20,stack=99,split=true},
        [2]={name="Poke Balls",offset=0x600,capacity=16,stack=99,split=true},
        [3]={name="TM/HM",offset=0x640,capacity=64,stack=99},
        [4]={name="Berries",offset=0x740,capacity=46,stack=999},
        [5]={name="Key Items",offset=0x5B0,capacity=20,stack=99,split=true,protected=true},
    }
}
local function profile(extra)
    local result={}; for key,value in pairs(shared) do result[key]=value end
    for key,value in pairs(extra) do result[key]=value end
    return result
end
return {
    AXV=profile({name="Ruby",dataCode="AXVE",speciesInfo=0x081FEC30,speciesNames=0x081F7184,moveNames=0x081F8338,battleMoves=0x081FB144,items=0x083C5580,cb2Overworld=0x080543C4,wildHeaders=0x0839D46C,wildHeadersByRevision={[0]=0x0839D454,[1]=0x0839D46C,[2]=0x0839D46C},starters={"Treecko","Torchic","Mudkip"},roamers={"Latios"},roamerSpecies=381,endScriptedWild=0x08081D0C,evolutionTask=0x0811242C,replaceMoveTask=0x0809E280,modern={speciesInfo=0x081FEC64,speciesNames=0x081F71B8,moveNames=0x081F836C,battleMoves=0x081FB178,items=0x083C55B0,cb2Overworld=0x080543E8,wildHeaders=0x0839D4A0,wildHeadersByRevision={[0]=0x0839D4A0},sweetScentEncounter=0x08085340,createMon=0x0803A7B4,initRoamer=0x08134350,endScriptedWild=0x08081D30,evolutionTask=0x08112450,warpIntoMap=0x08084C2C},revisionOverrides={[0]={speciesInfo=0x081FEC18,speciesNames=0x081F716C,moveNames=0x081F8320,battleMoves=0x081FB12C,items=0x083C5564,cb2Overworld=0x080543A4,wildHeaders=0x0839D454,sweetScentEncounter=0x080852FC,initRoamer=0x0813430C,endScriptedWild=0x08081CEC,evolutionTask=0x0811240C,replaceMoveTask=0x0809E260}}}),
    AXP=profile({name="Sapphire",dataCode="AXPE",speciesInfo=0x081FEBC0,speciesNames=0x081F7114,moveNames=0x081F82C8,battleMoves=0x081FB0D4,items=0x083C55DC,cb2Overworld=0x080543C8,wildHeaders=0x0839D2B4,wildHeadersByRevision={[0]=0x0839D29C,[1]=0x0839D2B4,[2]=0x0839D2B4},starters={"Treecko","Torchic","Mudkip"},roamers={"Latias"},roamerSpecies=380,endScriptedWild=0x08081D0C,evolutionTask=0x0811242C,replaceMoveTask=0x0809E280,modern={speciesInfo=0x081FEBF4,speciesNames=0x081F7148,moveNames=0x081F82FC,battleMoves=0x081FB108,items=0x083C5608,cb2Overworld=0x080543EC,wildHeaders=0x0839D2E8,wildHeadersByRevision={[0]=0x0839D2E8},sweetScentEncounter=0x08085340,createMon=0x0803A7B4,initRoamer=0x08134350,endScriptedWild=0x08081D30,evolutionTask=0x08112450,warpIntoMap=0x08084C2C},revisionOverrides={[0]={speciesInfo=0x081FEBA8,speciesNames=0x081F70FC,moveNames=0x081F82B0,battleMoves=0x081FB0BC,items=0x083C55BC,cb2Overworld=0x080543A8,wildHeaders=0x0839D29C,sweetScentEncounter=0x080852FC,initRoamer=0x0813430C,endScriptedWild=0x08081CEC,evolutionTask=0x0811240C,replaceMoveTask=0x0809E260}}})
}
