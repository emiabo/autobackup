#!/bin/bash
# AutoBackup for macOS and Linux. AutoBackup.ps1 is its Windows twin: keep flags, config keys,
# log messages and file layout the same in both.
# Written for bash 3.2 (the /bin/bash macOS ships): no associative arrays, no mapfile, no ${x,,}.
#
# Reads jobs from an INI-style config (see README.md), archives each job's folders with tar, and
# moves the archives into a cloud-sync folder. Safe to run often: each job only runs when its
# `every` interval has elapsed, and skips when nothing changed.
#
# Run `autobackup.sh --help` for flags.

AB_HERE=$(cd "$(dirname "$0")" && pwd -P)
AB_SELF="$AB_HERE/$(basename "$0")"
AB_OS=$(uname -s)
if [ "$AB_OS" = Darwin ]; then AB_PLATFORM=macos; else AB_PLATFORM=linux; fi
AB_CONFIG="${AUTOBACKUP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/autobackup/autobackup.conf}"
# macOS ships bsdtar. On Linux, bsdtar (package libarchive-tools) is preferred so behavior matches
# macOS and Windows exactly; GNU tar works too.
if [ -n "$AUTOBACKUP_TAR" ]; then AB_TAR="$AUTOBACKUP_TAR"
elif [ "$AB_OS" = Darwin ]; then AB_TAR=/usr/bin/tar
else AB_TAR=$(command -v bsdtar || command -v tar); fi
AB_LABEL=local.autobackup
AB_SEP=$'\x1f'
CFG=()
AB_MACHINE=''
AB_STATE=''
AB_LOCK=''
AB_TAR_ZSTD=''
AB_TAR_GNU=''
AB_U_INC=()
AB_U_EXC=()
opt_force=0
opt_dry=0
opt_verbose=0
opt_only=()

# launchd and systemd start jobs with a minimal PATH; make Homebrew tools (zstd, brew, mas) visible.
for d in /usr/local/bin /opt/homebrew/bin /home/linuxbrew/.linuxbrew/bin; do
    if [ -d "$d" ]; then
        case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
    fi
done
export PATH
# Stop macOS tar from adding AppleDouble (._*) files.
export COPYFILE_DISABLE=1

# ---------------------------------------------------------------- helpers

usage() {
    cat <<EOF
Usage: autobackup.sh [options]

Runs every job in the config that is due. Meant to be called hourly by launchd or systemd.

Options:
  -c, --config FILE   Config file (default: ~/.config/autobackup/autobackup.conf,
                      or \$AUTOBACKUP_CONFIG)
  -o, --only JOB      Run only this job, even if not due (repeatable, or comma-separated).
                      The skip-if-unchanged check still applies.
  -f, --force         Ignore schedule and skip-if-unchanged checks
  -n, --dry-run       Show what would happen; change nothing
  -l, --list          List jobs, last run, and whether each is due
  -a, --add [JOB] [key=value ...]
                      Append a job to the config. With no key=value pairs,
                      prompts interactively.
  -e, --edit          Open the config in \$EDITOR (creates it from the template first)
      --install       Run hourly and at login (LaunchAgent on macOS, systemd timer on Linux)
      --uninstall     Remove that schedule. Config, state and archives are kept.
  -v, --verbose       Also print skipped/not-due details
  -h, --help          Show this help

Examples:
  autobackup.sh --only obsidian
  autobackup.sh --list
  autobackup.sh --only dotfiles --dry-run -v
  autobackup.sh --add notes root=~/Notes dest=Documents/Notes every=1d
EOF
}

log() {
    local level="$1"; shift
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') [$level] $*"
    if [ "$level" = ERROR ]; then echo "$line" >&2; else echo "$line"; fi
    if [ "$opt_dry" -eq 0 ] && [ -n "$AB_STATE" ] && [ -d "$AB_STATE" ]; then
        echo "$line" >>"$AB_STATE/autobackup.log"
    fi
}

vlog() {
    [ "$opt_verbose" -eq 1 ] && echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] $*"
    return 0
}

is_true() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        1|y|yes|true|on) return 0 ;;
        *) return 1 ;;
    esac
}

sanitize() {
    printf '%s\n' "$1" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

joined() {
    local s
    s=$(printf '%s, ' "$@")
    printf '%s' "${s%, }"
}

# ~ at the start, {here} (this script's folder) and {machine} are expanded.
expand_path() {
    local p="$1"
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    p="${p//\{here\}/$AB_HERE}"
    p="${p//\{machine\}/$AB_MACHINE}"
    printf '%s\n' "$p"
}

# "30m", "12h", "1d", "2w", "90s"; bare number = hours.
dur_secs() {
    local d n u
    d=$(trim "$1")
    n=$(printf '%s' "$d" | sed -nE 's/^([0-9]+)[[:space:]]*([smhdw]?)$/\1/p')
    u=$(printf '%s' "$d" | sed -nE 's/^([0-9]+)[[:space:]]*([smhdw]?)$/\2/p')
    [ -n "$n" ] || return 1
    case "$u" in
        s) echo "$n" ;;
        m) echo $((n * 60)) ;;
        d) echo $((n * 86400)) ;;
        w) echo $((n * 604800)) ;;
        *) echo $((n * 3600)) ;;
    esac
}

# "500M", "4G", "1T" (binary units, trailing B optional) -> bytes.
size_bytes() {
    local s n
    s=$(trim "$1" | tr '[:lower:]' '[:upper:]')
    s="${s%B}"
    n="${s%[KMGT]}"
    case "$n" in ''|*[!0-9]*) return 1 ;; esac
    case "${s#"$n"}" in
        K) echo $((n * 1024)) ;;
        M) echo $((n * 1048576)) ;;
        G) echo $((n * 1073741824)) ;;
        T) echo $((n * 1099511627776)) ;;
        *) return 1 ;;
    esac
}

human_size() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.1fG", b / 1073741824
        else if (b >= 1048576) printf "%.1fM", b / 1048576
        else printf "%dK", (b + 1023) / 1024 }'
}

