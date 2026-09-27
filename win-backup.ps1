<#
.SYNOPSIS
  AutoBackup: Windows implementation. mac-backup.fish is CANONICAL; keep this in sync with it.

.DESCRIPTION
  Reads jobs from win.conf (INI-style, see README.md), archives each job's folders with tar,
  and moves the archives into a cloud-sync folder (Proton Drive). Safe to run often:
  each job only runs when its `every` interval has elapsed, and skips when nothing changed.

  Runs on Windows PowerShell 5.1 and PowerShell 7.x. Keep this file ASCII-only:
  5.1 reads BOM-less scripts as ANSI.

.EXAMPLE
  .\win-backup.ps1 -List
.EXAMPLE
  .\win-backup.ps1 -Only minecraft -DryRun -Verbose
.EXAMPLE
  .\win-backup.ps1 -Add notes root=~/Notes dest=Documents/Notes every=1d
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    # Config file (default: win.conf next to this script, or $env:AUTOBACKUP_CONFIG)
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
    # Open the config in $env:EDITOR (or Notepad)
    [switch]$Edit,
    [switch]$Help,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'
$script:VerboseOn = $PSBoundParameters.ContainsKey('Verbose')
$VerbosePreference = 'SilentlyContinue'   # we print our own debug lines; keep cmdlets quiet

$script:Here = $PSScriptRoot
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
$script:OptForce = [bool]$Force
$script:OptDry = [bool]$DryRun
$script:OptOnly = @()

$script:CfgPath = Join-Path $script:Here 'win.conf'
if ($env:AUTOBACKUP_CONFIG) { $script:CfgPath = $env:AUTOBACKUP_CONFIG }
if ($env:AUTOBACKUP_TAR) {
    $script:Tar = $env:AUTOBACKUP_TAR
} elseif ($script:IsWin) {
    # Always the built-in bsdtar. Git for Windows puts GNU tar on PATH, which treats patterns differently.
    $script:Tar = Join-Path $env:SystemRoot 'System32\tar.exe'
} else {
    $script:Tar = 'tar'
}

# ---------------------------------------------------------------- helpers

