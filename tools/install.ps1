<#
.SYNOPSIS
    Install the HD2 Pure-Lua Mod Loader into a HELLDIVERS 2 installation.

.DESCRIPTION
    - Finds (or accepts) the game folder.
    - Refuses to run while the game is open.
    - Backs up the existing data\9ba626afa44a3aa3.patch_0 (+ .gpu_resources / .stream) first.
    - Copies the loader's three files into data\.
    - Prints what to look for in mods\loader.log after launching.

.PARAMETER GamePath
    HELLDIVERS 2 install folder. Auto-detected from Steam libraries when omitted.

.PARAMETER Build
    Which patch to install: 'solo' (loader only, default) or 'merged' (loader appended after a
    third-party host payload). 'solo' uses the prebuilt patch in releases\v0.1.0\; 'merged' always
    builds locally, because the host payload is not redistributed with this repo.

.PARAMETER HostPayload
    Path to a third-party `boot` payload Lua file. Required for -Build merged, ignored for -Build solo.

.PARAMETER Force
    Install even if the existing patch_0 looks like an unrelated mod (still backs it up).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\install.ps1
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [ValidateSet('solo', 'merged')]
    [string]$Build = 'solo',
    [string]$HostPayload,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$PatchName = '9ba626afa44a3aa3.patch_0'

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "[!] $msg" -ForegroundColor Yellow }
function Fail($msg) { Write-Host "[x] $msg" -ForegroundColor Red; exit 1 }

