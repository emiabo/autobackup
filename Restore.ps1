<#
.SYNOPSIS
  AutoBackup restore for Windows. restore.sh is its macOS/Linux twin: keep flags, messages
  and behavior the same in both.

.DESCRIPTION
  Optional: every archive is a plain tar file that any archive tool opens (README.md, Restoring).
  This finds the newest version of an archive, joins chunked parts, picks the decompressor, and
  extracts into a scratch folder. It only reads drive_root and machine from the config, and both
  can be given as parameters, so it also works on a new machine before anything is set up.

  Runs on Windows PowerShell 5.1 and PowerShell 7.x. Keep this file ASCII-only:
  5.1 reads BOM-less scripts as ANSI.

.EXAMPLE
  .\Restore.ps1 -List
.EXAMPLE
  .\Restore.ps1 dotfiles
.EXAMPLE
  .\Restore.ps1 -Drive "$HOME\OneDrive\AutoBackup" -Machine MyPC -To ~ -Overwrite dotfiles
.EXAMPLE
  .\Restore.ps1 -All -To D:\restore
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # List archives instead of extracting. With names, list every version.
    [switch]$List,
    # Restore the newest version of every archive for this machine, each into its own folder
    [switch]$All,
    # Extract into this folder (default: a new folder per archive under ~\autobackup-restore).
    # With -All, it holds one folder per archive instead.
    [string]$To,
    # Replace files that already exist with the archive's copy. Without it, only missing files are added.
    [switch]$Overwrite,
    # Newest version from this time or earlier: 2026-09-27 or 2026-09-27_1305
    [string]$At,
    # Read each archive to the end to check it's intact; extract nothing
    [switch]$Verify,
    # Archives from this machine (default: machine in the config; '*' for any)
    [string]$Machine,
    # The AutoBackup folder in the sync folder (default: drive_root in the config)
    [string]$Drive,
    # Config to read drive_root and machine from
    [string]$Config,
    # Show what would be extracted where; change nothing
    [switch]$DryRun,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Names
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$script:Here = $PSScriptRoot
$script:Sep = [IO.Path]::DirectorySeparatorChar
$script:IsWin = ($script:Sep -eq '\')
$script:US = [string][char]0x1F
# Not $script:Machine, $script:Drive or $script:To: those are the -Machine, -Drive and -To parameters.
$script:MachineName = ''
$script:MPat = ''
$script:DriveDir = ''
$script:ToDir = ''
$script:Versions = @()
$script:TarZstd = $null
$script:TarGnu = $null
$script:OptAll = [bool]$All
$script:OptVerify = [bool]$Verify
$script:OptOverwrite = [bool]$Overwrite
$script:OptDry = [bool]$DryRun
# archive name, optional .tar.gz/.tar.zst, optional .001 part number
$script:ArchiveRx = '^(.+?)(\.tar|\.tar\.gz|\.tar\.zst)(\.\d{3,})?$'
$script:StampRx = '^(.+)_(\d{4}-\d{2}-\d{2}_\d{6})$'

if ($env:APPDATA) { $script:CfgPath = Join-Path $env:APPDATA 'AutoBackup\autobackup.ini' }
else { $script:CfgPath = Join-Path $HOME '.config/autobackup/autobackup.ini' }
if ($env:AUTOBACKUP_CONFIG) { $script:CfgPath = $env:AUTOBACKUP_CONFIG }
if ($env:AUTOBACKUP_TAR) {
    $script:Tar = $env:AUTOBACKUP_TAR
} elseif ($script:IsWin) {
    # Always the built-in bsdtar. Git for Windows puts GNU tar on PATH, which behaves differently.
    $script:Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
} else {
    $script:Tar = 'tar'
}

# ---------------------------------------------------------------- helpers

function Show-Usage {
    Say @'
Usage: Restore.ps1 [options] NAME ...
       Restore.ps1 [options] -All

Finds the newest version of each named archive in the AutoBackup drive folder and extracts it.
NAME is a job name, or a subfolder name for per_subfolder jobs: the part of the archive's file
name before _<machine>. It can also be the path to an archive file, or to its .001 part.
Files that already exist are kept; only missing files are added, unless -Overwrite.

Options:
  -List               List archives instead of extracting. With NAMEs, list every version.
  -All                Restore the newest version of every archive for this machine, each into
                      its own folder
  -To DIR             Extract into DIR. Default: a new folder per archive under
                      ~\autobackup-restore. Paths inside an archive are relative to its job's source,
                      so -To ~ puts files from a job with source = ~ back where they were.
                      With -All, DIR holds one folder per archive instead.
  -Overwrite          Replace files that already exist with the archive's copy
  -At WHEN            Newest version from WHEN or earlier: 2026-09-27 or 2026-09-27_1305
  -Verify             Read each archive to the end to check it's intact; extract nothing.
                      With no NAMEs, checks the newest version of every archive.
  -Machine NAME       Archives from this machine (default: machine in the config; '*' for any)
  -Drive DIR          The AutoBackup folder in the sync folder (default: drive_root in the config)
  -Config FILE        Config to read drive_root and machine from (default:
                      %APPDATA%\AutoBackup\autobackup.ini, or $env:AUTOBACKUP_CONFIG)
  -DryRun             Show what would be extracted where; change nothing
  -Help               Show this help

Examples:
  .\Restore.ps1 -List
  .\Restore.ps1 dotfiles
  .\Restore.ps1 -At 2026-09-01 obsidian
  .\Restore.ps1 -All -To D:\restore
  .\Restore.ps1 -Drive "$HOME\OneDrive\AutoBackup" -Machine MyPC -To ~ -Overwrite dotfiles
'@
}

function Say([string]$s) { [Console]::Out.WriteLine($s) }

function Warn([string]$s) { [Console]::Error.WriteLine($s) }

# Same as Get-Sanitized in AutoBackup.ps1.
function Get-Sanitized([string]$s) { return ($s -replace '[\x00-\x7F-[A-Za-z0-9._-]]+', '-').Trim('-') }

function Get-Unquoted([string]$v) {
    if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { return $Matches[1] }
    return $v
}

# ~ at the start, %ENVVARS%, {here} (this script's folder) and {machine} are expanded.
function Expand-Path([string]$p) {
    if ($p -eq '~') { $p = $HOME }
    elseif ($p -match '^~[\\/]') { $p = $HOME + $p.Substring(1) }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    $p = $p.Replace('{here}', $script:Here).Replace('{machine}', $script:MachineName)
    $p = $p.Replace('/', $script:Sep).Replace('\', $script:Sep)
    if ($p.Length -gt 1) { $p = $p.TrimEnd($script:Sep) }
    return $p
}

function Get-FullPath([string]$p) {
    return [IO.Path]::GetFullPath([IO.Path]::Combine((Get-Location -PSProvider FileSystem).ProviderPath, $p)).TrimEnd($script:Sep)
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return '{0:N1}G' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1}M' -f ($b / 1MB) }
    return '{0:N0}K' -f [Math]::Ceiling($b / 1KB)
}

# 2026-09-27_130512 -> 2026-09-27 13:05:12
function Format-Stamp([string]$s) {
    return $s.Substring(0, 10) + ' ' + $s.Substring(11, 2) + ':' + $s.Substring(13, 2) + ':' + $s.Substring(15, 2)
}

function Test-TarZstd {
    if ($null -eq $script:TarZstd) {
        $v = (& $script:Tar --version 2>$null) -join ' '
        $script:TarZstd = ($v -match 'zstd')
    }
    return $script:TarZstd
}

# tar's flag to leave existing files alone. GNU tar's own -k fails on each one instead.
function Get-TarKeepFlag {
    if ($null -eq $script:TarGnu) {
        $v = @(& $script:Tar --version 2>$null)
        $script:TarGnu = ($v.Count -gt 0 -and "$($v[0])" -match 'GNU tar')
    }
    if ($script:TarGnu) { return '--skip-old-files' }
    return '-k'
}

# Last value of KEY in [global] (or before any section) of the config.
function Get-CfgGlobal([string]$key) {
    $sec = 'global'
    $out = ''
    foreach ($raw in [IO.File]::ReadAllLines($script:CfgPath)) {
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $sec = $line.Substring(1, $line.Length - 2).Trim()
        } elseif ($sec -eq 'global' -and $line.Contains('=')) {
            $i = $line.IndexOf('=')
            if ($line.Substring(0, $i).Trim().ToLowerInvariant() -eq $key) { $out = Get-Unquoted $line.Substring($i + 1).Trim() }
        }
    }
    return $out
}

