<#
.SYNOPSIS
    Automated smoke test for the HD2 Pure-Lua Mod Loader.

.DESCRIPTION
    Starts HELLDIVERS 2 through Steam, waits for mods\loader.log to report the boot summary,
    judges pass/fail from the log contents, closes the game, and prints a JSON result.

    Exit code 0 = pass, 1 = fail, 2 = could not run (game already open / not found).

.PARAMETER GamePath
    HELLDIVERS 2 install folder. Auto-detected when omitted.

.PARAMETER TimeoutSeconds
    How long to wait for the boot summary. Default 180.

.PARAMETER KeepRunning
    Do not close the game after the test (useful when you want to look at something).

.PARAMETER ExpectMods
    Optional: the exact number of mods you expect to be loaded.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\smoke_test.ps1
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [int]$TimeoutSeconds = 180,
    [switch]$KeepRunning,
    [int]$ExpectMods = -1
)

$ErrorActionPreference = 'Stop'
$script:steps = @()
function Add-Step($name, $ok, $detail) {
    $script:steps += [pscustomobject]@{ step = $name; ok = [bool]$ok; detail = $detail }
    $colour = if ($ok) { 'Green' } else { 'Red' }
    $mark = if ($ok) { '+ ' } else { 'x ' }
    Write-Host ("  {0}{1,-28} {2}" -f $mark, $name, $detail) -ForegroundColor $colour
}

function Find-GamePath {
    $candidates = @()
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($v.SteamPath)   { $candidates += (Join-Path $v.SteamPath   'steamapps\common\Helldivers 2') }
            if ($v.InstallPath) { $candidates += (Join-Path $v.InstallPath 'steamapps\common\Helldivers 2') }
        } catch { }
    }
    $candidates += 'D:\steam\steamapps\common\Helldivers 2'
    $candidates += 'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2'
    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'bin\helldivers2.exe'))) { return (Resolve-Path $c).Path }
    }
    return $null
}

if (-not $GamePath) { $GamePath = Find-GamePath }
if (-not $GamePath) {
    Write-Host '{"result":"error","reason":"game not found"}'
    exit 2
}

$dataDir  = Join-Path $GamePath 'data'
$modsDir  = Join-Path $GamePath 'mods'
$logPath  = Join-Path $modsDir 'loader.log'
$patch    = Join-Path $dataDir '9ba626afa44a3aa3.patch_0'

Write-Host "smoke test: $GamePath" -ForegroundColor Cyan

if (Get-Process -Name 'helldivers2' -ErrorAction SilentlyContinue) {
    Write-Host '{"result":"error","reason":"game already running"}'
    exit 2
}

# preconditions
$patchOk = Test-Path $patch
Add-Step 'patch_0 present' $patchOk $(if ($patchOk) { "$((Get-Item $patch).Length) B" } else { 'missing — run install.ps1' })
if (-not $patchOk) {
    Write-Host (($script:steps | ConvertTo-Json -Compress))
    exit 1
}

# note the log length before launch so we only read the new session
$before = 0
if (Test-Path $logPath) { $before = (Get-Item $logPath).Length }

Write-Host "[*] launching via Steam..." -ForegroundColor Cyan
Start-Process 'steam://rungameid/553850'

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$booted = $false
$sawProcess = $false
$text = ''

while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    $proc = Get-Process -Name 'helldivers2' -ErrorAction SilentlyContinue
    if ($proc) { $sawProcess = $true }
    elseif ($sawProcess) {
        # process existed and then vanished: crashed
        break
    }
    if (Test-Path $logPath) {
        $len = (Get-Item $logPath).Length
        if ($len -gt $before) {
            $fs = [System.IO.File]::Open($logPath, 'Open', 'Read', 'ReadWrite')
            try {
                $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::UTF8)
                $text = $sr.ReadToEnd()
            } finally { $fs.Dispose() }
            if ($text -match '\[boot\] loaded \d+ mod\(s\)') { $booted = $true; break }
        }
    }
}

Add-Step 'game launched' $sawProcess $(if ($sawProcess) { 'process seen' } else { 'never started' })
Add-Step 'boot summary in log' $booted $(if ($booted) { 'found [boot] loaded N' } else { "not within ${TimeoutSeconds}s" })

# ---------------------------------------------------------------- judge the log
$started   = $text -match '=== hd2 pure-lua loader start ==='
$hooked    = $text -match '\[host\] update/shutdown hooked'
$hooked4   = $text -match '\[host\] init/render hooked'
$scanned   = $text -match '\[boot\] mods root'
$loadedN   = -1
if ($text -match '\[boot\] loaded (\d+) mod\(s\)') { $loadedN = [int]$Matches[1] }
$loadErr   = [regex]::Matches($text, '\[load\] .*(compile error|runtime error|expected table)').Count
$hostErr   = $text -match '\[update\] host error'
$firstTick = $text -match '\[bsl\] first tick ->'

Add-Step 'loader started'      $started  $(if ($started) { 'start banner present' } else { 'no banner' })
Add-Step 'host hooks installed' $hooked  $(if ($hooked) { 'update/shutdown chained' } else { 'no hook line' })
Add-Step 'all four hooks defined' $hooked4 $(if ($hooked4) { 'init/render present' } else { 'init/render line missing — loader is older than 0.2.0' })
Add-Step 'mod scan ran'         $scanned $(if ($scanned) { 'mods root scanned' } else { 'no scan line' })
Add-Step 'mods loaded'          ($loadedN -ge 0) $(if ($loadedN -ge 0) { "$loadedN mod(s)" } else { 'unknown' })
Add-Step 'no mod load errors'   ($loadErr -eq 0) ("$loadErr error line(s)")
Add-Step 'no host errors'       (-not $hostErr) $(if ($hostErr) { 'host error present' } else { 'clean' })
if ($firstTick) { Add-Step 'bsl-mod first tick' $true 'a third-party wrapper mod ran' }

if ($ExpectMods -ge 0) {
    Add-Step 'expected mod count' ($loadedN -eq $ExpectMods) "expected $ExpectMods, got $loadedN"
}

$pass = $started -and $hooked -and $hooked4 -and $scanned -and ($loadedN -ge 0) -and ($loadErr -eq 0) -and (-not $hostErr)
if ($ExpectMods -ge 0 -and $loadedN -ne $ExpectMods) { $pass = $false }

# --------------------------------------------------------------- close the game
if (-not $KeepRunning) {
    $proc = Get-Process -Name 'helldivers2' -ErrorAction SilentlyContinue
    if ($proc) {
        $proc.CloseMainWindow() | Out-Null
        Start-Sleep -Seconds 3
        $proc = Get-Process -Name 'helldivers2' -ErrorAction SilentlyContinue
        if ($proc) { Stop-Process -Id $proc.Id -Force }
        Add-Step 'game closed' $true 'process ended'
    }
}

$result = [pscustomobject]@{
    result      = if ($pass) { 'pass' } else { 'fail' }
    game        = $GamePath
    patch_bytes = (Get-Item $patch).Length
    patch_sha256= (Get-FileHash $patch -Algorithm SHA256).Hash
    mods_loaded = $loadedN
    log_lines   = ($text -split "`n").Count
    log_tail    = (($text -split "`n") | Where-Object { $_ -match '^\[' } | Select-Object -Last 12)
    steps       = $script:steps
}
Write-Host ''
Write-Host ($result | ConvertTo-Json -Depth 5)
if ($pass) { exit 0 } else { exit 1 }