# ---------------------------------------------------------------- find the game
function Find-GamePath {
    $candidates = @()
    # 1) Steam registry
    foreach ($key in @('HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam')) {
        try {
            $v = Get-ItemProperty -Path $key -ErrorAction Stop
            if ($v.SteamPath) { $candidates += (Join-Path $v.SteamPath 'steamapps\common\Helldivers 2') }
            if ($v.InstallPath) { $candidates += (Join-Path $v.InstallPath 'steamapps\common\Helldivers 2') }
        } catch { }
    }
    # 2) libraryfolders.vdf for extra libraries
    $steamRoots = @()
    try { $steamRoots += (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath } catch { }
    try { $steamRoots += (Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam' -ErrorAction Stop).InstallPath } catch { }
    foreach ($root in $steamRoots) {
        if (-not $root) { continue }
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        if (Test-Path $vdf) {
            foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $candidates += (Join-Path ($m.Groups[1].Value -replace '\\\\', '\') 'steamapps\common\Helldivers 2')
            }
        }
    }
    # 3) common defaults
    $candidates += 'D:\steam\steamapps\common\Helldivers 2'
    $candidates += 'C:\Program Files (x86)\Steam\steamapps\common\Helldivers 2'

    foreach ($c in $candidates) {
        if ($c -and (Test-Path (Join-Path $c 'bin\helldivers2.exe'))) { return (Resolve-Path $c).Path }
    }
    return $null
}

if (-not $GamePath) { $GamePath = Find-GamePath }
if (-not $GamePath) {
    Fail "Could not find HELLDIVERS 2. Re-run with -GamePath 'X:\path\to\Helldivers 2'."
}
if (-not (Test-Path (Join-Path $GamePath 'bin\helldivers2.exe'))) {
    Fail "'$GamePath' does not look like a HELLDIVERS 2 install (bin\helldivers2.exe missing)."
}
Write-Ok "game folder: $GamePath"

# ---------------------------------------------------------- make sure it is closed
$proc = Get-Process -Name 'helldivers2' -ErrorAction SilentlyContinue
if ($proc) { Fail "The game is running (PID $($proc.Id)). Close it completely, then run this again." }

# ---------------------------------------------------------------- locate the patch
$patch = $null
if ($Build -eq 'solo') {
    $patch = Join-Path $RepoRoot "releases\v0.1.0\$PatchName"
} else {
    # merged = loader appended after a third-party host payload. That payload is NOT
    # redistributed with this repo, so a merged build always happens locally.
    if (-not $HostPayload) {
        Fail "-Build merged needs -HostPayload 'X:\path\to\host_payload.lua' -- a third-party boot payload, which this repo does not ship. Use -Build solo for a normal install."
    }
    if (-not (Test-Path $HostPayload)) {
        Fail "host payload not found: $HostPayload"
    }
}

if (-not $patch -or -not (Test-Path $patch)) {
    Write-Warn2 "no prebuilt patch for build '$Build'; building from source..."
    $py = (Get-Command python -ErrorAction SilentlyContinue)
    if (-not $py) { Fail "No prebuilt patch and no python on PATH. Use -Build solo (the repo ships a prebuilt solo patch), or run loader\build_loader_patch.py manually." }
    $argList = @((Join-Path $RepoRoot 'loader\build_loader_patch.py'))
    if ($Build -eq 'solo') { $argList += '--solo' } else { $argList += @('--host-payload', $HostPayload) }
    & $py.Source @argList
    if ($LASTEXITCODE -ne 0) { Fail "build_loader_patch.py exited with code $LASTEXITCODE -- nothing was installed." }
    $built = Join-Path $RepoRoot 'loader\dist\9ba626afa44a3aa3.patch_0'
    if (-not (Test-Path $built)) { Fail "build did not produce '$built'." }
    $patch = $built
}
Write-Ok "patch: $patch ($((Get-Item $patch).Length) B)"

# ------------------------------------------------------------------- back up first
$dataDir = Join-Path $GamePath 'data'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path $dataDir "_loader-backup\$stamp"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$existing = Get-ChildItem -Path $dataDir -Filter "$PatchName*" -File -ErrorAction SilentlyContinue
if ($existing) {
    foreach ($f in $existing) { Copy-Item $f.FullName $backupDir -Force }
    Write-Ok "backed up $($existing.Count) file(s) -> $backupDir"
    $sha = (Get-FileHash (Join-Path $dataDir $PatchName) -Algorithm SHA256).Hash
    Set-Content -Path (Join-Path $backupDir 'BACKUP-INFO.txt') -Encoding UTF8 -Value @(
        "backed up : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
        "source    : $GamePath",
        "patch_0   : $sha",
        "files     : $($existing.Name -join ', ')"
    )
} else {
    Write-Warn2 "no existing $PatchName found (clean install); nothing to back up"
    Set-Content -Path (Join-Path $backupDir 'BACKUP-INFO.txt') -Encoding UTF8 -Value @(
        "backed up : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')",
        "source    : $GamePath",
        "note      : clean install, no patch_0 present before this install"
    )
}

if (-not $Force -and $existing) {
    $size = (Get-Item (Join-Path $dataDir $PatchName)).Length
    Write-Warn2 "existing patch_0 is $size B — it may be someone else's mod."
    Write-Warn2 "it has been backed up; use tools\rollback.ps1 to restore it."
    Write-Host    "    continuing in 3 s (Ctrl+C to abort)..." -ForegroundColor Yellow
    Start-Sleep -Seconds 3
}

# ----------------------------------------------------------------------- install
Copy-Item $patch (Join-Path $dataDir $PatchName) -Force
foreach ($side in @('.gpu_resources', '.stream')) {
    $s = "$patch$side"
    if (Test-Path $s) { Copy-Item $s (Join-Path $dataDir "$PatchName$side") -Force }
    else { Set-Content -Path (Join-Path $dataDir "$PatchName$side") -Value $null }
}

$installed = Get-ChildItem -Path $dataDir -Filter "$PatchName*" -File
Write-Ok "installed:"
foreach ($f in $installed) { Write-Host ("      {0,-42} {1,10:N0} B" -f $f.Name, $f.Length) }
Write-Host ("      patch_0 SHA256 = " + (Get-FileHash (Join-Path $dataDir $PatchName) -Algorithm SHA256).Hash)

# ------------------------------------------------------------------------ next steps
$modsDir = Join-Path $GamePath 'mods'
if (-not (Test-Path $modsDir)) { New-Item -ItemType Directory -Force -Path $modsDir | Out-Null }
if (-not (Test-Path (Join-Path $modsDir 'mods.txt'))) {
    Set-Content -Path (Join-Path $modsDir 'mods.txt') -Encoding ASCII -Value @(
        '# one mod dir name per line; lines starting with # are comments'
    )
    Write-Ok "created mods\mods.txt (empty)"
}

Write-Host ""
Write-Ok "done. Now:"
Write-Host "    1. start the game through Steam   ->  steam://rungameid/553850"
Write-Host "    2. after it reaches the title screen, open   $modsDir\loader.log"
Write-Host "       you should see '=== hd2 pure-lua loader start ===', the two '[host] ... hooked' lines"
Write-Host "       and '[boot] loaded N mod(s)'"
Write-Host "    3. add mods to   $modsDir\<name>\main.lua   and list them in   mods\mods.txt"
Write-Host ""
Write-Host "    roll back with:  powershell -ExecutionPolicy Bypass -File .\tools\rollback.ps1"
Write-Host "    smoke test:      powershell -ExecutionPolicy Bypass -File .\tools\smoke_test.ps1"