# ---------------------------------------------------------------- versions

# The files that make up version V, in order: the whole file, or its .001, .002 ... parts.
# When both exist (a job that started or stopped chunking), the newer one wins. $null when a
# part is missing.
function Get-VersionFiles([string]$v) {
    $leaf = Split-Path -Leaf $v
    $rx = '^' + [regex]::Escape($leaf) + '\.\d{3,}$'
    $n = @(Get-ChildItem -LiteralPath (Split-Path -Parent $v) -File -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match $rx }).Count
    $whole = Get-Item -LiteralPath $v -Force -ErrorAction SilentlyContinue
    $first = Get-Item -LiteralPath "$v.001" -Force -ErrorAction SilentlyContinue
    if ($whole -and ($n -eq 0 -or -not $first -or $whole.LastWriteTimeUtc -ge $first.LastWriteTimeUtc)) { return , @($whole) }
    $files = @()
    for ($i = 1; $i -le $n; $i++) {
        $p = Get-Item -LiteralPath ($v + '.' + $i.ToString('000')) -Force -ErrorAction SilentlyContinue
        if (-not $p) {
            Warn "$($leaf): part $leaf.$($i.ToString('000')) is missing (still syncing?)"
            return $null
        }
        $files += $p
    }
    if ($n -eq 0) { return $null }
    return , $files
}

