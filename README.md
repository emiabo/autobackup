# AutoBackup

Config-driven backup scripts that archive chosen folders with `tar` and drop the archives into a cloud sync folder: Proton Drive, iCloud Drive, Dropbox, Google Drive, OneDrive, or anything else that syncs a local folder. The sync app does the uploading, so there are no APIs, accounts or credentials to manage.

It started as an automated version of a manual habit: zip the Obsidian vault now and then, in case Obsidian Sync overwrites something. Tools like restic and kopia are the better fit for S3/B2-style object storage. This is for consumer sync folders, where every backup should be one ordinary file you can open anywhere.

Principles:

- **Set and forget.** One hourly scheduled run. Each job decides whether it's due and whether anything changed. Failures, jobs that haven't succeeded in a while, and a quarterly "is this list still right?" reminder show up as notifications.
- **Observable.** One source folder becomes one archive (`dotfiles_MyMac.tar.zst`) that any archive tool can open. Very large archives can be cut into numbered parts that join back with `cat` or `copy /b`.
- **Vendor-neutral.** It only writes to a folder. Version history comes from the sync service, or from `keep` when the service has none.
- **Universal.** One bash script for macOS and Linux, and one PowerShell script for Windows. They mirror each other and use the same config format.

## Quick start

macOS or Linux:

```sh
git clone https://github.com/emiabo/autobackup.git ~/Code/autobackup && cd ~/Code/autobackup
./autobackup.sh --edit       # creates ~/.config/autobackup/autobackup.conf from the template
./autobackup.sh --dry-run -v # check what it would write
./autobackup.sh --install    # hourly + at login
```

Windows (PowerShell 5.1 or 7):

```powershell
git clone https://github.com/emiabo/autobackup.git $HOME\Code\autobackup; cd $HOME\Code\autobackup
.\AutoBackup.ps1 -Edit       # creates %APPDATA%\AutoBackup\autobackup.conf from the template
.\AutoBackup.ps1 -DryRun -Verbose
.\AutoBackup.ps1 -Install    # hourly + at logon
```

Setting `drive_root` and `machine` is the only required edit. [SETUP.md](SETUP.md) covers the details: sync-app settings, macOS privacy permissions, and what `--install` sets up on each platform.

## Files

| File | What it is |
|---|---|
| `autobackup.sh` | macOS and Linux. bash 3.2+ (macOS `/bin/bash`). |
| `AutoBackup.ps1` | Windows. Windows PowerShell 5.1 and PowerShell 7. ASCII-only. |
| `templates/macos.conf`, `linux.conf`, `windows.conf` | Starting job lists. `--edit` / `-Edit` copies the right one into place. |
| `hooks/inventory.sh` | macOS/Linux app lists: `Applications.tsv`, `Brewfile`, `mas.txt`, apt/dnf/pacman/flatpak/snap lists, npm/pipx/uv/cargo globals. |
| `hooks/Inventory.ps1` | Windows app lists: `winget.json`, `installed.csv` (Add or remove programs, from the registry), `store-apps.csv`, `scoop.json`. |
| `SETUP.md` | Installing, scheduling, permissions, sync-app settings. |

Your own config lives outside the repo, so updating the scripts never touches it:

| | macOS / Linux | Windows |
|---|---|---|
| Config | `~/.config/autobackup/autobackup.conf` | `%APPDATA%\AutoBackup\autobackup.conf` |
| Stamps, log, lock | `~/.local/state/autobackup/` | `%LOCALAPPDATA%\AutoBackup\state\` |
| Staging (archives being built) | `~/.cache/autobackup/` | `%LOCALAPPDATA%\AutoBackup\staging\` |
| Inventory output | `~/.local/state/autobackup/inventory/` | `%LOCALAPPDATA%\AutoBackup\inventory\` |

The templates' `dotfiles` job already includes the config folder, so your job list is backed up along with everything else.

`winget export` only includes apps it can match to a winget source, so on its own it misses anything installed some other way. That's why the Windows hook also reads the registry's uninstall keys, the same list Settings shows.

## Drive layout

With the templates' jobs enabled on a Mac named `MyMac` and a PC named `MyPC`:

```
AutoBackup/
  Config/                 dotfiles_MyMac.tar.zst, dotfiles_MyPC.tar.zst,
                          Applications_MyMac.tsv, Brewfile_MyMac, installed_MyPC.csv, winget_MyPC.json, ...
  Code/                   code_MyMac.tar.zst
  Documents/Obsidian/     obsidian_MyMac.tar.zst
  Games/Minecraft/        <instance>_MyPC.tar.zst.001, .002, ... (one set per Prism instance)
