<#
.SYNOPSIS
  AutoBackup for Windows. autobackup.sh is its macOS/Linux twin: keep flags, config keys,
  log messages and file layout the same in both.

.DESCRIPTION
  Reads jobs from an INI-style config (see README.md), archives each job's folders with tar,
  and moves the archives into a cloud-sync folder. Safe to run often: each job only runs
  when its `every` interval has elapsed, and skips when nothing changed.

  Runs on Windows PowerShell 5.1 and PowerShell 7.x. Keep this file ASCII-only:
  5.1 reads BOM-less scripts as ANSI.

.EXAMPLE
  .\AutoBackup.ps1 -List
.EXAMPLE
  .\AutoBackup.ps1 -Only minecraft -DryRun -Verbose
.EXAMPLE
  .\AutoBackup.ps1 -Add notes root=~/Notes dest=Documents/Notes every=1d
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Config file (default: %APPDATA%\AutoBackup\autobackup.ini, or $env:AUTOBACKUP_CONFIG)
    [string]$Config,
    # Run only these jobs, even if not due. Skip-if-unchanged still applies.
    [string[]]$Only,
    # Ignore schedule and skip-if-unchanged checks
    [switch]$Force,
    # Show what would happen; change nothing
    [switch]$DryRun,
    # List jobs, last run, and whether each is due
    [switch]$List,
    # Append a job: -Add [JOB] [key=value ...]. With no key=value pairs, prompts interactively.
    [switch]$Add,
    # Open the config in $env:EDITOR (or Notepad), creating it from the template first
    [switch]$Edit,
    # Register the hourly + at-logon scheduled task
    [switch]$Install,
    # Remove the scheduled task. Config, state and archives are kept.
    [switch]$Uninstall,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$script:VerboseOn = $PSBoundParameters.ContainsKey('Verbose')
$VerbosePreference = 'SilentlyContinue'   # we print our own debug lines; keep cmdlets quiet

$script:Here = $PSScriptRoot
$script:Self = $PSCommandPath
$script:Sep = [IO.Path]::DirectorySeparatorChar
$script:IsWin = ($script:Sep -eq '\')
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:Cfg = New-Object System.Collections.ArrayList
$script:Machine = ''
$script:State = ''
$script:Staging = ''
$script:Drive = ''
$script:TarZstd = $null
$script:UInc = @()
$script:UExc = @()
$script:J = @{}
$script:OptForce = [bool]$Force
$script:OptDry = [bool]$DryRun
$script:OptOnly = @()
$script:TaskName = 'AutoBackup'

if ($env:APPDATA) { $script:CfgPath = Join-Path $env:APPDATA 'AutoBackup\autobackup.ini' }
else { $script:CfgPath = Join-Path $HOME '.config/autobackup/autobackup.ini' }
if ($env:AUTOBACKUP_CONFIG) { $script:CfgPath = $env:AUTOBACKUP_CONFIG }
$script:Template = Join-Path (Join-Path $script:Here 'templates') 'windows.ini'
# Known folders and what to back up in them. AUTOBACKUP_PRESETS points elsewhere (the tests use it).
$script:Presets = Join-Path $script:Here 'presets.ini'
if ($env:AUTOBACKUP_PRESETS) { $script:Presets = $env:AUTOBACKUP_PRESETS }
if ($env:AUTOBACKUP_TAR) {
    $script:Tar = $env:AUTOBACKUP_TAR
} elseif ($script:IsWin) {
    # Always the built-in bsdtar. Git for Windows puts GNU tar on PATH, which behaves differently.
    $script:Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
} else {
    $script:Tar = 'tar'
}

# tar reads -T file lists in the ANSI code page on Windows.
$script:ListEnc = $script:Utf8
if ($script:IsWin) {
    try { $script:ListEnc = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.ANSICodePage) } catch { }
}

# ---------------------------------------------------------------- helpers

function Show-Usage {
    Say @'
Usage: AutoBackup.ps1 [options]

Runs every job in the config that is due. Meant to be called hourly by Task Scheduler.

Options:
  -Config FILE        Config file (default: %APPDATA%\AutoBackup\autobackup.ini,
                      or $env:AUTOBACKUP_CONFIG)
  -Only JOB[,JOB]     Run only these jobs, even if not due.
                      The skip-if-unchanged check still applies.
  -Force              Ignore schedule and skip-if-unchanged checks
  -DryRun             Show what would happen; change nothing
  -List               List jobs, last run, and whether each is due
  -Add [JOB] [key=value ...]
                      Append a job to the config. With no key=value pairs,
                      prompts interactively.
  -Edit               Open the config in $env:EDITOR or Notepad (creates it from the template first)
  -Install            Run hourly and at logon (Task Scheduler)
  -Uninstall          Remove that task. Config, state and archives are kept.
  -Verbose            Also print skipped/not-due details
  -Help               Show this help

Examples:
  .\AutoBackup.ps1 -Only minecraft
  .\AutoBackup.ps1 -List
  .\AutoBackup.ps1 -Only dotfiles -DryRun -Verbose
  .\AutoBackup.ps1 -Add notes root=~/Notes dest=Documents/Notes every=1d
'@
}

function Write-Log([string]$Level, [string]$Msg) {
    $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " [$Level] $Msg"
    # Console writes, not Write-Output: functions below return $true/$false, and pipeline output would pollute that.
    if ($Level -eq 'ERROR') { [Console]::Error.WriteLine($line) } else { [Console]::Out.WriteLine($line) }
    if (-not $script:OptDry -and $script:State -and (Test-Path -LiteralPath $script:State)) {
        [IO.File]::AppendAllText((Join-Path $script:State 'autobackup.log'), $line + [Environment]::NewLine, $script:Utf8)
    }
}

