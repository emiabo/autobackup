# Setup and scheduling

## Why hourly instead of "daily at 3am"

A fixed-time schedule fails whenever the machine is asleep or off at that time. cron on macOS skips missed runs entirely, and Task Scheduler only catches up if a specific setting is on.

So the scheduler here does nothing clever. It starts the script **every hour** and **at login/boot**. The script decides per job whether work is needed:

1. **Due check.** Each job has `every` (e.g. `1d`, `7d`). The script compares that to the job's last successful pass (`stamps/<job>.checked`). Not due means exit in milliseconds.
2. **Changed check.** If due, it looks for any file newer than the last archive. Nothing newer means it records a successful pass without uploading anything.
3. **Build.** Only then does it tar, compress, and move the archive into the Proton folder.

The result: a daily job runs within about an hour of the Mac or PC first being awake after 24 hours have passed. That holds no matter when it slept or shut down.

A lock (a lock dir on Mac, a named mutex on Windows) stops the hourly run from colliding with a manual one.

## Proton Drive (both machines)

1. Make the root folder: create `AutoBackup` inside your Proton Drive sync folder. The scripts create subfolders themselves.
2. Set version-history retention at proton.me > Drive > Settings.
   - Every archive keeps one filename, so Proton's version history is the snapshot history.
   - Old versions use quota. With about 14 GB of weekly game archives, 3 months of history is roughly 180 GB worst case. Pick a period that fits your 520 GB.
3. After the first two real runs, check that versions accumulate. Open any archive in the Proton web app, then open Version history. It should list two entries, not one. See README > Not done yet.

## macOS

### 1. Install

```fish
# Put the folder somewhere stable, then:
cd ~/Code/autobackup
chmod +x mac-backup.fish mac-backup.sh hooks/mac-inventory.sh
brew install zstd   # optional; without it the script uses tar's built-in zstd, or falls back to gzip
```

### 2. Configure and test by hand

```fish
cp templates/mac.conf mac.conf
ls ~/Library/CloudStorage          # find your sync folder's name for drive_root
./mac-backup.fish --edit           # set drive_root, machine, and enable the jobs you want
./mac-backup.fish --list
./mac-backup.fish --dry-run -v     # shows every archive it would write, and skipped includes
./mac-backup.fish --force          # first real run
./mac-backup.fish --list           # everything should now say "ok"
```

### 3. LaunchAgent

A LaunchAgent (not a LaunchDaemon) runs as you, in your login session, only while you're logged in. That's correct here: the Proton folder and your home folder are only reachable in your session.

`RunAtLoad` fires at login. `StartInterval` fires hourly while awake. After a wake, the next check is at most an hour away.

Save this as `~/Library/LaunchAgents/local.autobackup.plist`. Replace `YOU` with your short username (`whoami`).

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>local.autobackup</string>
    <key>ProgramArguments</key>
    <array>
        <string>/opt/homebrew/bin/fish</string>
        <string>/Users/YOU/Code/autobackup/mac-backup.fish</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
    <key>StandardOutPath</key>
    <string>/Users/YOU/.local/state/autobackup/launchd.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOU/.local/state/autobackup/launchd.log</string>