```

Naming is `<name>_<machine><ext>`:

- `<name>` is the job name, the `name =` override, or the subfolder name for `per_subfolder` jobs. Anything outside `A-Z a-z 0-9 . _ -` becomes `-`.
- With `keep` above 1, a timestamp is added: `obsidian_MyMac_2026-09-27_130512.tar.zst`.
- With `chunk_size`, the archive is stored as numbered parts: `.tar.zst.001`, `.002`, ...
- In `copy` mode the machine suffix goes before the extension (`Brewfile_MyMac`, `installed_MyPC.csv`).

## How a run works

For each job in the config (or only the jobs named by `--only`):

1. **Skip it** if disabled, if not due (`stamps/<job>.checked` is younger than `every`), or if a process in `skip_if_running` is running. Nothing is recorded, so the job retries next run.
2. **Run `pre`** if set: `/bin/sh -c` on macOS/Linux, `Invoke-Expression` on Windows. A non-zero exit fails the job.
3. **Build each unit.** A job is one archive, or one per subfolder with `per_subfolder = true`.
   - **Skip if unchanged** when all of these hold: the archive exists in the drive folder; `stamps/<unit>.last` records the same settings, includes and excludes; and no file or folder under the includes is newer than that stamp.
   - **Otherwise build it.** If the unit contains git repos, `.gitignore` rules pick the files (below). tar writes to the staging folder, gets compressed, and is optionally cut into parts, then moved (renamed) into the drive folder.
   - The stamp is written **before** tar starts. Files that change mid-archive are therefore caught next run.
   - **Retention.** With `keep = 1`, the new archive replaces the old one. With `keep` above 1, older timestamped versions beyond `keep` (or `keep_max_size`) are deleted.
4. **Touch `stamps/<job>.checked`** if every unit succeeded.

After all jobs:

- A **failure** logs an error and shows a notification. The job isn't marked checked, so it retries next hour. A failed build never replaces the archive already in the drive folder.
- A job with **no successful pass for `alert_after`** (default: 3× its `every`, at least a day) is logged and notified, at most once a day. This catches jobs that never fail but never run either, like a `skip_if_running` process that's always open.
- Every **`review_every`** (default 90 days) you get a reminder to check the job list still covers what matters. Editing the config resets the clock.

Notifications use Notification Center on macOS, `notify-send` on Linux, and a native toast on Windows.

To force a job to be due again, delete its `.checked` stamp. To force a full rebuild, delete its `.last` stamps, or use `--force`.

## Usage

| bash | PowerShell | Effect |
|---|---|---|
| *(no flags)* | *(no flags)* | Run every job that is due. This is what the scheduler calls. |
| `-l`, `--list` | `-List` | Jobs, last successful pass, and ok/due/stale/disabled. |
| `-n`, `--dry-run` | `-DryRun` | Show what would be written. Changes nothing, runs no `pre`. |
| `-v`, `--verbose` | `-Verbose` | Also show not-due, unchanged, and missing-include details. |
| `-o JOB`, `--only JOB[,JOB]` | `-Only JOB[,JOB]` | Run just these jobs, ignoring the schedule. The unchanged check still applies. |
| `-f`, `--force` | `-Force` | Ignore the schedule and the unchanged check. |
| `-a [JOB] [k=v ...]`, `--add` | `-Add [JOB] [k=v ...]` | Append a job to the config. Prompts interactively when no `k=v` pairs are given. |
| `-e`, `--edit` | `-Edit` | Open the config in `$VISUAL`/`$EDITOR` (fallback: TextEdit, `xdg-open`, Notepad). Creates it from the template first. |
| `--install` | `-Install` | Schedule hourly + login runs (LaunchAgent, systemd user timer, or Task Scheduler). |
| `--uninstall` | `-Uninstall` | Remove the schedule. Config, state and archives stay. |
| `-c FILE`, `--config FILE` | `-Config FILE` | Use another config file. `$AUTOBACKUP_CONFIG` does the same. |

Examples:

```sh
./autobackup.sh --add screenshots root=~/Pictures/Screenshots dest=Pictures every=7d compress=none
./autobackup.sh --only screenshots --dry-run -v
```

```powershell
.\AutoBackup.ps1 -Add saves root='%USERPROFILE%\Saved Games' dest=Games/Saves every=7d
.\AutoBackup.ps1 -Only minecraft -DryRun -Verbose
```

## Config reference

The config is INI-style: a `[global]` section, then one `[job]` section per backup job. Other rules:

- `#` and `;` start comment lines.
- Keys are case-insensitive. Values are taken literally; don't quote them.
- `include` and `exclude` can repeat. Every other key uses its last value.
- Any job key set in `[global]` becomes the default for all jobs.
- `exclude` lines in `[global]` are added to each job's own excludes.
- Durations: `30m`, `12h`, `1d`, `2w` (a bare number means hours). Sizes: `500M`, `4G`, `1T`.

