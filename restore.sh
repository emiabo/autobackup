#!/bin/bash
# AutoBackup restore for macOS and Linux. Restore.ps1 is its Windows twin: keep flags, messages
# and behavior the same in both. Written for bash 3.2, like autobackup.sh.
#
# Optional: every archive is a plain tar file that any archive tool opens (README.md, Restoring).
# This finds the newest version of an archive, joins chunked parts, picks the decompressor, and
# extracts into a scratch folder. It only reads drive_root and machine from the config, and both
# can be given as flags, so it also works on a new machine before anything is set up.
#
# Run `restore.sh --help` for flags.

AB_HERE=$(cd "$(dirname "$0")" && pwd -P)
AB_OS=$(uname -s)
AB_CONFIG="${AUTOBACKUP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/autobackup/autobackup.ini}"
if [ -n "$AUTOBACKUP_TAR" ]; then AB_TAR="$AUTOBACKUP_TAR"
elif [ "$AB_OS" = Darwin ]; then AB_TAR=/usr/bin/tar
else AB_TAR=$(command -v bsdtar || command -v tar); fi
AB_SEP=$'\x1f'
AB_TAR_ZSTD=''
AB_TAR_GNU=''
AB_MACHINE=''
AB_MPAT=''
AB_DRIVE=''
AB_VERSIONS=''
# archive name, optional .tar.gz/.tar.zst, optional .001 part number
AB_ARCHIVE_RE='^(.+)(\.tar|\.tar\.gz|\.tar\.zst)(\.[0-9][0-9][0-9]+)?$'
AB_STAMP_RE='^(.+)_([0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6})$'
VF=()
opt_list=0
opt_verify=0
opt_dry=0
opt_overwrite=0
opt_all=0
opt_to=''
opt_at=''
fail_after_list=''

for d in /usr/local/bin /opt/homebrew/bin /home/linuxbrew/.linuxbrew/bin; do
    if [ -d "$d" ]; then
        case ":$PATH:" in *":$d:"*) ;; *) PATH="$d:$PATH" ;; esac
    fi
done
export PATH

# ---------------------------------------------------------------- helpers

usage() {
    cat <<EOF
Usage: restore.sh [options] NAME ...
       restore.sh [options] --all

Finds the newest version of each named archive in the AutoBackup drive folder and extracts it.
NAME is a job name, or a subfolder name for per_subfolder jobs: the part of the archive's file
name before _<machine>. It can also be the path to an archive file, or to its .001 part.
Files that already exist are kept; only missing files are added, unless --overwrite.

Options:
  -l, --list          List archives instead of extracting. With NAMEs, list every version.
      --all           Restore the newest version of every archive for this machine, each into
                      its own folder
  -t, --to DIR        Extract into DIR. Default: a new folder per archive under
                      ~/autobackup-restore. Paths inside an archive are relative to its job's source,
                      so --to ~ puts files from a job with source = ~ back where they were.
                      With --all, DIR holds one folder per archive instead.
      --overwrite     Replace files that already exist with the archive's copy
  -a, --at WHEN       Newest version from WHEN or earlier: 2026-09-27 or 2026-09-27_1305
      --verify        Read each archive to the end to check it's intact; extract nothing.
                      With no NAMEs, checks the newest version of every archive.
  -m, --machine NAME  Archives from this machine (default: machine in the config; '*' for any)
  -d, --drive DIR     The AutoBackup folder in the sync folder (default: drive_root in the config)
  -c, --config FILE   Config to read drive_root and machine from (default:
                      ~/.config/autobackup/autobackup.ini, or \$AUTOBACKUP_CONFIG)
  -n, --dry-run       Show what would be extracted where; change nothing
  -h, --help          Show this help

Examples:
  restore.sh --list
  restore.sh dotfiles
  restore.sh --at 2026-09-01 obsidian
  restore.sh --all --to /Volumes/Spare/restore
  restore.sh --drive ~/Dropbox/AutoBackup --machine MyMac --to ~ --overwrite dotfiles
EOF
}

