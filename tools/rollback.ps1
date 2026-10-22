<#
.SYNOPSIS
    Restore a previously backed-up 9ba626afa44a3aa3.patch_0 into HELLDIVERS 2.

.DESCRIPTION
    Backups live in <game>\data\_loader-backup\<timestamp>\ and are created by tools\install.ps1.
    Without -Latest the script lists them and asks which one to restore.

.PARAMETER GamePath
    HELLDIVERS 2 install folder. Auto-detected when omitted.

.PARAMETER Latest
    Restore the newest backup without asking.

.PARAMETER List
    Only list backups, do not restore anything.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\rollback.ps1 -Latest
#>
[CmdletBinding()]
param(
    [string]$GamePath,
    [switch]$Latest,
    [switch]$List
)

$ErrorActionPreference = 'Stop'
$PatchName = '9ba626afa44a3aa3.patch_0'

function Write-Ok($m)   { Write-Host "[+] $m" -ForegroundColor Green }
function Write-Warn2($m){ Write-Host "[!] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "[x] $m" -ForegroundColor Red; exit 1 }

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
if (-not $GamePath) { Fail "Could not find HELLDIVERS 2. Pass -GamePath." }

$dataDir   = Join-Path $GamePath 'data'
$backupRoot = Join-Path $dataDir '_loader-backup'
if (-not (Test-Path $backupRoot)) { Fail "No backups found at $backupRoot" }

$backups = Get-ChildItem -Path $backupRoot -Directory | Sort-Object Name -Descending
if (-not $backups) { Fail "No backups found at $backupRoot" }

Write-Host "backups in $backupRoot :" -ForegroundColor Cyan
$i = 0
foreach ($b in $backups) {
    $i++
    $info = Join-Path $b.FullName 'BACKUP-INFO.txt'
    $note = ''
    if (Test-Path $info) {
        $lines = Get-Content $info
        $note = ($lines | Where-Object { $_ -match '^patch_0|^note' }) -join ' | '
    }
    $files = (Get-ChildItem $b.FullName -File | Where-Object { $_.Name -like "$PatchName*" }).Count
    Write-Host ("  [{0}] {1}   files={2}   {3}" -f $i, $b.Name, $files, $note)
}

if ($List) { return }

$chosen = $null
if ($Latest) {
    $chosen = $backups[0]
} else {
    $sel = Read-Host "restore which one? (1-$($backups.Count), Enter = newest, q = quit)"
    if ($sel -eq 'q') { return }
    if ([string]::IsNullOrWhiteSpace($sel)) { $chosen = $backups[0] }
    else {
        $n = 0
        if ([int]::TryParse($sel, [ref]$n) -and $n -ge 1 -and $n -le $backups.Count) { $chosen = $backups[$n - 1] }
    }
}
if (-not $chosen) { Fail "No backup selected." }

$proc = Get-Process -Name 'helldivers2' -ErrorAction SilentlyContinue
if ($proc) { Fail "The game is running (PID $($proc.Id)). Close it first." }

Write-Warn2 "restoring from $($chosen.FullName)"
$restored = Get-ChildItem -Path $chosen.FullName -File | Where-Object { $_.Name -like "$PatchName*" }
if (-not $restored) {
    # backup recorded a clean install: remove the loader's files instead
    Write-Warn2 "this backup has no patch_0 (clean install) -> removing installed files"
    foreach ($f in (Get-ChildItem -Path $dataDir -Filter "$PatchName*" -File -ErrorAction SilentlyContinue)) {
        Remove-Item $f.FullName -Force
        Write-Host "      removed $($f.Name)"
    }
    Write-Ok "game restored to clean state"
    return
}

# remove current files first so a partial backup cannot leave stale siblings behind
foreach ($f in (Get-ChildItem -Path $dataDir -Filter "$PatchName*" -File -ErrorAction SilentlyContinue)) {
    Remove-Item $f.FullName -Force
}
foreach ($f in $restored) {
    Copy-Item $f.FullName (Join-Path $dataDir $f.Name) -Force
    Write-Host ("      restored {0,-42} {1,10:N0} B" -f $f.Name, $f.Length)
}
Write-Ok ("patch_0 SHA256 = " + (Get-FileHash (Join-Path $dataDir $PatchName) -Algorithm SHA256).Hash)
Write-Ok "rollback complete"
