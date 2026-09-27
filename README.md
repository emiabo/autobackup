# AutoBackup

Small, config-driven backup scripts for macOS and Windows. They archive selected folders with `tar` and drop the archives into a cloud sync folder (Proton Drive, iCloud Drive, Dropbox, Google Drive, OneDrive...). The sync service's version history then acts as the snapshot history.

Each machine has its own job list (`mac.conf` or `win.conf`) next to the scripts. Those files are personal and git-ignored; start from the matching file in `templates/`.

A scheduler starts the script hourly. Each job decides for itself whether it's due and whether anything changed, so sleep and shutdown never cause missed backups. Scheduling setup and the reasoning behind it are in [SETUP.md](SETUP.md).

## Files

| File | What it is |
|---|---|
| `mac-backup.fish` | **Canonical implementation.** Edit this one first. |
| `mac-backup.sh` | Port for bash 3.2+ (macOS `/bin/bash`). Same flags, same behavior. |
| `win-backup.ps1` | Port for Windows PowerShell 5.1 and PowerShell 7. ASCII-only. |
| `templates/mac.conf` | Starting Mac job list. Copy to `mac.conf` (used by both Mac scripts). |
| `templates/win.conf` | Starting Windows job list. Copy to `win.conf`. |
| `hooks/mac-inventory.sh` | Writes `Applications.tsv`, `Brewfile`, `mas.txt`, and npm/pipx/uv/cargo lists. |
| `hooks/win-inventory.ps1` | Writes `winget.json`, `installed.csv` (Add or remove programs, from the registry), `store-apps.csv`, `scoop.json`. |
| `SETUP.md` | Install, test, LaunchAgent, Task Scheduler, permissions. |

`winget export` only includes apps it can match to a winget source, so on its own it misses anything installed some other way. That's why the Windows hook also reads the registry's uninstall keys, the same list Settings shows.

## Drive layout

With the templates' jobs enabled on a Mac named `MyMac` and a PC named `MyPC`:

```
AutoBackup/
  Config/                 dotfiles_MyMac.tar.zst, dotfiles_MyPC.tar.zst,
                          Applications_MyMac.tsv, Brewfile_MyMac, installed_MyPC.csv, winget_MyPC.json, ...
  Code/                   code_MyMac.tar.zst
  Documents/Obsidian/     obsidian_MyMac.tar.zst
  Games/Minecraft/        <instance name>_MyPC.tar.zst (one per Prism instance)
```

Naming is `<name>_<machine><ext>`. `<name>` is the job name, the `name =` override, or the subfolder name for `split` jobs, with anything outside `A-Z a-z 0-9 . _ -` turned into `-`. In `copy` mode the machine suffix goes before the extension (`Brewfile_MyMac`, `installed_MyPC.csv`).

Each archive keeps the same filename forever. Every change uploads a new version of that file, so no dated copies pile up.

## How a run works

For each job in the config (or only the jobs named by `--only`):

1. **Skip it** if disabled, if not due (`stamps/<job>.checked` is younger than `every`), or if a process in `skip_if_running` is running. Nothing is recorded in these cases, so the job retries next run.
2. **Run `pre`** if set: `/bin/sh -c` on the Mac, `Invoke-Expression` on Windows. A non-zero exit fails the job.
3. **Build each unit.** A job is one archive, or one per subfolder with `split = true`.
   - **Skip if unchanged** when all of these hold: the archive already exists in Drive; `stamps/<unit>.last` records the same root, method, level, includes and excludes; and no file or folder under the includes is newer than that stamp.
   - Otherwise tar into the staging folder, compress, and move (rename) into the Drive folder.
   - The stamp is written **before** tar starts. Files that change mid-archive are therefore caught next run.
4. **Touch `stamps/<job>.checked`** if every unit succeeded.

Failures are logged. The job isn't marked checked, so it retries next hour. On the Mac a notification appears; on Windows one appears only if BurntToast is installed. A failed build never replaces the archive already in Drive.

State lives outside the project folder:

| | Mac | Windows |
|---|---|---|
| Stamps, log, lock | `~/.local/state/autobackup/` | `%LOCALAPPDATA%\AutoBackup\state\` |
| Staging (temp archives) | `~/.cache/autobackup/` | `%LOCALAPPDATA%\AutoBackup\staging\` |
| Inventory output | `~/.local/state/autobackup/inventory/` | `%LOCALAPPDATA%\AutoBackup\inventory\` |

Staging must be on the same volume as the Drive folder, so that the final move is an atomic rename. The defaults satisfy this.

To force a job to be due again, delete its `.checked` stamp. To force a full rebuild, delete its `.last` stamps, or use `--force`.

## Usage

| fish / bash | PowerShell | Effect |
|---|---|---|
| *(no flags)* | *(no flags)* | Run every job that is due. This is what the scheduler calls. |
| `-l`, `--list` | `-List` | Jobs, last successful pass, due/ok/disabled. |
| `-n`, `--dry-run` | `-DryRun` | Show what would be written. Changes nothing, runs no `pre`. |
| `-v`, `--verbose` | `-Verbose` | Also show not-due, unchanged, and missing-include details. |
| `-o JOB`, `--only JOB[,JOB]` | `-Only JOB[,JOB]` | Run just these jobs, ignoring the schedule. Unchanged check still applies. |
| `-f`, `--force` | `-Force` | Ignore the schedule and the unchanged check. |
| `-a [JOB] [k=v ...]`, `--add` | `-Add [JOB] [k=v ...]` | Append a job to the config. Prompts interactively when no `k=v` pairs are given. |
| `-e`, `--edit` | `-Edit` | Open the config in `$EDITOR` (Mac falls back to TextEdit, Windows to Notepad). |
| `-c FILE`, `--config FILE` | `-Config FILE` | Use another config file. |

Examples:

```fish
./mac-backup.fish --add screenshots root=~/Pictures/Screenshots dest=Pictures every=7d compress=none
./mac-backup.fish --only screenshots --dry-run -v
```

```powershell
.\win-backup.ps1 -Add saves root='%USERPROFILE%\Saved Games' dest=Games/Saves every=7d
.\win-backup.ps1 -Only minecraft -DryRun -Verbose
```

## Config reference

The config is INI-style: a `[global]` section, then one `[job]` section per backup job. Other rules:

- `#` and `;` start comment lines.
- Keys are case-insensitive. Values are taken literally; don't quote them.
- `include` and `exclude` can repeat. Every other key uses its last value.
- Any job key set in `[global]` becomes the default for all jobs.
- `exclude` lines in `[global]` are added to each job's own excludes.

Path expansion applies to `root`, `drive_root`, `state`, `staging`, and `pre`:

