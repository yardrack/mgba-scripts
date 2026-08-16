param([int]$TimeoutSeconds=25)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runner=Join-Path $PSScriptRoot 'live_suite_smoke.lua'
$mgba='C:\Program Files\mGBA\mGBA.exe'
$romRoot='C:\Users\j\Documents\Codex\2026-08-10\ins\work\pokebot-gen3\roms'
$cases=@(
    @{Name='Emerald';Rom=(Join-Path $romRoot 'Pokemon - Emerald Version (USA, Europe).gba')},
    @{Name='Ruby';Rom=(Join-Path $romRoot 'Pokemon - Ruby Version (U) (V1.1).gba')},
    @{Name='Sapphire';Rom=(Join-Path $romRoot 'Pokemon - Sapphire Version (USA, Europe) (Rev 2).gba')},
    @{Name='FireRed';Rom=(Join-Path $romRoot 'Pokemon - FireRed Version (USA, Europe) (Rev 1).gba')},
    @{Name='LeafGreen';Rom=(Join-Path $romRoot 'Pokemon - Leaf Green Version (U) (V1.1).gba')}
)
foreach($case in $cases){
    if(-not (Test-Path -LiteralPath $case.Rom)){ throw "Missing ROM for $($case.Name): $($case.Rom)" }
    $result=Join-Path $env:TEMP ("gen3-live-{0}-{1}.txt" -f $case.Name,[guid]::NewGuid().ToString('N'))
    $env:GEN3_TEST_ROOT=$root
    $env:GEN3_TEST_RESULT=$result
    $quotedRunner='"'+$runner+'"'
    $quotedRom='"'+$case.Rom+'"'
    $process=Start-Process -FilePath $mgba -ArgumentList @('--script',$quotedRunner,$quotedRom) -PassThru -WindowStyle Hidden
    try{
        $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
        while((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $result)){ Start-Sleep -Milliseconds 100 }
        if(-not (Test-Path -LiteralPath $result)){ throw "$($case.Name) timed out after $TimeoutSeconds seconds" }
        $text=(Get-Content -LiteralPath $result -Raw).Trim()
        Write-Output "$($case.Name): $text"
        if(-not $text.StartsWith('PASS ')){ throw "$($case.Name) live suite failed" }
    } finally {
        if(-not $process.HasExited){ Stop-Process -Id $process.Id -Force }
        if(Test-Path -LiteralPath $result){ Remove-Item -LiteralPath $result -Force }
    }
}
Remove-Item Env:GEN3_TEST_ROOT -ErrorAction SilentlyContinue
Remove-Item Env:GEN3_TEST_RESULT -ErrorAction SilentlyContinue
Write-Output "PASS live suite load/tool transitions on all five games"