function Get-FilesSize($files) {
    $total = [long]0
    foreach ($f in $files) { $total += $f.Length }
    return $total
}

# V (an archive path without any part suffix) -> BASE<US>STAMP<US>V. BASE is NAME_MACHINE.
# Archives without a timestamp in their name (keep = 1) get their file's modification time.
function Get-VersionRecord([string]$v) {
    if ((Split-Path -Leaf $v) -notmatch $script:ArchiveRx) { return $null }
    $stem = $Matches[1]
    if ($stem -match $script:StampRx) {
        $base = $Matches[1]
        $stamp = $Matches[2]
    } else {
        $base = $stem
        $f = Get-Item -LiteralPath $v -Force -ErrorAction SilentlyContinue
        if (-not $f) { $f = Get-Item -LiteralPath "$v.001" -Force }
        $stamp = $f.LastWriteTime.ToString('yyyy-MM-dd_HHmmss')
    }
    return ($base + $script:US + $stamp + $script:US + $v)
}

# Every archive version under the drive folder, one record each, by name and then oldest first.
function Get-AllVersions {
    $seen = @{}
    $recs = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ChildItem -LiteralPath $script:DriveDir -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name.StartsWith('.') -or $f.Name -notmatch $script:ArchiveRx) { continue }
        $v = Join-Path $f.DirectoryName ($Matches[1] + $Matches[2])
        if ($seen.ContainsKey($v)) { continue }
        $seen[$v] = $true
        $r = Get-VersionRecord $v
        if ($r) { $recs.Add($r) }
    }
    $arr = $recs.ToArray()
    [Array]::Sort($arr, [StringComparer]::Ordinal)
    return , $arr
}

function Get-RecBase([string]$r) { return $r.Split([char]0x1F)[0] }
function Get-RecStamp([string]$r) { return $r.Split([char]0x1F)[1] }
function Get-RecPath([string]$r) { return $r.Split([char]0x1F)[2] }

function Get-AllBases {
    [string[]]$b = @($script:Versions | ForEach-Object { Get-RecBase $_ } | Select-Object -Unique)
    [Array]::Sort($b, [StringComparer]::Ordinal)
    return , $b
}

# Archive names (NAME_MACHINE) for NAME: the archive name itself if it exists, else NAME_<machine>.
function Get-MatchBases([string]$name) {
    $all = Get-AllBases
    if ($all -ccontains $name) { return , @($name) }
    $pat = [WildcardPattern]::Escape((Get-Sanitized $name)) + '_' + $script:MPat
    return , @($all | Where-Object { $_ -clike $pat })
}