mtime() {
    if [ "$AB_OS" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

fsize() {
    if [ "$AB_OS" = Darwin ]; then stat -f %z "$1" 2>/dev/null; else stat -c %s "$1" 2>/dev/null; fi
}

vol_id() {
    if [ "$AB_OS" = Darwin ]; then stat -f %d "$1" 2>/dev/null; else stat -c %d "$1" 2>/dev/null; fi
}

fmt_epoch() {
    if [ "$AB_OS" = Darwin ]; then date -r "$1" '+%Y-%m-%d %H:%M'; else date -d "@$1" '+%Y-%m-%d %H:%M'; fi
}

notify() {
    if [ "$AB_OS" = Darwin ]; then
        osascript -e 'on run argv' -e 'display notification (item 1 of argv) with title "AutoBackup"' \
            -e 'end run' "$1" >/dev/null 2>&1
    elif command -v notify-send >/dev/null 2>&1; then
        notify-send AutoBackup "$1" >/dev/null 2>&1
    fi
    return 0
}

# ---------------------------------------------------------------- config

# Parses the INI file into CFG records: section<US>key<US>value.
# Keys before any [section] belong to "global". Keys are case-insensitive.
cfg_load() {
    CFG=()
    local sec=global n=0 raw line k v
    while IFS= read -r raw || [ -n "$raw" ]; do
        n=$((n + 1))
        line=$(trim "${raw//$'\r'/}")
        case "$line" in
            ''|'#'*|';'*) continue ;;
            '['*']')
                sec="${line#[}"; sec=$(trim "${sec%]}") ;;
            *=*)
                k=$(trim "${line%%=*}")
                k=$(printf '%s' "$k" | tr '[:upper:]' '[:lower:]')
                v=$(trim "${line#*=}")
                CFG+=("$sec$AB_SEP$k$AB_SEP$v") ;;
            *) log WARN "config line $n ignored: $line" ;;
        esac
    done <"$1"
}

# All values of key in section, in file order.
cfg_vals() {
    local rec
    for rec in "${CFG[@]}"; do
        if [ "${rec%%"$AB_SEP"*}" = "$1" ]; then
            local rest="${rec#*"$AB_SEP"}"
            if [ "${rest%%"$AB_SEP"*}" = "$2" ]; then
                printf '%s\n' "${rest#*"$AB_SEP"}"
            fi
        fi
    done
}

# Last value of key in section, else in [global], else the default.
cfg_get() {
    local v
    v=$(cfg_vals "$1" "$2" | tail -n 1)
    if [ -z "$(cfg_vals "$1" "$2")" ]; then
        v=$(cfg_vals global "$2" | tail -n 1)
        if [ -z "$(cfg_vals global "$2")" ]; then v="$3"; fi
    fi
    [ -n "$v" ] && printf '%s\n' "$v"
    return 0
}

cfg_jobs() {
    local rec s seen=$'\n'
    for rec in "${CFG[@]}"; do
        s="${rec%%"$AB_SEP"*}"
        [ "$s" = global ] && continue
        case "$seen" in *$'\n'"$s"$'\n'*) continue ;; esac
        seen="$seen$s"$'\n'
        printf '%s\n' "$s"
    done
}

# Creates the config from templates/<platform>.conf if it doesn't exist yet.
cfg_create() {
    local tpl="$AB_HERE/templates/$AB_PLATFORM.conf"
    [ -f "$AB_CONFIG" ] && return 0
    [ -f "$tpl" ] || { echo "Config not found: $AB_CONFIG (and no template at $tpl)" >&2; return 1; }
    mkdir -p "$(dirname "$AB_CONFIG")" && cp "$tpl" "$AB_CONFIG" || return 1
    echo "Created $AB_CONFIG from $tpl"
}

# ---------------------------------------------------------------- state