die() {
    echo "$*" >&2
    exit 1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

unquote() {
    case "$1" in
        \"*\"|\'*\') printf '%s' "${1:1:${#1}-2}" ;;
        *) printf '%s' "$1" ;;
    esac
}

sanitize() {
    printf '%s\n' "$1" | sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//'
}

glob_escape() {
    printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'
}

expand_path() {
    local p="$1"
    # shellcheck disable=SC2088  # matching a literal ~, not expanding it
    case "$p" in
        "~") p="$HOME" ;;
        "~/"*) p="$HOME/${p#\~/}" ;;
    esac
    p="${p//\{here\}/$AB_HERE}"
    p="${p//\{machine\}/$AB_MACHINE}"
    printf '%s\n' "$p"
}

# An absolute path, with the parent's symlinks resolved when it exists. DIR itself may not.
abs_path() {
    local p="$1" parent
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    p="${p%/}"
    parent=$(cd "$(dirname "$p")" 2>/dev/null && pwd -P) || { printf '%s\n' "$p"; return 0; }
    printf '%s\n' "${parent%/}/$(basename "$p")"
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

# A file's modification time in the timestamp format of archive names.
file_stamp() {
    local t
    t=$(mtime "$1")
    if [ "$AB_OS" = Darwin ]; then date -r "$t" '+%Y-%m-%d_%H%M%S'; else date -d "@$t" '+%Y-%m-%d_%H%M%S'; fi
}

# 2026-09-27_130512 -> 2026-09-27 13:05:12
show_stamp() {
    printf '%s\n' "${1:0:10} ${1:11:2}:${1:13:2}:${1:15:2}"
}

tar_has_zstd() {
    if [ -z "$AB_TAR_ZSTD" ]; then
        if "$AB_TAR" --version 2>/dev/null | grep -q zstd; then AB_TAR_ZSTD=1; else AB_TAR_ZSTD=0; fi
    fi
    [ "$AB_TAR_ZSTD" -eq 1 ]
}

# tar's flag to leave existing files alone. GNU tar's own -k fails on each one instead.
tar_keep_flag() {
    if [ -z "$AB_TAR_GNU" ]; then
        if "$AB_TAR" --version 2>/dev/null | head -n 1 | grep -q 'GNU tar'; then AB_TAR_GNU=1; else AB_TAR_GNU=0; fi
    fi
    if [ "$AB_TAR_GNU" -eq 1 ]; then echo --skip-old-files; else echo -k; fi
}

# Last value of KEY in [global] (or before any section) of the config.
cfg_global() {
    local raw line sec=global k out=''
    while IFS= read -r raw || [ -n "$raw" ]; do
        line=$(trim "${raw//$'\r'/}")
        case "$line" in
            ''|'#'*|';'*) ;;
            '['*']') sec=$(trim "${line:1:${#line}-2}") ;;
            *=*)
                [ "$sec" = global ] || continue
                k=$(trim "${line%%=*}" | tr '[:upper:]' '[:lower:]')
                [ "$k" = "$1" ] && out=$(unquote "$(trim "${line#*=}")") ;;
        esac
    done <"$AB_CONFIG"
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------- versions

# Sets VF to the files that make up version V, in order: the whole file, or its .001, .002 ...
# parts. When both exist (a job that started or stopped chunking), the newer one wins.
version_files() {
    local v="$1" p n=0 i
    VF=()
    for p in "$v".[0-9][0-9][0-9]*; do [ -e "$p" ] && n=$((n + 1)); done
    if [ -e "$v" ] && { [ $n -eq 0 ] || [ ! -e "$v.001" ] || [ "$(mtime "$v")" -ge "$(mtime "$v.001")" ]; }; then
        VF=("$v"); return 0
    fi
    for ((i = 1; i <= n; i++)); do
        p="$v.$(printf '%03d' "$i")"
        if [ ! -e "$p" ]; then
            echo "$(basename "$v"): part $(basename "$p") is missing (still syncing?)" >&2
            return 1
        fi
        VF+=("$p")
    done
    [ $n -gt 0 ]
}

version_size() {
    local total=0 f s
    for f in "${VF[@]}"; do s=$(fsize "$f"); total=$((total + ${s:-0})); done
    echo "$total"
}

# V (an archive path without any part suffix) -> BASE<US>STAMP<US>V. BASE is NAME_MACHINE.
# Archives without a timestamp in their name (keep = 1) get their file's modification time.
version_record() {
    local v="$1" n stem base stamp
    n=$(basename "$v")
    [[ $n =~ $AB_ARCHIVE_RE ]] || return 1
    stem="${BASH_REMATCH[1]}"
    if [[ $stem =~ $AB_STAMP_RE ]]; then
        base="${BASH_REMATCH[1]}"; stamp="${BASH_REMATCH[2]}"
    else
        base="$stem"
        if [ -e "$v" ]; then stamp=$(file_stamp "$v"); else stamp=$(file_stamp "$v.001"); fi
    fi
    printf '%s\n' "$base$AB_SEP$stamp$AB_SEP$v"
}

# Every archive version under the drive folder, one record per line, by name and then oldest first.
scan_versions() {
    local f n
    find "$AB_DRIVE" -type f ! -name '.*' \( -name '*.tar' -o -name '*.tar.gz' -o -name '*.tar.zst' \
        -o -name '*.tar*.[0-9][0-9][0-9]*' \) 2>/dev/null | while IFS= read -r f; do
        n=$(basename "$f")
        [[ $n =~ $AB_ARCHIVE_RE ]] || continue
        printf '%s\n' "$(dirname "$f")/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
    done | LC_ALL=C sort -u | while IFS= read -r f; do
        version_record "$f"
    done | LC_ALL=C sort
}

rec_base() { printf '%s\n' "${1%%"$AB_SEP"*}"; }
rec_stamp() { local r="${1#*"$AB_SEP"}"; printf '%s\n' "${r%%"$AB_SEP"*}"; }
rec_path() { printf '%s\n' "${1##*"$AB_SEP"}"; }

# Archive names (NAME_MACHINE) for NAME: the archive name itself if it exists, else NAME_<machine>.
match_bases() {
    local name="$1" s b all
    all=$(printf '%s\n' "$AB_VERSIONS" | while IFS= read -r b; do [ -n "$b" ] && rec_base "$b"; done | LC_ALL=C sort -u)
    if printf '%s\n' "$all" | grep -qxF -- "$name"; then printf '%s\n' "$name"; return 0; fi
    s=$(sanitize "$name")
    printf '%s\n' "$all" | while IFS= read -r b; do
        # shellcheck disable=SC2254  # AB_MPAT is a glob pattern on purpose
        case "$b" in "$s"_$AB_MPAT) printf '%s\n' "$b" ;; esac
    done
}

# Newest version record of BASE, at or before --at when given.
pick_version() {
    local base="$1" limit='' r out='' st
    if [ -n "$opt_at" ]; then limit=$(printf '%s' "$opt_at" | tr -d '_-'); fi
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        [ "$(rec_base "$r")" = "$base" ] || continue
        if [ -n "$limit" ]; then
            st=$(rec_stamp "$r" | tr -d '_-')
            [ "$st" -le "$limit" ] || continue
        fi
        out="$r"
    done <<<"$AB_VERSIONS"
    [ -n "$out" ] && printf '%s\n' "$out"
}

# ---------------------------------------------------------------- extracting

# Why an archive with extension EXT can't be read here, if it can't.
missing_tool() {
    case "$1" in
        .tar.zst)
            command -v zstd >/dev/null 2>&1 || tar_has_zstd \
                || echo "needs zstd (macOS: brew install zstd; Linux: your distro's zstd package)" ;;
        .tar.gz) command -v gzip >/dev/null 2>&1 || echo "needs gzip" ;;
    esac
    return 0
}

