<#
  Writes app-inventory text files into -OutDir (default: %LOCALAPPDATA%\AutoBackup\inventory).
  Used as the `pre` command of the [app-inventory] job on Windows. PowerShell 5.1 and 7. ASCII-only.
  Output is deterministic (no timestamps) so unchanged inventories are not re-uploaded.

    winget.json       winget export: only packages winget can match to a source (reinstallable
                      with `winget import`). Apps it cannot match are silently left out.
    installed.csv     everything in "Installed apps" / Add or remove programs (registry), with versions
    store-apps.csv    Microsoft Store / MSIX apps that are not frameworks
    scoop.json        scoop export, if scoop is installed
#>
param([string]$OutDir = (Join-Path $env:LOCALAPPDATA 'AutoBackup\inventory'))

$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Write-Lines([string]$name, [string[]]$lines) {
    $path = Join-Path $OutDir $name
    if ($lines -and $lines.Count -gt 0) { [IO.File]::WriteAllLines($path, $lines, $utf8) }
    else { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
}

# 1. winget export, with its CreationDate stripped so identical inventories compare equal.
if (Get-Command winget -ErrorAction SilentlyContinue) {
    $tmp = Join-Path $OutDir '.winget-export.json'
    winget export -o $tmp --include-versions --accept-source-agreements --disable-interactivity 2>$null | Out-Null
    if (Test-Path -LiteralPath $tmp) {
        $j = Get-Content -LiteralPath $tmp -Raw | ConvertFrom-Json
        $j.PSObject.Properties.Remove('CreationDate')
        Write-Lines 'winget.json' @($j | ConvertTo-Json -Depth 20)
        Remove-Item -LiteralPath $tmp -Force
    }
}

# 2. Add or remove programs, straight from the registry (machine 64/32-bit + current user).
$keys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$apps = Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -and $_.SystemComponent -ne 1 -and -not $_.ParentKeyName } |
    Select-Object @{ n = 'Name'; e = { $_.DisplayName.Trim() } }, @{ n = 'Version'; e = { $_.DisplayVersion } }, Publisher |
    Sort-Object Name, Version -Unique
Write-Lines 'installed.csv' @($apps | ConvertTo-Csv -NoTypeInformation)

# 3. Store / MSIX apps. The Appx module needs Windows PowerShell compatibility on some 7.x builds.
try {
    if ($PSVersionTable.PSVersion.Major -ge 7) { Import-Module Appx -UseWindowsPowerShell -WarningAction SilentlyContinue -ErrorAction Stop }
    $store = Get-AppxPackage -ErrorAction Stop |
        Where-Object { -not $_.IsFramework -and $_.SignatureKind -eq 'Store' } |
        Select-Object Name, Version | Sort-Object Name
    Write-Lines 'store-apps.csv' @($store | ConvertTo-Csv -NoTypeInformation)
} catch { }

# 4. scoop, if present.
if (Get-Command scoop -ErrorAction SilentlyContinue) {
    Write-Lines 'scoop.json' @(scoop export 2>$null)
}

exit 0