function Write-VLog([string]$Msg) {
    if ($script:VerboseOn) { [Console]::Out.WriteLine((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " [DEBUG] $Msg") }
}

function Say([string]$s) { [Console]::Out.WriteLine($s) }

function Test-True([string]$v) { return ("$v".Trim() -match '^(?i)(1|y|yes|true|on)$') }

function Get-Sanitized([string]$s) { return ($s -replace '[^A-Za-z0-9._-]+', '-').Trim('-') }

# ~ at the start, %ENVVARS%, {here} (this script's folder) and {machine} are expanded.
function Expand-Value([string]$p) {
    if ($p -eq '~') { $p = $HOME }
    elseif ($p -match '^~[\\/]') { $p = $HOME + $p.Substring(1) }
    $p = [Environment]::ExpandEnvironmentVariables($p)
    $p = $p.Replace('{here}', $script:Here).Replace('{machine}', $script:Machine)
    return $p
}

function ConvertTo-NativePath([string]$p) {
    $p = $p.Replace('/', $script:Sep).Replace('\', $script:Sep)
    if ($p.Length -gt 1) { $p = $p.TrimEnd($script:Sep) }   # a trailing \ breaks 5.1 native arg quoting
    return $p
}

function Expand-Path([string]$p) { return (ConvertTo-NativePath (Expand-Value $p)) }

# "30m", "12h", "1d", "2w", "90s"; bare number = hours. Returns $null when invalid.
function Get-DurSecs([string]$d) {
    if ($d -notmatch '^\s*(\d+)\s*([smhdw]?)\s*$') { return $null }
    $n = [long]$Matches[1]
    switch ($Matches[2]) {
        's' { return $n }
        'm' { return $n * 60 }
        'd' { return $n * 86400 }
        'w' { return $n * 604800 }
        default { return $n * 3600 }
    }
}

# "500M", "4G", "1T" (binary units, trailing B optional) -> bytes. Returns $null when invalid.
function Get-SizeBytes([string]$s) {
    if ($s -notmatch '^\s*(\d+)\s*([KMGT])B?\s*$') { return $null }
    $n = [long]$Matches[1]
    switch ($Matches[2].ToUpper()) {
        'K' { return $n * 1KB }
        'M' { return $n * 1MB }
        'G' { return $n * 1GB }
        'T' { return $n * 1TB }
    }
}

function Format-Size([long]$b) {
    if ($b -ge 1GB) { return '{0:N1}G' -f ($b / 1GB) }
    if ($b -ge 1MB) { return '{0:N1}M' -f ($b / 1MB) }
    return '{0:N0}K' -f [Math]::Ceiling($b / 1KB)
}

function Get-MTime([string]$f) { return (Get-Item -LiteralPath $f -Force).LastWriteTimeUtc }

function Get-AgeSecs([string]$f) { return ([DateTime]::UtcNow - (Get-MTime $f)).TotalSeconds }

# A native Windows toast. Windows PowerShell 5.1 can load the WinRT types directly; PowerShell 7
# can't, so it hands the same code to powershell.exe.
$script:ToastCode = @'
param([string]$Text)
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
$xml.LoadXml('<toast><visual><binding template="ToastGeneric"><text>AutoBackup</text><text>' + [Security.SecurityElement]::Escape($Text) + '</text></binding></visual></toast>')
$app = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($app).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
'@

# AUTOBACKUP_NOTIFY=0 turns notifications off (the test suite uses it).
function Send-Notify([string]$msg) {
    if (-not $script:IsWin -or $env:AUTOBACKUP_NOTIFY -eq '0') { return }
    try {
        if ($PSVersionTable.PSEdition -ne 'Core') {
            & ([scriptblock]::Create($script:ToastCode)) $msg
        } else {
            $cmd = '& {' + $script:ToastCode + "} '" + $msg.Replace("'", "''") + "'"
            $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
            $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            & $ps -NoProfile -NonInteractive -EncodedCommand $enc | Out-Null
        }
    } catch { }
}

# Runs a native command, logs its output (stderr included), returns $true on exit code 0.
function Invoke-Native([string]$exe, [string[]]$argList, [string]$key) {
    $global:LASTEXITCODE = 0
    $out = & $exe @argList 2>&1
    $code = $LASTEXITCODE
    foreach ($l in $out) {
        $s = "$l".Trim()
        if ($s) { Write-Log 'WARN' "[$key] $(Split-Path -Leaf $exe): $s" }
    }
    return ($code -eq 0)
}

# ---------------------------------------------------------------- config

# Every key the config understands. Anything else gets a warning and is ignored.
$script:Keys = @('drive_root', 'machine', 'state', 'staging', 'review_every', 'root', 'dest', 'include', 'exclude',
    'gitignore', 'compress', 'level', 'every', 'per_subfolder', 'keep', 'keep_max_size', 'chunk_size', 'alert_after',
    'skip_if_running', 'pre', 'enabled', 'preset')

# Strips one pair of matching surrounding quotes: "x" or 'x' -> x.
function Get-Unquoted([string]$v) {
    if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { return $Matches[1] }
    return $v
}

# Parses an INI file into $script:Cfg records {Sec, Key, Val}, appended to what's already there.
# Keys before any [section] belong to "global". Keys are case-insensitive. $prefix goes in front
# of every section name: presets.ini loads as "preset:NAME", so presets never look like jobs.
function Import-Cfg([string]$file, [string]$prefix = '') {
    $sec = $prefix + 'global'
    $name = Split-Path -Leaf $file
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($file)) {
        $n++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $sec = $prefix + $line.Substring(1, $line.Length - 2).Trim()
        } elseif ($line.Contains('=')) {
            $i = $line.IndexOf('=')
            $k = $line.Substring(0, $i).Trim().ToLower()
            $v = $line.Substring($i + 1).Trim()
            if ($script:Keys -notcontains $k) { Write-Log 'WARN' "$name line ${n}: unknown key '$k' ignored"; continue }
            # pre is a shell command: its quotes and # mean something there.
            if ($k -ne 'pre') {
                $v = Get-Unquoted $v
                if ($v -match '\s[#;]') { Write-Log 'WARN' "$name line ${n}: '$v' is used as-is; comments only work on their own line" }
            }
            [void]$script:Cfg.Add([pscustomobject]@{ Sec = $sec; Key = $k; Val = $v })
        } else {
            Write-Log 'WARN' "$name line $n ignored: $line"
        }
    }
}

# All values of key in section, in file order. Always wrap calls in @().
function Get-CfgVals([string]$sec, [string]$key) {
    foreach ($r in $script:Cfg) { if ($r.Sec -ceq $sec -and $r.Key -eq $key) { $r.Val } }
}

# Comma-separated items -> trimmed, non-empty items. Always wrap calls in @().
function Get-ListItems([string[]]$lists) {
    foreach ($l in $lists) { foreach ($p in ("$l" -split ',')) { if ($p.Trim()) { $p.Trim() } } }
}

# The presets a job uses, in the order listed. Always wrap calls in @().
function Get-JobPresets([string]$job) { Get-ListItems @(Get-CfgVals $job 'preset') }

# The last value any of the given presets sets for key, or ''.
function Get-PresetsLast([string[]]$presets, [string]$key) {
    $out = ''
    foreach ($p in $presets) {
        $v = @(Get-CfgVals "preset:$p" $key)
        if ($v.Count -gt 0 -and $v[-1]) { $out = $v[-1] }
    }
    return $out
}

# Last value of key in the section; else from the job's presets (the last one listed wins);
# else from [global]; else the default.
function Get-Cfg([string]$sec, [string]$key, [string]$def = '') {
    $v = @(Get-CfgVals $sec $key)
    if ($v.Count -gt 0 -and $v[-1]) { return $v[-1] }
    if ($sec -ne 'global') {
        $pv = Get-PresetsLast @(Get-JobPresets $sec) $key
        if ($pv) { return $pv }
    }
    $v = @(Get-CfgVals 'global' $key)
    if ($v.Count -gt 0 -and $v[-1]) { return $v[-1] }
    return $def
}

# All values of a list key (include, exclude) for a job: its presets' first, then its own.
function Get-JobVals([string]$job, [string]$key) {
    foreach ($p in @(Get-JobPresets $job)) { Get-CfgVals "preset:$p" $key }
    Get-CfgVals $job $key
}

function Get-CfgJobs {
    $seen = New-Object System.Collections.ArrayList
    foreach ($r in $script:Cfg) {
        if ($r.Sec -ne 'global' -and -not $r.Sec.StartsWith('preset:') -and -not $seen.Contains($r.Sec)) { [void]$seen.Add($r.Sec) }
    }
    return , $seen.ToArray()
}

