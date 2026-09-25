<#
.SYNOPSIS
  Tempest 4000 (PC) Resolution List Fix - Windows patcher (no dependencies).

.DESCRIPTION
  Patches your own Tempest4000.exe so the launcher lists every resolution/refresh rate
  your display supports (1080p, 1440p, 4K ...) instead of stopping at the first 256
  modes the graphics driver reports.  A backup (Tempest4000.exe.orig) is kept.
  Only the two known Steam builds are patched (verified by SHA-256 and by the exact
  bytes at every patch site); anything else is refused untouched.
  Details: README.md and docs/TECHNICAL.md in the repository.

.EXAMPLE
  .\T4K-ResolutionFix.ps1                 # find the Steam install, patch Win10 + Win7-8 exes
  .\T4K-ResolutionFix.ps1 -Check          # report state only
  .\T4K-ResolutionFix.ps1 -Restore        # put the backups back
  .\T4K-ResolutionFix.ps1 "C:\...\Tempest 4000\Win10\Tempest4000.exe" ["...\Win7-8\Tempest4000.exe"]
  .\T4K-ResolutionFix.ps1 -SetMode 3840x2160@60   # pre-select a mode in the prefs file (optional)
  .\T4K-ResolutionFix.ps1 -Exclusive             # keep the original exclusive-fullscreen mode switch
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Path,
    [switch]$Check,
    [switch]$Restore,
    [switch]$NoCave,
    [switch]$Exclusive,
    [string]$SetMode,
    [string]$Prefs
)
$ErrorActionPreference = 'Stop'
$Version = '1.0.0'

# ---- known builds: sha256 -> patch rows (file offset, original hex, patched hex) ---------------
# Row 0 = part A (2-byte cap fix), rows 1-2 = part B (hook + position-independent code cave),
# rows 3-4 = part C (default: never enter exclusive fullscreen, keeps Windows HDR on; -Exclusive omits it).
$Builds = @{
    '591fa01282c4a62eaed8583dac845c369d9330e7e5052e95856b80c8eba2fb1a' = @{
        Label = 'Steam Win10 build (2018-10-09)'
        Rows  = @(
            @(0x8e690, '81fe001c0000', '81f900010000'),
            @(0x8e6e5, '0f82f7010000', 'e97601020090'),
            @(0xae860, '000000000000000000000000000000000000000000000000000000000000000000000000000000', '0f827c00feffe800000000588b8031fffdff8b008b401cd1e839043e0f826000feffe964fefdff'),
            @(0x8fe9a, '01', '00'),
            @(0x8fecb, '01', '00')
        )
    }
    '411aa66ab702b21c4e0949e4049b486aeb88325786c3f6d14a853888058a9b9b' = @{
        Label = 'Steam Win7-8 build (2018-10-12)'
        Rows  = @(
            @(0x8e720, '81fe001c0000', '81f900010000'),
            @(0x8e775, '0f82f7010000', 'e97601020090'),
            @(0xae8f0, '000000000000000000000000000000000000000000000000000000000000000000000000000000', '0f827c00feffe800000000588b8031fffdff8b008b401cd1e839043e0f826000feffe964fefdff'),
            @(0x8ff2a, '01', '00'),
            @(0x8ff5b, '01', '00')
        )
    }
}

function ConvertFrom-Hex([string]$hex) {
    $b = New-Object byte[] ($hex.Length / 2)
    for ($i = 0; $i -lt $b.Length; $i++) { $b[$i] = [Convert]::ToByte($hex.Substring(2 * $i, 2), 16) }
    return ,$b
}
function Get-Sha256([byte[]]$data) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($data)) -replace '-', '').ToLower() } finally { $sha.Dispose() }
}
function Test-Bytes([byte[]]$data, [int]$off, [byte[]]$want) {
    if ($off + $want.Length -gt $data.Length) { return $false }
    for ($i = 0; $i -lt $want.Length; $i++) { if ($data[$off + $i] -ne $want[$i]) { return $false } }
    return $true
}
function Get-RowState([byte[]]$data, $row) {
    if (Test-Bytes $data $row[0] (ConvertFrom-Hex $row[1])) { return 'orig' }
    if (Test-Bytes $data $row[0] (ConvertFrom-Hex $row[2])) { return 'patched' }
    return 'unknown'
}
function Find-Build([byte[]]$data) {
    $h = Get-Sha256 $data
    if ($Builds.ContainsKey($h)) { return $Builds[$h] }
    # already patched (or A-only patched) files hash differently: identify by patch-site bytes
    foreach ($b in $Builds.Values) {
        $ok = $true
        foreach ($row in $b.Rows) { if ((Get-RowState $data $row) -eq 'unknown') { $ok = $false } }
        if ($ok) { return $b }
    }
    return $null
}