# Newest version record of BASE, at or before -At when given.
function Get-PickedVersion([string]$base) {
    $out = $null
    foreach ($r in $script:Versions) {
        if ((Get-RecBase $r) -cne $base) { continue }
        if ($script:AtLimit -and [long]((Get-RecStamp $r) -replace '[_-]', '') -gt $script:AtLimit) { continue }
        $out = $r
    }
    return $out
}

# ---------------------------------------------------------------- extracting

# Why an archive with extension EXT can't be read here, if it can't.
function Get-MissingTool([string]$ext) {
    if ($ext -eq '.tar.zst' -and -not (Test-TarZstd) -and -not (Get-Command zstd -ErrorAction SilentlyContinue)) {
        if ($script:IsWin) { return 'needs zstd (winget install -e --id Meta.Zstandard)' }
        return "needs zstd (macOS: brew install zstd; Linux: your distro's zstd package)"
    }
    return ''
}

# Runs a native command. Its stderr goes to our stderr; its stdout (tar -t's listing) is dropped.
function Invoke-Quiet([string]$exe, [string[]]$argList) {
    $global:LASTEXITCODE = 0
    & $exe @argList 2>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { $s = "$_".Trim(); if ($s) { Warn $s } }
    }
    return ($LASTEXITCODE -eq 0)
}

# Joins the parts into one temp file, decompresses zstd first when tar can't, then runs tar.
# Two steps on purpose, like AutoBackup.ps1: piping into tar on Windows is unreliable.
function Invoke-Unpack([string]$ext, $files, [string[]]$tarArgs) {
    $tmp = @()
    try {
        $src = $files[0].FullName
        if ($files.Count -gt 1) {
            $src = Join-Path ([IO.Path]::GetTempPath()) ('autobackup-restore-' + [guid]::NewGuid().ToString('N') + $ext)
            $tmp += $src
            $out = [IO.File]::Create($src)
            try {
                foreach ($f in $files) {
                    $in = [IO.File]::OpenRead($f.FullName)
                    try { $in.CopyTo($out) } finally { $in.Dispose() }
                }
            } finally { $out.Dispose() }
        }
        if ($ext -eq '.tar.zst' -and -not (Test-TarZstd)) {
            $raw = Join-Path ([IO.Path]::GetTempPath()) ('autobackup-restore-' + [guid]::NewGuid().ToString('N') + '.tar')
            $tmp += $raw
            if (-not (Invoke-Quiet (Get-Command zstd).Source @('-d', '-q', '-f', $src, '-o', $raw))) { return $false }
            $src = $raw
        }
        return (Invoke-Quiet $script:Tar ($tarArgs + @('-f', $src)))
    } finally {
        foreach ($t in $tmp) { Remove-Item -LiteralPath $t -Force -ErrorAction SilentlyContinue }
    }
}

# One archive version: verify it, or extract it. Returns $false on failure.
function Invoke-RestoreOne([string]$r) {
    $base = Get-RecBase $r
    $stamp = Get-RecStamp $r
    $v = Get-RecPath $r
    [void]((Split-Path -Leaf $v) -match $script:ArchiveRx)
    $ext = $Matches[2]
    $files = Get-VersionFiles $v
    if ($null -eq $files) { return $false }
    $desc = "$base ($(Format-Stamp $stamp), $(Format-Size (Get-FilesSize $files))"
    if ($files.Count -gt 1) { $desc += ", $($files.Count) parts" }
    $desc += ')'
    $why = Get-MissingTool $ext
    if ($why) { Warn "$($desc): $why"; return $false }

    if ($script:OptVerify) {
        if ($script:OptDry) { Say "Would verify $desc"; return $true }
        if (Invoke-Unpack $ext $files @('-t')) { Say "ok      $desc"; return $true }
        Warn "FAILED  $($desc): $v"
        return $false
    }

    if ($script:ToDir -and -not $script:OptAll) { $dir = $script:ToDir } else { $dir = Join-Path $script:Parent ($base + '_' + $stamp) }
    $dir = Get-FullPath $dir
    $cmp = [StringComparison]::Ordinal
    if ($script:IsWin) { $cmp = [StringComparison]::OrdinalIgnoreCase }
    if (($dir + $script:Sep).StartsWith($script:DriveDir + $script:Sep, $cmp)) {
        Warn "$($desc): won't extract into the drive folder ($dir); the sync app would upload it"
        return $false
    }
    $xargs = @('-x', '-C', $dir)
    if ($script:OptOverwrite) {
        $how = ' (replacing files already there)'
    } else {
        $xargs += Get-TarKeepFlag
        $how = ' (keeping files already there)'
    }
    # Only worth saying when there's something there.
    if (-not ((Test-Path -LiteralPath $dir -PathType Container) -and
            @(Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1).Count -gt 0)) { $how = '' }
    if ($script:OptDry) { Say "Would restore $desc into $dir$how"; return $true }
    Say "Restoring $desc into $dir$how"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not (Invoke-Unpack $ext $files $xargs)) {
        Warn "Extracting $v failed; $dir may be incomplete."
        return $false
    }
    return $true
}