function Get-PresetNames {
    $seen = New-Object System.Collections.ArrayList
    foreach ($r in $script:Cfg) {
        if ($r.Sec.StartsWith('preset:') -and $r.Sec -ne 'preset:global') {
            $p = $r.Sec.Substring(7)
            if (-not $seen.Contains($p)) { [void]$seen.Add($p) }
        }
    }
    return , $seen.ToArray()
}

# The given names that presets.ini doesn't define. Always wrap calls in @().
function Get-UnknownPresets([string[]]$names) {
    $known = Get-PresetNames
    foreach ($p in $names) { if ($known -notcontains $p) { $p } }
}

# Creates the config from templates\windows.ini if it doesn't exist yet.
function New-CfgFromTemplate {
    if (Test-Path -LiteralPath $script:CfgPath -PathType Leaf) { return $true }
    if (-not (Test-Path -LiteralPath $script:Template -PathType Leaf)) {
        [Console]::Error.WriteLine("Config not found: $script:CfgPath (and no template at $script:Template)")
        return $false
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:CfgPath) | Out-Null
    Copy-Item -LiteralPath $script:Template -Destination $script:CfgPath
    Say "Created $script:CfgPath from $script:Template"
    return $true
}

# ---------------------------------------------------------------- state

# A job is due when its .checked stamp is older than `every` (or missing).
# The stamp is touched after every successful pass, including "unchanged" skips.
function Test-JobDue([string]$job, [string]$every) {
    $f = Join-Path (Join-Path $script:State 'stamps') "$job.checked"
    if (-not (Test-Path -LiteralPath $f)) { return $true }
    $secs = Get-DurSecs $every
    if ($null -eq $secs) { Write-Log 'WARN' "[$job] bad every='$every', using 1d"; $secs = 86400 }
    return ((Get-AgeSecs $f) -ge $secs)
}

# A job is stale when its last successful pass (or, if it never had one, the first run that saw it)
# is older than alert_after. Default: 3x every, at least 1 day. alert_after = 0 turns this off.
function Test-JobStale([string]$job) {
    $sd = Join-Path $script:State 'stamps'
    $f = Join-Path $sd "$job.checked"
    if (-not (Test-Path -LiteralPath $f)) { $f = Join-Path $sd "$job.added" }
    if (-not (Test-Path -LiteralPath $f)) { return $false }
    $limit = $null
    $v = Get-Cfg $job 'alert_after'
    if ($v) { $limit = Get-DurSecs $v }
    if ($null -eq $limit) {
        $secs = Get-DurSecs (Get-Cfg $job 'every' '1d')
        if ($null -eq $secs) { $secs = 86400 }
        $limit = [Math]::Max($secs * 3, 86400)
    }
    if ($limit -le 0) { return $false }
    return ((Get-AgeSecs $f) -ge $limit)
}

function Get-RunningName([string]$list) {
    foreach ($p in ($list -split ',')) {
        $p = $p.Trim()
        if ($p.ToLower().EndsWith('.exe')) { $p = $p.Substring(0, $p.Length - 4) }
        if ($p -and (Get-Process -Name $p -ErrorAction SilentlyContinue)) { return $p }
    }
    return $null
}

function Set-Stamp([string]$f) {
    if (Test-Path -LiteralPath $f) { (Get-Item -LiteralPath $f).LastWriteTimeUtc = [DateTime]::UtcNow }
    else { [IO.File]::WriteAllText($f, '', $script:Utf8) }
}

# The final move into the sync folder is only atomic when staging is on the same volume.
function Show-SameVolumeWarning {
    $a = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($script:Staging))
    $b = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($script:Drive))
    if ($a -and $b -and $a -ne $b) {
        Say "Warning: staging ($script:Staging) is on a different drive than drive_root."
        Say "         Set 'staging' in [global] to a folder on the same drive, so the sync app never sees half-written files."
    }
}

# ---------------------------------------------------------------- compression

function Test-TarZstd {
    if ($null -eq $script:TarZstd) {
        $v = (& $script:Tar --version 2>$null) -join ' '
        $script:TarZstd = ($v -match 'zstd')
    }
    return $script:TarZstd
}

# Config value -> concrete method. zstd prefers the zstd CLI (multithreaded),
# then tar's built-in zstd, then falls back to gzip.
function Resolve-Method([string]$mode) {
    switch ($mode) {
        { $_ -in 'zstd', 'zst' } {
            if (Get-Command zstd -ErrorAction SilentlyContinue) { return 'zstd-ext' }
            if (Test-TarZstd) { return 'zstd-native' }
            return 'gzip'
        }
        { $_ -in 'gzip', 'gz' } { return 'gzip' }
        { $_ -in 'none', 'tar' } { return 'none' }
        'copy' { return 'copy' }
    }
    return $null
}

function Get-MethodExt([string]$method) {
    switch ($method) {
        'zstd-ext' { return '.tar.zst' }
        'zstd-native' { return '.tar.zst' }
        'gzip' { return '.tar.gz' }
        'none' { return '.tar' }
    }
}

# Two-step tar-then-zstd on purpose: piping tar into zstd on Windows can hang on large inputs.
function Invoke-BuildArchive([string]$method, [string]$level, [string]$out, [string]$root, [string[]]$rest, [string]$key) {
    $base = @('-c', '-C', $root)
    switch ($method) {
        'zstd-ext' {
            $raw = "$out.part.tar"
            if (-not (Invoke-Native $script:Tar ($base + @('-f', $raw) + $rest) $key)) {
                Remove-Item -LiteralPath $raw -Force -ErrorAction SilentlyContinue
                return $false
            }
            $zstd = (Get-Command zstd).Source
            if (-not (Invoke-Native $zstd @('-q', '-T0', "-$level", '-f', '--rm', '-o', $out, $raw) $key)) {
                Remove-Item -LiteralPath $raw, $out -Force -ErrorAction SilentlyContinue
                return $false
            }
            return $true
        }
        'zstd-native' { return (Invoke-Native $script:Tar ($base + @('-f', $out, '--zstd', '--options', "zstd:compression-level=$level") + $rest) $key) }
        'gzip' { return (Invoke-Native $script:Tar ($base + @('-f', $out, '-z', '--options', "gzip:compression-level=$level") + $rest) $key) }
        'none' { return (Invoke-Native $script:Tar ($base + @('-f', $out) + $rest) $key) }
    }
    return $false
}

# Cuts PATH into PATH.001, PATH.002 ... of at most SIZE bytes each, deletes PATH, returns the count.
function Split-Archive([string]$path, [long]$size) {
    $n = 0
    $buf = New-Object byte[] (4MB)
    $in = [IO.File]::OpenRead($path)
    try {
        while ($in.Position -lt $in.Length) {
            $n++
            $out = [IO.File]::Create($path + '.' + $n.ToString('000'))
            try {
                $left = $size
                while ($left -gt 0) {
                    $r = $in.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $left))
                    if ($r -le 0) { break }
                    $out.Write($buf, 0, $r)
                    $left -= $r
                }
            } finally { $out.Dispose() }
        }
    } finally { $in.Dispose() }
    Remove-Item -LiteralPath $path -Force
    return $n
}

