param([string]$SuiteRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$lua=(Get-Command lua -ErrorAction Stop).Source
$tests=@('profile_matrix.lua','inventory_storage.lua','session_stats.lua','frame_clock.lua','launcher_paths.lua')
foreach($test in $tests){
    & $lua (Join-Path $PSScriptRoot $test) $SuiteRoot
    if($LASTEXITCODE -ne 0){ throw "$test failed with exit code $LASTEXITCODE" }
}
Write-Output "PASS all module tests ($($tests.Count) files)"
