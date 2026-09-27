#!/bin/bash
# AutoBackup: macOS implementation, bash port. mac-backup.fish is CANONICAL; keep this in sync with it.
# Written for bash 3.2 (the /bin/bash macOS ships): no associative arrays, no mapfile, no ${x,,}.
#
# Reads jobs from mac.conf (INI-style, see README.md), archives each job's folders with tar,
# and moves the archives into a cloud-sync folder (Proton Drive). Safe to run often:
# each job only runs when its `every` interval has elapsed, and skips when nothing changed.
#
# Run `mac-backup.sh --help` for flags.

AB_HERE=$(cd "$(dirname "$0")" && pwd -P)
AB_OS=$(uname -s)
AB_CONFIG="${AUTOBACKUP_CONFIG:-$AB_HERE/mac.conf}"
AB_TAR="${AUTOBACKUP_TAR:-/usr/bin/tar}"
AB_SEP=$'\x1f'
CFG=()
AB_MACHINE=''
AB_STATE=''
AB_LOCK=''
AB_TAR_ZSTD=''
AB_U_INC=()
AB_U_EXC=()
opt_force=0
opt_dry=0
opt_verbose=0
opt_only=()

# launchd starts jobs with a minimal PATH; make Homebrew tools (zstd, brew, mas) visible.
for d in /usr/local/bin /opt/homebrew/bin; do
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
Usage: mac-backup.sh [options]

Runs every job in the config that is due. Meant to be called hourly by launchd.

Options:
  -c, --config FILE   Config file (default: mac.conf next to this script,
                      or \$AUTOBACKUP_CONFIG)
  -o, --only JOB      Run only this job, even if not due (repeatable, or comma-separated).
                      The skip-if-unchanged check still applies.
  -f, --force         Ignore schedule and skip-if-unchanged checks
  -n, --dry-run       Show what would happen; change nothing
  -l, --list          List jobs, last run, and whether each is due
  -a, --add [JOB] [key=value ...]
                      Append a job to the config. With no key=value pairs,
                      prompts interactively.
  -e, --edit          Open the config in \$EDITOR (or TextEdit)
  -v, --verbose       Also print skipped/not-due details
  -h, --help          Show this help

Examples:
  mac-backup.sh --only obsidian            # Alfred keyword
  mac-backup.sh --list
  mac-backup.sh --only dotfiles --dry-run -v
  mac-backup.sh --add notes root=~/Notes dest=Documents/Notes every=1d
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

mtime() {
    if [ "$AB_OS" = Darwin ]; then stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

fmt_epoch() {
    if [ "$AB_OS" = Darwin ]; then date -r "$1" '+%Y-%m-%d %H:%M'; else date -d "@$1" '+%Y-%m-%d %H:%M'; fi
}

notify() {
    command -v osascript >/dev/null 2>&1 || return 0
    osascript -e "display notification \"$1\" with title \"AutoBackup\"" >/dev/null 2>&1
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

any_running() {
    local IFS=, p
    for p in $1; do
        p=$(trim "$p")
        [ -n "$p" ] || continue
        if pgrep -x -- "$p" >/dev/null 2>&1; then printf '%s\n' "$p"; return 0; fi
    done
    return 1
}

# ---------------------------------------------------------------- compression

tar_has_zstd() {
    if [ -z "$AB_TAR_ZSTD" ]; then
        if "$AB_TAR" --version 2>/dev/null | grep -q zstd; then AB_TAR_ZSTD=1; else AB_TAR_ZSTD=0; fi
    fi
    [ "$AB_TAR_ZSTD" -eq 1 ]
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

# build_archive METHOD LEVEL OUTFILE ROOT [tar args: --exclude P ... -- INCLUDES...]
build_archive() {
    local method="$1" level="$2" out="$3" root="$4"
    shift 4
    local base=(-c -C "$root")
    [ "$AB_OS" = Darwin ] && base+=(--no-mac-metadata)
    case "$method" in
        zstd-ext)
            local raw="$out.part.tar"
            if ! "$AB_TAR" "${base[@]}" -f "$raw" "$@"; then rm -f "$raw"; return 1; fi
            if ! zstd -q -T0 "-$level" -f --rm -o "$out" "$raw"; then rm -f "$raw" "$out"; return 1; fi ;;
        zstd-native)
            "$AB_TAR" "${base[@]}" -f "$out" --zstd --options "zstd:compression-level=$level" "$@" ;;
        gzip)
            "$AB_TAR" "${base[@]}" -f "$out" -z --options "gzip:compression-level=$level" "$@" ;;
        none)
            "$AB_TAR" "${base[@]}" -f "$out" "$@" ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------- jobs