lock_acquire() {
    local dir="$AB_STATE/lock" pid
    if mkdir "$dir" 2>/dev/null; then
        echo $$ >"$dir/pid"; AB_LOCK="$dir"; return 0
    fi
    pid=$(cat "$dir/pid" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
    # Lock dir without a live owner: stale (crash, reboot). Take it over.
    rm -rf "$dir"
    mkdir "$dir" 2>/dev/null || return 1
    echo $$ >"$dir/pid"; AB_LOCK="$dir"
}

lock_release() {
    [ -n "$AB_LOCK" ] && rm -rf "$AB_LOCK"
    AB_LOCK=''
}
trap lock_release EXIT
trap 'lock_release; exit 143' TERM INT

# A job is due when its .checked stamp is older than `every` (or missing).
# The stamp is touched after every successful pass, including "unchanged" skips.
job_due() {
    local f="$AB_STATE/stamps/$1.checked" secs
    [ -e "$f" ] || return 0
    if ! secs=$(dur_secs "$2"); then
        log WARN "[$1] bad every='$2', using 1d"; secs=86400
    fi
    [ $(( $(date +%s) - $(mtime "$f") )) -ge "$secs" ]
}

# A job is stale when its last successful pass (or, if it never had one, the first run that saw it)
# is older than alert_after. Default: 3x every, at least 1 day. alert_after = 0 turns this off.
job_stale() {
    local job="$1" f every secs limit
    f="$AB_STATE/stamps/$job.checked"
    [ -e "$f" ] || f="$AB_STATE/stamps/$job.added"
    [ -e "$f" ] || return 1
    limit=$(cfg_get "$job" alert_after)
    if [ -n "$limit" ]; then
        limit=$(dur_secs "$limit") || limit=''
    fi
    if [ -z "$limit" ]; then
        every=$(cfg_get "$job" every 1d)
        secs=$(dur_secs "$every") || secs=86400
        limit=$((secs * 3))
        [ "$limit" -lt 86400 ] && limit=86400
    fi
    [ "$limit" -gt 0 ] || return 1
    [ $(( $(date +%s) - $(mtime "$f") )) -ge "$limit" ]
}

any_running() {
    local IFS=, p
    for p in $1; do
        p=$(trim "$p")
        [ -n "$p" ] || continue
        if pgrep -x -- "$p" >/dev/null 2>&1; then printf '%s\n' "$p"; return 0; fi
    done
    return 1
}

# The final move into the sync folder is only atomic when staging is on the same volume.
same_volume_warning() {
    mkdir -p "$AB_STAGING" 2>/dev/null
    local a b
    a=$(vol_id "$AB_STAGING"); b=$(vol_id "$(dirname "$AB_DRIVE")")
    if [ -n "$a" ] && [ -n "$b" ] && [ "$a" != "$b" ]; then
        echo "Warning: staging ($AB_STAGING) is on a different volume than drive_root."
        echo "         Set 'staging' in [global] to a folder on the same volume, so the sync app never sees half-written files."
    fi
}

# ---------------------------------------------------------------- compression

tar_has_zstd() {
    if [ -z "$AB_TAR_ZSTD" ]; then
        if "$AB_TAR" --version 2>/dev/null | grep -q zstd; then AB_TAR_ZSTD=1; else AB_TAR_ZSTD=0; fi
    fi
    [ "$AB_TAR_ZSTD" -eq 1 ]
}

# GNU tar exits 1 when a file changed while it was read. That's expected here (the change is
# caught next run), so it counts as success.
tar_ok() {
    [ "$1" -eq 0 ] && return 0
    if [ -z "$AB_TAR_GNU" ]; then
        if "$AB_TAR" --version 2>/dev/null | head -n 1 | grep -q 'GNU tar'; then AB_TAR_GNU=1; else AB_TAR_GNU=0; fi
    fi
    [ "$1" -eq 1 ] && [ "$AB_TAR_GNU" -eq 1 ]
}

# Config value -> concrete method. zstd prefers the zstd CLI (multithreaded),
# then tar's built-in zstd, then falls back to gzip.
resolve_method() {
    case "$1" in
        zstd|zst)
            if command -v zstd >/dev/null 2>&1; then echo zstd-ext
            elif tar_has_zstd; then echo zstd-native
            else echo gzip; fi ;;
        gzip|gz) echo gzip ;;
        none|tar) echo none ;;
        copy) echo copy ;;
        *) return 1 ;;
    esac
}

method_ext() {
    case "$1" in
        zstd-ext|zstd-native) echo .tar.zst ;;
        gzip) echo .tar.gz ;;
        none) echo .tar ;;
    esac
}

# stdin -> OUT, or OUT.aaa, OUT.aab ... when CHUNK (bytes) is set.
write_out() {
    if [ -n "$2" ]; then split -b "$2" -a 3 - "$1."; else cat >"$1"; fi
}

# build_archive METHOD LEVEL OUT CHUNK ROOT [tar args: --exclude P ... then inputs]
# tar streams straight into the compressor, so no uncompressed copy is written to disk.
build_archive() {
    local method="$1" level="$2" out="$3" chunk="$4" root="$5" st
    shift 5
    local base=(-c -f - -C "$root")
    [ "$AB_OS" = Darwin ] && base+=(--no-mac-metadata)
    case "$method" in
        zstd-ext)
            "$AB_TAR" "${base[@]}" "$@" | zstd -q -T0 "-$level" -c | write_out "$out" "$chunk"
            st=("${PIPESTATUS[@]}") ;;
        zstd-native)
            "$AB_TAR" "${base[@]}" --zstd --options "zstd:compression-level=$level" "$@" | write_out "$out" "$chunk"
            st=("${PIPESTATUS[@]}" 0) ;;
        gzip)
            "$AB_TAR" "${base[@]}" "$@" | gzip "-$level" -c | write_out "$out" "$chunk"
            st=("${PIPESTATUS[@]}") ;;
        none)
            "$AB_TAR" "${base[@]}" "$@" | write_out "$out" "$chunk"
            st=("${PIPESTATUS[@]}" 0) ;;
        *) return 1 ;;
    esac
    tar_ok "${st[0]}" && [ "${st[1]}" -eq 0 ] && [ "${st[2]}" -eq 0 ]
}

# Renames OUT.aaa, OUT.aab ... to OUT.001, OUT.002 ... and prints the part count.
number_parts() {
    local n=0 p
    for p in "$1".[a-z][a-z][a-z]; do
        [ -e "$p" ] || continue
        n=$((n + 1))
        mv -f "$p" "$1.$(printf '%03d' "$n")"
    done
    echo "$n"
}

# ---------------------------------------------------------------- versions

# Prints the archive versions of one unit, oldest first: the path each version's file(s) share,
# without any .001 part suffix. KEEP=1 has one fixed name; KEEP>1 names carry a timestamp.
unit_versions() {
    local d="$1" b="$2" e="$3" keep="$4" f
    if [ "$keep" -le 1 ]; then
        if [ -e "$d/$b$e" ] || [ -e "$d/$b$e.001" ]; then echo "$d/$b$e"; fi
        return 0
    fi
    {
        for f in "$d/${b}_"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]"$e"; do
            [ -e "$f" ] && echo "$f"
        done
        for f in "$d/${b}_"[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]_[0-9][0-9][0-9][0-9][0-9][0-9]"$e".[0-9][0-9][0-9]*; do
            [ -e "$f" ] && echo "${f%.*}"
        done
    } | LC_ALL=C sort -u
}

version_size() {
    local total=0 f s
    for f in "$1" "$1".[0-9][0-9][0-9]*; do
        [ -e "$f" ] || continue
        s=$(fsize "$f"); total=$((total + ${s:-0}))
    done
    echo "$total"
}

remove_version() {
    rm -f "$1" "$1".[0-9][0-9][0-9]*
}