# Streams VF through the decompressor for EXT into tar, with the given tar arguments.
unpack() {
    local ext="$1" st
    shift
    case "$ext" in
        .tar.zst)
            if command -v zstd >/dev/null 2>&1; then
                cat "${VF[@]}" | zstd -dcq | "$AB_TAR" "$@" -f -
                st=("${PIPESTATUS[@]}")
            else
                # bsdtar with libzstd detects the compression itself.
                cat "${VF[@]}" | "$AB_TAR" "$@" -f -
                st=("${PIPESTATUS[@]}" 0)
            fi ;;
        .tar.gz)
            cat "${VF[@]}" | gzip -dc | "$AB_TAR" "$@" -f -
            st=("${PIPESTATUS[@]}") ;;
        *)
            cat "${VF[@]}" | "$AB_TAR" "$@" -f -
            st=("${PIPESTATUS[@]}" 0) ;;
    esac
    [ "${st[0]}" -eq 0 ] && [ "${st[1]}" -eq 0 ] && [ "${st[2]}" -eq 0 ]
}

# One archive version: verify it, or extract it. Returns 1 on failure.
restore_one() {
    local r="$1" base stamp v n ext why desc dir how='' xargs
    base=$(rec_base "$r"); stamp=$(rec_stamp "$r"); v=$(rec_path "$r")
    n=$(basename "$v"); [[ $n =~ $AB_ARCHIVE_RE ]]; ext="${BASH_REMATCH[2]}"
    version_files "$v" || return 1
    desc="$base ($(show_stamp "$stamp"), $(human_size "$(version_size)")"
    [ ${#VF[@]} -gt 1 ] && desc="$desc, ${#VF[@]} parts"
    desc="$desc)"
    why=$(missing_tool "$ext")
    if [ -n "$why" ]; then echo "$desc: $why" >&2; return 1; fi

    if [ $opt_verify -eq 1 ]; then
        if [ $opt_dry -eq 1 ]; then echo "Would verify $desc"; return 0; fi
        if unpack "$ext" -t >/dev/null; then echo "ok      $desc"; return 0; fi
        echo "FAILED  $desc: $v" >&2
        return 1
    fi

    if [ -n "$opt_to" ] && [ $opt_all -eq 0 ]; then dir="$opt_to"; else dir="$AB_PARENT/${base}_$stamp"; fi
    dir=$(abs_path "$dir")
    case "$dir/" in
        "$AB_DRIVE"/*) echo "$desc: won't extract into the drive folder ($dir); the sync app would upload it" >&2; return 1 ;;
    esac
    xargs=(-x -C "$dir")
    if [ $opt_overwrite -eq 1 ]; then
        how=' (replacing files already there)'
    else
        xargs+=("$(tar_keep_flag)")
        how=' (keeping files already there)'
    fi
    # Only worth saying when there's something there.
    [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ] || how=''
    if [ $opt_dry -eq 1 ]; then echo "Would restore $desc into $dir$how"; return 0; fi
    echo "Restoring $desc into $dir$how"
    mkdir -p "$dir" || return 1
    if ! unpack "$ext" "${xargs[@]}"; then
        echo "Extracting $v failed; $dir may be incomplete." >&2
        return 1
    fi
}

# ---------------------------------------------------------------- commands

# One line per archive (newest version), or with NAMEs one line per version.
cmd_list() {
    local r base prev='' count=0 last='' rel
    if [ $# -gt 0 ]; then
        printf '%-32s %-19s %8s  %s\n' ARCHIVE VERSION SIZE FILE
        for r in "$@"; do
            version_files "$(rec_path "$r")" 2>/dev/null
            rel=$(rec_path "$r"); rel="${rel#"$AB_DRIVE"/}"
            printf '%-32s %-19s %8s  %s\n' "$(rec_base "$r")" "$(show_stamp "$(rec_stamp "$r")")" \
                "$(human_size "$(version_size)")" "$rel"
        done
        return 0
    fi
    printf '%-32s %-19s %8s %8s  %s\n' ARCHIVE NEWEST VERSIONS SIZE FOLDER
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        base=$(rec_base "$r")
        # shellcheck disable=SC2254  # AB_MPAT is a glob pattern on purpose
        case "$base" in *_$AB_MPAT) ;; *) continue ;; esac
        if [ "$base" != "$prev" ] && [ -n "$last" ]; then list_row "$last" "$count"; count=0; fi
        prev="$base"; last="$r"; count=$((count + 1))
    done <<<"$AB_VERSIONS"
    [ -n "$last" ] && list_row "$last" "$count"
    return 0
}

list_row() {
    local r="$1" rel
    version_files "$(rec_path "$r")" 2>/dev/null
    rel=$(dirname "$(rec_path "$r")"); rel="${rel#"$AB_DRIVE"}"; rel="${rel#/}"
    printf '%-32s %-19s %8s %8s  %s\n' "$(rec_base "$r")" "$(show_stamp "$(rec_stamp "$r")")" "$2" \
        "$(human_size "$(version_size)")" "${rel:-.}"
}

# ---------------------------------------------------------------- main

cfg_flag=''; drive_flag=''; machine_flag=''
names=()
while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config) cfg_flag="$2"; shift ;;
        --config=*) cfg_flag="${1#*=}" ;;
        -d|--drive) drive_flag="$2"; shift ;;
        --drive=*) drive_flag="${1#*=}" ;;
        -m|--machine) machine_flag="$2"; shift ;;
        --machine=*) machine_flag="${1#*=}" ;;
        -t|--to) opt_to="$2"; shift ;;
        --to=*) opt_to="${1#*=}" ;;
        -a|--at) opt_at="$2"; shift ;;
        --at=*) opt_at="${1#*=}" ;;
        -l|--list) opt_list=1 ;;
        --verify) opt_verify=1 ;;
        --overwrite) opt_overwrite=1 ;;
        --all) opt_all=1 ;;
        -n|--dry-run) opt_dry=1 ;;
        -h|--help) usage; exit 0 ;;
        --) shift; names+=("$@"); break ;;
        -*) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
        *) names+=("$1") ;;
    esac
    shift
done
[ -n "$cfg_flag" ] && AB_CONFIG=$(expand_path "$cfg_flag")
[ -n "$opt_to" ] && opt_to=$(expand_path "$opt_to")
if [ $opt_all -eq 1 ] && [ ${#names[@]} -gt 0 ]; then
    echo "Use --all or NAMEs, not both." >&2; exit 2
fi
# Where per-archive folders go: ~/autobackup-restore, or --to with --all.
AB_PARENT="$HOME/autobackup-restore"
[ $opt_all -eq 1 ] && [ -n "$opt_to" ] && AB_PARENT=$(abs_path "$opt_to")

if [ -n "$opt_at" ]; then
    if ! printf '%s\n' "$opt_at" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}(_[0-9]{2}([0-9]{2}([0-9]{2})?)?)?$'; then
        echo "--at wants a date like 2026-09-27 or 2026-09-27_1305, got: $opt_at" >&2; exit 2
    fi
    at_given="$opt_at"
    # Round up to the end of the day, hour or minute given.
    case ${#opt_at} in
        10) opt_at="${opt_at}_235959" ;;
        13) opt_at="${opt_at}5959" ;;
        15) opt_at="${opt_at}59" ;;
    esac
fi

if [ -f "$AB_CONFIG" ]; then
    AB_MACHINE=$(cfg_global machine)
    [ -z "$drive_flag" ] && AB_DRIVE=$(expand_path "$(cfg_global drive_root)")
elif [ -n "$cfg_flag" ]; then
    die "Config not found: $AB_CONFIG"
fi
[ -n "$machine_flag" ] && AB_MACHINE="$machine_flag"
if [ -n "$machine_flag" ]; then AB_MPAT="$machine_flag"
elif [ -n "$AB_MACHINE" ]; then AB_MPAT=$(glob_escape "$AB_MACHINE")
else AB_MPAT='*'; fi
[ -n "$drive_flag" ] && AB_DRIVE=$(expand_path "$drive_flag")
if [ -z "$AB_DRIVE" ]; then
    die "No AutoBackup folder: pass --drive DIR (the AutoBackup folder in your sync folder), or set drive_root in $AB_CONFIG."
fi
[ -d "$AB_DRIVE" ] || die "AutoBackup folder not found: $AB_DRIVE"
AB_DRIVE=$(cd "$AB_DRIVE" && pwd -P)

if [ ${#names[@]} -eq 0 ] && [ $opt_list -eq 0 ] && [ $opt_verify -eq 0 ] && [ $opt_all -eq 0 ]; then
    echo "Name what to restore. Available archives:" >&2
    opt_list=1
    exec >&2
    fail_after_list=1
fi

AB_VERSIONS=$(scan_versions)

# Resolve every NAME to one archive version before touching anything.
picked=()
bad=0
for name in "${names[@]}"; do
    n=$(basename "$name")
    if [[ $name == */* ]] || { [[ $n =~ $AB_ARCHIVE_RE ]] && [ -f "$name" ]; }; then
        [ -e "$name" ] || { echo "No such file: $name" >&2; bad=1; continue; }
        if ! [[ $n =~ $AB_ARCHIVE_RE ]]; then echo "Not an archive: $name" >&2; bad=1; continue; fi
        v="$(cd "$(dirname "$name")" && pwd -P)/${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
        if [ $opt_list -eq 1 ]; then
            base=$(rec_base "$(version_record "$v")")
            while IFS= read -r r; do [ "$(rec_base "$r")" = "$base" ] && picked+=("$r"); done <<<"$AB_VERSIONS"
        else
            picked+=("$(version_record "$v")")
        fi
        continue
    fi
    bases=()
    while IFS= read -r b; do [ -n "$b" ] && bases+=("$b"); done < <(match_bases "$name")
    if [ ${#bases[@]} -eq 0 ]; then
        echo "No archive named '$name' for machine '$AB_MPAT' in $AB_DRIVE (see --list)." >&2; bad=1; continue
    fi
    if [ ${#bases[@]} -gt 1 ]; then
        echo "'$name' matches more than one archive: ${bases[*]}. Name one of those, or pass --machine." >&2
        bad=1; continue
    fi
    if [ $opt_list -eq 1 ]; then
        while IFS= read -r r; do [ "$(rec_base "$r")" = "${bases[0]}" ] && picked+=("$r"); done <<<"$AB_VERSIONS"
    elif r=$(pick_version "${bases[0]}"); then
        picked+=("$r")
    else
        echo "No version of ${bases[0]} from $at_given or earlier." >&2; bad=1
    fi
done
[ $bad -eq 0 ] || exit 1

if [ $opt_list -eq 1 ]; then
    cmd_list "${picked[@]}"
    [ -n "$fail_after_list" ] && exit 2
    exit 0
fi

# --all, or --verify with no NAMEs: the newest version of every archive for this machine.
# With --at, archives that didn't exist yet are left out.
if [ ${#picked[@]} -eq 0 ]; then
    while IFS= read -r b; do
        # shellcheck disable=SC2254  # AB_MPAT is a glob pattern on purpose
        case "$b" in *_$AB_MPAT) r=$(pick_version "$b") && picked+=("$r") ;; esac
    done < <(printf '%s\n' "$AB_VERSIONS" | while IFS= read -r r; do [ -n "$r" ] && rec_base "$r"; done | LC_ALL=C sort -u)
    [ ${#picked[@]} -gt 0 ] || die "No archives for machine '$AB_MPAT' in $AB_DRIVE."
fi

failed=0
for r in "${picked[@]}"; do
    restore_one "$r" || failed=$((failed + 1))
done
if [ $failed -gt 0 ]; then
    echo "$failed of ${#picked[@]} failed." >&2
    exit 1
fi
if [ $opt_verify -eq 0 ] && [ $opt_dry -eq 0 ] && { [ -z "$opt_to" ] || [ $opt_all -eq 1 ]; }; then
    echo "Done. Nothing in place was changed: copy back what you need from $AB_PARENT."
fi
exit 0