# ---------------------------------------------------------------- commands

function Get-RelPath([string]$p) {
    if ($p.StartsWith($script:DriveDir + $script:Sep)) { return $p.Substring($script:DriveDir.Length + 1) }
    return $p
}

# One line per archive (newest version), or with NAMEs one line per version.
function Show-List([string[]]$picked) {
    if ($picked.Count -gt 0) {
        Say ('{0,-32} {1,-19} {2,8}  {3}' -f 'ARCHIVE', 'VERSION', 'SIZE', 'FILE')
        foreach ($r in $picked) {
            $files = Get-VersionFiles (Get-RecPath $r) 2>$null
            Say ('{0,-32} {1,-19} {2,8}  {3}' -f (Get-RecBase $r), (Format-Stamp (Get-RecStamp $r)),
                (Format-Size (Get-FilesSize $files)), (Get-RelPath (Get-RecPath $r)))
        }
        return
    }
    Say ('{0,-32} {1,-19} {2,8} {3,8}  {4}' -f 'ARCHIVE', 'NEWEST', 'VERSIONS', 'SIZE', 'FOLDER')
    foreach ($b in (Get-AllBases)) {
        if ($b -notlike ('*_' + $script:MPat)) { continue }
        $vs = @($script:Versions | Where-Object { (Get-RecBase $_) -ceq $b })
        $r = $vs[$vs.Count - 1]
        $files = Get-VersionFiles (Get-RecPath $r) 2>$null
        $rel = Get-RelPath (Split-Path -Parent (Get-RecPath $r))
        if ($rel -eq $script:DriveDir) { $rel = '.' }
        Say ('{0,-32} {1,-19} {2,8} {3,8}  {4}' -f $b, (Format-Stamp (Get-RecStamp $r)), $vs.Count,
            (Format-Size (Get-FilesSize $files)), $rel)
    }
}

# ---------------------------------------------------------------- main

if ($Help) { Show-Usage; exit 0 }
$bad = @($Names | Where-Object { $_ -like '-*' })
if ($bad.Count -gt 0) {
    Warn "Unknown option: $($bad[0])"
    Show-Usage
    exit 2
}
if ($Config) { $script:CfgPath = Expand-Path $Config }
if ($To) { $script:ToDir = Expand-Path $To }
if ($All -and $Names.Count -gt 0) {
    Warn 'Use -All or NAMEs, not both.'
    exit 2
}
# Where per-archive folders go: ~\autobackup-restore, or -To with -All.
$script:Parent = Join-Path $HOME 'autobackup-restore'
if ($All -and $script:ToDir) { $script:Parent = Get-FullPath $script:ToDir }

$script:AtLimit = $null
if ($At) {
    if ($At -notmatch '^\d{4}-\d{2}-\d{2}(_\d{2}(\d{2}(\d{2})?)?)?$') {
        Warn "-At wants a date like 2026-09-27 or 2026-09-27_1305, got: $At"
        exit 2
    }
    # Round up to the end of the day, hour or minute given.
    $full = $At
    switch ($At.Length) {
        10 { $full = $At + '_235959' }
        13 { $full = $At + '5959' }
        15 { $full = $At + '59' }
    }
    $script:AtLimit = [long]($full -replace '[_-]', '')
}