# ---------------------------------------------------------------- versions

# The archive versions of one unit, oldest first: the path each version's file(s) share, without
# any .001 part suffix. KEEP=1 has one fixed name; KEEP>1 names carry a timestamp.
function Get-UnitVersions([string]$destdir, [string]$base, [string]$ext, [int]$keep) {
    if (-not (Test-Path -LiteralPath $destdir -PathType Container)) { return }
    if ($keep -le 1) {
        $t = Join-Path $destdir ($base + $ext)
        if ((Test-Path -LiteralPath $t) -or (Test-Path -LiteralPath "$t.001")) { $t }
        return
    }
    $rx = '^' + [regex]::Escape($base) + '_\d{4}-\d{2}-\d{2}_\d{6}' + [regex]::Escape($ext) + '(\.\d{3,})?$'
    Get-ChildItem -LiteralPath $destdir -File -Force | Where-Object { $_.Name -match $rx } |
        ForEach-Object { Join-Path $destdir ($_.Name -replace '\.\d{3,}$', '') } | Sort-Object -Unique
}

# The whole file and/or the .NNN parts of one version.
function Get-VersionFiles([string]$v) {
    $rx = '^' + [regex]::Escape((Split-Path -Leaf $v)) + '(\.\d{3,})?$'
    Get-ChildItem -LiteralPath (Split-Path -Parent $v) -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rx }
}

function Get-VersionSize([string]$v) {
    $total = [long]0
    foreach ($f in @(Get-VersionFiles $v)) { $total += $f.Length }
    return $total
}

function Remove-Version([string]$v) {
    foreach ($f in @(Get-VersionFiles $v)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue }
}

# After replacing a fixed-name archive with N parts (0 = one whole file), delete leftovers
# from the previous build: the whole file if now chunked, and parts beyond N.
function Remove-StaleParts([string]$t, [int]$n) {
    $leaf = Split-Path -Leaf $t
    foreach ($f in @(Get-VersionFiles $t)) {
        if ($f.Name -eq $leaf) { if ($n -gt 0) { Remove-Item -LiteralPath $f.FullName -Force } }
        elseif ([int]($f.Name.Substring($leaf.Length + 1)) -gt $n) { Remove-Item -LiteralPath $f.FullName -Force }
    }
}

# Keeps the newest KEEP versions, fewer if their total size would pass MAX bytes. The newest
# version is always kept.
function Invoke-PruneVersions([string]$key, [string]$destdir, [string]$base, [string]$ext, [int]$keep, $max) {
    $vs = @(Get-UnitVersions $destdir $base $ext $keep)
    $kept = 0
    $total = [long]0
    $pruning = $false
    for ($i = $vs.Count - 1; $i -ge 0; $i--) {
        $v = $vs[$i]
        $sz = Get-VersionSize $v
        if (-not $pruning -and ($kept -eq 0 -or ($kept -lt $keep -and ($null -eq $max -or ($total + $sz) -le $max)))) {
            $kept++
            $total += $sz
        } else {
            $pruning = $true
            Remove-Version $v
            Write-Log 'INFO' "[$key] removed old version $(Split-Path -Leaf $v)"
        }
    }
}

# ---------------------------------------------------------------- .gitignore

# Repos to read through git for include folder FULL: FULL itself when it's inside a repo,
# plus every repo nested below it.
function Get-Repos([string]$full) {
    $p = $full
    while ($p) {
        if (Test-Path -LiteralPath (Join-Path $p '.git')) { $full; break }
        $p = Split-Path -Parent $p
    }
    Get-ChildItem -LiteralPath $full -Recurse -Force -Filter '.git' -ErrorAction SilentlyContinue |
        ForEach-Object { Split-Path -Parent $_.FullName } | Where-Object { $_ -ne $full }
}

# Everything under FULL, as paths starting with REL, skipping folders in the SKIP set.
function Add-TreeEntries($list, [string]$full, [string]$rel, $skip) {
    [void]$list.Add($rel)
    foreach ($c in @(Get-ChildItem -LiteralPath $full -Force -ErrorAction SilentlyContinue)) {
        $crel = $rel + '/' + $c.Name
        if ($c.PSIsContainer -and -not ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            if ($skip -and $skip.Contains($c.FullName)) { continue }
            Add-TreeEntries $list $c.FullName $crel $skip
        } else {
            [void]$list.Add($crel)
        }
    }
}

# A repo's files: tracked and untracked but not ignored, per git's own rules (every .gitignore,
# .git/info/exclude and the global excludes file), plus the .git folder itself so unpushed
# commits are kept. Falls back to the whole folder if git fails there.
function Add-RepoEntries($list, [string]$full, [string]$rel, [string]$key) {
    [void]$list.Add($rel)
    $prev = $null
    try { $prev = [Console]::OutputEncoding; [Console]::OutputEncoding = $script:Utf8 } catch { }
    $global:LASTEXITCODE = 0
    $raw = & git -C $full ls-files -z --cached --others --exclude-standard 2>$null
    $code = $LASTEXITCODE
    try { if ($prev) { [Console]::OutputEncoding = $prev } } catch { }
    if ($code -ne 0) {
        Write-Log 'WARN' "[$key] git ls-files failed in $full; archiving that folder whole"
        Add-TreeEntries $list $full $rel $null
        return
    }
    foreach ($f in ((@($raw) -join "`n") -split "`0")) {
        if (-not $f) { continue }
        # Tracked files deleted from the working tree are still listed by git.
        $p = Join-Path $full $f
        if ([IO.File]::Exists($p) -or [IO.Directory]::Exists($p)) { [void]$list.Add($rel + '/' + $f.TrimEnd('/')) }
    }
    $g = Join-Path $full '.git'
    if (Test-Path -LiteralPath $g) { Add-TreeEntries $list $g ($rel + '/.git') $null }
}