# After replacing a fixed-name archive with N parts (0 = one whole file), delete leftovers
# from the previous build: the whole file if now chunked, and parts beyond N.
remove_stale_parts() {
    local t="$1" n="$2" p num
    [ "$n" -gt 0 ] && rm -f "$t"
    for p in "$t".[0-9][0-9][0-9]*; do
        [ -e "$p" ] || continue
        num="${p##*.}"
        [ $((10#$num)) -gt "$n" ] && rm -f "$p"
    done
    return 0
}

# Keeps the newest KEEP versions, fewer if their total size would pass MAXBYTES. The newest
# version is always kept.
prune_versions() {
    local key="$1" destdir="$2" base="$3" ext="$4" keep="$5" max="$6"
    local vs=() v i sz kept=0 total=0 pruning=0
    while IFS= read -r v; do vs+=("$v"); done < <(unit_versions "$destdir" "$base" "$ext" "$keep")
    for ((i = ${#vs[@]} - 1; i >= 0; i--)); do
        v="${vs[$i]}"
        sz=$(version_size "$v")
        if [ $pruning -eq 0 ] && { [ $kept -eq 0 ] || { [ $kept -lt "$keep" ] && { [ -z "$max" ] || [ $((total + sz)) -le "$max" ]; }; }; }; then
            kept=$((kept + 1)); total=$((total + sz))
        else
            pruning=1
            remove_version "$v"
            log INFO "[$key] removed old version $(basename "$v")"
        fi
    done
}

# ---------------------------------------------------------------- .gitignore

# git is usable. On macOS /usr/bin/git is a stub that pops up an installer dialog unless the
# Command Line Tools are installed, so check for those first.
git_ok() {
    local g
    g=$(command -v git) || return 1
    [ "$AB_OS" = Darwin ] && [ "$g" = /usr/bin/git ] && ! xcode-select -p >/dev/null 2>&1 && return 1
    return 0
}

# Repos to read through git for include DIR (a path relative to the current folder): DIR itself
# when it's inside a repo, plus every repo nested below it.
find_repos() {
    local d="$1" p
    p=$(cd "$d" && pwd -P)
    while [ -n "$p" ]; do
        if [ -e "$p/.git" ]; then echo "$d"; break; fi
        p="${p%/*}"
    done
    find "$d" -mindepth 2 -name .git -prune -print 2>/dev/null | sed 's#/\.git$##'
}

glob_escape() {
    printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'
}

# Everything under DIR, one NUL-terminated path per entry, skipping the listed repo folders.
list_tree() {
    local d="$1" r prune=()
    shift
    for r in "$@"; do
        [ "$r" = "$d" ] && continue
        prune+=(-path "$(glob_escape "$r")" -prune -o)
    done
    find "$d" "${prune[@]}" -print0 2>/dev/null
}

# A repo's files: tracked and untracked but not ignored, per git's own rules (every .gitignore,
# .git/info/exclude and the global excludes file), plus the .git folder itself so unpushed
# commits are kept. Falls back to the whole folder if git fails there.
list_repo() {
    local key="$1" r="$2" tmp="$3" f
    printf '%s\0' "$r"
    if ! (cd "$r" && git ls-files -z --cached --others --exclude-standard) >"$tmp" 2>/dev/null; then
        log WARN "[$key] git ls-files failed in $r; archiving that folder whole" >&2  # stdout is the list
        find "$r" -mindepth 1 -print0 2>/dev/null
        return 0
    fi
    while IFS= read -r -d '' f; do
        # Tracked files deleted from the working tree are still listed by git.
        if [ -e "$r/$f" ] || [ -L "$r/$f" ]; then printf '%s\0' "$r/$f"; fi
    done <"$tmp"
    [ -e "$r/.git" ] && find "$r/.git" -print0 2>/dev/null
    return 0
}

# Writes the tar input list for a unit that contains git repos. Returns 1 (and writes nothing
# useful) when there are no repos, so the caller archives the includes normally.
# tar's own excludes still apply to every listed path.
write_file_list() {
    local key="$1" uroot="$2" out="$3"
    shift 3
    git_ok || return 1
    (
        cd "$uroot" || exit 1
        local i r any=0 repos
        : >"$out"
        for i in "$@"; do
            repos=()
            if [ -d "$i" ] && [ ! -L "$i" ]; then
                while IFS= read -r r; do repos+=("$r"); done < <(find_repos "$i")
            fi
            if [ ${#repos[@]} -eq 0 ]; then
                if [ -d "$i" ] && [ ! -L "$i" ]; then list_tree "$i"; else printf '%s\0' "$i"; fi
                continue
            fi
            any=1
            [ "${repos[0]}" = "$i" ] || list_tree "$i" "${repos[@]}"
            for r in "${repos[@]}"; do list_repo "$key" "$r" "$out.git"; done
        done >>"$out"
        rm -f "$out.git"
        [ $any -eq 1 ]
    )
}

# ---------------------------------------------------------------- jobs

# Per-job settings, filled in by run_job for archive_unit.
J_METHOD=''; J_LEVEL=''; J_SKIP=''; J_KEEP=1; J_KEEPMAX=''; J_CHUNK=''; J_GIT=''; J_DESTDIR=''

# archive_unit KEY NAME ROOT
# Uses globals AB_U_INC (paths relative to ROOT), AB_U_EXC (tar patterns) and the J_* settings.
archive_unit() {
    local key="$1" uname="$2" uroot="$3"
    local base ext stamp i e
    base="$(sanitize "$uname")_$AB_MACHINE"
    ext=$(method_ext "$J_METHOD")
    stamp="$AB_STATE/stamps/$key.last"

    local incs=()
    for i in "${AB_U_INC[@]}"; do
        if [ -e "$uroot/$i" ] || [ -L "$uroot/$i" ]; then incs+=("$i")
        else vlog "[$key] include not found, skipped: $i"; fi
    done
    if [ ${#incs[@]} -eq 0 ]; then
        log WARN "[$key] nothing to archive under $uroot"
        return 0
    fi

    # The descriptor records what produced the archive; editing the job forces a rebuild.
    local desc
    desc="root=$uroot"$'\n'"method=$J_METHOD"$'\n'"level=$J_LEVEL"$'\n'"chunk=$J_CHUNK"$'\n'"gitignore=$J_GIT"
    for i in "${incs[@]}"; do desc="$desc"$'\n'"include=$i"; done
    for e in "${AB_U_EXC[@]}"; do desc="$desc"$'\n'"exclude=$e"; done

    if [ "$opt_force" -eq 0 ] && is_true "$J_SKIP" && [ -e "$stamp" ] \
        && [ -n "$(unit_versions "$J_DESTDIR" "$base" "$ext" "$J_KEEP")" ]; then
        if [ "$desc" = "$(cat "$stamp")" ]; then
            local paths=() hit
            for i in "${incs[@]}"; do paths+=("$uroot/$i"); done
            # Conservative: excluded and git-ignored files count too, so this can rebuild
            # needlessly but never miss a change.
            hit=$(find "${paths[@]}" -newer "$stamp" -print -quit 2>/dev/null)
            if [ -z "$hit" ]; then
                vlog "[$key] unchanged, skipped"
                return 0
            fi
            vlog "[$key] changed: $hit"
        fi
    fi

    local fname="$base$ext"
    [ "$J_KEEP" -gt 1 ] && fname="${base}_$(date '+%Y-%m-%d_%H%M%S')$ext"

    if [ "$opt_dry" -eq 1 ]; then
        log INFO "[$key] would write $J_DESTDIR/$fname ($J_METHOD, from $uroot: $(joined "${incs[@]}"))"
        return 0
    fi

    mkdir -p "$AB_STAGING" "$AB_STATE/stamps"
    if ! mkdir -p "$J_DESTDIR"; then
        log ERROR "[$key] cannot create $J_DESTDIR"; return 1
    fi
    local pending="$AB_STATE/stamps/$key.pending"
    printf '%s\n' "$desc" >"$pending"
    local tmp="$AB_STAGING/$fname" listf="$AB_STAGING/$key.list"
    rm -f "$tmp" "$tmp".*

    local targs=()
    for e in "${AB_U_EXC[@]}"; do targs+=(--exclude "$e"); done
    if is_true "$J_GIT" && write_file_list "$key" "$uroot" "$listf" "${incs[@]}"; then
        vlog "[$key] git repos found; using .gitignore rules"
        targs+=(--no-recursion --null -T "$listf")
    else
        targs+=(-- "${incs[@]}")  # tar end-of-options marker, then the include paths
    fi

    local t0
    t0=$(date +%s)
    if ! build_archive "$J_METHOD" "$J_LEVEL" "$tmp" "$J_CHUNK" "$uroot" "${targs[@]}"; then
        rm -f "$tmp" "$tmp".* "$pending" "$listf"
        log ERROR "[$key] archiving failed for $uroot"
        return 1
    fi
    rm -f "$listf"

    # Same volume as the sync folder, so each move is an atomic rename: the sync client never
    # sees a partial file. With chunking, parts land one by one.
    local target="$J_DESTDIR/$fname" nparts=0 p
    if [ -n "$J_CHUNK" ]; then
        nparts=$(number_parts "$tmp")
        for p in "$tmp".[0-9][0-9][0-9]*; do
            if ! mv -f "$p" "$target.${p##*.}"; then
                rm -f "$tmp".* "$pending"
                log ERROR "[$key] could not move archive part to $target.${p##*.}"
                return 1
            fi
        done
    elif ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" "$pending"
        log ERROR "[$key] could not move archive to $target"
        return 1
    fi
    mv -f "$pending" "$stamp"

    [ "$J_KEEP" -le 1 ] && remove_stale_parts "$target" "$nparts"

    local shown="$target"
    [ "$nparts" -gt 0 ] && shown="$target.001-$(printf '%03d' "$nparts")"
    log INFO "[$key] wrote $shown ($(human_size "$(version_size "$target")"), $(( $(date +%s) - t0 ))s)"
    [ "$J_KEEP" -gt 1 ] && prune_versions "$key" "$J_DESTDIR" "$base" "$ext" "$J_KEEP" "$J_KEEPMAX"
    return 0
}

# copy mode: flat copy of the files directly inside ROOT, renamed NAME_MACHINE.ext.
# Only changed files are copied.
copy_files() {
    local key="$1" root="$2" destdir="$3" fail=0 f name skip e stem ext tname tgt
    for f in "$root"/*; do
        [ -f "$f" ] || continue
        name=$(basename "$f")
        skip=0
        for e in "${AB_U_EXC[@]}"; do
            # shellcheck disable=SC2254
            case "$name" in $e) skip=1 ;; esac
        done
        [ $skip -eq 1 ] && continue
        case "$name" in
            ?*.*) stem="${name%.*}"; ext=".${name##*.}" ;;
            *) stem="$name"; ext='' ;;
        esac
        tname="$(sanitize "$stem")_$AB_MACHINE$ext"
        tgt="$destdir/$tname"
        if [ -e "$tgt" ] && cmp -s "$f" "$tgt"; then
            vlog "[$key] unchanged: $tname"; continue
        fi
        if [ "$opt_dry" -eq 1 ]; then
            log INFO "[$key] would copy $name -> $tgt"; continue
        fi
        mkdir -p "$destdir" "$AB_STAGING"
        if cp -f "$f" "$AB_STAGING/$tname" && mv -f "$AB_STAGING/$tname" "$tgt"; then
            log INFO "[$key] updated $tgt"
        else
            log ERROR "[$key] could not copy $f"; fail=1
        fi
    done
    return $fail
}

run_job() {
    local job="$1" root dest mode every ignore_due running pre fail=0 l v
    if ! is_true "$(cfg_get "$job" enabled true)"; then
        vlog "[$job] disabled"; return 0
    fi
    root=$(expand_path "$(cfg_get "$job" root)")
    dest=$(cfg_get "$job" dest); dest="${dest#/}"; dest="${dest%/}"
    if [ -z "$(cfg_get "$job" root)" ] || [ -z "$dest" ]; then
        log ERROR "[$job] needs both root and dest"; return 1
    fi
    mode=$(cfg_get "$job" compress zstd | tr '[:upper:]' '[:lower:]')
    if ! J_METHOD=$(resolve_method "$mode"); then
        log ERROR "[$job] unknown compress '$mode' (use zstd, gzip, none or copy)"; return 1
    fi
    J_LEVEL=$(cfg_get "$job" level)
    if [ -z "$J_LEVEL" ]; then
        if [ "$J_METHOD" = gzip ]; then J_LEVEL=6; else J_LEVEL=3; fi
    fi
    J_KEEP=$(cfg_get "$job" keep 1)
    case "$J_KEEP" in ''|*[!0-9]*|0) log ERROR "[$job] keep must be a whole number, 1 or more"; return 1 ;; esac
    J_KEEPMAX=''
    v=$(cfg_get "$job" keep_max_size)
    if [ -n "$v" ] && ! J_KEEPMAX=$(size_bytes "$v"); then
        log ERROR "[$job] bad keep_max_size '$v' (use e.g. 500M, 20G)"; return 1
    fi
    J_CHUNK=''
    v=$(cfg_get "$job" chunk_size)
    if [ -n "$v" ] && ! J_CHUNK=$(size_bytes "$v"); then
        log ERROR "[$job] bad chunk_size '$v' (use e.g. 500M, 4G)"; return 1
    fi
    J_GIT=$(cfg_get "$job" gitignore true)
    J_SKIP=$(cfg_get "$job" skip_unchanged true)
    J_DESTDIR="$AB_DRIVE/$dest"
    every=$(cfg_get "$job" every 1d)

    ignore_due=$opt_force
    [ ${#opt_only[@]} -gt 0 ] && ignore_due=1
    if [ "$ignore_due" -eq 0 ] && ! job_due "$job" "$every"; then
        vlog "[$job] not due (every $every)"; return 0
    fi

    if running=$(any_running "$(cfg_get "$job" skip_if_running)"); then
        log INFO "[$job] skipped: $running is running; will retry next run"; return 0
    fi

    pre=$(cfg_vals "$job" pre | tail -n 1)
    if [ -n "$pre" ]; then
        pre=$(expand_path "$pre")
        if [ "$opt_dry" -eq 1 ]; then
            log INFO "[$job] would run pre: $pre"
        elif ! /bin/sh -c "$pre"; then
            log ERROR "[$job] pre command failed: $pre"; return 1
        fi
    fi

    if [ ! -d "$root" ]; then
        if [ "$opt_dry" -eq 1 ] && [ -n "$pre" ]; then
            log INFO "[$job] root $root does not exist yet (pre would create it)"; return 0
        fi
        log ERROR "[$job] root folder not found: $root"; return 1
    fi

    AB_U_EXC=()
    while IFS= read -r l; do AB_U_EXC+=("$l"); done < <(cfg_vals global exclude; cfg_vals "$job" exclude)

    if [ "$J_METHOD" = copy ]; then
        copy_files "$job" "$root" "$J_DESTDIR" || fail=1
    elif is_true "$(cfg_get "$job" per_subfolder false)"; then
        # One archive per immediate subfolder (e.g. one per Prism instance).
        local found=0 d sub skip e
        for d in "$root"/*/; do
            [ -d "$d" ] || continue
            sub=$(basename "$d")
            skip=0
            for e in "${AB_U_EXC[@]}"; do
                # shellcheck disable=SC2254
                case "$sub" in $e) skip=1 ;; esac
            done
            [ $skip -eq 1 ] && continue
            found=1
            AB_U_INC=(.)
            archive_unit "$job@$(sanitize "$sub")" "$sub" "$root/$sub" || fail=1
        done
        [ $found -eq 0 ] && log WARN "[$job] per_subfolder = true but no subfolders in $root"
    else
        AB_U_INC=()
        while IFS= read -r l; do AB_U_INC+=("$l"); done < <(cfg_vals "$job" include)
        [ ${#AB_U_INC[@]} -eq 0 ] && AB_U_INC=(.)
        local name
        name=$(cfg_vals "$job" name | tail -n 1)
        [ -z "$name" ] && name="$job"
        archive_unit "$job" "$name" "$root" || fail=1
    fi

    if [ $fail -eq 0 ] && [ "$opt_dry" -eq 0 ]; then
        mkdir -p "$AB_STATE/stamps"
        touch "$AB_STATE/stamps/$job.checked"
    fi
    return $fail
}

# Once a day at most: warn about jobs with no recent successful backup. Every review_every
# (default 90d, 0 = off): remind you to check the job list still covers what you need.
# Editing the config resets the reminder.
check_alerts() {
    local job now stale=() n secs last
    now=$(date +%s)
    mkdir -p "$AB_STATE/stamps"
    while IFS= read -r job; do
        is_true "$(cfg_get "$job" enabled true)" || continue
        [ -e "$AB_STATE/stamps/$job.checked" ] || [ -e "$AB_STATE/stamps/$job.added" ] \
            || touch "$AB_STATE/stamps/$job.added"
        job_stale "$job" && stale+=("$job")
    done < <(cfg_jobs)
    n="$AB_STATE/stamps/stale.notified"
    if [ ${#stale[@]} -gt 0 ] && { [ ! -e "$n" ] || [ $((now - $(mtime "$n"))) -ge 86400 ]; }; then
        log WARN "no successful backup in a while: $(joined "${stale[@]}")"
        notify "No recent backup: $(joined "${stale[@]}"). See autobackup.log."
        touch "$n"
    fi

    secs=$(dur_secs "$(cfg_get global review_every 90d)") || secs=0
    [ "$secs" -gt 0 ] || return 0
    n="$AB_STATE/stamps/review.notified"
    last=$(mtime "$AB_CONFIG")
    if [ -e "$n" ] && [ "$(mtime "$n")" -gt "$last" ]; then last=$(mtime "$n"); fi
    if [ $((now - last)) -ge "$secs" ]; then
        log INFO "review reminder: check the job list still matches what you need backed up"
        notify "Time to review your backup list: autobackup.sh --list, then --edit."
        touch "$n"
    fi
}

# ---------------------------------------------------------------- commands

cmd_list() {
    local job f last st
    printf '%-18s %-5s %-6s %-26s %-16s %s\n' JOB MODE EVERY DEST 'LAST RUN' STATUS
    while IFS= read -r job; do
        f="$AB_STATE/stamps/$job.checked"
        last=never
        [ -e "$f" ] && last=$(fmt_epoch "$(mtime "$f")")
        st=ok
        if ! is_true "$(cfg_get "$job" enabled true)"; then st=disabled
        elif job_stale "$job"; then st=stale
        elif job_due "$job" "$(cfg_get "$job" every 1d)"; then st=due; fi
        printf '%-18s %-5s %-6s %-26s %-16s %s\n' "$job" "$(cfg_get "$job" compress zstd)" \
            "$(cfg_get "$job" every 1d)" "$(cfg_get "$job" dest)" "$last" "$st"
    done < <(cfg_jobs)
    echo
    echo "Config:     $AB_CONFIG"
    echo "Drive root: $AB_DRIVE"
    echo "Log:        $AB_STATE/autobackup.log"
    same_volume_warning
}

cmd_add() {
    local name="$1" p k v have_root=0 have_dest=0 npairs
    [ $# -gt 0 ] && shift
    npairs=$#
    if [ -z "$name" ]; then
        read -r -p 'Job name (letters, digits, . _ -): ' name || return 1
    fi
    case "$name" in
        ''|*[!A-Za-z0-9._-]*) echo "Invalid job name: '$name'" >&2; return 1 ;;
    esac
    if cfg_jobs | grep -qxF -- "$name"; then
        echo "Job [$name] already exists in $AB_CONFIG. Edit it there (--edit)." >&2; return 1
    fi
    local lines=("[$name]")
    for p in "$@"; do
        case "$p" in
            [A-Za-z_]*=*) ;;
            *) echo "Expected key=value, got: $p" >&2; return 1 ;;
        esac
        k="${p%%=*}"; v="${p#*=}"
        lines+=("$k = $v")
        [ "$k" = root ] && have_root=1
        [ "$k" = dest ] && have_dest=1
    done
    if [ $have_root -eq 0 ]; then
        read -r -p 'Source folder (root): ' v || return 1
        [ -n "$v" ] || return 1
        lines+=("root = $v")
    fi
    if [ $have_dest -eq 0 ]; then
        read -r -p 'Drive subfolder under the drive root (e.g. Documents/Obsidian): ' v || return 1
        [ -n "$v" ] || return 1
        lines+=("dest = $v")
    fi
    if [ "$npairs" -eq 0 ]; then
        echo 'Paths inside root to include, one per line. Blank line = done (none = whole root).'
        while read -r -p '  include: ' v && [ -n "$v" ]; do lines+=("include = $v"); done
        echo 'Exclude patterns (e.g. node_modules, *.log, sub/dir). Blank line = done.'
        while read -r -p '  exclude: ' v && [ -n "$v" ]; do lines+=("exclude = $v"); done
        read -r -p "Compression: zstd, gzip, none or copy [default $(cfg_get global compress zstd)]: " v
        [ -n "$v" ] && lines+=("compress = $v")
        read -r -p "How often, e.g. 12h, 1d, 7d [default $(cfg_get global every 1d)]: " v
        [ -n "$v" ] && lines+=("every = $v")
        read -r -p 'One archive per subfolder of root? [y/N]: ' v
        is_true "$v" && lines+=("per_subfolder = true")
    fi
    printf '\n' >>"$AB_CONFIG"
    printf '%s\n' "${lines[@]}" >>"$AB_CONFIG"
    echo "Added to $AB_CONFIG:"
    printf '  %s\n' "${lines[@]}"
    echo "Test it: $AB_SELF --only $name --dry-run -v"
}

cmd_edit() {
    cfg_create || return 1
    if [ -n "${VISUAL:-$EDITOR}" ]; then eval "${VISUAL:-$EDITOR} \"\$AB_CONFIG\""
    elif [ "$AB_OS" = Darwin ]; then open -t "$AB_CONFIG"
    elif command -v xdg-open >/dev/null 2>&1; then xdg-open "$AB_CONFIG"
    else vi "$AB_CONFIG"; fi
}

xml_escape() {
    printf '%s' "$1" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'
}

cmd_install() {
    local cfg
    cfg="$(cd "$(dirname "$AB_CONFIG")" && pwd -P)/$(basename "$AB_CONFIG")"
    if [ "$AB_OS" = Darwin ]; then
        local plist="$HOME/Library/LaunchAgents/$AB_LABEL.plist" dom
        dom="gui/$(id -u)"
        mkdir -p "$(dirname "$plist")" "$AB_STATE"
        cat >"$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$AB_LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$(xml_escape "$AB_SELF")</string>
        <string>--config</string>
        <string>$(xml_escape "$cfg")</string>
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
    <string>$(xml_escape "$AB_STATE/launchd.log")</string>
    <key>StandardErrorPath</key>
    <string>$(xml_escape "$AB_STATE/launchd.log")</string>
</dict>
</plist>
EOF
        launchctl bootout "$dom/$AB_LABEL" 2>/dev/null
        if ! launchctl bootstrap "$dom" "$plist"; then
            echo "launchctl bootstrap failed for $plist" >&2; return 1
        fi
        echo "Installed $plist. It runs now, at every login, and hourly while awake."
        echo "If the log shows 'Operation not permitted', add /bin/bash to System Settings >"
        echo "Privacy & Security > Full Disk Access (see SETUP.md)."
    else
        if ! command -v systemctl >/dev/null 2>&1; then
            echo "systemd not found. Add this to 'crontab -e' instead:" >&2
            echo "  0 * * * * /bin/bash '$AB_SELF' --config '$cfg'" >&2
            return 1
        fi
        local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        mkdir -p "$dir"
        cat >"$dir/autobackup.service" <<EOF
[Unit]
Description=AutoBackup

[Service]
Type=oneshot
ExecStart=/bin/bash "$AB_SELF" --config "$cfg"
Nice=10
IOSchedulingClass=idle
EOF
        cat >"$dir/autobackup.timer" <<EOF
[Unit]
Description=Run AutoBackup hourly

[Timer]
OnStartupSec=2min
OnUnitActiveSec=1h

[Install]
WantedBy=timers.target
EOF
        systemctl --user daemon-reload && systemctl --user enable --now autobackup.timer || return 1
        echo "Installed autobackup.timer in $dir. It runs 2 minutes after login, then hourly."
    fi
    same_volume_warning
}

cmd_uninstall() {
    if [ "$AB_OS" = Darwin ]; then
        local plist="$HOME/Library/LaunchAgents/$AB_LABEL.plist"
        launchctl bootout "gui/$(id -u)/$AB_LABEL" 2>/dev/null
        rm -f "$plist"
        echo "Removed $plist."
    else
        local dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        systemctl --user disable --now autobackup.timer 2>/dev/null
        rm -f "$dir/autobackup.service" "$dir/autobackup.timer"
        systemctl --user daemon-reload 2>/dev/null
        echo "Removed autobackup.timer."
    fi
    echo "Config ($AB_CONFIG), state and archives are untouched."
}

# ---------------------------------------------------------------- main

want_list=0; want_add=0; want_edit=0; want_install=0; want_uninstall=0; cfg_flag=''
args=()
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config) cfg_flag="$2"; shift ;;
        --config=*) cfg_flag="${1#*=}" ;;
        -o|--only) opt_only+=("$2"); shift ;;
        --only=*) opt_only+=("${1#*=}") ;;
        -f|--force) opt_force=1 ;;
        -n|--dry-run) opt_dry=1 ;;
        -l|--list) want_list=1 ;;
        -a|--add) want_add=1 ;;
        -e|--edit) want_edit=1 ;;
        --install) want_install=1 ;;
        --uninstall) want_uninstall=1 ;;
        -v|--verbose) opt_verbose=1 ;;
        -h|--help) usage; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) args+=("$1") ;;
    esac
    shift