if (Test-Path -LiteralPath $script:CfgPath -PathType Leaf) {
    $script:MachineName = Get-CfgGlobal 'machine'
    if (-not $Drive) {
        $d = Get-CfgGlobal 'drive_root'
        if ($d) { $script:DriveDir = Expand-Path $d }
    }
} elseif ($Config) {
    Warn "Config not found: $script:CfgPath"
    exit 1
}
if ($Machine) { $script:MachineName = $Machine; $script:MPat = $Machine }
elseif ($script:MachineName) { $script:MPat = [WildcardPattern]::Escape($script:MachineName) }
else { $script:MPat = '*' }
if ($Drive) { $script:DriveDir = Expand-Path $Drive }
if (-not $script:DriveDir) {
    Warn "No AutoBackup folder: pass -Drive DIR (the AutoBackup folder in your sync folder), or set drive_root in $script:CfgPath."
    exit 1
}
if (-not (Test-Path -LiteralPath $script:DriveDir -PathType Container)) {
    Warn "AutoBackup folder not found: $script:DriveDir"
    exit 1
}
$script:DriveDir = (Get-FullPath (Get-Item -LiteralPath $script:DriveDir -Force).FullName)

$showList = [bool]$List
$failAfterList = $false
if ($Names.Count -eq 0 -and -not $List -and -not $Verify -and -not $All) {
    Warn 'Name what to restore. Available archives:'
    $showList = $true
    $failAfterList = $true
}

$script:Versions = Get-AllVersions

# Resolve every NAME to one archive version before touching anything.
$picked = @()
$failed = $false
foreach ($name in $Names) {
    $leaf = Split-Path -Leaf $name
    if ($name -match '[\\/]' -or ($leaf -match $script:ArchiveRx -and (Test-Path -LiteralPath $name -PathType Leaf))) {
        if (-not (Test-Path -LiteralPath $name)) { Warn "No such file: $name"; $failed = $true; continue }
        if ($leaf -notmatch $script:ArchiveRx) { Warn "Not an archive: $name"; $failed = $true; continue }
        $v = Join-Path (Split-Path -Parent (Get-FullPath $name)) ($Matches[1] + $Matches[2])
        $rec = Get-VersionRecord $v
        if ($showList) {
            $b = Get-RecBase $rec
            $picked += @($script:Versions | Where-Object { (Get-RecBase $_) -ceq $b })
        } else {
            $picked += $rec
        }
        continue
    }
    $bases = Get-MatchBases $name
    if ($bases.Count -eq 0) {
        Warn "No archive named '$name' for machine '$script:MPat' in $script:DriveDir (see -List)."
        $failed = $true
        continue
    }
    if ($bases.Count -gt 1) {
        Warn "'$name' matches more than one archive: $($bases -join ' '). Name one of those, or pass -Machine."
        $failed = $true
        continue
    }
    if ($showList) {
        $picked += @($script:Versions | Where-Object { (Get-RecBase $_) -ceq $bases[0] })
    } else {
        $r = Get-PickedVersion $bases[0]
        if ($r) { $picked += $r }
        else { Warn "No version of $($bases[0]) from $At or earlier."; $failed = $true }
    }
}
if ($failed) { exit 1 }

if ($showList) {
    if ($failAfterList) {
        # The list goes to stderr here, like any other usage error.
        $old = [Console]::Out
        [Console]::SetOut([Console]::Error)
        try { Show-List $picked } finally { [Console]::SetOut($old) }
        exit 2
    }
    Show-List $picked
    exit 0
}

# -All, or -Verify with no NAMEs: the newest version of every archive for this machine.
# With -At, archives that didn't exist yet are left out.
if ($picked.Count -eq 0) {
    foreach ($b in (Get-AllBases)) {
        if ($b -notlike ('*_' + $script:MPat)) { continue }
        $r = Get-PickedVersion $b
        if ($r) { $picked += $r }
    }
    if ($picked.Count -eq 0) { Warn "No archives for machine '$script:MPat' in $script:DriveDir."; exit 1 }
}

$nfail = 0
foreach ($r in $picked) {
    if (-not (Invoke-RestoreOne $r)) { $nfail++ }
}
if ($nfail -gt 0) {
    Warn "$nfail of $($picked.Count) failed."
    exit 1
}
if (-not $Verify -and -not $DryRun -and (-not $script:ToDir -or $All)) {
    Say "Done. Nothing in place was changed: copy back what you need from $script:Parent."
}
exit 0