# archive_unit JOB KEY NAME ROOT METHOD LEVEL SKIP_UNCHANGED DESTDIR
# Uses globals AB_U_INC (paths relative to ROOT) and AB_U_EXC (tar patterns).
archive_unit() {
    local job="$1" key="$2" uname="$3" uroot="$4" method="$5" level="$6" skip_unch="$7" destdir="$8"
    local fname target stamp i e
    fname="$(sanitize "$uname")_$AB_MACHINE$(method_ext "$method")"
    target="$destdir/$fname"
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
    desc="root=$uroot"$'\n'"method=$method"$'\n'"level=$level"
    for i in "${incs[@]}"; do desc="$desc"$'\n'"include=$i"; done
    for e in "${AB_U_EXC[@]}"; do desc="$desc"$'\n'"exclude=$e"; done

    if [ "$opt_force" -eq 0 ] && is_true "$skip_unch" && [ -e "$target" ] && [ -e "$stamp" ]; then
        if [ "$desc" = "$(cat "$stamp")" ]; then
            local paths=() hit
            for i in "${incs[@]}"; do paths+=("$uroot/$i"); done
            # Conservative: excluded files count too, so this can rebuild needlessly but never miss a change.
            hit=$(find "${paths[@]}" -newer "$stamp" -print -quit 2>/dev/null)
            if [ -z "$hit" ]; then
                vlog "[$key] unchanged, skipped"
                return 0
            fi
            vlog "[$key] changed: $hit"
        fi
    fi

    if [ "$opt_dry" -eq 1 ]; then
        local joined
        joined=$(printf '%s, ' "${incs[@]}"); joined="${joined%, }"
        log INFO "[$key] would write $target ($method, from $uroot: $joined)"
        return 0
    fi

    mkdir -p "$AB_STAGING" "$AB_STATE/stamps"
    if ! mkdir -p "$destdir"; then
        log ERROR "[$key] cannot create $destdir"; return 1
    fi
    local pending="$AB_STATE/stamps/$key.pending"
    printf '%s\n' "$desc" >"$pending"
    local tmp="$AB_STAGING/$fname"
    rm -f "$tmp" "$tmp.part.tar"

    local targs=()
    for e in "${AB_U_EXC[@]}"; do targs+=(--exclude "$e"); done
    targs+=(-- "${incs[@]}")  # tar end-of-options marker, then the include paths

    local t0
    t0=$(date +%s)
    if ! build_archive "$method" "$level" "$tmp" "$uroot" "${targs[@]}"; then
        rm -f "$tmp" "$pending"
        log ERROR "[$key] archiving failed for $uroot"
        return 1
    fi
    # Same volume as the sync folder, so this is an atomic rename: the sync client never sees a partial file.
    if ! mv -f "$tmp" "$target"; then
        rm -f "$tmp" "$pending"
        log ERROR "[$key] could not move archive to $target"
        return 1
    fi
    mv -f "$pending" "$stamp"
    local size
    size=$(du -h "$target" | cut -f1 | tr -d '[:space:]')
    log INFO "[$key] wrote $target ($size, $(( $(date +%s) - t0 ))s)"
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
    local job="$1" root dest mode method level every ignore_due running pre destdir skip_unch fail=0 l
    if ! is_true "$(cfg_get "$job" enabled true)"; then
        vlog "[$job] disabled"; return 0
    fi
    root=$(expand_path "$(cfg_get "$job" root)")
    dest=$(cfg_get "$job" dest); dest="${dest#/}"; dest="${dest%/}"
    if [ -z "$(cfg_get "$job" root)" ] || [ -z "$dest" ]; then
        log ERROR "[$job] needs both root and dest"; return 1
    fi
    mode=$(cfg_get "$job" compress zstd | tr '[:upper:]' '[:lower:]')
    if ! method=$(resolve_method "$mode"); then
        log ERROR "[$job] unknown compress '$mode' (use zstd, gzip, none or copy)"; return 1
    fi
    level=$(cfg_get "$job" level)
    if [ -z "$level" ]; then
        if [ "$method" = gzip ]; then level=6; else level=3; fi
    fi
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
    destdir="$AB_DRIVE/$dest"
    skip_unch=$(cfg_get "$job" skip_unchanged true)

    if [ "$method" = copy ]; then
        copy_files "$job" "$root" "$destdir" || fail=1
    elif is_true "$(cfg_get "$job" split false)"; then
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
            archive_unit "$job" "$job@$(sanitize "$sub")" "$sub" "$root/$sub" "$method" "$level" "$skip_unch" "$destdir" || fail=1
        done
        [ $found -eq 0 ] && log WARN "[$job] split=true but no subfolders in $root"
    else
        AB_U_INC=()
        while IFS= read -r l; do AB_U_INC+=("$l"); done < <(cfg_vals "$job" include)
        [ ${#AB_U_INC[@]} -eq 0 ] && AB_U_INC=(.)
        local name
        name=$(cfg_vals "$job" name | tail -n 1)
        [ -z "$name" ] && name="$job"
        archive_unit "$job" "$job" "$name" "$root" "$method" "$level" "$skip_unch" "$destdir" || fail=1
    fi

    if [ $fail -eq 0 ] && [ "$opt_dry" -eq 0 ]; then
        mkdir -p "$AB_STATE/stamps"
        touch "$AB_STATE/stamps/$job.checked"
    fi
    return $fail
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
        elif job_due "$job" "$(cfg_get "$job" every 1d)"; then st=due; fi
        printf '%-18s %-5s %-6s %-26s %-16s %s\n' "$job" "$(cfg_get "$job" compress zstd)" \
            "$(cfg_get "$job" every 1d)" "$(cfg_get "$job" dest)" "$last" "$st"
    done < <(cfg_jobs)
    echo
    echo "Drive root: $AB_DRIVE"
    echo "Log:        $AB_STATE/autobackup.log"
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
        is_true "$v" && lines+=("split = true")
    fi
    printf '\n' >>"$AB_CONFIG"
    printf '%s\n' "${lines[@]}" >>"$AB_CONFIG"
    echo "Added to $AB_CONFIG:"
    printf '  %s\n' "${lines[@]}"
    echo "Test it: $0 --only $name --dry-run -v"
}

# ---------------------------------------------------------------- main

want_list=0; want_add=0; want_edit=0; cfg_flag=''
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

if [ ! -f "$AB_CONFIG" ]; then
    echo "Config not found: $AB_CONFIG" >&2; exit 1
fi

if [ $want_edit -eq 1 ]; then
    if [ -n "$EDITOR" ]; then eval "$EDITOR \"\$AB_CONFIG\""; else open -t "$AB_CONFIG"; fi
    exit $?
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

# Refuse to run if the sync folder's parent is missing (Proton not installed/mounted).
if [ ! -d "$(dirname "$AB_DRIVE")" ]; then
    log ERROR "drive_root parent does not exist: $(dirname "$AB_DRIVE") (is Proton Drive running?)"
    [ "$opt_dry" -eq 0 ] && notify "Drive folder missing; nothing backed up."
    exit 1
fi

# Keep the log from growing forever.
logf="$AB_STATE/autobackup.log"
if [ -f "$logf" ] && [ "$(wc -c <"$logf" | tr -d ' ')" -gt 1048576 ]; then
    mv -f "$logf" "$logf.1"
fi

if ! lock_acquire; then
    vlog "another run is in progress; exiting"; exit 0
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

if [ ${#failed[@]} -gt 0 ]; then
    joined=$(printf '%s, ' "${failed[@]}"); joined="${joined%, }"
    [ "$opt_dry" -eq 0 ] && notify "Failed: $joined. See autobackup.log."
    exit 1
fi
exit 0