# ---- locating the game -----------------------------------------------------------------------
function Get-SteamLibraries {
    $roots = @()
    $isWin = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    if ($isWin) {
        foreach ($k in 'HKCU:\Software\Valve\Steam', 'HKLM:\SOFTWARE\WOW6432Node\Valve\Steam') {
            try {
                $p = Get-ItemProperty -Path $k -ErrorAction Stop
                if ($p.SteamPath) { $roots += ($p.SteamPath -replace '/', '\') }
                if ($p.InstallPath) { $roots += $p.InstallPath }
            } catch { }
        }
        $roots += 'C:\Program Files (x86)\Steam', 'C:\Program Files\Steam'
    }
    $libs = @()
    foreach ($r in $roots) {
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $libs += $r
        $vdf = Join-Path $r 'steamapps\libraryfolders.vdf'
        if (Test-Path -LiteralPath $vdf) {
            foreach ($m in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
                $libs += ($m.Groups[1].Value -replace '\\\\', '\')
            }
        }
    }
    return $libs | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -Unique
}
function Find-GameExes {
    $found = @()
    foreach ($lib in Get-SteamLibraries) {
        foreach ($sub in 'Win10', 'Win7-8') {
            $p = Join-Path $lib "steamapps\common\Tempest 4000\$sub\Tempest4000.exe"
            if (Test-Path -LiteralPath $p) { $found += $p }
        }
    }
    return $found
}

# ---- prefs file: pre-select a mode (CRC-16/XMODEM at 0x894 over the first 0x894 bytes) ----------
function Get-Crc16Xmodem([byte[]]$data, [int]$len) {
    $crc = 0
    for ($i = 0; $i -lt $len; $i++) {
        $crc = $crc -bxor ([int]$data[$i] -shl 8)
        for ($j = 0; $j -lt 8; $j++) {
            if ($crc -band 0x8000) { $crc = (($crc -shl 1) -bxor 0x1021) -band 0xffff } else { $crc = ($crc -shl 1) -band 0xffff }
        }
    }
    return $crc
}
function Set-PrefsMode([string]$prefsPath, [string]$spec) {
    $m = [regex]::Match($spec, '^\s*(\d+)\s*[xX]\s*(\d+)\s*@\s*(\d+(?:\.\d+)?)\s*(?:[Hh][Zz])?\s*$')
    if (-not $m.Success) { throw "mode must look like 3840x2160@60 (fractional refresh like 59.94 is fine)" }
    $w = [uint32]$m.Groups[1].Value; $h = [uint32]$m.Groups[2].Value; $hz = $m.Groups[3].Value
    if ($hz.Contains('.')) { $den = [uint32][math]::Pow(10, $hz.Split('.')[1].Length); $num = [uint32][math]::Round([double]$hz * $den) }
    else { $num = [uint32]$hz; $den = [uint32]1 }
    $d = [System.IO.File]::ReadAllBytes($prefsPath)
    $magic = [System.Text.Encoding]::ASCII.GetBytes('LE MAN SUL CUL!')
    if ($d.Length -ne 0x898 -or -not (Test-Bytes $d 0 $magic)) { throw "not a Tempest4000_UserPrefs.dat (size $($d.Length))" }
    $old = "{0}x{1} @ {2:g} Hz" -f [BitConverter]::ToUInt32($d, 0x818), [BitConverter]::ToUInt32($d, 0x81c), ([double][BitConverter]::ToUInt32($d, 0x820) / [math]::Max(1, [BitConverter]::ToUInt32($d, 0x824)))
    [Array]::Copy([BitConverter]::GetBytes($w), 0, $d, 0x818, 4)
    [Array]::Copy([BitConverter]::GetBytes($h), 0, $d, 0x81c, 4)
    [Array]::Copy([BitConverter]::GetBytes($num), 0, $d, 0x820, 4)
    [Array]::Copy([BitConverter]::GetBytes($den), 0, $d, 0x824, 4)
    $crc = Get-Crc16Xmodem $d 0x894
    [Array]::Copy([BitConverter]::GetBytes([uint32]$crc), 0, $d, 0x894, 4)
    if (-not (Test-Path -LiteralPath "$prefsPath.orig")) { Copy-Item -LiteralPath $prefsPath -Destination "$prefsPath.orig" }
    [System.IO.File]::WriteAllBytes($prefsPath, $d)
    Write-Host ("prefs: {0} -> {1}x{2} @ {3} Hz   ({4})" -f $old, $w, $h, $hz, $prefsPath)
}

# ---- main --------------------------------------------------------------------------------------
Write-Host "Tempest 4000 Resolution List Fix v$Version"
if ($SetMode) {
    $p = $Prefs
    if (-not $p) { $p = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'Tempest4000_Savedata\Tempest4000_UserPrefs.dat' }
    if (-not (Test-Path -LiteralPath $p)) { Write-Host "prefs file not found ($p) - launch the game once first, or pass -Prefs <path>"; exit 1 }
    Set-PrefsMode $p $SetMode
    exit 0
}

$exes = $Path
if (-not $exes) { $exes = Find-GameExes }
if (-not $exes) {
    Write-Host 'Tempest4000.exe not found automatically. Run again with:'
    Write-Host '  .\T4K-ResolutionFix.ps1 "C:\Program Files (x86)\Steam\steamapps\common\Tempest 4000\Win10\Tempest4000.exe"'
    exit 1
}
$rc = 0
foreach ($exe in $exes) {
    Write-Host "== $exe"
    try {
        $bak = "$exe.orig"
        if ($Restore) {
            if (-not (Test-Path -LiteralPath $bak)) { Write-Host "   no backup found ($bak). Use Steam > Verify integrity of game files."; $rc = 1; continue }
            Copy-Item -LiteralPath $bak -Destination $exe -Force
            Write-Host "   restored from $bak"; continue
        }
        $data = [System.IO.File]::ReadAllBytes($exe)
        $build = Find-Build $data
        if (-not $build) {
            Write-Host ("   unknown build (sha256 {0}) - not touching it. Please report this hash in a GitHub issue;" -f (Get-Sha256 $data))
            Write-Host "   the Python patcher (t4k_resfix.py --force) can locate the patch sites by code signature."
            $rc = 1; continue
        }
        $full = $build.Rows
        $rows = @(, $full[0])
        if (-not $NoCave) { $rows += , $full[1]; $rows += , $full[2] }
        if (-not $Exclusive) { $rows += , $full[3]; $rows += , $full[4] }
        function PartState($r) { $st = @($r | ForEach-Object { Get-RowState $data $_ } | Select-Object -Unique); if ($st.Count -eq 1) { return $st[0] } else { return 'unknown' } }
        $states = @(); foreach ($row in $rows) { $states += (Get-RowState $data $row) }
        Write-Host ("   build: {0}   state: A: {1}, B: {2}, C(borderless): {3}" -f $build.Label, (PartState @(, $full[0])), (PartState @($full[1], $full[2])), (PartState @($full[3], $full[4])))
        if ($Check) { continue }
        if ($states -contains 'unknown') { Write-Host "   unexpected bytes at a patch site - refusing to touch this file"; $rc = 1; continue }
        if (-not ($states -contains 'orig')) { Write-Host "   already patched - nothing to do"; continue }
        if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $exe -Destination $bak; Write-Host "   backup: $bak" }
        $n = 0
        for ($i = 0; $i -lt $rows.Count; $i++) {
            if ($states[$i] -ne 'orig') { continue }
            $new = ConvertFrom-Hex $rows[$i][2]
            [Array]::Copy($new, 0, $data, $rows[$i][0], $new.Length); $n += $new.Length
        }
        [System.IO.File]::WriteAllBytes($exe, $data)
        Write-Host ("   patched ({0} bytes changed). sha256: {1}" -f $n, (Get-Sha256 $data))
    } catch [System.UnauthorizedAccessException] {
        Write-Host "   access denied writing to the game folder - run this from an elevated (Administrator) prompt"; $rc = 1
    } catch {
        Write-Host "   error: $($_.Exception.Message)"; $rc = 1
    }
}
exit $rc
