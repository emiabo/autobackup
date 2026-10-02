# Setup and scheduling

## Why hourly instead of "daily at 3am"

A fixed-time schedule fails whenever the machine is asleep or off at that time. cron on macOS skips missed runs entirely, and Task Scheduler only catches up if a specific setting is on.

So the scheduler here does nothing clever. It starts the script **every hour** and **at login**. The script decides per job whether work is needed:

1. **Due check.** Each job has `every` (e.g. `1d`, `7d`). The script compares that to the job's last successful pass (`stamps/<job>.checked`). Not due means exit in milliseconds.
2. **Changed check.** If due, it looks for any file newer than the last archive. Nothing newer means it records a successful pass without uploading anything.
3. **Build.** Only then does it tar, compress, and move the archive into the sync folder.

The result: a daily job runs within about an hour of the computer first being awake after 24 hours have passed. That holds no matter when it slept or shut down.

A lock (a lock dir on macOS/Linux, a named mutex on Windows) stops the hourly run from colliding with a manual one.

## The sync service

1. **Make the root folder.** Create `AutoBackup` inside your sync folder, and put its path in `drive_root`. The scripts create subfolders themselves.
2. **Decide on version history.**
   - With `keep = 1` (the default), every archive keeps one filename. The service's version history is then the snapshot history. Check its retention setting and how much quota old versions use; for example, 14 GB of weekly game archives over 3 months is roughly 180 GB worst case.
   - If the service keeps no usable history (iCloud Drive, or a free tier with short retention), set `keep = 5` (or similar) in `[global]` so the script keeps timestamped copies itself. `keep_max_size` caps their total size.
3. **Consider online-only.** Marking `AutoBackup/` online-only in the sync app frees the local copy of each archive after upload.
4. **Check after the first two real runs.** For a `keep = 1` job, open any archive in the service's web app and look at its version history. It should list two entries, not one.

## macOS

### 1. Install

```sh
cd ~/Code/autobackup
brew install zstd              # optional; without it archives fall back to .tar.gz (macOS tar has no zstd)
./autobackup.sh --edit         # creates ~/.config/autobackup/autobackup.ini; set drive_root
ls ~/Library/CloudStorage      # helps find your sync folder's name
./autobackup.sh --list
./autobackup.sh --dry-run -v   # shows every archive it would write, and skipped includes
./autobackup.sh --install
```

`--install` writes `~/Library/LaunchAgents/local.autobackup.plist` and loads it. It runs `/bin/bash autobackup.sh --config <your config>`:

- **At once and at every login** (`RunAtLoad`).
- **Hourly while awake** (`StartInterval`). After a wake, the next check is at most an hour away.
- **At low priority** (`Nice`, `LowPriorityIO`).

A LaunchAgent (not a LaunchDaemon) runs as you, only while you're logged in. That's correct here: your home folder and the sync folder are only reachable in your session. macOS shows a "Background item added" notice, and the agent appears under System Settings > General > Login Items & Extensions.

Check on it (bash or zsh):

```bash
launchctl print gui/$(id -u)/local.autobackup | grep -E 'state|last exit code'
tail ~/.local/state/autobackup/autobackup.log ~/.local/state/autobackup/launchd.log
```

Or in fish:

```fish
launchctl print gui/(id -u)/local.autobackup | grep -E 'state|last exit code'
tail ~/.local/state/autobackup/autobackup.log ~/.local/state/autobackup/launchd.log
```

Editing the scripts or the config needs no reinstall. Moving the repo folder does: run `--install` again from the new location. `--uninstall` removes the agent.

### 2. Privacy permissions (TCC)

A launchd job doesn't inherit your terminal's permissions. If a scheduled run logs `Operation not permitted` on a path that works when you run the script by hand, TCC is blocking it. This is most likely for folders under `~/Documents` or `~/Desktop`, or for `~/Library/CloudStorage`.

- **First try:** watch the first scheduled run (it starts right after `--install`) and approve any prompt that appears.
- **If there's no prompt:** go to System Settings > Privacy & Security > Full Disk Access and add `/bin/bash` (press ⌘⇧G in the file picker to type the path). The agent always runs through `/bin/bash`, a path that never changes, so the grant survives updates.

### 3. Run a job on demand

From a launcher like Alfred or Raycast, or a shell alias:

```sh
~/Code/autobackup/autobackup.sh --only dotfiles
```

`--only` ignores the schedule but still skips the upload when nothing changed. Add `--force` to always rebuild.

## Linux

Same steps as macOS:

```sh
./autobackup.sh --edit && ./autobackup.sh --dry-run -v && ./autobackup.sh --install
```

`--install` writes `autobackup.service` and `autobackup.timer` to `~/.config/systemd/user/` and enables the timer. It runs 2 minutes after login, then hourly, at idle I/O priority. Output also goes to the journal:

```sh
systemctl --user list-timers autobackup.timer
journalctl --user -u autobackup.service -n 50
```

User timers only run while you're logged in, which matches the macOS behavior. Without systemd, `--install` prints a crontab line to add instead.

Recommended packages:

- `zstd` for multithreaded compression.
- `libarchive-tools` (bsdtar), so excludes and archive details match macOS and Windows exactly. GNU tar works too.
- `libnotify` (`notify-send`) for notifications.

## Windows

### 1. Install

Works in both `powershell` (5.1) and `pwsh` (7).

```powershell
cd $HOME\Code\autobackup
Get-ChildItem -Recurse | Unblock-File   # only needed if you downloaded a zip
winget install -e --id Meta.Zstandard   # optional; see below
.\AutoBackup.ps1 -Edit                  # creates %APPDATA%\AutoBackup\autobackup.ini; set drive_root
.\AutoBackup.ps1 -List
.\AutoBackup.ps1 -DryRun -Verbose
.\AutoBackup.ps1 -Install
```

**tar and zstd.** The script always uses Windows' own `tar.exe`, never Git for Windows' GNU tar, so behavior matches the other platforms.

- If `tar.exe --version` lists `libzstd`, the built-in tar can do zstd alone.
- Otherwise the zstd CLI from winget handles it.
- With neither available, archives fall back to `.tar.gz`.

### 2. The scheduled task

`-Install` registers a task named `AutoBackup`:

- **Runs as you, unelevated, only while you're logged in.**
- **Triggers:** at logon, plus a repeating hourly trigger.
- **Catch-up:** "Run task as soon as possible after a scheduled start is missed" (`-StartWhenAvailable`) covers the PC being off or asleep at the top of the hour.
- **No stacking:** a slow run blocks the next one (`-MultipleInstances IgnoreNew`). The script's own mutex covers manual runs too.
- **Interpreter:** Windows PowerShell 5.1 (`powershell.exe`), even if you ran `-Install` from pwsh. It's always present and can show toast notifications without extra modules.

If registration fails with "Access is denied", run `-Install` once from an admin PowerShell. The task still runs as you, unelevated.

Check on it:

- Open Task Scheduler > AutoBackup > Triggers. The one-time trigger should say "repeat every 1 hour indefinitely". If it shows a duration, edit it to Indefinitely.
- Check the log: `Get-Content "$env:LOCALAPPDATA\AutoBackup\state\autobackup.log" -Tail 20`.

`-WindowStyle Hidden` still flashes a console window for a split second each hour. To remove the flash, edit the task's action: set the program to `conhost.exe`, and put `--headless "<path to powershell.exe>"` in front of the existing arguments.

`-Uninstall` removes the task.