done
[ -n "$cfg_flag" ] && AB_CONFIG=$(expand_path "$cfg_flag")
if [ ${#opt_only[@]} -gt 0 ]; then
    split_only=()
    for o in "${opt_only[@]}"; do
        IFS=, read -r -a parts <<<"$o"
        for p in "${parts[@]}"; do p=$(trim "$p"); [ -n "$p" ] && split_only+=("$p"); done
    done
    opt_only=("${split_only[@]}")
fi

if [ $want_uninstall -eq 1 ]; then cmd_uninstall; exit $?; fi
if [ $want_edit -eq 1 ]; then cmd_edit; exit $?; fi
if [ $want_install -eq 1 ] && [ ! -f "$AB_CONFIG" ]; then
    cfg_create || exit 1
    echo "Set drive_root and machine in it (--edit), then run --install again."
    exit 1
fi
if [ ! -f "$AB_CONFIG" ]; then
    echo "Config not found: $AB_CONFIG" >&2
    echo "Run '$AB_SELF --edit' to create it from the template." >&2
    exit 1
fi

cfg_load "$AB_CONFIG"
AB_MACHINE=$(cfg_get global machine)
AB_DRIVE=$(expand_path "$(cfg_get global drive_root)"); AB_DRIVE="${AB_DRIVE%/}"
AB_STATE=$(expand_path "$(cfg_get global state "$HOME/.local/state/autobackup")")
AB_STAGING=$(expand_path "$(cfg_get global staging "$HOME/.cache/autobackup")")

if [ $want_add -eq 1 ]; then
    cmd_add "${args[@]}"
    exit $?
fi

if [ -z "$AB_MACHINE" ] || [ -z "$AB_DRIVE" ]; then
    echo "[global] needs machine and drive_root in $AB_CONFIG" >&2; exit 1
fi
mkdir -p "$AB_STATE/stamps"

if [ $want_list -eq 1 ]; then
    cmd_list; exit 0
fi

# Refuse to run if the sync folder's parent is missing (sync app not installed, or drive not mounted).
if [ ! -d "$(dirname "$AB_DRIVE")" ]; then
    log ERROR "drive_root parent does not exist: $(dirname "$AB_DRIVE") (is the sync app running?)"
    [ "$opt_dry" -eq 0 ] && [ $want_install -eq 0 ] && notify "Drive folder missing; nothing backed up."
    exit 1
fi

if [ $want_install -eq 1 ]; then cmd_install; exit $?; fi

# Keep the log from growing forever.
logf="$AB_STATE/autobackup.log"
if [ -f "$logf" ] && [ "$(wc -c <"$logf" | tr -d ' ')" -gt 1048576 ]; then
    mv -f "$logf" "$logf.1"
fi

if ! lock_acquire; then
    echo "Another AutoBackup run is in progress; exiting."; exit 0
fi

jobs=()
while IFS= read -r j; do jobs+=("$j"); done < <(cfg_jobs)
if [ ${#opt_only[@]} -gt 0 ]; then
    for o in "${opt_only[@]}"; do
        if ! printf '%s\n' "${jobs[@]}" | grep -qxF -- "$o"; then
            log ERROR "no job named [$o] in $AB_CONFIG"; exit 1
        fi
    done
    jobs=("${opt_only[@]}")
fi

failed=()
for job in "${jobs[@]}"; do
    run_job "$job" || failed+=("$job")
done

if [ "$opt_dry" -eq 0 ]; then
    [ ${#failed[@]} -gt 0 ] && notify "Failed: $(joined "${failed[@]}"). See autobackup.log."
    check_alerts
fi
[ ${#failed[@]} -eq 0 ]
