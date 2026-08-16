param([int]$TimeoutSeconds=90,[string]$Game='')
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runner=Join-Path $PSScriptRoot 'live_scenarios.lua'
$mgba='C:\Program Files\mGBA\mGBA.exe'
$romRoot='C:\Users\j\Documents\Codex\2026-08-10\ins\work\pokebot-gen3\roms'
$stateRoot='C:\Users\j\Documents\Codex\2026-08-13\i-basically-want-you-to-write\outputs\Gen 3 mGBA Lua Suite v2'
$grassRoot='C:\Users\j\Documents\Codex\2026-08-10\ins\work\pokebot-gen3\tests\states'
$sapphireMaster='C:\Users\j\Documents\Codex\2026-08-16\lets-start-fresh-rewrite-me-a\work\Pokebot-Profiles\Drop-In Profiles\Master Tests\USA_EUR\Sapphire\states'
$cases=@(
    @{Name='Emerald';Rom=(Join-Path $romRoot 'Pokemon - Emerald Version (USA, Europe).gba');State=(Join-Path $grassRoot 'emerald\in_tall_grass_after_receiving_pokeballs.ss1')},
    @{Name='Ruby';Rom=(Join-Path $romRoot 'Pokemon - Ruby Version (U) (V1.1).gba');State=(Join-Path $grassRoot 'ruby\in_tall_grass_after_receiving_pokeballs.ss1')},
    @{Name='Sapphire';Rom=(Join-Path $romRoot 'Pokemon - Sapphire Version (USA, Europe) (Rev 2).gba');State=(Join-Path $sapphireMaster 'Spin_Bunny-Everywhere.ss1')},
    @{Name='FireRed';Rom=(Join-Path $romRoot 'Pokemon - FireRed Version (USA, Europe) (Rev 1).gba');State=(Join-Path $grassRoot 'firered\in_tall_grass_after_receiving_pokeballs.ss1')},
    @{Name='LeafGreen';Rom=(Join-Path $romRoot 'Pokemon - Leaf Green Version (U) (V1.1).gba');State=(Join-Path $stateRoot 'LeafGreen Wild Checkpoint.ss1')}
)
if($Game){ $cases=@($cases | Where-Object Name -eq $Game); if($cases.Count -ne 1){ throw "Unknown game: $Game" } }
foreach($case in $cases){
    if(-not (Test-Path -LiteralPath $case.Rom)){ throw "Missing ROM for $($case.Name)" }
    if(-not (Test-Path -LiteralPath $case.State)){ throw "Missing state for $($case.Name)" }
    $result=Join-Path $env:TEMP ("gen3-scenario-{0}-{1}.txt" -f $case.Name,[guid]::NewGuid().ToString('N'))
    $env:GEN3_TEST_ROOT=$root; $env:GEN3_TEST_RESULT=$result; $env:GEN3_TEST_STATE=$case.State
    $env:GEN3_TEST_ENCOUNTER_STATE=if($case.EncounterState){$case.EncounterState}else{$case.State}
    $quotedRunner='"'+$runner+'"'; $quotedRom='"'+$case.Rom+'"'
    $process=Start-Process -FilePath $mgba -ArgumentList @('-C','audioSync=0','-C','videoSync=0','--script',$quotedRunner,$quotedRom) -PassThru -WindowStyle Hidden
    try{
        $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
        while((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $result)){ Start-Sleep -Milliseconds 100 }
        if(-not (Test-Path -LiteralPath $result)){
            $progress=$result+'.progress'
            $detail=if(Test-Path -LiteralPath $progress){ (Get-Content -LiteralPath $progress -Raw).Trim() }else{ 'no progress callback' }
            throw "$($case.Name) scenario timed out after $TimeoutSeconds seconds ($detail)"
        }
        $text=(Get-Content -LiteralPath $result -Raw).Trim(); Write-Output "$($case.Name): $text"
        if(-not $text.StartsWith('PASS ')){ throw "$($case.Name) scenario failed" }
    } finally {
        if(-not $process.HasExited){ Stop-Process -Id $process.Id -Force }
        if(Test-Path -LiteralPath $result){ Remove-Item -LiteralPath $result -Force }
        if(Test-Path -LiteralPath ($result+'.progress')){ Remove-Item -LiteralPath ($result+'.progress') -Force }
    }
}
Remove-Item Env:GEN3_TEST_ROOT,Env:GEN3_TEST_RESULT,Env:GEN3_TEST_STATE,Env:GEN3_TEST_ENCOUNTER_STATE -ErrorAction SilentlyContinue
Write-Output 'PASS full-bag Pickup, Battle, and Hunter live scenarios on all five games'
