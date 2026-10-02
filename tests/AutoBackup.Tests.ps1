# Black-box tests for both scripts. Each case builds a small folder tree, runs the script under
# test against a throwaway config, and checks what landed in the drive folder. The same cases run
# against autobackup.sh (macOS, Linux) and AutoBackup.ps1 (Windows, and macOS via pwsh), which
# keeps the two in step. Runs on Pester 5+ under Windows PowerShell 5.1 and PowerShell 7.
# Keep this file ASCII-only.
#
#   Invoke-Pester ./tests -Output Detailed

BeforeDiscovery {
    $onWindows = [IO.Path]::DirectorySeparatorChar -eq '\'
    $impls = @()
    if (-not $onWindows) { $impls += @{ Impl = 'bash' } }
    # AutoBackup.ps1 relies on bsdtar options, which Linux's GNU tar lacks.
    if (-not $IsLinux) { $impls += @{ Impl = 'powershell' } }
}

Describe '<Impl>' -ForEach $impls {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        $onWindows = [IO.Path]::DirectorySeparatorChar -eq '\'
        # /bin/bash is bash 3.2 on macOS, the version the script has to support.
        $bash = 'bash'
        if (Test-Path '/bin/bash') { $bash = '/bin/bash' }
        $tarExe = 'tar'
        if ($onWindows) { $tarExe = Join-Path $env:SystemRoot 'System32\tar.exe' }
        $psExe = (Get-Process -Id $PID).Path
        $env:AUTOBACKUP_NOTIFY = '0'

        # Runs the script under test. Flags are written bash-style and translated for PowerShell.
        function Invoke-AB([string[]]$Flags) {
            # Windows PowerShell 5.1 turns a native command's stderr into error records under 2>&1,
            # which would stop the test; the scripts write errors to stderr on purpose.
            $ErrorActionPreference = 'Continue'
            if ($Impl -eq 'bash') {
                $out = & $bash (Join-Path $repo 'autobackup.sh') --config $conf @Flags 2>&1
            } else {
                $map = @{ '--force' = '-Force'; '--dry-run' = '-DryRun'; '--list' = '-List'; '--verbose' = '-Verbose'; '--only' = '-Only'; '--add' = '-Add'; '--install' = '-Install' }
                $psFlags = @($Flags | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { $_ } })
                $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'AutoBackup.ps1') -Config $conf @psFlags 2>&1
            }
            return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
        }

        # Runs the restore script under test, the same way. Without a config file, runs without one.
        function Invoke-Restore([string[]]$Flags) {
            $ErrorActionPreference = 'Continue'
            if (Test-Path -LiteralPath $conf) { $Flags = @('--config', $conf) + $Flags }
            if ($Impl -eq 'bash') {
                $out = & $bash (Join-Path $repo 'restore.sh') @Flags 2>&1
            } else {
                $map = @{ '--list' = '-List'; '--to' = '-To'; '--overwrite' = '-Overwrite'; '--at' = '-At'; '--verify' = '-Verify';
                    '--machine' = '-Machine'; '--drive' = '-Drive'; '--config' = '-Config'; '--dry-run' = '-DryRun' }
                $psFlags = @($Flags | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { $_ } })
                $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'Restore.ps1') @psFlags 2>&1
            }
            return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
        }

        # Files under DIR, relative, with / separators.
        function Get-Tree([string]$dir) {
            $full = (Get-Item -LiteralPath $dir).FullName.TrimEnd('\', '/')
            @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force |
                    ForEach-Object { $_.FullName.Substring($full.Length + 1).Replace('\', '/') } | Sort-Object)
        }

        # Writes the config: shared [global] settings plus the given job sections.
        function Set-Jobs([string]$jobs) {
            $global = "[global]`ndrive_root = $drive`nmachine = T`nstate = $state`nstaging = $staging`n"
            [IO.File]::WriteAllText($conf, $global + $jobs)
        }

        function New-File([string]$path, [string]$text = 'x') {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
            [IO.File]::WriteAllText($path, $text)
        }

        # File entries of a tar archive (any compression), without ./ and without folders.
        function Get-Entries([string]$archive) {
            @(& $tarExe -tf $archive) | ForEach-Object { $_ -replace '^\./', '' } |
                Where-Object { $_ -and -not $_.EndsWith('/') } | Sort-Object
        }

        function Get-DriveFiles([string]$sub) {
            $dir = Join-Path $drive $sub
            if (-not (Test-Path $dir)) { return @() }
            @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object Name | Sort-Object)
        }
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $src = Join-Path $root 'src'
        $drive = Join-Path $root 'drive/AutoBackup'
        $state = Join-Path $root 'state'
        $staging = Join-Path $root 'staging'
        $conf = Join-Path $root 'test.ini'
        $rulegroups = Join-Path $root 'rulegroups.ini'
        New-Item -ItemType Directory -Force -Path $src, (Split-Path -Parent $drive) | Out-Null
    }

    AfterEach {
        Remove-Item Env:AUTOBACKUP_RULEGROUPS, Env:AUTOBACKUP_CONFIG -ErrorAction SilentlyContinue
    }

    It 'archives a folder, skips it when unchanged, and rebuilds after a change' {
        New-File (Join-Path $src 'a.txt')
        New-File (Join-Path $src 'sub/b.txt')
        New-File (Join-Path $src 'skip.log')
        Set-Jobs "[plain]`nsource = $src`ndest = Plain`ncompress = none`nexclude = *.log`n"

        (Invoke-AB '--force').Code | Should -Be 0
        $archive = Join-Path $drive 'Plain/plain_T.tar'
        Get-Entries $archive | Should -Be @('a.txt', 'sub/b.txt')

        (Invoke-AB '--only', 'plain', '--verbose').Text | Should -Match 'unchanged, skipped'

        New-File (Join-Path $src 'c.txt')
        (Get-Item (Join-Path $src 'c.txt')).LastWriteTime = (Get-Date).AddMinutes(1)
        (Invoke-AB '--only', 'plain').Code | Should -Be 0
        Get-Entries $archive | Should -Contain 'c.txt'
    }

    It 'ignores changes to excluded files when checking for changes' {
        New-File (Join-Path $src 'a.txt')
        New-File (Join-Path $src 'skip.log')
        New-File (Join-Path $src 'sub/cache/c.bin')
        Set-Jobs "[plain]`nsource = $src`ndest = Plain`ncompress = none`nexclude = *.log`nexclude = sub/cache`n"
        (Invoke-AB '--force').Code | Should -Be 0

        foreach ($f in 'skip.log', 'sub/cache/c.bin') {
            (Get-Item (Join-Path $src $f)).LastWriteTime = (Get-Date).AddMinutes(1)
        }
        (Invoke-AB '--only', 'plain', '--verbose').Text | Should -Match 'unchanged, skipped'

        (Get-Item (Join-Path $src 'a.txt')).LastWriteTime = (Get-Date).AddMinutes(1)
        (Invoke-AB '--only', 'plain', '--verbose').Text | Should -Match 'changed: .*a\.txt'
    }

    It 'lists jobs, and a dry run writes nothing' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[plain]`nsource = $src`ndest = Plain`n"

        (Invoke-AB '--list').Text | Should -Match 'plain\s.*\sdue'
        $r = Invoke-AB '--dry-run'
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'would write'
        Test-Path $drive | Should -BeFalse
    }

    It 'makes one archive per subfolder with per_subfolder' {
        New-File (Join-Path $src 'One/a.txt')
        New-File (Join-Path $src 'Two/b.txt')
        New-File (Join-Path $src '.hidden/c.txt')
        Set-Jobs "[games]`nsource = $src`ndest = Games`ncompress = none`nper_subfolder = true`n"

        (Invoke-AB '--force').Code | Should -Be 0
        Get-DriveFiles 'Games' | Should -Be @('One_T.tar', 'Two_T.tar')
        Get-Entries (Join-Path $drive 'Games/Two_T.tar') | Should -Be @('b.txt')
    }

    It 'keeps non-Latin folder names, and refuses archives whose names clash' {
        $world = [string][char]0x4E16 + [char]0x754C
        $kana = [string][char]0x30EF + [char]0x30FC + [char]0x30EB + [char]0x30C9
        foreach ($d in 'My World', 'My-World', $world, $kana, 'ok') { New-File (Join-Path $src "$d/a.txt") }
        Set-Jobs "[games]`nsource = $src`ndest = Games`ncompress = none`nper_subfolder = true`n"

        $r = Invoke-AB '--force'
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match 'share the name Games[\\/]My-World_T'
        Get-DriveFiles 'Games' | Should -Be @(@("${kana}_T.tar", "${world}_T.tar", 'ok_T.tar') | Sort-Object)
        (Invoke-AB '--list').Text | Should -Match 'games\s.*\sfailed'
    }

    It 'fails a job with nothing to archive, and lists it as failed until it succeeds' {
        Set-Jobs "[empty]`nsource = $src`ndest = Empty`ncompress = none`ninclude = missing`n"

        (Invoke-AB '--force').Code | Should -Not -Be 0
        Test-Path (Join-Path $state 'stamps/empty.checked') | Should -BeFalse
        (Invoke-AB '--list').Text | Should -Match 'empty\s.*\sfailed'

        New-File (Join-Path $src 'missing/a.txt')
        (Invoke-AB '--force').Code | Should -Be 0
        (Invoke-AB '--list').Text | Should -Match 'empty\s.*\sok'
    }

    It 'copies top-level files with the machine suffix in copy mode' {
        New-File (Join-Path $src 'list.tsv') "a`tb"
        New-File (Join-Path $src '.hidden') 'no'
        Set-Jobs "[inv]`nsource = $src`ndest = Config`ncompress = copy`n"

        (Invoke-AB '--force').Code | Should -Be 0
        Get-DriveFiles 'Config' | Should -Be @('list_T.tsv')
        [IO.File]::ReadAllText((Join-Path $drive 'Config/list_T.tsv')) | Should -Be "a`tb"
    }

    It 'follows .gitignore inside git repos' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        $proj = Join-Path $src 'proj'
        New-File (Join-Path $proj '.gitignore') "dist/`n.env`n"
        New-File (Join-Path $proj 'src/a.js')
        New-File (Join-Path $proj 'dist/b.js')
        New-File (Join-Path $proj '.env')
        & git -C $proj init -q
        & git -C $proj add -A
        & git -C $proj -c user.name=t -c user.email=t@t commit -qm init
        New-File (Join-Path $proj 'src/new.js')
        New-File (Join-Path $src 'notes.txt')
        Set-Jobs "[code]`nsource = $src`ndest = Code`ncompress = none`n"

        (Invoke-AB '--force').Code | Should -Be 0
        $entries = Get-Entries (Join-Path $drive 'Code/code_T.tar')
        $entries | Should -Contain 'notes.txt'
        $entries | Should -Contain 'proj/src/a.js'
        $entries | Should -Contain 'proj/src/new.js'
        $entries | Should -Contain 'proj/.git/HEAD'
        $entries | Should -Not -Contain 'proj/dist/b.js'
        $entries | Should -Not -Contain 'proj/.env'
    }

    It 'keeps non-ASCII file names inside git repos' -Skip:(-not (Get-Command git -ErrorAction SilentlyContinue)) {
        # cafe with an accent (in the Windows ANSI code page 1252) and two CJK characters (not in it).
        $names = @(('caf' + [char]0xE9 + '.txt'), ([string][char]0x65E5 + [char]0x672C + '.txt')) | Sort-Object
        $proj = Join-Path $src 'proj'
        foreach ($n in $names) { New-File (Join-Path $proj $n) }
        & git -C $proj init -q
        & git -C $proj add -A
        & git -C $proj -c user.name=t -c user.email=t@t commit -qm init
        Set-Jobs "[code]`nsource = $src`ndest = Code`ncompress = none`n"

        (Invoke-AB '--force').Code | Should -Be 0
        $x = Join-Path $root 'extracted'
        New-Item -ItemType Directory -Path $x | Out-Null
        & $tarExe -xf (Join-Path $drive 'Code/code_T.tar') -C $x
        @(Get-ChildItem -LiteralPath (Join-Path $x 'proj') -File | ForEach-Object Name | Sort-Object) | Should -Be $names
    }

    It 'keeps only the newest versions with keep' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[notes]`nsource = $src`ndest = Notes`ncompress = none`nkeep = 2`n"

        (Invoke-AB '--force').Code | Should -Be 0
        $first = @(Get-DriveFiles 'Notes')
        foreach ($i in 1..2) {
            Start-Sleep -Milliseconds 1100   # timestamps have 1-second resolution
            (Invoke-AB '--force').Code | Should -Be 0
        }
        $files = @(Get-DriveFiles 'Notes')
        $files.Count | Should -Be 2
        $files | Should -Not -Contain $first[0]
        $files | ForEach-Object { $_ | Should -Match '^notes_T_\d{4}-\d{2}-\d{2}_\d{6}\.tar$' }
    }

    It 'splits into parts with chunk_size that join back into one archive' {
        $bytes = New-Object byte[] 300000
        (New-Object Random 1).NextBytes($bytes)
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $src 'big.bin'), $bytes)
        Set-Jobs "[game]`nsource = $src`ndest = Games`ncompress = none`nchunk_size = 100K`n"

        (Invoke-AB '--force').Code | Should -Be 0
        $parts = @(Get-DriveFiles 'Games')
        $parts.Count | Should -BeGreaterThan 1
        for ($i = 0; $i -lt $parts.Count; $i++) { $parts[$i] | Should -Be ('game_T.tar.' + ($i + 1).ToString('000')) }

        $joined = Join-Path $root 'joined.tar'
        $out = [IO.File]::Create($joined)
        foreach ($p in $parts) { $b = [IO.File]::ReadAllBytes((Join-Path $drive "Games/$p")); $out.Write($b, 0, $b.Length) }
        $out.Dispose()
        Get-Entries $joined | Should -Be @('big.bin')

        # A smaller rebuild leaves no stale parts behind.
        [IO.File]::WriteAllText((Join-Path $src 'big.bin'), 'small')
        (Invoke-AB '--force').Code | Should -Be 0
        Get-DriveFiles 'Games' | Should -Be @('game_T.tar.001')
    }

    It 'fails a job with a missing source and leaves it due' {
        Set-Jobs "[gone]`nsource = $(Join-Path $root 'missing')`ndest = Gone`n"

        (Invoke-AB '--force').Code | Should -Not -Be 0
        Test-Path (Join-Path $state 'stamps/gone.checked') | Should -BeFalse
        Get-Content (Join-Path $state 'autobackup.log') -Raw | Should -Match 'source folder not found'
    }

    It 'warns about a job with no recent successful backup' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[old]`nsource = $src`ndest = Old`ncompress = none`n[fresh]`nsource = $src`ndest = Fresh`ncompress = none`n"

        (Invoke-AB '--force').Code | Should -Be 0
        (Get-Item (Join-Path $state 'stamps/old.checked')).LastWriteTime = (Get-Date).AddDays(-10)
        (Invoke-AB '--only', 'fresh').Code | Should -Be 0
        Get-Content (Join-Path $state 'autobackup.log') -Raw | Should -Match 'no successful backup in a while: old'
        (Invoke-AB '--list').Text | Should -Match 'old\s.*\sstale'
    }

    It 'takes source, includes and settings from a rulegroup next to the config, with job keys winning' {
        New-File (Join-Path $src 'keep/a.txt')
        New-File (Join-Path $src 'keep/b.log')
        New-File (Join-Path $src 'keep/c.tmp')
        New-File (Join-Path $src 'other.txt')
        [IO.File]::WriteAllText($rulegroups, "[tool]`nsource = $src`ninclude = keep`nexclude = *.log`ncompress = gzip`nevery = 7d`n")
        Set-Jobs "[mytool]`nrulegroup = tool`ndest = Tools`ncompress = none`nexclude = *.tmp`n"

        (Invoke-AB '--force').Code | Should -Be 0
        Get-Entries (Join-Path $drive 'Tools/mytool_T.tar') | Should -Be @('keep/a.txt')
        (Invoke-AB '--list').Text | Should -Match 'mytool\s+none\s+7d\s'
    }

    It 'fails a job that names an unknown rulegroup' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[typo]`nrulegroup = no-such-group`nsource = $src`ndest = Typo`n"

        $r = Invoke-AB '--force'
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match 'unknown rulegroup: no-such-group'
        Test-Path $drive | Should -BeFalse
    }

    It 'warns about unknown keys and trailing comments, and strips quotes' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[plain]`nsource = `"$src`"`ndest = 'Plain'`nexlude = *.txt`nevery = 1d  # daily`n"

        $r = Invoke-AB '--dry-run'
        $r.Text | Should -Match "unknown key 'exlude' ignored"
        $r.Text | Should -Match 'comments only work on their own line'
        $r.Text | Should -Match 'would write .*Plain[\\/]plain_T\.tar'
    }

    It 'loads the shipped rulegroups.ini without warnings' {
        Set-Jobs ''
        $r = Invoke-AB '--list'
        $r.Code | Should -Be 0
        $r.Text | Should -Not -Match 'WARN'
    }

    It 'creates the config with a copy of the shipped rulegroups.ini next to it' {
        $r = Invoke-AB '--install'
        $r.Code | Should -Be 1
        Test-Path $conf | Should -BeTrue
        [IO.File]::ReadAllText($rulegroups) | Should -Be ([IO.File]::ReadAllText((Join-Path $repo 'rulegroups.ini')))
        [IO.File]::ReadAllText($conf) | Should -Match '(?m)^machine = [A-Za-z0-9]'
        [IO.File]::ReadAllText($conf) | Should -Not -Match '(?m)^machine = My(Mac|PC|Linux)\s*$'
    }

    It "says so when drive_root is still the template's example" {
        [IO.File]::WriteAllText($conf, "[global]`ndrive_root = ~/YOUR_SYNC_FOLDER/AutoBackup`nmachine = T`nstate = $state`nstaging = $staging`n")
        $r = Invoke-AB '--dry-run'
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match "drive_root is still the template's example"
    }

    It 'adds a job that uses a rulegroup without asking for its source' {
        [IO.File]::WriteAllText($rulegroups, "[tool]`nsource = $src`ninclude = keep`n")
        $env:AUTOBACKUP_RULEGROUPS = $rulegroups
        Set-Jobs ''

        (Invoke-AB '--add', 'mytool', 'rulegroup=tool', 'dest=Tools').Code | Should -Be 0
        $text = [IO.File]::ReadAllText($conf)
        $text | Should -Match '\[mytool\]\r?\nrulegroup = tool\r?\ndest = Tools'
        $text | Should -Not -Match '(?m)^source = '
    }

    It 'restores the newest version, or an older one with --at' {
        New-File (Join-Path $src 'a.txt') 'one'
        Set-Jobs "[notes]`nsource = $src`ndest = Notes`ncompress = gzip`nkeep = 3`n"
        (Invoke-AB '--force').Code | Should -Be 0
        $first = (@(Get-DriveFiles 'Notes')[0]) -replace '^notes_T_(\d{4}-\d{2}-\d{2})_(\d{6}).*$', '$1_$2'
        Start-Sleep -Milliseconds 1100   # timestamps have 1-second resolution
        New-File (Join-Path $src 'a.txt') 'two'
        New-File (Join-Path $src 'sub/b.txt')
        (Invoke-AB '--force').Code | Should -Be 0

        $r = Invoke-Restore '--list', 'notes'
        $r.Code | Should -Be 0
        ([regex]::Matches($r.Text, 'notes_T_\d{4}')).Count | Should -Be 2

        $out = Join-Path $root 'out'
        (Invoke-Restore '--to', $out, 'notes').Code | Should -Be 0
        Get-Tree $out | Should -Be @('a.txt', 'sub/b.txt')
        [IO.File]::ReadAllText((Join-Path $out 'a.txt')) | Should -Be 'two'

        $old = Join-Path $root 'old'
        (Invoke-Restore '--to', $old, '--at', $first, 'notes').Code | Should -Be 0
        Get-Tree $old | Should -Be @('a.txt')
        [IO.File]::ReadAllText((Join-Path $old 'a.txt')) | Should -Be 'one'
    }

    It 'joins chunked parts on restore, and --verify catches a missing part' {
        $bytes = New-Object byte[] 300000
        (New-Object Random 1).NextBytes($bytes)
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'One'), (Join-Path $src 'Two') | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $src 'One/big.bin'), $bytes)
        New-File (Join-Path $src 'Two/t.txt')
        Set-Jobs "[games]`nsource = $src`ndest = Games`ncompress = gzip`nper_subfolder = true`nchunk_size = 100K`n"
        (Invoke-AB '--force').Code | Should -Be 0
        @(Get-DriveFiles 'Games' | Where-Object { $_ -like 'One_T.tar.gz.*' }).Count | Should -BeGreaterThan 1

        $r = Invoke-Restore '--verify'
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'ok\s+One_T\b'
        $r.Text | Should -Match 'ok\s+Two_T\b'

        $out = Join-Path $root 'out'
        (Invoke-Restore '--to', $out, 'One').Code | Should -Be 0
        [IO.File]::ReadAllBytes((Join-Path $out 'big.bin')).Length | Should -Be 300000

        Remove-Item -LiteralPath (Join-Path $drive 'Games/One_T.tar.gz.002')
        $r = Invoke-Restore '--verify', 'One'
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match 'One_T\.tar\.gz\.002 is missing'
    }

    It 'adds only missing files unless --overwrite, and refuses the drive folder' {
        New-File (Join-Path $src 'a.txt') 'new'
        New-File (Join-Path $src 'b.txt') 'new'
        Set-Jobs "[plain]`nsource = $src`ndest = Plain`ncompress = none`n"
        (Invoke-AB '--force').Code | Should -Be 0

        $out = Join-Path $root 'out'
        New-File (Join-Path $out 'a.txt') 'old'
        $r = Invoke-Restore '--to', $out, 'plain'
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'keeping files already there'
        [IO.File]::ReadAllText((Join-Path $out 'a.txt')) | Should -Be 'old'
        [IO.File]::ReadAllText((Join-Path $out 'b.txt')) | Should -Be 'new'

        $r = Invoke-Restore '--to', $out, '--overwrite', 'plain'
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'replacing files already there'
        [IO.File]::ReadAllText((Join-Path $out 'a.txt')) | Should -Be 'new'

        $r = Invoke-Restore '--to', (Join-Path $drive 'x'), 'plain'
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match "won't extract into the drive folder"
        Test-Path (Join-Path $drive 'x') | Should -BeFalse
    }

    It 'restores every archive into its own folder with --all' {
        New-File (Join-Path $src 'notes/a.txt')
        New-File (Join-Path $src 'games/One/b.txt')
        New-File (Join-Path $src 'games/Two/c.txt')
        Set-Jobs ("[notes]`nsource = $(Join-Path $src 'notes')`ndest = Notes`ncompress = none`n" +
            "[games]`nsource = $(Join-Path $src 'games')`ndest = Games`ncompress = none`nper_subfolder = true`n")
        (Invoke-AB '--force').Code | Should -Be 0

        (Invoke-Restore '--all', 'notes').Code | Should -Be 2

        $out = Join-Path $root 'out'
        (Invoke-Restore '--all', '--to', $out).Code | Should -Be 0
        $dirs = @(Get-ChildItem -LiteralPath $out -Directory | ForEach-Object Name | Sort-Object)
        $dirs.Count | Should -Be 3
        $dirs | ForEach-Object { $_ | Should -Match '^(One|Two|notes)_T_\d{4}-\d{2}-\d{2}_\d{6}$' }
        @(Get-Tree $out | ForEach-Object { $_ -replace '_T_[^/]+', '' } | Sort-Object) |
            Should -Be @('notes/a.txt', 'One/b.txt', 'Two/c.txt')
    }

    It 'restores without a config, given the drive folder and machine' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[plain]`nsource = $src`ndest = Plain`ncompress = none`n"
        (Invoke-AB '--force').Code | Should -Be 0
        Remove-Item -LiteralPath $conf
        $env:AUTOBACKUP_CONFIG = $conf   # so a real config in the default place isn't read

        $r = Invoke-Restore '--drive', $drive, '--list'
        $r.Code | Should -Be 0
        $r.Text | Should -Match 'plain_T\s'

        $out = Join-Path $root 'out'
        (Invoke-Restore '--drive', $drive, '--machine', 'T', '--to', $out, 'plain').Code | Should -Be 0
        Get-Tree $out | Should -Be @('a.txt')

        $r = Invoke-Restore '--drive', $drive, '--machine', 'Other', '--to', $out, 'plain'
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match "No archive named 'plain'"
    }
}

# The app-inventory hooks call real package tools, so this checks the files the platform always has.
Describe 'inventory hook' {
    BeforeAll {
        $repo = Split-Path -Parent $PSScriptRoot
        $psExe = (Get-Process -Id $PID).Path
    }

    It 'writes the app lists for this platform' {
        $out = Join-Path $TestDrive 'inventory'
        if ([IO.Path]::DirectorySeparatorChar -eq '\') {
            & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'hooks/Inventory.ps1') $out
            $expected = 'installed.csv'
        } else {
            & sh (Join-Path $repo 'hooks/inventory.sh') $out
            if ($IsMacOS) { $expected = 'Applications.tsv' } else { $expected = 'apt-manual.txt' }
        }
        $LASTEXITCODE | Should -Be 0
        $file = Join-Path $out $expected
        Test-Path -LiteralPath $file | Should -BeTrue
        @(Get-Content -LiteralPath $file).Count | Should -BeGreaterThan 1
    }
}