Path expansion applies to `root`, `drive_root`, `state`, `staging`, and `pre`:

- A leading `~` becomes your home folder.
- `{here}` becomes the script's folder, and `{machine}` the machine name.
- Windows also expands `%ENVVARS%` and accepts `/` or `\`.

**Global keys**

| Key | Default | Meaning |
|---|---|---|
| `drive_root` | *(required)* | Folder archives go into, inside the sync folder. Its parent must exist, or the run aborts. |
| `machine` | *(required)* | Suffix for every archive name (`MyMac`, `MyPC`). |
| `state`, `staging` | see Files | Override the state and staging folders. Staging must be on the same volume as `drive_root` (`--list` warns if not). |
| `review_every` | `90d` | How often to remind you to review the job list. `0` turns it off. |

**Job keys**

| Key | Default | Meaning |
|---|---|---|
| `root` | *(required)* | Folder the archive is built from. Paths inside the archive are relative to this. |
| `dest` | *(required)* | Subfolder of `drive_root`, e.g. `Games/Minecraft`. |
| `include` | `.` (all of root) | Path inside `root` to archive. Repeatable. Missing paths are skipped (shown with `-v`). |
| `exclude` | *(none)* | tar exclude pattern. Repeatable. Rules below. |
| `gitignore` | `true` | Inside git repos, archive only what git doesn't ignore. Details below. |
| `compress` | `zstd` | `zstd`, `gzip`, `none` (plain `.tar`), or `copy` (see below). |
| `level` | 3 (zstd), 6 (gzip) | Compression level. Use 1 for already-compressed data like game files. |
| `every` | `1d` | Minimum time between passes. |
| `skip_unchanged` | `true` | Skip the build when nothing changed since the last archive. |
| `per_subfolder` | `false` | One archive per non-hidden subfolder of `root`, named after the subfolder. `include` is ignored. Top-level `exclude` patterns also filter subfolder names. |
| `keep` | `1` | `1`: one archive, replaced on each change; rely on the sync service's version history. More than 1: timestamped archives, the newest `keep` are kept. |
| `keep_max_size` | *(none)* | With `keep` above 1, also delete the oldest versions once their total size would pass this. The newest is always kept. |
| `chunk_size` | *(none)* | Cut the archive into parts of at most this size (`.001`, `.002`, ...). Helps sync apps that struggle with multi-GB files. |
| `alert_after` | 3× `every`, min `1d` | Notify when the job hasn't had a successful pass for this long. `0` turns it off. |
| `skip_if_running` | *(none)* | Comma-separated process names. If any is running, skip and retry next run. |
| `pre` | *(none)* | Command to run first (e.g. an inventory hook). |
| `name` | job name | Archive base name. |
| `enabled` | `true` | `false` skips the job. |

**`copy` mode** doesn't archive. It copies each non-hidden file directly inside `root` (not recursive) to `dest`, renamed with the machine suffix, and only when its content changed. This keeps inventories readable in the sync service's web UI and on a phone.

**Exclude patterns** are passed to tar's `--exclude`. The scripts use bsdtar (libarchive) on all platforms when available: macOS `/usr/bin/tar`, Windows `tar.exe`, and `bsdtar` on Linux (package `libarchive-tools`). GNU tar follows the same rules for these patterns. Checked against bsdtar 3.5–3.7:

- **A pattern matches a path, or the end of one, at any depth.** `node_modules` and `*.sqlite` match that name anywhere. `.obsidian/workspace.json` matches that file under any folder, including the top.
- **`*` also matches `/`**: `*minecraft/logs` matches both `minecraft/logs` and `.minecraft/logs`.
- **There's no way to anchor a pattern to the root.** Use a more specific path if a short name would catch too much.
- **Slashes:** always write `/`. The PowerShell script converts `\` for you.

**`.gitignore` handling.** When a unit contains git repos (or sits inside one), the script builds tar's file list itself:

- **Inside each repo:** the files `git ls-files --cached --others --exclude-standard` reports. That's tracked plus untracked files, minus anything ignored by any `.gitignore`, `.git/info/exclude` or your global excludes file.
- **The `.git` folder:** kept, so unpushed commits are backed up too. Add `exclude = .git` if you don't want it.
- **Outside repos:** everything, as usual.
- **Job excludes:** still apply on top.

With `gitignore = false`, or when git isn't installed, units are archived without these rules. On macOS, git is only used if the Command Line Tools are installed, which avoids an install prompt from `/usr/bin/git`.

If your home folder is itself a git repo that ignores everything by default (a `*` line in `~/.gitignore`), jobs rooted in `~` would skip every untracked file. Set `gitignore = false` on those jobs.

**Change detection is conservative.** It ignores excludes and `.gitignore`. An excluded file that changes, such as a sqlite database, `workspace.json` or a `node_modules` install, can trigger a rebuild that wasn't needed. It can never cause a real change to be missed.

## Restoring

Extract to a scratch folder first and copy back what you need. Extracting dotfiles straight into `~` overwrites live config.

```sh
mkdir ~/restore-test
tar -xf dotfiles_MyMac.tar.zst -C ~/restore-test                 # bsdtar/GNU tar with zstd support
zstd -dc dotfiles_MyMac.tar.zst | tar -xf - -C ~/restore-test    # otherwise
cat Inst-One_MyPC.tar.zst.* | zstd -dc | tar -xf - -C ~/restore-test   # chunked archive
```

```powershell
New-Item -ItemType Directory "$HOME\restore-test" | Out-Null
zstd -d "Inst-One_MyPC.tar.zst" -o "$env:TEMP\r.tar"
tar.exe -xf "$env:TEMP\r.tar" -C "$HOME\restore-test"
cmd /c copy /b "Inst-One_MyPC.tar.zst.001+Inst-One_MyPC.tar.zst.002" "$env:TEMP\joined.tar.zst"   # chunked
```

Windows 11's Explorer can also open `.tar.zst` and `.tar.gz` directly, once the parts of a chunked archive are joined.

To get an older snapshot, restore that version in the sync service first (its version history), or pick an older timestamped file if the job uses `keep`. A Prism instance archive holds the instance folder's contents. Extract it into `%APPDATA%\PrismLauncher\instances\<name>\`, and Prism re-downloads libraries and assets on launch.

## Platform support

| | Status |
|---|---|
| **macOS** (tier 1) | Ran on macOS with `/bin/bash` 3.2 and bsdtar 3.5: plain, `per_subfolder`, `copy`, `.gitignore`, `keep` / `keep_max_size`, `chunk_size`, and the alerts. `--install` itself hasn't been run yet. |
| **Windows** (tier 1) | `AutoBackup.ps1` passed the same fixture run under PowerShell 7 on macOS with bsdtar. It has never run on Windows or under 5.1. The toast, Task Scheduler and `tar.exe` paths are untested. |
| **Linux** (tier 2) | Same fixture run passed in a Debian container (colima), once with GNU tar 1.35 and once with bsdtar 3.7.4, including the inventory hook. `--install` wrote systemd units that pass `systemd-analyze verify`, but the timer hasn't run under a real user session, and `notify-send` is untested. |

## Working on this

`autobackup.sh` and `AutoBackup.ps1` mirror each other. There's no canonical version, but a change to one should land in the other with the same flags, config keys, log messages and file layout. Both use the same function order and matching names (`cfg_load` / `Import-Cfg`, `archive_unit` / `Invoke-ArchiveUnit`, ...), so their diffs map across.

The one intended difference is how archives get built. bash pipes tar straight into zstd (and `split` for chunking), so no uncompressed copy touches the disk. PowerShell writes a raw `.tar` first and compresses it in a second step, because piping tar into zstd on Windows is reported to hang on inputs over a few hundred MB.

Constraints:

- **bash:** must run on 3.2. No associative arrays, `mapfile`, `${x,,}`, or `set -u` with empty arrays. Branch on `$AB_OS` for BSD vs GNU tools (`stat`, `date`).
- **PowerShell:** must run on 5.1.
  - Keep the file ASCII-only.
  - No `??`, `?:`, `&&`, or `$IsWindows`.
  - Use 2-arg `Join-Path`.
  - Functions return `$true`/`$false`. All logging goes through `[Console]::Out` or `Error` (`Write-Log`, `Say`), never `Write-Output`, so return values stay clean.

Testing without touching real data: point `--config` at a test config whose `drive_root`, `state` and `staging` live in a scratch folder. `AUTOBACKUP_TAR` overrides the tar binary. For example, `AUTOBACKUP_TAR=/usr/bin/tar pwsh AutoBackup.ps1 ...` exercises the Windows script on macOS with the same bsdtar.

## Not done yet

**Never run for real**

- Neither script has run against a real sync folder or from its scheduler.
- `hooks/Inventory.ps1` has only been parse-checked. The Linux half of `hooks/inventory.sh` has only run on Debian (apt).

**To verify per sync service**

- The scripts replace each `keep = 1` archive by rename. Confirm the service records a new version of the same file each time, rather than a delete plus a new file with no history.
- Set version-history retention, and check quota after a few weeks.
- Marking `AutoBackup/` as online-only (Dropbox, iCloud "Optimize Mac Storage", OneDrive Files On-Demand, Proton "Free up space") should stop archives from doubling local disk use. Unchanged checks only look at whether the file exists, so placeholders are fine. Worth confirming.

**Windows-specific unknowns**

- Whether exclude matching in Windows `tar.exe` is case-sensitive.
- Whether this Windows build's `tar.exe` has native zstd. The script detects this and falls back either way.
- Git-managed file lists are written in the ANSI code page for `tar.exe -T`. Paths that code page can't represent would make that archive fail, with an error in the log.

**Deliberately not backed up (your call)**

- Some secrets are inside included folders, e.g. `~/.config/gh/hosts.yml`. Whether that's acceptable depends on whether your sync service is end-to-end encrypted. Add excludes if you'd rather keep tokens out.
- Prism's `accounts.json` (login tokens) is outside `instances/`, so the Minecraft job never picks it up.

**Missing features**

- No restore command; restore is manual (above).
- `keep = 1` archives are never pruned. Archives for deleted `per_subfolder` subfolders or renamed jobs stay in the drive folder until deleted by hand.
- Chunked parts land one at a time, so the sync app can briefly see a mix of old and new parts.
- Rebuilds are whole-archive. A small change in a large folder re-uploads all of it; `per_subfolder` and tighter `include` lists keep units small.

**Not in scope**

- Full-disk images (Time Machine, Windows system images) are a separate layer.

## License

[Mozilla Public License 2.0](LICENSE).
