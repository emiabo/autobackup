# AutoBackup

[![test](https://github.com/emiabo/autobackup/actions/workflows/test.yml/badge.svg)](https://github.com/emiabo/autobackup/actions/workflows/test.yml)

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
./autobackup.sh --edit       # creates ~/.config/autobackup/autobackup.ini from the template
./autobackup.sh --dry-run -v # check what it would write
./autobackup.sh --install    # hourly + at login
```

Windows (PowerShell 5.1 or 7):

```powershell
git clone https://github.com/emiabo/autobackup.git $HOME\Code\autobackup; cd $HOME\Code\autobackup
.\AutoBackup.ps1 -Edit       # creates %APPDATA%\AutoBackup\autobackup.ini from the template
.\AutoBackup.ps1 -DryRun -Verbose
.\AutoBackup.ps1 -Install    # hourly + at logon
```

Setting `drive_root` and `machine` is the only required edit. [SETUP.md](SETUP.md) covers the details: sync-app settings, macOS privacy permissions, and what `--install` sets up on each platform.

## Files

| File | What it is |
|---|---|
| `autobackup.sh` | macOS and Linux. bash 3.2+ (macOS `/bin/bash`). |
| `AutoBackup.ps1` | Windows. Windows PowerShell 5.1 and PowerShell 7. ASCII-only. |
| `templates/macos.ini`, `linux.ini`, `windows.ini` | Starting configs: app inventory and dotfiles jobs, plus commented-out examples. `--edit` / `-Edit` copies the right one into place. |
| `rulegroups.ini` | Example rules for known folders (coding agents, notes, some apps and games), for jobs to reuse. See [Rulegroups](#rulegroups). |
| `restore.sh`, `Restore.ps1` | Optional. Find, verify and extract archives. See [Restoring](#restoring). |
| `hooks/inventory.sh` | macOS/Linux app lists: `Applications.tsv`, `Brewfile`, `mas.txt`, apt/dnf/pacman/flatpak/snap lists, npm/pipx/uv/cargo globals. |
| `hooks/Inventory.ps1` | Windows app lists: `winget.json`, `installed.csv` (Add or remove programs, from the registry), `store-apps.csv`, `scoop.json`. |
| `SETUP.md` | Installing, scheduling, permissions, sync-app settings. |

Your own config lives outside the repo, so updating the scripts never touches it:

| | macOS / Linux | Windows |
|---|---|---|
| Config | `~/.config/autobackup/autobackup.ini` | `%APPDATA%\AutoBackup\autobackup.ini` |
| Stamps, log, lock | `~/.local/state/autobackup/` | `%LOCALAPPDATA%\AutoBackup\state\` |
| Staging (archives being built) | `~/.cache/autobackup/` | `%LOCALAPPDATA%\AutoBackup\staging\` |
| Inventory output | `~/.local/state/autobackup/inventory/` | `%LOCALAPPDATA%\AutoBackup\inventory\` |

The templates' `dotfiles` job already includes the config folder, so your job list is backed up along with everything else.

`winget export` only includes apps it can match to a winget source, so on its own it misses anything installed some other way. That's why the Windows hook also reads the registry's uninstall keys, the same list Settings shows.

## Drive layout

With the templates' jobs and examples enabled on a Mac named `MyMac` and a PC named `MyPC`:

```
AutoBackup/
  Config/                 dotfiles_MyMac.tar.zst, dotfiles_MyPC.tar.zst,
                          Applications_MyMac.tsv, Brewfile_MyMac, installed_MyPC.csv, winget_MyPC.json, ...
  Projects/               projects_MyMac.tar.zst
  Documents/Notes/        notes_MyMac_2026-09-27_130512.tar.zst, ... (keep = 10)
  Games/Minecraft/        <instance>_MyPC.tar.zst.001, .002, ... (one set per Prism instance)
```

Naming is `<name>_<machine><ext>`:

- `<name>` is the job name, or the subfolder name for `per_subfolder` jobs. Anything outside `A-Z a-z 0-9 . _ -` becomes `-`.
- With `keep` above 1, a timestamp is added: `notes_MyMac_2026-09-27_130512.tar.zst`.
- With `chunk_size`, the archive is stored as numbered parts: `.tar.zst.001`, `.002`, ...
- In `copy` mode the machine suffix goes before the extension (`Brewfile_MyMac`, `installed_MyPC.csv`).

## How a run works

For each job in the config (or only the jobs named by `--only`):

1. **Skip it** if disabled, if not due (`stamps/<job>.checked` is younger than `every`), or if a process in `skip_if_running` is running. Nothing is recorded, so the job retries next run.
2. **Run `pre`** if set: `/bin/sh -c` on macOS/Linux, `Invoke-Expression` on Windows. A non-zero exit fails the job.
3. **Build each unit.** A job is one archive, or one per subfolder with `per_subfolder = true`.
   - **Skip if unchanged** when all of these hold: the archive exists in the drive folder; `stamps/<unit>.last` records the same settings, includes and excludes; and no file or folder under the includes, other than excluded ones, is newer than that stamp.
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
| `-a [JOB] [k=v ...]`, `--add` | `-Add [JOB] [k=v ...]` | Append a job to the config. Prompts interactively when no `k=v` pairs are given, and suggests [rulegroups](#rulegroups) for known folders. |
| `-e`, `--edit` | `-Edit` | Open the config in `$VISUAL`/`$EDITOR` (fallback: TextEdit, `xdg-open`, Notepad). Creates it from the template first. |
| `--install` | `-Install` | Schedule hourly + login runs (LaunchAgent, systemd user timer, or Task Scheduler). |
| `--uninstall` | `-Uninstall` | Remove the schedule. Config, state and archives stay. |
| `-c FILE`, `--config FILE` | `-Config FILE` | Use another config file. `$AUTOBACKUP_CONFIG` does the same. |

Examples:

```sh
./autobackup.sh --add screenshots source=~/Pictures/Screenshots dest=Pictures every=7d compress=none
./autobackup.sh --add codex rulegroup=ai.codex dest=Config
./autobackup.sh --only screenshots --dry-run -v
```

```powershell
.\AutoBackup.ps1 -Add saves source='%USERPROFILE%\Saved Games' dest=Games/Saves every=7d
.\AutoBackup.ps1 -Only minecraft -DryRun -Verbose
```

## Config reference

The config is an INI file: a `[global]` section, then one `[job]` section per backup job. Other rules:

- `#` and `;` start a comment only at the beginning of a line. A value containing ` #` is used as-is, with a warning.
- Keys are case-insensitive. Unknown keys (typos like `exlude`) are ignored with a warning.
- Values are taken literally. Quotes are optional: one pair around the whole value is removed, except in `pre`, which is passed to the shell unchanged.
- `include`, `exclude` and `rulegroup` can repeat. Every other key uses its last value.
- Any job key set in `[global]` becomes the default for all jobs.
- `exclude` lines in `[global]` are added to each job's own excludes.
- Durations: `30m`, `12h`, `1d`, `2w` (a bare number means hours). Sizes: `500M`, `4G`, `1T`.

Path expansion applies to `source`, `drive_root`, `state`, `staging`, and `pre`:

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
| `source` | *(required)* | Folder the archive is built from. Paths inside the archive are relative to this. |
| `dest` | *(required)* | Subfolder of `drive_root`, e.g. `Games/Minecraft`. |
| `include` | `.` (all of `source`) | Path inside `source` to archive. Repeatable. Missing paths are skipped (shown with `-v`). |
| `exclude` | *(none)* | tar exclude pattern. Repeatable. Rules below. |
| `gitignore` | `true` | Inside git repos, archive only what git doesn't ignore. Details below. |
| `compress` | `zstd` | `zstd`, `gzip`, `none` (plain `.tar`), or `copy` (see below). |
| `compress_level` | 3 (zstd), 6 (gzip) | Compression level. Use 1 for already-compressed data like game files. |
| `every` | `1d` | Minimum time between passes. |
| `per_subfolder` | `false` | One archive per non-hidden subfolder of `source`, named after the subfolder. `include` is ignored. Top-level `exclude` patterns also filter subfolder names. |
| `keep` | `1` | `1`: one archive, replaced on each change; rely on the sync service's version history. More than 1: timestamped archives, the newest `keep` are kept. |
| `keep_max_size` | *(none)* | With `keep` above 1, also delete the oldest versions once their total size would pass this. The newest is always kept. |
| `chunk_size` | *(none)* | Cut the archive into parts of at most this size (`.001`, `.002`, ...). Helps sync apps that struggle with multi-GB files. |
| `alert_after` | 3× `every`, min `1d` | Notify when the job hasn't had a successful pass for this long. `0` turns it off. |
| `skip_if_running` | *(none)* | Comma-separated process names. If any is running, skip and retry next run. |
| `pre` | *(none)* | Command to run first (e.g. an inventory hook). |
| `rulegroup` | *(none)* | Comma-separated rulegroups from `rulegroups.ini` (below). |
| `enabled` | `true` | `false` skips the job. |

**`copy` mode** doesn't archive. It copies each non-hidden file directly inside `source` (not recursive) to `dest`, renamed with the machine suffix, and only when its content changed. This keeps inventories readable in the sync service's web UI and on a phone.

**Exclude patterns** are passed to tar's `--exclude`. The scripts use bsdtar (libarchive) on all platforms when available: macOS `/usr/bin/tar`, Windows `tar.exe`, and `bsdtar` on Linux (package `libarchive-tools`). GNU tar follows the same rules for these patterns. Checked against bsdtar 3.5–3.8:

- **A pattern matches a path, or the end of one, at any depth.** `node_modules` and `*.sqlite` match that name anywhere. `.obsidian/workspace.json` matches that file under any folder, including the top.
- **`*` also matches `/`**: `*minecraft/logs` matches both `minecraft/logs` and `.minecraft/logs`.
- **There's no way to anchor a pattern to the top of `source`.** Use a more specific path if a short name would catch too much.
- **Patterns are case-sensitive**, on Windows too: `*.log` doesn't match `Debug.LOG`.
- **Slashes:** always write `/`. The PowerShell script converts `\` for you.

**`.gitignore` handling.** When a unit contains git repos (or sits inside one), the script builds tar's file list itself:

- **Inside each repo:** the files `git ls-files --cached --others --exclude-standard` reports. That's tracked plus untracked files, minus anything ignored by any `.gitignore`, `.git/info/exclude` or your global excludes file.
- **The `.git` folder:** kept, so unpushed commits are backed up too. Add `exclude = .git` if you don't want it.
- **Outside repos:** everything, as usual.
- **Job excludes:** still apply on top.

With `gitignore = false`, or when git isn't installed, units are archived without these rules. On macOS, git is only used if the Command Line Tools are installed, which avoids an install prompt from `/usr/bin/git`.

If your home folder is itself a git repo that ignores everything by default (a `*` line in `~/.gitignore`), jobs with `source = ~` would skip every untracked file. Set `gitignore = false` on those jobs.

**Change detection skips excluded files**, matching them the same way tar does. It doesn't read `.gitignore`, so a change to a git-ignored file (build output, a `node_modules` install inside a repo) can trigger a rebuild that wasn't needed. Creating or deleting an excluded file also counts, because it changes its parent folder's timestamp. Neither can cause a real change to be missed.

### Rulegroups

A rulegroup is a named set of job keys, usually the includes and excludes for one app's folder, that any job can reuse. `rulegroups.ini` (next to the scripts) holds them, in the same format as the config. A job uses one or more with `rulegroup = NAME` or `rulegroup = a, b`:

```ini
[ai-settings]
rulegroup = ai.claude, ai.codex
dest = Config
```

- **Precedence.** A key the job sets wins over its rulegroups, and a later rulegroup wins over an earlier one; both win over `[global]`. `include` and `exclude` lines add up.
- **Paths inside your home folder.** Rulegroups with includes set `source = ~` and list paths like `.codex/config.toml`, so their archives extract back into `~`. Missing includes are skipped, which lets a rulegroup list every variant of a file (e.g. the Setapp version of an app's preferences).
- **Include lists, not exclude lists.** The unchanged check only looks at included paths, so tools that rewrite their databases all day don't cause a rebuild every run. And exclude patterns can't be anchored, so excluding `cache` in a tool folder would also drop same-named folders inside it.
- **`--add` suggests them.** Enter a folder like `~/.codex` or `~/Library/Application Support`, and it offers the rulegroups for the apps found inside it.
- **Unknown names fail the job**, so a typo never turns into an archive of your whole home folder.

The shipped rulegroups are examples drawn from real setups, not a catalog. Names are `category.name`, sorted by category:

| Rulegroup | Keeps |
|---|---|
| `ai.agents` | `~/.agents` (shared agent skills) |
| `ai.claude` | Claude Code instructions, settings, agents, commands, skills, hooks, installed plugin list. Not transcripts or session state. |
| `ai.codex` | Codex `config.toml`, `AGENTS.md`, agents, rules, prompts, skills, memories. Not `auth.json`, sessions, logs or plugins. |
| `audio.audio-hijack`, `audio.renoise` | App settings and libraries (macOS paths). |
| `browsers.helium` | The Helium browser profile without caches, cookies or saved passwords (macOS path). Runs weekly, only while the browser is closed. |
| `games.prism-instances` | Excludes and settings for Prism Launcher's `instances` folder: one archive per instance. Works under any source. |
| `network.transmission` | Transmission settings and torrent list (macOS). |
| `notes.obsidian` | Excludes only: workspace layout files and `.trash`. Works under any source. |
| `utilities.alfred`, `utilities.istat-menus`, `utilities.lasso` | macOS app settings, mostly from `~/Library/Preferences`. |

The comments in `rulegroups.ini` say what each one leaves out and why. To add your own, copy the closest section, give it a new `category.name`, and change its paths. `browsers.helium`, for example, works for any Chromium browser once its include points at that browser's profile folder.

## Secrets and encryption

AutoBackup doesn't encrypt archives. That's what makes them openable with any archive tool, and it means anyone who can read the sync folder can read them. Who that is depends on the service:

- **End-to-end encrypted:** Proton Drive, and iCloud Drive with Advanced Data Protection turned on. Only your devices hold the keys.
- **Encrypted, but the provider holds the keys:** Dropbox, Google Drive, OneDrive, and iCloud Drive with standard data protection. The provider, and anyone who gets into your account, can open the archives.

**Where secrets hide in a backup**

- Tool config folders can hold tokens in plain text. The templates back up `~/.config`, so check it. For example, `gh` keeps its token in the system keychain when one is available, but otherwise writes it to `~/.config/gh/hosts.yml`, which is common on Linux without a keyring.
- `.ssh/config` in the templates holds host settings only. Private keys (`~/.ssh/id_*`) aren't included.
- The rulegroups leave out the credential files they know about: Codex `auth.json`, and Helium cookies and saved passwords. Prism's `accounts.json` sits outside `instances/`, so the Minecraft job never sees it.
- Agent transcripts and shell history can contain anything that was pasted into them. The rulegroups leave them out, and the templates don't include shell history.

**Keeping secrets out**

- For folders in `~`, list what to keep with `include` rather than archiving a whole folder and excluding what to drop.
- Exclude single files by path: `exclude = gh/hosts.yml`.
- List what an archive actually holds: `tar -tf dotfiles_MyMac.tar.zst`.

**Encrypting with a service that isn't end-to-end encrypted**

Put `drive_root` inside an encrypted folder that syncs as ciphertext, such as a Cryptomator vault in the sync folder. The vault is its own volume, so `staging` can't share it: each archive is copied into the vault rather than renamed, and `--list` shows a warning about that.

## Restoring

Every archive opens with ordinary tools, so the restore scripts are optional. They find the newest version, join chunked parts, pick the decompressor, and extract into a scratch folder. Files that already exist are never replaced unless you ask.

```sh
./restore.sh --list                  # archives for this machine: newest version, count, size
./restore.sh dotfiles                # newest version -> ~/autobackup-restore/dotfiles_MyMac_<time>/
./restore.sh --at 2026-09-01 notes   # newest version from that day or earlier (keep > 1)
./restore.sh --all                   # every archive, each into its own folder
./restore.sh --verify                # read every newest archive to the end; extract nothing
```

```powershell
.\Restore.ps1 -List
.\Restore.ps1 Inst-One -To "$env:APPDATA\PrismLauncher\instances\Inst-One"
```

- **Names.** Use the job name, or the subfolder name for `per_subfolder` jobs. A path to an archive file (or its `.001` part) works too. `--list NAME` shows every version.
- **Where files go.** By default, each archive gets a new folder under `~/autobackup-restore`. `--to DIR` extracts into `DIR` instead. Paths in an archive are relative to its job's `source`, so `--to ~` puts a job with `source = ~` back in place.
- **Everything at once.** `--all` restores the newest version (or the newest up to `--at`) of every archive for the machine. Jobs have different sources, so each archive always gets its own folder; with `--all`, `--to DIR` is the folder that holds them.
- **Existing files are kept.** Only files missing from the target are extracted, so a restore never loses data that's already there. `--overwrite` replaces existing files with the archive's copy, for example to bring back an older version of a config file. The drive folder is always refused, since the sync app would upload the extracted files.
- **On a new machine.** Only `drive_root` and `machine` come from the config. Without one, pass them: `./restore.sh --drive ~/Dropbox/AutoBackup --machine MyMac dotfiles`. `--machine '*'` matches any machine.
- **Checks.** `--verify` reads each archive through the decompressor and tar, catching missing parts and damaged files. `--dry-run` shows what would be extracted where.
- **Needs.** zstd archives need the `zstd` CLI, or a tar with built-in zstd (bsdtar with libzstd, Windows' `tar.exe` on recent builds). The Windows script joins parts and decompresses into temp files before extracting, like `AutoBackup.ps1` builds archives in two steps.
- **Not covered.** `copy` mode files (inventories) aren't archives; open them directly.

By hand, extract to a scratch folder first and copy back what you need. Extracting dotfiles straight into `~` overwrites live config.

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
| **macOS** (tier 1) | The test suite, including the inventory hook, passes in CI and locally with `/bin/bash` 3.2 and bsdtar, for both scripts. Not yet run for real: `--install`, notifications, and privacy permissions. |
| **Windows** (tier 1) | The test suite, including the inventory hook, passes in CI on Windows Server 2025 with the built-in `tar.exe` (bsdtar 3.8, which has native zstd; older Windows builds may not, and the script falls back), under both Windows PowerShell 5.1 and PowerShell 7. Not yet run for real: `-Install` (Task Scheduler) and toasts. |
| **Linux** (tier 2) | The test suite passes in CI on Ubuntu with GNU tar. Container runs also covered bsdtar (Debian) and the inventory hook (Debian, Fedora, Arch). `--install` wrote systemd units that pass `systemd-analyze verify`, but the timer hasn't run under a real user session, and `notify-send` is untested. |

## Working on this

`autobackup.sh` and `AutoBackup.ps1` mirror each other, as do `restore.sh` and `Restore.ps1`. There's no canonical version, but a change to one should land in the other with the same flags, config keys, log messages and file layout. Both use the same function order and matching names (`cfg_load` / `Import-Cfg`, `archive_unit` / `Invoke-ArchiveUnit`, ...), so their diffs map across.

The one intended difference is how archives get built. bash pipes tar straight into zstd (and `split` for chunking), so no uncompressed copy touches the disk. PowerShell writes a raw `.tar` first and compresses it in a second step, because piping tar into zstd on Windows is reported to hang on inputs over a few hundred MB.

Constraints:

- **bash:** must run on 3.2. No associative arrays, `mapfile`, `${x,,}`, or `set -u` with empty arrays. Branch on `$AB_OS` for BSD vs GNU tools (`stat`, `date`).
- **PowerShell:** must run on 5.1.
  - Keep the file ASCII-only.
  - No `??`, `?:`, `&&`, or `$IsWindows`.
  - Use 2-arg `Join-Path`.
  - Functions return `$true`/`$false`. All logging goes through `[Console]::Out` or `Error` (`Write-Log`, `Say`), never `Write-Output`, so return values stay clean.

### Tests and lint

`tests/AutoBackup.Tests.ps1` is one [Pester](https://pester.dev) suite that runs the same black-box cases against both scripts. Each case builds a folder tree in a temp dir, runs the script with a throwaway config, and checks the archives. One suite for both scripts is what keeps them mirrored: a behavior change has to pass in both.

```sh
pwsh -c 'Install-Module Pester, PSScriptAnalyzer -Scope CurrentUser'   # once
brew install shellcheck                                       # or your distro's package

pwsh -c 'Invoke-Pester ./tests -Output Detailed'
shellcheck autobackup.sh restore.sh hooks/inventory.sh
pwsh -c 'Invoke-ScriptAnalyzer -Path AutoBackup.ps1 -Settings ./PSScriptAnalyzerSettings.psd1'
pwsh -c 'Invoke-ScriptAnalyzer -Path Restore.ps1 -Settings ./PSScriptAnalyzerSettings.psd1'
```

`PSScriptAnalyzerSettings.psd1` turns off rules meant for modules, and rules that flag deliberate choices; each has a comment saying why.

GitHub Actions (`.github/workflows/test.yml`) runs lint on Ubuntu and the tests on:

- **macOS:** bash 3.2 and PowerShell 7.
- **Ubuntu:** bash with GNU tar.
- **Windows:** PowerShell 7 and Windows PowerShell 5.1.

Standard runners are free for public repos.

For manual runs, point `--config` at a test config whose `drive_root`, `state` and `staging` live in a scratch folder. Two environment variables help:

- `AUTOBACKUP_NOTIFY=0` silences notifications.
- `AUTOBACKUP_TAR` overrides the tar binary.
- `AUTOBACKUP_RULEGROUPS` points at another rulegroups file.

## Not done yet

**Not yet run for real.** The first real setup on each machine covers these:

- Neither script has run against a real sync folder or from its scheduler (LaunchAgent, systemd timer, Task Scheduler).
- Notifications (Notification Center, `notify-send`, Windows toasts) and macOS privacy permissions.
- The inventory hooks run in CI and in Fedora and Arch containers, but haven't yet listed a real desktop's winget, Store or Mac App Store apps.
- The restore scripts have only restored the test suite's archives, not a real machine's.

**To verify per sync service**

- The scripts replace each `keep = 1` archive by rename. Confirm the service records a new version of the same file each time, rather than a delete plus a new file with no history.
- Set version-history retention, and check quota after a few weeks.
- Marking `AutoBackup/` as online-only (Dropbox, iCloud "Optimize Mac Storage", OneDrive Files On-Demand, Proton "Free up space") should stop archives from doubling local disk use. Unchanged checks only look at whether the file exists, so placeholders are fine. Worth confirming.

**Windows limitation**

- Inside git repos, `tar.exe` reads the file list in the ANSI code page (1252 on English Windows). A name with characters outside it, such as Japanese on an English system, reaches tar with `?` in their place, and `tar.exe` treats `?` as a wildcard. The file is still archived, but so is any other file in that folder whose name fits the same pattern, even one git ignores, and a listed file can end up in the archive twice.

**Missing features**

- `keep = 1` archives are never pruned. Archives for deleted `per_subfolder` subfolders or renamed jobs stay in the drive folder until deleted by hand.
- Chunked parts land one at a time, so the sync app can briefly see a mix of old and new parts.
- Rebuilds are whole-archive. A small change in a large folder re-uploads all of it; `per_subfolder` and tighter `include` lists keep units small.

**Not in scope**

- Full-disk images (Time Machine, Windows system images) are a separate layer.

## License

[Mozilla Public License 2.0](LICENSE).
