param([int]$TimeoutSeconds=20,[int]$Frames=50000,[string]$Game='',[switch]$NoUI)
$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$runner=Join-Path $PSScriptRoot 'live_fast_forward.lua'
$mgba='C:\Program Files\mGBA\mGBA.exe'
$romRoot='C:\Users\j\Documents\Codex\2026-08-10\ins\work\pokebot-gen3\roms'
$cases=@(
    @{Name='Emerald';Rom=(Join-Path $romRoot 'Pokemon - Emerald Version (USA, Europe).gba')},
    @{Name='Ruby';Rom=(Join-Path $romRoot 'Pokemon - Ruby Version (U) (V1.1).gba')},
    @{Name='Sapphire';Rom=(Join-Path $romRoot 'Pokemon - Sapphire Version (USA, Europe) (Rev 2).gba')},
    @{Name='FireRed';Rom=(Join-Path $romRoot 'Pokemon - FireRed Version (USA, Europe) (Rev 1).gba')},
    @{Name='LeafGreen';Rom=(Join-Path $romRoot 'Pokemon - Leaf Green Version (U) (V1.1).gba')}
)
if($Game){
    $cases=@($cases | Where-Object Name -eq $Game)
    if($cases.Count -ne 1){ throw "Unknown game: $Game" }
}

foreach($case in $cases){
    $result=Join-Path $env:TEMP ("gen3-fast-forward-{0}-{1}.txt" -f $case.Name,[guid]::NewGuid().ToString('N'))
    $env:GEN3_TEST_ROOT=$root
    $env:GEN3_TEST_RESULT=$result
    $env:GEN3_TEST_FRAMES=$Frames
    $env:GEN3_TEST_NO_UI=if($NoUI){'1'}else{'0'}
    $quotedRunner='"'+$runner+'"'
    $quotedRom='"'+$case.Rom+'"'
    $process=Start-Process -FilePath $mgba -ArgumentList @(
        '-C','audioSync=0','-C','videoSync=0','--script',$quotedRunner,$quotedRom
    ) -PassThru -WindowStyle Hidden
    try{
        $deadline=(Get-Date).AddSeconds($TimeoutSeconds)
        while((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $result)){
            Start-Sleep -Milliseconds 100
        }
        if(-not (Test-Path -LiteralPath $result)){
            $progress=$result+'.progress'
            $detail=if(Test-Path -LiteralPath $progress){(Get-Content -LiteralPath $progress -Raw).Trim()}else{'no callback progress'}
            throw "$($case.Name) fast-forward timeout ($detail)"
        }
        $text=(Get-Content -LiteralPath $result -Raw).Trim()
        Write-Output "$($case.Name): $text"
        if(-not $text.StartsWith('PASS ')){ throw "$($case.Name) fast-forward probe failed" }
    } finally {
        if(-not $process.HasExited){Stop-Process -Id $process.Id -Force}
        Remove-Item -LiteralPath $result,($result+'.progress') -Force -ErrorAction SilentlyContinue
    }
}

Remove-Item Env:GEN3_TEST_ROOT,Env:GEN3_TEST_RESULT,Env:GEN3_TEST_FRAMES,Env:GEN3_TEST_NO_UI -ErrorAction SilentlyContinue
Write-Output 'PASS full-suite fast-forward stress probe'
