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
                $map = @{ '--force' = '-Force'; '--dry-run' = '-DryRun'; '--list' = '-List'; '--verbose' = '-Verbose'; '--only' = '-Only' }
                $psFlags = @($Flags | ForEach-Object { if ($map.ContainsKey($_)) { $map[$_] } else { $_ } })
                $out = & $psExe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $repo 'AutoBackup.ps1') -Config $conf @psFlags 2>&1
            }
            return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($out | Out-String) }
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
        $conf = Join-Path $root 'test.conf'
        New-Item -ItemType Directory -Force -Path $src, (Split-Path -Parent $drive) | Out-Null
    }

    It 'archives a folder, skips it when unchanged, and rebuilds after a change' {
        New-File (Join-Path $src 'a.txt')
        New-File (Join-Path $src 'sub/b.txt')
        New-File (Join-Path $src 'skip.log')
        Set-Jobs "[plain]`nroot = $src`ndest = Plain`ncompress = none`nexclude = *.log`n"

        (Invoke-AB '--force').Code | Should -Be 0
        $archive = Join-Path $drive 'Plain/plain_T.tar'
        Get-Entries $archive | Should -Be @('a.txt', 'sub/b.txt')

        (Invoke-AB '--only', 'plain', '--verbose').Text | Should -Match 'unchanged, skipped'

        New-File (Join-Path $src 'c.txt')
        (Get-Item (Join-Path $src 'c.txt')).LastWriteTime = (Get-Date).AddMinutes(1)
        (Invoke-AB '--only', 'plain').Code | Should -Be 0
        Get-Entries $archive | Should -Contain 'c.txt'
    }

    It 'lists jobs, and a dry run writes nothing' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[plain]`nroot = $src`ndest = Plain`n"

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
        Set-Jobs "[games]`nroot = $src`ndest = Games`ncompress = none`nper_subfolder = true`n"

        (Invoke-AB '--force').Code | Should -Be 0
        Get-DriveFiles 'Games' | Should -Be @('One_T.tar', 'Two_T.tar')
        Get-Entries (Join-Path $drive 'Games/Two_T.tar') | Should -Be @('b.txt')
    }

    It 'copies top-level files with the machine suffix in copy mode' {
        New-File (Join-Path $src 'list.tsv') "a`tb"
        New-File (Join-Path $src '.hidden') 'no'
        Set-Jobs "[inv]`nroot = $src`ndest = Config`ncompress = copy`n"

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
        Set-Jobs "[code]`nroot = $src`ndest = Code`ncompress = none`n"

        (Invoke-AB '--force').Code | Should -Be 0
        $entries = Get-Entries (Join-Path $drive 'Code/code_T.tar')
        $entries | Should -Contain 'notes.txt'
        $entries | Should -Contain 'proj/src/a.js'
        $entries | Should -Contain 'proj/src/new.js'
        $entries | Should -Contain 'proj/.git/HEAD'
        $entries | Should -Not -Contain 'proj/dist/b.js'
        $entries | Should -Not -Contain 'proj/.env'
    }

    It 'keeps only the newest versions with keep' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[notes]`nroot = $src`ndest = Notes`ncompress = none`nkeep = 2`n"

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
        Set-Jobs "[game]`nroot = $src`ndest = Games`ncompress = none`nchunk_size = 100K`n"

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

    It 'fails a job with a missing root and leaves it due' {
        Set-Jobs "[gone]`nroot = $(Join-Path $root 'missing')`ndest = Gone`n"

        (Invoke-AB '--force').Code | Should -Not -Be 0
        Test-Path (Join-Path $state 'stamps/gone.checked') | Should -BeFalse
        Get-Content (Join-Path $state 'autobackup.log') -Raw | Should -Match 'root folder not found'
    }

    It 'warns about a job with no recent successful backup' {
        New-File (Join-Path $src 'a.txt')
        Set-Jobs "[old]`nroot = $src`ndest = Old`ncompress = none`n[fresh]`nroot = $src`ndest = Fresh`ncompress = none`n"

        (Invoke-AB '--force').Code | Should -Be 0
        (Get-Item (Join-Path $state 'stamps/old.checked')).LastWriteTime = (Get-Date).AddDays(-10)
        (Invoke-AB '--only', 'fresh').Code | Should -Be 0
        Get-Content (Join-Path $state 'autobackup.log') -Raw | Should -Match 'no successful backup in a while: old'
        (Invoke-AB '--list').Text | Should -Match 'old\s.*\sstale'
    }
}