</dict>
</plist>
```

Load it and trigger one run now:

```fish
launchctl bootstrap gui/(id -u) ~/Library/LaunchAgents/local.autobackup.plist
launchctl kickstart -k gui/(id -u)/local.autobackup
launchctl print gui/(id -u)/local.autobackup | grep -E 'state|last exit code'
tail ~/.local/state/autobackup/autobackup.log ~/.local/state/autobackup/launchd.log
```

After editing the plist, run `launchctl bootout gui/(id -u)/local.autobackup`, then `bootstrap` again. Editing the scripts or `mac.conf` needs no reload.

macOS will show a "Background item added" notice. The agent also appears under System Settings > General > Login Items & Extensions.

### 4. Privacy permissions (TCC)

A launchd job doesn't inherit your terminal's permissions. If a scheduled run logs `Operation not permitted` on a path that works when you run the script by hand, TCC is blocking it. This is most likely for a vault under `~/Documents` or `~/Desktop`, or for the CloudStorage folder.

- **First try:** run `kickstart` (above) while at the Mac and approve any prompt that appears.
- **If there's no prompt:** go to System Settings > Privacy & Security > Full Disk Access and add the interpreter. Homebrew's fish binary lives at a versioned Cellar path (`realpath (command -v fish)`), and every `brew upgrade fish` changes that path and silently drops the grant.
- **Stable alternative:** point the plist at `/bin/bash` + `mac-backup.sh`, and grant Full Disk Access to `/bin/bash` once. That path never changes. The trade-off is that you must propagate script edits from the fish file to the bash file. Config edits apply to both automatically.

### 5. Alfred

Replace the old Obsidian script's command with:

```sh
/opt/homebrew/bin/fish ~/Code/autobackup/mac-backup.fish --only obsidian
```

`--only` ignores the schedule but still skips the upload when the vault hasn't changed. Add `--force` to always rebuild.

## Windows

### 1. Install

```powershell
# Put the folder at e.g. $HOME\Code\autobackup, then from that folder:
Get-ChildItem -Recurse | Unblock-File     # clears the downloaded-file flag
winget install -e --id Meta.Zstandard     # optional; see below
& "$env:SystemRoot\System32\tar.exe" --version
```

The script always uses Windows' own `tar.exe`, never Git for Windows' GNU tar, because exclude patterns behave differently between the two. If `tar --version` lists `libzstd`, the built-in tar can do zstd alone. Otherwise the zstd CLI from winget handles it. With neither available, archives fall back to `.tar.gz`.

The script compresses in two steps (tar to a temp file, then zstd) instead of piping. Piping tar into zstd on Windows is reported to hang on inputs over a few hundred MB.

### 2. Configure and test by hand

Works in both `pwsh` (7) and `powershell` (5.1).

```powershell
Copy-Item templates\win.conf win.conf
.\win-backup.ps1 -Edit              # set drive_root, machine, and enable the jobs you want
.\win-backup.ps1 -List
.\win-backup.ps1 -DryRun -Verbose
.\win-backup.ps1 -Force             # first real run; Minecraft at level 1 is the slow one
```

### 3. Scheduled task

Run this once from an **admin** PowerShell. Admin is only needed to register the logon trigger; the task itself runs as you, unelevated, only while you're logged in.

```powershell
$dir = "$HOME\Code\autobackup"
$exe = (Get-Command pwsh).Source   # or "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $dir `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dir\win-backup.ps1`""
$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 3)
Register-ScheduledTask -TaskName 'AutoBackup' -Action $action -Trigger $triggers -Settings $settings `
    -Description 'Hourly check; jobs run when due. Config: win.conf next to win-backup.ps1.'
Start-ScheduledTask -TaskName 'AutoBackup'
```

What each piece does:

- **`-StartWhenAvailable`** is the GUI's "Run task as soon as possible after a scheduled start is missed." It covers the PC being off or asleep at the top of the hour.
- **`-AtLogOn`** covers first boot of the day.
- **`-MultipleInstances IgnoreNew`** stops a slow Minecraft run from stacking up. The script's own mutex covers manual runs too.

Verify it:

- Open Task Scheduler > AutoBackup > Triggers. The one-time trigger should say "repeat every 1 hour indefinitely". If it shows a duration, edit it to Indefinitely.
- Check the log: `Get-Content "$env:LOCALAPPDATA\AutoBackup\state\autobackup.log" -Tail 20`.

`-WindowStyle Hidden` still flashes a console window for a split second each hour. To remove the flash, change the action's program to `conhost.exe`, with arguments `--headless "<path to pwsh.exe>" -NoProfile ...` (the same arguments as above).

Failure notifications on Windows are optional: `Install-Module BurntToast -Scope CurrentUser` and the script will use it. Without it, failures only appear in the log.