function Show-Usage {
    Say @'
Usage: win-backup.ps1 [options]

Runs every job in the config that is due. Meant to be called hourly by Task Scheduler.

Options:
  -Config FILE        Config file (default: win.conf next to this script,
                      or $env:AUTOBACKUP_CONFIG)
  -Only JOB[,JOB]     Run only these jobs, even if not due.
                      The skip-if-unchanged check still applies.
  -Force              Ignore schedule and skip-if-unchanged checks
  -DryRun             Show what would happen; change nothing
  -List               List jobs, last run, and whether each is due
  -Add [JOB] [key=value ...]
                      Append a job to the config. With no key=value pairs,
                      prompts interactively.
  -Edit               Open the config in $env:EDITOR (or Notepad)
  -Verbose            Also print skipped/not-due details
  -Help               Show this help

Examples:
  .\win-backup.ps1 -Only minecraft
  .\win-backup.ps1 -List
  .\win-backup.ps1 -Only dotfiles -DryRun -Verbose
  .\win-backup.ps1 -Add notes root=~/Notes dest=Documents/Notes every=1d
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

function Get-MTime([string]$f) { return (Get-Item -LiteralPath $f -Force).LastWriteTimeUtc }

function Send-Notify([string]$msg) {
    # Optional: toast via the BurntToast module (Install-Module BurntToast -Scope CurrentUser).
    if (Get-Module -ListAvailable -Name BurntToast) {
        try { Import-Module BurntToast; New-BurntToastNotification -Text 'AutoBackup', $msg } catch { }
    }
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

# Parses the INI file into $script:Cfg records {Sec, Key, Val}.
# Keys before any [section] belong to "global". Keys are case-insensitive.
function Import-Cfg([string]$file) {
    $script:Cfg.Clear()
    $sec = 'global'
    $n = 0
    foreach ($raw in [IO.File]::ReadAllLines($file)) {
        $n++
        $line = $raw.Trim()
        if ($line -eq '' -or $line.StartsWith('#') -or $line.StartsWith(';')) { continue }
        if ($line.StartsWith('[') -and $line.EndsWith(']')) {
            $sec = $line.Substring(1, $line.Length - 2).Trim()
        } elseif ($line.Contains('=')) {
            $i = $line.IndexOf('=')
            [void]$script:Cfg.Add([pscustomobject]@{
                Sec = $sec
                Key = $line.Substring(0, $i).Trim().ToLower()
                Val = $line.Substring($i + 1).Trim()
            })
        } else {
            Write-Log 'WARN' "config line $n ignored: $line"
        }
    }
}

# All values of key in section, in file order. Always wrap calls in @().
function Get-CfgVals([string]$sec, [string]$key) {
    foreach ($r in $script:Cfg) { if ($r.Sec -ceq $sec -and $r.Key -eq $key) { $r.Val } }
}

# Last value of key in section, else in [global], else the default.
function Get-Cfg([string]$sec, [string]$key, [string]$def = '') {
    $v = @(Get-CfgVals $sec $key)
    if ($v.Count -eq 0) { $v = @(Get-CfgVals 'global' $key) }
    if ($v.Count -gt 0) { return $v[-1] }
    return $def
}

function Get-CfgJobs {
    $seen = New-Object System.Collections.ArrayList
    foreach ($r in $script:Cfg) {
        if ($r.Sec -ne 'global' -and -not $seen.Contains($r.Sec)) { [void]$seen.Add($r.Sec) }
    }
    return , $seen.ToArray()
}

# ---------------------------------------------------------------- state

# A job is due when its .checked stamp is older than `every` (or missing).
# The stamp is touched after every successful pass, including "unchanged" skips.
function Test-JobDue([string]$job, [string]$every) {
    $f = Join-Path (Join-Path $script:State 'stamps') "$job.checked"
    if (-not (Test-Path -LiteralPath $f)) { return $true }
    $secs = Get-DurSecs $every
    if ($null -eq $secs) { Write-Log 'WARN' "[$job] bad every='$every', using 1d"; $secs = 86400 }
    return (([DateTime]::UtcNow - (Get-MTime $f)).TotalSeconds -ge $secs)
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

# ---------------------------------------------------------------- jobs

# Uses $script:UInc (paths relative to root) and $script:UExc (tar patterns). Returns $true on success.
function Invoke-ArchiveUnit([string]$job, [string]$key, [string]$uname, [string]$uroot, [string]$method, [string]$level, [string]$skipUnch, [string]$destdir) {
    $fname = (Get-Sanitized $uname) + '_' + $script:Machine + (Get-MethodExt $method)
    $target = Join-Path $destdir $fname
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
    $desc = @("root=$uroot", "method=$method", "level=$level")
    foreach ($i in $incs) { $desc += "include=$i" }
    foreach ($e in $script:UExc) { $desc += "exclude=$e" }
    $descText = $desc -join "`n"

    if (-not $script:OptForce -and (Test-True $skipUnch) -and (Test-Path -LiteralPath $target) -and (Test-Path -LiteralPath $stamp)) {
        if ($descText -eq ([IO.File]::ReadAllText($stamp, $script:Utf8).TrimEnd())) {
            $since = Get-MTime $stamp
            $hit = $null
            # Conservative: excluded files count too, so this can rebuild needlessly but never miss a change.
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

    if ($script:OptDry) {
        Write-Log 'INFO' "[$key] would write $target ($method, from ${uroot}: $($incs -join ', '))"
        return $true
    }

    New-Item -ItemType Directory -Force -Path $script:Staging, $stampDir | Out-Null
    try { New-Item -ItemType Directory -Force -Path $destdir -ErrorAction Stop | Out-Null }
    catch { Write-Log 'ERROR' "[$key] cannot create $destdir"; return $false }
    $pending = Join-Path $stampDir "$key.pending"
    [IO.File]::WriteAllText($pending, $descText + "`n", $script:Utf8)
    $tmp = Join-Path $script:Staging $fname
    Remove-Item -LiteralPath $tmp, "$tmp.part.tar" -Force -ErrorAction SilentlyContinue

    $targs = @()
    foreach ($e in $script:UExc) { $targs += @('--exclude', $e.Replace('\', '/')) }
    $targs += '--'   # tar end-of-options marker, then the include paths
    $targs += $incs

    $t0 = [DateTime]::UtcNow
    if (-not (Invoke-BuildArchive $method $level $tmp $uroot $targs $key)) {
        Remove-Item -LiteralPath $tmp, $pending -Force -ErrorAction SilentlyContinue
        Write-Log 'ERROR' "[$key] archiving failed for $uroot"
        return $false
    }
    # Same volume as the sync folder, so this is a rename: the sync client never sees a partial file.
    try { Move-Item -LiteralPath $tmp -Destination $target -Force -ErrorAction Stop }
    catch {
        Remove-Item -LiteralPath $tmp, $pending -Force -ErrorAction SilentlyContinue
        Write-Log 'ERROR' "[$key] could not move archive to ${target}: $($_.Exception.Message)"
        return $false
    }
    Move-Item -LiteralPath $pending -Destination $stamp -Force
    $size = (Get-Item -LiteralPath $target).Length
    $sizeText = if ($size -ge 1GB) { '{0:N1}G' -f ($size / 1GB) } elseif ($size -ge 1MB) { '{0:N1}M' -f ($size / 1MB) } else { '{0:N0}K' -f [Math]::Ceiling($size / 1KB) }
    Write-Log 'INFO' "[$key] wrote $target ($sizeText, $([int]([DateTime]::UtcNow - $t0).TotalSeconds)s)"
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
    $rootRaw = Get-Cfg $job 'root'
    $dest = (Get-Cfg $job 'dest').Trim('/', '\')
    if (-not $rootRaw -or -not $dest) { Write-Log 'ERROR' "[$job] needs both root and dest"; return $false }
    $root = Expand-Path $rootRaw
    $mode = (Get-Cfg $job 'compress' 'zstd').ToLower()
    $method = Resolve-Method $mode
    if (-not $method) { Write-Log 'ERROR' "[$job] unknown compress '$mode' (use zstd, gzip, none or copy)"; return $false }
    $level = Get-Cfg $job 'level'
    if (-not $level) { if ($method -eq 'gzip') { $level = '6' } else { $level = '3' } }
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

    $script:UExc = @(Get-CfgVals 'global' 'exclude') + @(Get-CfgVals $job 'exclude')
    $destdir = Join-Path $script:Drive (ConvertTo-NativePath $dest)
    $skipUnch = Get-Cfg $job 'skip_unchanged' 'true'
    $ok = $true

    if ($method -eq 'copy') {
        if (-not (Invoke-CopyFiles $job $root $destdir)) { $ok = $false }
    } elseif (Test-True (Get-Cfg $job 'split' 'false')) {
        # One archive per immediate subfolder (e.g. one per Prism instance).
        $found = $false
        $subs = Get-ChildItem -LiteralPath $root -Directory -Force | Where-Object { -not $_.Name.StartsWith('.') } | Sort-Object Name
        foreach ($d in $subs) {
            $skip = $false
            foreach ($e in $script:UExc) { if ($d.Name -like $e) { $skip = $true } }
            if ($skip) { continue }
            $found = $true
            $script:UInc = @('.')
            if (-not (Invoke-ArchiveUnit $job ("$job@" + (Get-Sanitized $d.Name)) $d.Name $d.FullName $method $level $skipUnch $destdir)) { $ok = $false }
        }
        if (-not $found) { Write-Log 'WARN' "[$job] split=true but no subfolders in $root" }
    } else {
        $script:UInc = @(Get-CfgVals $job 'include')
        if ($script:UInc.Count -eq 0) { $script:UInc = @('.') }
        $name = @(Get-CfgVals $job 'name')
        if ($name.Count -gt 0 -and $name[-1]) { $name = $name[-1] } else { $name = $job }
        if (-not (Invoke-ArchiveUnit $job $job $name $root $method $level $skipUnch $destdir)) { $ok = $false }
    }

    if ($ok -and -not $script:OptDry) {
        $sd = Join-Path $script:State 'stamps'
        New-Item -ItemType Directory -Force -Path $sd | Out-Null
        Set-Stamp (Join-Path $sd "$job.checked")
    }
    return $ok
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
        elseif (Test-JobDue $job (Get-Cfg $job 'every' '1d')) { $st = 'due' }
        Say ($fmt -f $job, (Get-Cfg $job 'compress' 'zstd'), (Get-Cfg $job 'every' '1d'), (Get-Cfg $job 'dest'), $last, $st)
    }
    Say ''
    Say "Drive root: $script:Drive"
    Say "Log:        $(Join-Path $script:State 'autobackup.log')"
}

function Add-Job([string[]]$argv) {
    $argv = @($argv | Where-Object { $_ })
    $name = ''
    $pairs = @()
    if ($argv.Count -gt 0) { $name = $argv[0]; if ($argv.Count -gt 1) { $pairs = $argv[1..($argv.Count - 1)] } }
    if (-not $name) { $name = Read-Host 'Job name (letters, digits, . _ -)' }
    if ($name -notmatch '^[A-Za-z0-9._-]+$') { [Console]::Error.WriteLine("Invalid job name: '$name'"); return $false }
    if ((Get-CfgJobs) -contains $name) { [Console]::Error.WriteLine("Job [$name] already exists in $script:CfgPath. Edit it there (-Edit)."); return $false }
    $lines = @("[$name]")
    $haveRoot = $false; $haveDest = $false
    foreach ($p in $pairs) {
        if ($p -notmatch '^[A-Za-z_]+=') { [Console]::Error.WriteLine("Expected key=value, got: $p"); return $false }
        $i = $p.IndexOf('=')
        $k = $p.Substring(0, $i); $v = $p.Substring($i + 1)
        $lines += "$k = $v"
        if ($k -eq 'root') { $haveRoot = $true }
        if ($k -eq 'dest') { $haveDest = $true }
    }
    if (-not $haveRoot) {
        $v = Read-Host 'Source folder (root)'
        if (-not $v) { return $false }
        $lines += "root = $v"
    }
    if (-not $haveDest) {
        $v = Read-Host 'Drive subfolder under the drive root (e.g. Games/Minecraft)'
        if (-not $v) { return $false }
        $lines += "dest = $v"
    }
    if ($pairs.Count -eq 0) {
        Say 'Paths inside root to include, one per line. Blank line = done (none = whole root).'
        while ($true) { $v = Read-Host '  include'; if (-not $v) { break }; $lines += "include = $v" }
        Say 'Exclude patterns (e.g. node_modules, *.log, sub/dir). Blank line = done.'
        while ($true) { $v = Read-Host '  exclude'; if (-not $v) { break }; $lines += "exclude = $v" }
        $v = Read-Host "Compression: zstd, gzip, none or copy [default $(Get-Cfg 'global' 'compress' 'zstd')]"
        if ($v) { $lines += "compress = $v" }
        $v = Read-Host "How often, e.g. 12h, 1d, 7d [default $(Get-Cfg 'global' 'every' '1d')]"
        if ($v) { $lines += "every = $v" }
        $v = Read-Host 'One archive per subfolder of root? [y/N]'
        if (Test-True $v) { $lines += 'split = true' }
    }
    $nl = "`r`n"
    [IO.File]::AppendAllText($script:CfgPath, $nl + ($lines -join $nl) + $nl, $script:Utf8)
    Say "Added to ${script:CfgPath}:"
    foreach ($l in $lines) { Say "  $l" }
    Say "Test it: .\win-backup.ps1 -Only $name -DryRun -Verbose"
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

if (-not (Test-Path -LiteralPath $script:CfgPath -PathType Leaf)) {
    [Console]::Error.WriteLine("Config not found: $script:CfgPath")
    exit 1
}

if ($Edit) {
    if ($env:EDITOR) { Invoke-Expression "$env:EDITOR `"$script:CfgPath`"" } else { notepad.exe $script:CfgPath }
    exit 0
}

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

# Refuse to run if the sync folder's parent is missing (Proton not installed/mounted).
$driveParent = Split-Path -Parent $script:Drive
if (-not (Test-Path -LiteralPath $driveParent -PathType Container)) {
    Write-Log 'ERROR' "drive_root parent does not exist: $driveParent (is Proton Drive running?)"
    if (-not $script:OptDry) { Send-Notify 'Drive folder missing; nothing backed up.' }
    exit 1
}

# Keep the log from growing forever.
$logf = Join-Path $script:State 'autobackup.log'
if ((Test-Path -LiteralPath $logf) -and (Get-Item -LiteralPath $logf).Length -gt 1MB) {
    Move-Item -LiteralPath $logf -Destination "$logf.1" -Force
}

$mutex = New-Object System.Threading.Mutex($false, 'Local\AutoBackup')
$haveLock = $false
# An abandoned mutex (previous run killed) throws, but still hands us ownership.
try { $haveLock = $mutex.WaitOne(0) } catch { $haveLock = $true }
if (-not $haveLock) { Write-VLog 'another run is in progress; exiting'; exit 0 }

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
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}

if ($failed.Count -gt 0) {
    if (-not $script:OptDry) { Send-Notify "Failed: $($failed -join ', '). See autobackup.log." }
    exit 1
}
exit 0