# Writes the tar input list for a unit that contains git repos. Returns $false when there are
# no repos, so the caller archives the includes normally. tar's own excludes still apply.
function Write-FileList([string]$key, [string]$uroot, [string]$out, [string[]]$incs) {
    if (-not (Get-Command git -ErrorAction SilentlyContinue)) { return $false }
    $list = New-Object System.Collections.ArrayList
    $any = $false
    foreach ($i in $incs) {
        $full = [IO.Path]::GetFullPath((Join-Path $uroot (ConvertTo-NativePath $i)))
        $item = Get-Item -LiteralPath $full -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { [void]$list.Add($i); continue }
        $repos = @(Get-Repos $full)
        if ($repos.Count -eq 0) { Add-TreeEntries $list $full $i $null; continue }
        $any = $true
        if ($repos[0] -ne $full) {
            $set = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            foreach ($r in $repos) { [void]$set.Add($r) }
            Add-TreeEntries $list $full $i $set
        }
        foreach ($r in $repos) { Add-RepoEntries $list $r ($i + $r.Substring($full.Length).Replace('\', '/')) $key }
    }
    if (-not $any) { return $false }
    [IO.File]::WriteAllText($out, (($list -join "`0") + "`0"), $script:ListEnc)
    return $true
}

# ---------------------------------------------------------------- jobs

# Uses $script:UInc (paths relative to root), $script:UExc (tar patterns) and the per-job
# settings in $script:J. Returns $true on success.
function Invoke-ArchiveUnit([string]$key, [string]$uname, [string]$uroot) {
    $J = $script:J
    $base = (Get-Sanitized $uname) + '_' + $script:Machine
    $ext = Get-MethodExt $J.Method
    $stampDir = Join-Path $script:State 'stamps'
    $stamp = Join-Path $stampDir "$key.last"

    $incs = @()
    foreach ($i in $script:UInc) {
        $i = $i.Replace('\', '/')
        if (Test-Path -LiteralPath (Join-Path $uroot (ConvertTo-NativePath $i))) { $incs += $i }
        else { Write-VLog "[$key] include not found, skipped: $i" }
    }
    if ($incs.Count -eq 0) {
        Write-Log 'WARN' "[$key] nothing to archive under $uroot"
        return $true
    }

    # The descriptor records what produced the archive; editing the job forces a rebuild.
    $desc = @("root=$uroot", "method=$($J.Method)", "level=$($J.Level)", "chunk=$($J.Chunk)", "gitignore=$($J.Git)")
    foreach ($i in $incs) { $desc += "include=$i" }
    foreach ($e in $script:UExc) { $desc += "exclude=$e" }
    $descText = $desc -join "`n"

    if (-not $script:OptForce -and (Test-Path -LiteralPath $stamp) -and
        @(Get-UnitVersions $J.DestDir $base $ext $J.Keep).Count -gt 0) {
        if ($descText -eq ([IO.File]::ReadAllText($stamp, $script:Utf8).TrimEnd())) {
            $since = Get-MTime $stamp
            $hit = $null
            # Conservative: excluded and git-ignored files count too, so this can rebuild
            # needlessly but never miss a change.
            foreach ($i in $incs) {
                $p = Join-Path $uroot (ConvertTo-NativePath $i)
                $item = Get-Item -LiteralPath $p -Force
                if ($item.LastWriteTimeUtc -gt $since) { $hit = $p; break }
                if ($item.PSIsContainer) {
                    $h = Get-ChildItem -LiteralPath $p -Recurse -Force -ErrorAction SilentlyContinue |
                        Where-Object { $_.LastWriteTimeUtc -gt $since } | Select-Object -First 1
                    if ($h) { $hit = $h.FullName; break }
                }
            }
            if (-not $hit) {
                Write-VLog "[$key] unchanged, skipped"
                return $true
            }
            Write-VLog "[$key] changed: $hit"
        }
    }

    $fname = $base + $ext
    if ($J.Keep -gt 1) { $fname = $base + '_' + (Get-Date -Format 'yyyy-MM-dd_HHmmss') + $ext }
    $target = Join-Path $J.DestDir $fname

    if ($script:OptDry) {
        Write-Log 'INFO' "[$key] would write $target ($($J.Method), from ${uroot}: $($incs -join ', '))"
        return $true
    }

    New-Item -ItemType Directory -Force -Path $script:Staging, $stampDir | Out-Null
    try { New-Item -ItemType Directory -Force -Path $J.DestDir -ErrorAction Stop | Out-Null }
    catch { Write-Log 'ERROR' "[$key] cannot create $($J.DestDir)"; return $false }
    $pending = Join-Path $stampDir "$key.pending"
    [IO.File]::WriteAllText($pending, $descText + "`n", $script:Utf8)
    $tmp = Join-Path $script:Staging $fname
    $listf = Join-Path $script:Staging "$key.list"
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $script:Staging -Filter "$fname.*" -Force | Remove-Item -Force -ErrorAction SilentlyContinue

    $targs = @()
    foreach ($e in $script:UExc) { $targs += @('--exclude', $e.Replace('\', '/')) }
    if ((Test-True $J.Git) -and (Write-FileList $key $uroot $listf $incs)) {
        Write-VLog "[$key] git repos found; using .gitignore rules"
        $targs += @('--no-recursion', '--null', '-T', $listf)
    } else {
        $targs += '--'   # tar end-of-options marker, then the include paths
        $targs += $incs
    }

    $t0 = [DateTime]::UtcNow
    $ok = Invoke-BuildArchive $J.Method $J.Level $tmp $uroot $targs $key
    Remove-Item -LiteralPath $listf -Force -ErrorAction SilentlyContinue
    if (-not $ok) {
        Remove-Item -LiteralPath $tmp, $pending -Force -ErrorAction SilentlyContinue
        Write-Log 'ERROR' "[$key] archiving failed for $uroot"
        return $false
    }

    # Same volume as the sync folder, so each move is a rename: the sync client never sees a
    # partial file. With chunking, parts land one by one.
    $nparts = 0
    try {
        if ($J.Chunk) {
            $nparts = Split-Archive $tmp $J.Chunk
            for ($k = 1; $k -le $nparts; $k++) {
                $sfx = '.' + $k.ToString('000')
                Move-Item -LiteralPath ($tmp + $sfx) -Destination ($target + $sfx) -Force -ErrorAction Stop
            }
        } else {
            Move-Item -LiteralPath $tmp -Destination $target -Force -ErrorAction Stop
        }
    } catch {
        Get-ChildItem -LiteralPath $script:Staging -Filter "$fname*" -Force | Remove-Item -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue
        Write-Log 'ERROR' "[$key] could not move archive to ${target}: $($_.Exception.Message)"
        return $false
    }
    Move-Item -LiteralPath $pending -Destination $stamp -Force
    if ($J.Keep -le 1) { Remove-StaleParts $target $nparts }

    $shown = $target
    if ($nparts -gt 0) { $shown = $target + '.001-' + $nparts.ToString('000') }
    Write-Log 'INFO' "[$key] wrote $shown ($(Format-Size (Get-VersionSize $target)), $([int]([DateTime]::UtcNow - $t0).TotalSeconds)s)"
    if ($J.Keep -gt 1) { Invoke-PruneVersions $key $J.DestDir $base $ext $J.Keep $J.KeepMax }
    return $true
}

# copy mode: flat copy of the files directly inside root, renamed NAME_MACHINE.ext.
# Only changed files are copied.
function Invoke-CopyFiles([string]$key, [string]$root, [string]$destdir) {
    $ok = $true
    $files = Get-ChildItem -LiteralPath $root -File -Force | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name
    foreach ($f in $files) {
        $skip = $false
        foreach ($e in $script:UExc) { if ($f.Name -like $e) { $skip = $true } }
        if ($skip) { continue }
        $tname = (Get-Sanitized ([IO.Path]::GetFileNameWithoutExtension($f.Name))) + '_' + $script:Machine + [IO.Path]::GetExtension($f.Name)
        $tgt = Join-Path $destdir $tname
        if (Test-Path -LiteralPath $tgt) {
            $old = Get-Item -LiteralPath $tgt
            if ($old.Length -eq $f.Length -and (Get-FileHash -LiteralPath $tgt).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) {
                Write-VLog "[$key] unchanged: $tname"
                continue
            }
        }
        if ($script:OptDry) { Write-Log 'INFO' "[$key] would copy $($f.Name) -> $tgt"; continue }
        try {
            New-Item -ItemType Directory -Force -Path $destdir, $script:Staging -ErrorAction Stop | Out-Null
            $st = Join-Path $script:Staging $tname
            Copy-Item -LiteralPath $f.FullName -Destination $st -Force -ErrorAction Stop
            Move-Item -LiteralPath $st -Destination $tgt -Force -ErrorAction Stop
            Write-Log 'INFO' "[$key] updated $tgt"
        } catch {
            Write-Log 'ERROR' "[$key] could not copy $($f.FullName): $($_.Exception.Message)"
            $ok = $false
        }
    }
    return $ok
}

function Invoke-Job([string]$job) {
    if (-not (Test-True (Get-Cfg $job 'enabled' 'true'))) { Write-VLog "[$job] disabled"; return $true }
    $bad = @(Get-UnknownPresets @(Get-JobPresets $job))
    if ($bad.Count -gt 0) {
        Write-Log 'ERROR' "[$job] unknown preset: $($bad -join ', ') (known: $((Get-PresetNames) -join ', '))"
        return $false
    }
    $rootRaw = Get-Cfg $job 'root'
    $dest = (Get-Cfg $job 'dest').Trim('/', '\')
    if (-not $rootRaw -or -not $dest) { Write-Log 'ERROR' "[$job] needs both root and dest"; return $false }
    $root = Expand-Path $rootRaw
    $mode = (Get-Cfg $job 'compress' 'zstd').ToLower()
    $method = Resolve-Method $mode
    if (-not $method) { Write-Log 'ERROR' "[$job] unknown compress '$mode' (use zstd, gzip, none or copy)"; return $false }
    $level = Get-Cfg $job 'level'
    if (-not $level) { if ($method -eq 'gzip') { $level = '6' } else { $level = '3' } }
    $keepRaw = Get-Cfg $job 'keep' '1'
    if ($keepRaw -notmatch '^\d+$' -or [int]$keepRaw -lt 1) { Write-Log 'ERROR' "[$job] keep must be a whole number, 1 or more"; return $false }
    $keepMax = $null
    $v = Get-Cfg $job 'keep_max_size'
    if ($v) {
        $keepMax = Get-SizeBytes $v
        if ($null -eq $keepMax) { Write-Log 'ERROR' "[$job] bad keep_max_size '$v' (use e.g. 500M, 20G)"; return $false }
    }
    $chunk = ''
    $v = Get-Cfg $job 'chunk_size'
    if ($v) {
        $chunk = Get-SizeBytes $v
        if ($null -eq $chunk) { Write-Log 'ERROR' "[$job] bad chunk_size '$v' (use e.g. 500M, 4G)"; return $false }
    }
    $script:J = @{
        Method = $method; Level = $level; Keep = [int]$keepRaw; KeepMax = $keepMax; Chunk = $chunk
        Git = (Get-Cfg $job 'gitignore' 'true')
        DestDir = (Join-Path $script:Drive (ConvertTo-NativePath $dest))
    }
    $every = Get-Cfg $job 'every' '1d'

    $ignoreDue = $script:OptForce -or ($script:OptOnly.Count -gt 0)
    if (-not $ignoreDue -and -not (Test-JobDue $job $every)) { Write-VLog "[$job] not due (every $every)"; return $true }

    $running = Get-RunningName (Get-Cfg $job 'skip_if_running')
    if ($running) { Write-Log 'INFO' "[$job] skipped: $running is running; will retry next run"; return $true }

    $pre = @(Get-CfgVals $job 'pre')
    $preCmd = ''
    if ($pre.Count -gt 0 -and $pre[-1]) {
        $preCmd = Expand-Value $pre[-1]
        if ($script:OptDry) {
            Write-Log 'INFO' "[$job] would run pre: $preCmd"
        } else {
            $preOk = $true
            try {
                $global:LASTEXITCODE = 0
                Invoke-Expression $preCmd | ForEach-Object { Write-VLog "[$job] pre: $_" }
                if ($LASTEXITCODE -ne 0) { $preOk = $false }
            } catch { $preOk = $false }
            if (-not $preOk) { Write-Log 'ERROR' "[$job] pre command failed: $preCmd"; return $false }
        }
    }

    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        if ($script:OptDry -and $preCmd) { Write-Log 'INFO' "[$job] root $root does not exist yet (pre would create it)"; return $true }
        Write-Log 'ERROR' "[$job] root folder not found: $root"
        return $false
    }

    $script:UExc = @(Get-CfgVals 'global' 'exclude') + @(Get-JobVals $job 'exclude')
    $ok = $true

    if ($method -eq 'copy') {
        if (-not (Invoke-CopyFiles $job $root $script:J.DestDir)) { $ok = $false }
    } elseif (Test-True (Get-Cfg $job 'per_subfolder' 'false')) {
        # One archive per immediate subfolder (e.g. one per Prism instance).
        $found = $false
        $subs = Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name
        foreach ($d in $subs) {
            $skip = $false
            foreach ($e in $script:UExc) { if ($d.Name -like $e) { $skip = $true } }
            if ($skip) { continue }
            $found = $true
            $script:UInc = @('.')
            if (-not (Invoke-ArchiveUnit ("$job@" + (Get-Sanitized $d.Name)) $d.Name $d.FullName)) { $ok = $false }
        }
        if (-not $found) { Write-Log 'WARN' "[$job] per_subfolder = true but no subfolders in $root" }
    } else {
        $script:UInc = @(Get-JobVals $job 'include')
        if ($script:UInc.Count -eq 0) { $script:UInc = @('.') }
        if (-not (Invoke-ArchiveUnit $job $job $root)) { $ok = $false }
    }

    if ($ok -and -not $script:OptDry) {
        $sd = Join-Path $script:State 'stamps'
        New-Item -ItemType Directory -Force -Path $sd | Out-Null
        Set-Stamp (Join-Path $sd "$job.checked")
    }
    return $ok
}

# Once a day at most: warn about jobs with no recent successful backup. Every review_every
# (default 90d, 0 = off): remind you to check the job list still covers what you need.
# Editing the config resets the reminder.
function Invoke-Alerts {
    $sd = Join-Path $script:State 'stamps'
    New-Item -ItemType Directory -Force -Path $sd | Out-Null
    $stale = @()
    foreach ($job in (Get-CfgJobs)) {
        if (-not (Test-True (Get-Cfg $job 'enabled' 'true'))) { continue }
        $added = Join-Path $sd "$job.added"
        if (-not (Test-Path -LiteralPath (Join-Path $sd "$job.checked")) -and -not (Test-Path -LiteralPath $added)) { Set-Stamp $added }
        if (Test-JobStale $job) { $stale += $job }
    }
    $n = Join-Path $sd 'stale.notified'
    if ($stale.Count -gt 0 -and (-not (Test-Path -LiteralPath $n) -or (Get-AgeSecs $n) -ge 86400)) {
        Write-Log 'WARN' "no successful backup in a while: $($stale -join ', ')"
        Send-Notify "No recent backup: $($stale -join ', '). See autobackup.log."
        Set-Stamp $n
    }

    $secs = Get-DurSecs (Get-Cfg 'global' 'review_every' '90d')
    if (-not $secs) { return }
    $n = Join-Path $sd 'review.notified'
    $last = Get-MTime $script:CfgPath
    if ((Test-Path -LiteralPath $n) -and (Get-MTime $n) -gt $last) { $last = Get-MTime $n }
    if (([DateTime]::UtcNow - $last).TotalSeconds -ge $secs) {
        Write-Log 'INFO' 'review reminder: check the job list still matches what you need backed up'
        Send-Notify 'Time to review your backup list: AutoBackup.ps1 -List, then -Edit.'
        Set-Stamp $n
    }
}

# ---------------------------------------------------------------- commands

function Show-List {
    $fmt = '{0,-18} {1,-5} {2,-6} {3,-26} {4,-16} {5}'
    Say ($fmt -f 'JOB', 'MODE', 'EVERY', 'DEST', 'LAST RUN', 'STATUS')
    foreach ($job in (Get-CfgJobs)) {
        $f = Join-Path (Join-Path $script:State 'stamps') "$job.checked"
        $last = 'never'
        if (Test-Path -LiteralPath $f) { $last = (Get-Item -LiteralPath $f).LastWriteTime.ToString('yyyy-MM-dd HH:mm') }
        $st = 'ok'
        if (-not (Test-True (Get-Cfg $job 'enabled' 'true'))) { $st = 'disabled' }
        elseif (Test-JobStale $job) { $st = 'stale' }
        elseif (Test-JobDue $job (Get-Cfg $job 'every' '1d')) { $st = 'due' }
        Say ($fmt -f $job, (Get-Cfg $job 'compress' 'zstd'), (Get-Cfg $job 'every' '1d'), (Get-Cfg $job 'dest'), $last, $st)
    }
    Say ''
    Say "Config:     $script:CfgPath"
    Say "Drive root: $script:Drive"
    Say "Log:        $(Join-Path $script:State 'autobackup.log')"
    Show-SameVolumeWarning
}

# Presets that cover folder $path or something inside it, and exist on this machine. Only presets
# rooted at ~ match, by their include paths. Always wrap calls in @().
function Get-PresetsFor([string]$path) {
    $full = Expand-Path $path
    $home_ = ConvertTo-NativePath $HOME
    if (-not $full.StartsWith($home_ + $script:Sep, [StringComparison]::OrdinalIgnoreCase)) { return }
    $rel = $full.Substring($home_.Length + 1).Replace('\', '/')
    foreach ($p in (Get-PresetNames)) {
        if ((Get-PresetsLast @($p) 'root') -ne '~') { continue }
        foreach ($i in @(Get-CfgVals "preset:$p" 'include')) {
            if ($i -ne $rel -and -not $i.StartsWith("$rel/", [StringComparison]::OrdinalIgnoreCase)) { continue }
            if (Test-Path -LiteralPath (Join-Path $HOME (ConvertTo-NativePath $i))) { $p; break }
        }
    }
}

function Test-AddName([string]$name) {
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { [Console]::Error.WriteLine("Invalid job name: '$name'"); return $false }
    if ((Get-CfgJobs) -contains $name) { [Console]::Error.WriteLine("Job [$name] already exists in $script:CfgPath. Edit it there (-Edit)."); return $false }
    return $true
}

# The default an interactive -Add prompt shows: from the chosen presets, else [global].
function Get-AddDefault([string[]]$presets, [string]$key, [string]$def = '') {
    $v = Get-PresetsLast $presets $key
    if ($v) { return $v }
    return (Get-Cfg 'global' $key $def)
}

function Add-Job([string[]]$argv) {
    $argv = @($argv | Where-Object { $_ })
    $name = ''
    $pairs = @()
    if ($argv.Count -gt 0) { $name = $argv[0]; if ($argv.Count -gt 1) { $pairs = $argv[1..($argv.Count - 1)] } }
    if ($name -and -not (Test-AddName $name)) { return $false }
    $root = ''; $dest = ''; $presets = @()
    $lines = @()
    foreach ($p in $pairs) {
        if ($p -notmatch '^[A-Za-z_]+=') { [Console]::Error.WriteLine("Expected key=value, got: $p"); return $false }
        $i = $p.IndexOf('=')
        $k = $p.Substring(0, $i); $v = $p.Substring($i + 1)
        switch ($k) {
            'root' { $root = $v }
            'dest' { $dest = $v }
            'preset' { $presets = @(Get-ListItems @($v)) }
            default { $lines += "$k = $v" }
        }
    }
    $bad = @(Get-UnknownPresets $presets)
    if ($bad.Count -gt 0) {
        [Console]::Error.WriteLine("Unknown preset: $($bad -join ', ') (known: $((Get-PresetNames) -join ', '))")
        return $false
    }

    if (-not $root -and ($pairs.Count -eq 0 -or -not (Get-AddDefault $presets 'root'))) {
        $root = Read-Host 'Source folder (root)'
        if (-not $root) { return $false }
    }

    if ($pairs.Count -eq 0) {
        $sugg = @(Get-PresetsFor $root) -join ', '
        while ($true) {
            if ($sugg) {
                $v = Read-Host "Presets for this folder ('none' to skip) [$sugg]"
                if (-not $v) { $v = $sugg }
            } else {
                $v = Read-Host "Presets, comma-separated (blank for none; known: $((Get-PresetNames) -join ', '))"
            }
            if ($v -eq 'none') { $v = '' }
            $presets = @(Get-ListItems @($v))
            $bad = @(Get-UnknownPresets $presets)
            if ($bad.Count -eq 0) { break }
            [Console]::Error.WriteLine("Unknown preset: $($bad -join ', ')")
        }
        # A preset's includes are paths inside ~, so its root applies instead of the folder typed.
        $presetRoot = Get-PresetsLast $presets 'root'
        if ($presetRoot) { Say "Root: $presetRoot (from the preset)"; $root = '' }
    }

    if (-not $name) {
        $def = ''
        if ($presets.Count -eq 1) { $def = $presets[0] }
        elseif ($root) { $def = (Get-Sanitized (Split-Path -Leaf (Expand-Path $root))).ToLower() }
        if ((Get-CfgJobs) -contains $def) { $def = '' }
        $prompt = 'Job name (letters, digits, . _ -)'
        if ($def) { $prompt += " [$def]" }
        while ($true) {
            $name = Read-Host $prompt
            if (-not $name) { $name = $def }
            if (Test-AddName $name) { break }
        }
    }

    if (-not $dest) {
        $dest = Read-Host 'Drive subfolder under the drive root (e.g. Games/Minecraft)'
        if (-not $dest) { return $false }
    }

    if ($pairs.Count -eq 0) {
        if (-not (Get-AddDefault $presets 'include')) {
            Say 'Paths inside root to include, one per line. Blank line = done (none = whole root).'
            while ($true) { $v = Read-Host '  include'; if (-not $v) { break }; $lines += "include = $v" }
        }
        Say 'Exclude patterns (e.g. node_modules, *.log, sub/dir). Blank line = done.'
        while ($true) { $v = Read-Host '  exclude'; if (-not $v) { break }; $lines += "exclude = $v" }
        $v = Read-Host "Compression: zstd, gzip, none or copy [default $(Get-AddDefault $presets 'compress' 'zstd')]"
        if ($v) { $lines += "compress = $v" }
        $v = Read-Host "How often, e.g. 12h, 1d, 7d [default $(Get-AddDefault $presets 'every' '1d')]"
        if ($v) { $lines += "every = $v" }
        if (-not (Get-AddDefault $presets 'per_subfolder')) {
            $v = Read-Host 'One archive per subfolder of root? [y/N]'
            if (Test-True $v) { $lines += 'per_subfolder = true' }
        }
    }

    $out = @("[$name]")
    if ($presets.Count -gt 0) { $out += "preset = $($presets -join ', ')" }
    if ($root) { $out += "root = $root" }
    $out += "dest = $dest"
    $out += $lines
    $nl = "`r`n"
    [IO.File]::AppendAllText($script:CfgPath, $nl + ($out -join $nl) + $nl, $script:Utf8)
    Say "Added to ${script:CfgPath}:"
    foreach ($l in $out) { Say "  $l" }
    Say "Test it: .\AutoBackup.ps1 -Only $name -DryRun -Verbose"
    return $true
}

function Open-Cfg {
    if (-not (New-CfgFromTemplate)) { return $false }
    $ed = $env:VISUAL
    if (-not $ed) { $ed = $env:EDITOR }
    if ($ed) { Invoke-Expression "$ed `"$script:CfgPath`"" } else { notepad.exe $script:CfgPath }
    return $true
}

# Hourly + at-logon task, running as you (unelevated) only while you're logged in. Uses
# Windows PowerShell 5.1, which is always present and can show toasts without extra modules.
function Install-Task {
    if (-not $script:IsWin) { [Console]::Error.WriteLine('-Install is for Windows. On macOS or Linux use autobackup.sh --install.'); return $false }
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $cfg = [IO.Path]::GetFullPath($script:CfgPath)
    $arg = "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script:Self`" -Config `"$cfg`""
    $action = New-ScheduledTaskAction -Execute $ps -Argument $arg -WorkingDirectory $script:Here
    $triggers = @(
        (New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME),
        (New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1))
    )
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
    try {
        Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger $triggers -Settings $settings `
            -Description "Hourly check; jobs run when due. Config: $cfg" -Force -ErrorAction Stop | Out-Null
    } catch {
        [Console]::Error.WriteLine("Could not register the task: $($_.Exception.Message)")
        [Console]::Error.WriteLine('The logon trigger can need admin rights. Run -Install again from an admin PowerShell.')
        return $false
    }
    # Clears the downloaded-from-the-internet flag, which would otherwise block the scripts.
    Get-ChildItem -LiteralPath $script:Here -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
    Start-ScheduledTask -TaskName $script:TaskName
    Say "Installed the '$script:TaskName' scheduled task. It runs now, at every logon, and hourly."
    Show-SameVolumeWarning
    return $true
}

function Uninstall-Task {
    if (-not $script:IsWin) { [Console]::Error.WriteLine('-Uninstall is for Windows. On macOS or Linux use autobackup.sh --uninstall.'); return $false }
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Say "Removed the '$script:TaskName' scheduled task."
    Say "Config ($script:CfgPath), state and archives are untouched."
    return $true
}

# ---------------------------------------------------------------- main

if ($Help) { Show-Usage; exit 0 }
if ($Config) { $script:CfgPath = Expand-Path $Config }
foreach ($o in $Only) { foreach ($p in ($o -split ',')) { if ($p.Trim()) { $script:OptOnly += $p.Trim() } } }
if (-not $Add -and $Rest) {
    [Console]::Error.WriteLine("Unexpected arguments: $($Rest -join ' ')")
    Show-Usage
    exit 2
}

if ($Uninstall) { if (Uninstall-Task) { exit 0 } else { exit 1 } }
if ($Edit) { if (Open-Cfg) { exit 0 } else { exit 1 } }
if ($Install -and -not (Test-Path -LiteralPath $script:CfgPath -PathType Leaf)) {
    if (New-CfgFromTemplate) { Say 'Set drive_root and machine in it (-Edit), then run -Install again.' }
    exit 1
}
if (-not (Test-Path -LiteralPath $script:CfgPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Config not found: $script:CfgPath")
    [Console]::Error.WriteLine("Run '.\AutoBackup.ps1 -Edit' to create it from the template.")
    exit 1
}

if (Test-Path -LiteralPath $script:Presets -PathType Leaf) { Import-Cfg $script:Presets 'preset:' }
Import-Cfg $script:CfgPath
$script:Machine = Get-Cfg 'global' 'machine'
$driveRaw = Get-Cfg 'global' 'drive_root'
if ($driveRaw) { $script:Drive = Expand-Path $driveRaw }
$script:State = Expand-Path (Get-Cfg 'global' 'state' '%LOCALAPPDATA%\AutoBackup\state')
$script:Staging = Expand-Path (Get-Cfg 'global' 'staging' '%LOCALAPPDATA%\AutoBackup\staging')

if ($Add) {
    if (Add-Job $Rest) { exit 0 } else { exit 1 }
}

if (-not $script:Machine -or -not $script:Drive) {
    [Console]::Error.WriteLine("[global] needs machine and drive_root in $script:CfgPath")
    exit 1
}
New-Item -ItemType Directory -Force -Path (Join-Path $script:State 'stamps') | Out-Null

if ($List) { Show-List; exit 0 }

# Refuse to run if the sync folder's parent is missing (sync app not installed, or drive not mounted).
$driveParent = Split-Path -Parent $script:Drive
if (-not (Test-Path -LiteralPath $driveParent -PathType Container)) {
    Write-Log 'ERROR' "drive_root parent does not exist: $driveParent (is the sync app running?)"
    if (-not $script:OptDry -and -not $Install) { Send-Notify 'Drive folder missing; nothing backed up.' }
    exit 1
}

if ($Install) { if (Install-Task) { exit 0 } else { exit 1 } }

# Keep the log from growing forever.
$logf = Join-Path $script:State 'autobackup.log'
if ((Test-Path -LiteralPath $logf) -and (Get-Item -LiteralPath $logf).Length -gt 1MB) {
    Move-Item -LiteralPath $logf -Destination "$logf.1" -Force
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\AutoBackup')
$haveLock = $false
# An abandoned mutex (previous run killed) throws, but still hands us ownership.
try { $haveLock = $mutex.WaitOne(0) } catch { $haveLock = $true }
if (-not $haveLock) { Say 'Another AutoBackup run is in progress; exiting.'; exit 0 }

$failed = @()
try {
    $jobs = Get-CfgJobs
    if ($script:OptOnly.Count -gt 0) {
        foreach ($o in $script:OptOnly) {
            if ($jobs -notcontains $o) { Write-Log 'ERROR' "no job named [$o] in $script:CfgPath"; exit 1 }
        }
        $jobs = $script:OptOnly
    }
    foreach ($job in $jobs) {
        if (-not (Invoke-Job $job)) { $failed += $job }
    }
    if (-not $script:OptDry) {
        if ($failed.Count -gt 0) { Send-Notify "Failed: $($failed -join ', '). See autobackup.log." }
        Invoke-Alerts
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

if ($failed.Count -gt 0) { exit 1 }
exit 0