- A leading `~` becomes your home folder.
- `{here}` becomes the script's folder, and `{machine}` the machine name.
- Windows also expands `%ENVVARS%` and accepts `/` or `\`.

**Global keys**

| Key | Meaning |
|---|---|
| `drive_root` | Folder archives go into (inside the cloud sync folder). Its parent must exist, or the run aborts. |
| `machine` | Suffix for every archive name (`MyMac`, `MyPC`). |
| `state`, `staging` | Override the state and staging folders above. |

**Job keys**

| Key | Default | Meaning |
|---|---|---|
| `root` | *(required)* | Folder the archive is built from. Paths inside the archive are relative to this. |
| `dest` | *(required)* | Subfolder of `drive_root`, e.g. `Games/Minecraft`. |
| `include` | `.` (all of root) | Path inside `root` to archive. Repeatable. Missing paths are skipped (shown with `-v`). |
| `exclude` | *(none)* | tar exclude pattern. Repeatable. Rules below. |
| `compress` | `zstd` | `zstd`, `gzip`, `none` (plain `.tar`), or `copy` (see below). |
| `level` | 3 (zstd), 6 (gzip) | Compression level. Use 1 for already-compressed data like game files. |
| `every` | `1d` | Minimum time between passes: `30m`, `12h`, `1d`, `2w`. A bare number means hours. |
| `skip_unchanged` | `true` | Skip the build when nothing changed since the last archive. |
| `split` | `false` | One archive per non-hidden subfolder of `root`, named after the subfolder. `include` is ignored. Top-level `exclude` patterns also filter subfolder names. |
| `skip_if_running` | *(none)* | Comma-separated process names. If any is running, skip and retry next run. |
| `pre` | *(none)* | Command to run first (e.g. an inventory hook). |
| `name` | job name | Archive base name. |
| `enabled` | `true` | `false` skips the job. |

**`copy` mode** doesn't archive. It copies each non-hidden file directly inside `root` (not recursive) to `dest`, renamed with the machine suffix, and only when its content changed. This keeps inventories readable in the Drive web UI and on the phone.

**Exclude patterns.** All three scripts pass patterns to bsdtar/libarchive: the `tar` on macOS and Windows' `tar.exe`. The rules below were verified against bsdtar 3.7:

- **No slash** matches that name at any depth: `node_modules`, `*.sqlite`, `logs`.
- **With a slash**, the pattern is anchored at the root-relative path: `.codex/sessions`, `.obsidian/workspace.json`. It matches whether the include was `.` or an explicit path.
- **`*` also matches `/`**, which gives "at any depth under something": `*minecraft/logs` matches both `minecraft/logs` and `.minecraft/logs`.
- **Slashes:** always write `/`. The PowerShell port converts `\` for you.

**Change detection is conservative.** It ignores excludes. An excluded file that changes, such as Codex's sqlite databases or Obsidian's `workspace.json`, can trigger a rebuild that wasn't needed. It can never cause a real change to be missed.

## Restoring

Extract to a scratch folder first and copy back what you need. Extracting dotfiles straight into `~` overwrites live config.

```fish
mkdir ~/restore-test
zstd -dc dotfiles_MyMac.tar.zst | tar -xf - -C ~/restore-test   # or: tar -xf file.tar.zst -C ... if tar has zstd
tar -xzf something_MyMac.tar.gz -C ~/restore-test
```

```powershell
New-Item -ItemType Directory "$HOME\restore-test" | Out-Null
zstd -d "Inst-One_MyPC.tar.zst" -o "$env:TEMP\r.tar"
tar.exe -xf "$env:TEMP\r.tar" -C "$HOME\restore-test"
```

Windows 11's Explorer can also open `.tar.zst` and `.tar.gz` directly.

To get an older snapshot, restore that version in the sync service first (its version history), then extract. A Prism instance archive holds the instance folder's contents. Extract it into `%APPDATA%\PrismLauncher\instances\<name>\`, and Prism re-downloads libraries and assets on launch.

## Working on this (notes for Claude Code)

**The fish script is canonical.** When it changes, port the change to `mac-backup.sh` and `win-backup.ps1`, keeping behavior, flags, log messages and file layout identical. All three share the same function layout, in the same order and with matching names (`cfg_load`/`Import-Cfg`, `archive_unit`/`Invoke-ArchiveUnit`, ...), so diffs map across.

Constraints per port:

- **bash:** must run on 3.2. No associative arrays, `mapfile`, `${x,,}`, or `set -u` with empty arrays.
- **PowerShell:** must run on 5.1.
  - Keep the file ASCII-only.
  - No `??`, `?:`, `&&`, or `$IsWindows`.
  - Use 2-arg `Join-Path`.
  - Functions return `$true`/`$false`. All logging goes through `[Console]::Out` or `Error` (`Write-Log`, `Say`), never `Write-Output`, so return values stay clean.

**How it was tested.** No real Mac or Windows machine was involved. The test machine was Ubuntu 24.04 with:

- bsdtar 3.7.2, which is the same libarchive tar that macOS and Windows ship;
- fish 3.7, bash 5.2, zstd 1.5.5, and pwsh 7.6.

A fake home folder held fixtures: `.claude`/`.codex` trees with sessions and sqlite files, a vault, and Prism instances with logs. Two env vars redirected the scripts:

- `AUTOBACKUP_CONFIG` points at a test config.
- `AUTOBACKUP_TAR=bsdtar` avoids Linux's GNU tar. The Windows port also uses `AUTOBACKUP_TAR` in place of `System32\tar.exe`.

The fish and bash ports produced byte-identical output across a scripted run. The PowerShell port produced the same archives with the same contents. The run covered:

- dry-run, due and not-due, and the unchanged skip;
- change detection, and a config edit forcing a rebuild;
- `split`, `copy`, and `skip_if_running`;
- `--add`, both interactive and `k=v`, plus duplicate-name rejection;
- a bad `--only`, the lock/mutex, a missing drive folder, and a failing `pre`.

## Not done yet

**Never run for real**

- The scripts haven't run on macOS or Windows (see testing above).
- `mac-backup.sh` hasn't run under bash 3.2.
- `win-backup.ps1` hasn't run under Windows PowerShell 5.1 at all; only 7.6 on Linux.
- `hooks/win-inventory.ps1` has only been parse-checked.
- `hooks/mac-inventory.sh` ran on Linux with fake `.app` folders; PlistBuddy, brew and mas paths are untested.

**Paths to fill in** (after copying a template)

- `drive_root` and `machine`.
- `root` for `[obsidian]` in mac.conf, then set `enabled = true` on the example jobs you want.

**Proton behavior to verify**

- The scripts replace each archive by rename. Confirm that Proton records a new version of the same file each time, rather than a delete plus a new file with no history.
- Set retention, and check quota after a few weeks.

**macOS permissions.** TCC may block the LaunchAgent from reading `~/Documents` or writing into CloudStorage. See SETUP.md, section 4, for the Full Disk Access trade-offs.

**Windows-specific unknowns**

- Whether exclude matching in Windows `tar.exe` is case-sensitive.
- Whether this Windows build's `tar.exe` has native zstd. The script detects this and falls back either way.

**Deliberately not backed up (your call)**

- Some secrets are inside included folders, e.g. `~/.config/gh/hosts.yml`. Whether that's acceptable depends on whether your sync service is end-to-end encrypted. Add excludes if you'd rather keep tokens out.
- Prism's `accounts.json` (login tokens) is outside `instances/`, so the Minecraft job never picks it up.

**Missing features**

- No restore script; restore is manual (above).
- No pruning. Archives for deleted `split` subfolders or renamed jobs stay in Drive until deleted by hand.
- The change check ignores excludes (conservative, as described above).
- Windows has no failure notification without BurntToast.

**Not in scope**

- Time Machine is unchanged and still the full-disk layer on the Mac.
- The Windows Backup app (OneDrive-based settings/app list) is independent of this.
