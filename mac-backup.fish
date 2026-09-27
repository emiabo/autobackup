#!/usr/bin/env fish
# AutoBackup: macOS implementation. THIS FILE IS CANONICAL.
# Ports that must stay behaviorally identical: mac-backup.sh (bash 3.2+), win-backup.ps1 (PowerShell 5.1/7).
#
# Reads jobs from mac.conf (INI-style, see README.md), archives each job's folders with tar,
# and moves the archives into a cloud-sync folder (Proton Drive). Safe to run often:
# each job only runs when its `every` interval has elapsed, and skips when nothing changed.
#
# Run `mac-backup.fish --help` for flags.

set -g AB_HERE (dirname (realpath (status filename)))
set -g AB_OS (uname -s)
set -g AB_CONFIG $AB_HERE/mac.conf
set -q AUTOBACKUP_CONFIG; and set AB_CONFIG $AUTOBACKUP_CONFIG
set -g AB_TAR /usr/bin/tar
set -q AUTOBACKUP_TAR; and set AB_TAR $AUTOBACKUP_TAR
set -g AB_SEP \x1f
set -g AB_CFG
set -g AB_MACHINE ''
set -g AB_STATE ''
set -g AB_LOCK ''
set -g AB_U_INC
set -g AB_U_EXC
set -g opt_force 0
set -g opt_dry 0
set -g opt_verbose 0
set -g opt_only

# launchd starts jobs with a minimal PATH; make Homebrew tools (zstd, brew, mas) visible.
for d in /usr/local/bin /opt/homebrew/bin
    if test -d $d; and not contains -- $d $PATH
        set -gx PATH $d $PATH
    end
end
# Stop macOS tar from adding AppleDouble (._*) files.
set -gx COPYFILE_DISABLE 1

# ---------------------------------------------------------------- helpers

function usage
    echo "Usage: mac-backup.fish [options]

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
  mac-backup.fish --only obsidian            # Alfred keyword
  mac-backup.fish --list
  mac-backup.fish --only dotfiles --dry-run -v
  mac-backup.fish --add notes root=~/Notes dest=Documents/Notes every=1d"
end

function log --argument-names level
    set -l line (date '+%Y-%m-%d %H:%M:%S')" [$level] "(string join ' ' -- $argv[2..-1])
    if test "$level" = ERROR
        echo $line >&2
    else
        echo $line
    end
    if test $opt_dry -eq 0; and test -n "$AB_STATE"; and test -d "$AB_STATE"
        echo $line >>$AB_STATE/autobackup.log
    end
end

function vlog
    test $opt_verbose -eq 1; and echo (date '+%Y-%m-%d %H:%M:%S')" [DEBUG] "(string join ' ' -- $argv)
    return 0
end

function is_true
    string match -qi -r '^(1|y|yes|true|on)$' -- "$argv[1]"
end

function sanitize --argument-names s
    string replace -ra -- '[^A-Za-z0-9._-]+' - $s | string trim -c -
end

# ~ at the start, {here} (this script's folder) and {machine} are expanded.
function expand_path --argument-names p
    set p (string replace -r -- '^~(?=/|$)' $HOME $p)
    set p (string replace -a -- '{here}' $AB_HERE $p)
    set p (string replace -a -- '{machine}' "$AB_MACHINE" $p)
    printf '%s\n' $p
end

# "30m", "12h", "1d", "2w", "90s"; bare number = hours.
function dur_secs --argument-names d
    set -l m (string match -r '^\s*(\d+)\s*([smhdw]?)\s*$' -- $d)
    or return 1
    switch "$m[3]"
        case s
            echo $m[2]
        case m
            math "$m[2] * 60"
        case d
            math "$m[2] * 86400"
        case w
            math "$m[2] * 604800"
        case '*'
            math "$m[2] * 3600"
    end
end

function mtime --argument-names f
    if test $AB_OS = Darwin
        stat -f %m $f 2>/dev/null
    else
        stat -c %Y $f 2>/dev/null
    end
end

function fmt_epoch --argument-names s
    if test $AB_OS = Darwin
        date -r $s '+%Y-%m-%d %H:%M'
    else
        date -d @$s '+%Y-%m-%d %H:%M'
    end
end

function notify --argument-names msg
    command -q osascript; or return 0
    osascript -e "display notification \"$msg\" with title \"AutoBackup\"" >/dev/null 2>&1
end

# ---------------------------------------------------------------- config

# Parses the INI file into AB_CFG records: section<US>key<US>value.
# Keys before any [section] belong to "global". Keys are case-insensitive.
function cfg_load --argument-names file
    set -g AB_CFG
    set -l sec global
    set -l n 0
    while read -l raw
        set n (math $n + 1)
        set -l line (string trim -- (string replace -a \r '' -- "$raw"))
        switch "$line"
            case '' '#*' ';*'
                continue
            case '[*]'
                set sec (string trim -- (string sub -s 2 -e -1 -- $line))
            case '*=*'
                set -l kv (string split -m 1 = -- $line)
                set -l k (string lower -- (string trim -- $kv[1]))
                set -l v (string trim -- $kv[2])
                set -a AB_CFG "$sec$AB_SEP$k$AB_SEP$v"
            case '*'
                log WARN "config line $n ignored: $line"
        end
    end <$file
end

# All values of key in section, in file order.
function cfg_vals --argument-names sec key
    for rec in $AB_CFG
        set -l p (string split $AB_SEP -- $rec)
        if test "$p[1]" = "$sec" -a "$p[2]" = "$key"
            printf '%s\n' $p[3]
        end
    end
end

# Last value of key in section, else in [global], else the default.
function cfg_get --argument-names sec key def
    set -l v (cfg_vals $sec $key)
    test (count $v) -eq 0; and set v (cfg_vals global $key)
    if test (count $v) -gt 0
        printf '%s\n' $v[-1]
    else if test -n "$def"
        printf '%s\n' $def
    end
end

function cfg_jobs
    set -l seen
    for rec in $AB_CFG
        set -l s (string split -f1 $AB_SEP -- $rec)
        if test "$s" != global; and not contains -- $s $seen
            set -a seen $s
        end
    end
    printf '%s\n' $seen
end

# ---------------------------------------------------------------- state

function lock_acquire
    set -l dir $AB_STATE/lock
    if mkdir $dir 2>/dev/null
        echo $fish_pid >$dir/pid
        set -g AB_LOCK $dir
        return 0
    end
    set -l pid (cat $dir/pid 2>/dev/null)
    if test -n "$pid"; and kill -0 $pid 2>/dev/null
        return 1
    end
    # Lock dir without a live owner: stale (crash, reboot). Take it over.
    rm -rf $dir
    mkdir $dir 2>/dev/null; or return 1
    echo $fish_pid >$dir/pid
    set -g AB_LOCK $dir
end

function lock_release --on-event fish_exit
    test -n "$AB_LOCK"; and rm -rf $AB_LOCK
    set -g AB_LOCK ''
end

function on_term --on-signal TERM --on-signal INT
    lock_release
    exit 143
end

# A job is due when its .checked stamp is older than `every` (or missing).
# The stamp is touched after every successful pass, including "unchanged" skips.
function job_due --argument-names job every
    set -l f $AB_STATE/stamps/$job.checked
    test -e $f; or return 0
    set -l secs (dur_secs $every)
    or begin
        log WARN "[$job] bad every='$every', using 1d"
        set secs 86400
    end
    test (math (date +%s) - (mtime $f)) -ge $secs
end

function any_running --argument-names list
    for p in (string split , -- $list)
        set p (string trim -- $p)
        test -n "$p"; or continue
        if pgrep -x -- $p >/dev/null 2>&1
            printf '%s\n' $p
            return 0
        end
    end
    return 1
end

# ---------------------------------------------------------------- compression

function tar_has_zstd
    if not set -q AB_TAR_ZSTD
        if $AB_TAR --version 2>/dev/null | string match -q '*zstd*'
            set -g AB_TAR_ZSTD 1
        else
            set -g AB_TAR_ZSTD 0
        end
    end
    test $AB_TAR_ZSTD -eq 1
end

# Config value -> concrete method. zstd prefers the zstd CLI (multithreaded),
# then tar's built-in zstd, then falls back to gzip.
function resolve_method --argument-names mode
    switch $mode
        case zstd zst
            if command -q zstd
                echo zstd-ext
            else if tar_has_zstd
                echo zstd-native
            else
                echo gzip
            end
        case gzip gz
            echo gzip
        case none tar
            echo none
        case copy
            echo copy
        case '*'
            return 1
    end
end

function method_ext --argument-names method
    switch $method
        case zstd-ext zstd-native
            echo .tar.zst
        case gzip
            echo .tar.gz
        case none
            echo .tar
    end
end

# build_archive METHOD LEVEL OUTFILE ROOT [tar args: --exclude P ... -- INCLUDES...]
function build_archive --argument-names method level out root
    set -l rest $argv[5..-1]
    set -l base -c -C $root
    test $AB_OS = Darwin; and set -a base --no-mac-metadata
    switch $method
        case zstd-ext
            set -l raw $out.part.tar
            if not $AB_TAR $base -f $raw $rest
                rm -f $raw
                return 1
            end
            zstd -q -T0 -$level -f --rm -o $out $raw
            or begin
                rm -f $raw $out
                return 1
            end
        case zstd-native
            $AB_TAR $base -f $out --zstd --options zstd:compression-level=$level $rest
        case gzip
            $AB_TAR $base -f $out -z --options gzip:compression-level=$level $rest
        case none
            $AB_TAR $base -f $out $rest
        case '*'
            return 1
    end
end

# ---------------------------------------------------------------- jobs

# archive_unit JOB KEY NAME ROOT METHOD LEVEL SKIP_UNCHANGED DESTDIR
# Uses globals AB_U_INC (paths relative to ROOT) and AB_U_EXC (tar patterns).
function archive_unit --argument-names job key uname uroot method level skip_unch destdir
    set -l fname (sanitize $uname)_$AB_MACHINE(method_ext $method)
    set -l target $destdir/$fname
    set -l stamp $AB_STATE/stamps/$key.last

    set -l incs
    for i in $AB_U_INC
        if test -e "$uroot/$i"; or test -L "$uroot/$i"
            set -a incs $i
        else
            vlog "[$key] include not found, skipped: $i"
        end
    end
    if test (count $incs) -eq 0
        log WARN "[$key] nothing to archive under $uroot"
        return 0
    end

    # The descriptor records what produced the archive; editing the job forces a rebuild.
    set -l desc "root=$uroot" "method=$method" "level=$level"
    for i in $incs
        set -a desc "include=$i"
    end
    for e in $AB_U_EXC
        set -a desc "exclude=$e"
    end

    if test $opt_force -eq 0; and is_true $skip_unch; and test -e $target; and test -e $stamp
        if test (string join \x1e -- $desc) = (string join \x1e -- (cat $stamp))
            set -l paths
            for i in $incs
                set -a paths $uroot/$i
            end
            # Conservative: excluded files count too, so this can rebuild needlessly but never miss a change.
            set -l hit (find $paths -newer $stamp -print -quit 2>/dev/null)
            if test -z "$hit"
                vlog "[$key] unchanged, skipped"
                return 0
            end
            vlog "[$key] changed: $hit"
        end
    end

    if test $opt_dry -eq 1
        log INFO "[$key] would write $target ($method, from $uroot: "(string join ', ' -- $incs)")"
        return 0
    end

    mkdir -p $AB_STAGING $AB_STATE/stamps
    if not mkdir -p $destdir
        log ERROR "[$key] cannot create $destdir"
        return 1
    end
    set -l pending $AB_STATE/stamps/$key.pending
    printf '%s\n' $desc >$pending
    set -l tmp $AB_STAGING/$fname
    rm -f $tmp $tmp.part.tar

    set -l targs
    for e in $AB_U_EXC
        set -a targs --exclude $e
    end
    set -a targs -- $incs  # tar end-of-options marker, then the include paths

    set -l t0 (date +%s)
    if not build_archive $method $level $tmp $uroot $targs
        rm -f $tmp $pending
        log ERROR "[$key] archiving failed for $uroot"
        return 1
    end
    # Same volume as the sync folder, so this is an atomic rename: the sync client never sees a partial file.
    if not mv -f $tmp $target
        rm -f $tmp $pending
        log ERROR "[$key] could not move archive to $target"
        return 1
    end
    mv -f $pending $stamp
    set -l size (du -h $target | cut -f1 | string trim)
    log INFO "[$key] wrote $target ($size, "(math (date +%s) - $t0)"s)"
end

# copy mode: flat copy of the files directly inside ROOT, renamed NAME_MACHINE.ext.
# Only changed files are copied.
function copy_files --argument-names key root destdir
    set -l fail 0
    for f in $root/*
        test -f $f; or continue
        set -l name (basename $f)
        set -l skip 0
        for e in $AB_U_EXC
            string match -q -- $e $name; and set skip 1
        end
        test $skip -eq 1; and continue
        set -l stem $name
        set -l ext ''
        set -l m (string match -r '^(.+)(\.[^.]+)$' -- $name)
        and begin
            set stem $m[2]
            set ext $m[3]
        end
        set -l tname (sanitize $stem)_$AB_MACHINE$ext
        set -l tgt $destdir/$tname
        if test -e $tgt; and cmp -s $f $tgt
            vlog "[$key] unchanged: $tname"
            continue
        end
        if test $opt_dry -eq 1
            log INFO "[$key] would copy $name -> $tgt"
            continue
        end
        mkdir -p $destdir $AB_STAGING
        if cp -f $f $AB_STAGING/$tname; and mv -f $AB_STAGING/$tname $tgt
            log INFO "[$key] updated $tgt"
        else
            log ERROR "[$key] could not copy $f"
            set fail 1
        end
    end
    return $fail
end

function run_job --argument-names job
    if not is_true (cfg_get $job enabled true)
        vlog "[$job] disabled"
        return 0
    end
    set -l root (expand_path (cfg_get $job root))
    set -l dest (string trim -c / -- (cfg_get $job dest))
    if test -z "$root" -o -z "$dest"
        log ERROR "[$job] needs both root and dest"
        return 1
    end
    set -l mode (string lower -- (cfg_get $job compress zstd))
    set -l method (resolve_method $mode)
    or begin
        log ERROR "[$job] unknown compress '$mode' (use zstd, gzip, none or copy)"
        return 1
    end
    set -l level (cfg_get $job level)
    if test -z "$level"
        test $method = gzip; and set level 6; or set level 3
    end
    set -l every (cfg_get $job every 1d)

    set -l ignore_due $opt_force
    test (count $opt_only) -gt 0; and set ignore_due 1
    if test $ignore_due -eq 0; and not job_due $job $every
        vlog "[$job] not due (every $every)"
        return 0
    end

    set -l running (any_running (cfg_get $job skip_if_running))
    if test -n "$running"
        log INFO "[$job] skipped: $running is running; will retry next run"
        return 0
    end

    set -l pre (cfg_vals $job pre)
    if test -n "$pre[-1]"
        set pre (expand_path $pre[-1])
        if test $opt_dry -eq 1
            log INFO "[$job] would run pre: $pre"
        else if not /bin/sh -c $pre
            log ERROR "[$job] pre command failed: $pre"
            return 1
        end
    end

    if not test -d $root
        if test $opt_dry -eq 1 -a -n "$pre"
            log INFO "[$job] root $root does not exist yet (pre would create it)"
            return 0
        end
        log ERROR "[$job] root folder not found: $root"
        return 1
    end

    set -g AB_U_EXC (cfg_vals global exclude) (cfg_vals $job exclude)
    set -l destdir $AB_DRIVE/$dest
    set -l skip_unch (cfg_get $job skip_unchanged true)
    set -l fail 0

    if test $method = copy
        copy_files $job $root $destdir; or set fail 1
    else if is_true (cfg_get $job split false)
        # One archive per immediate subfolder (e.g. one per Prism instance).
        set -l found 0
        for d in $root/*/
            set -l sub (basename $d)
            set -l skip 0
            for e in $AB_U_EXC
                string match -q -- $e $sub; and set skip 1
            end
            test $skip -eq 1; and continue
            set found 1
            set -g AB_U_INC .
            archive_unit $job "$job@"(sanitize $sub) $sub $root/$sub $method $level $skip_unch $destdir
            or set fail 1
        end
        test $found -eq 0; and log WARN "[$job] split=true but no subfolders in $root"
    else
        set -g AB_U_INC (cfg_vals $job include)
        test (count $AB_U_INC) -eq 0; and set -g AB_U_INC .
        set -l name (cfg_vals $job name)
        test -z "$name[-1]"; and set name $job
        archive_unit $job $job $name[-1] $root $method $level $skip_unch $destdir
        or set fail 1
    end

    if test $fail -eq 0 -a $opt_dry -eq 0
        mkdir -p $AB_STATE/stamps
        touch $AB_STATE/stamps/$job.checked
    end
    return $fail
end

# ---------------------------------------------------------------- commands

function cmd_list
    printf '%-18s %-5s %-6s %-26s %-16s %s\n' JOB MODE EVERY DEST 'LAST RUN' STATUS
    for job in (cfg_jobs)
        set -l f $AB_STATE/stamps/$job.checked
        set -l last never
        test -e $f; and set last (fmt_epoch (mtime $f))
        set -l status_ ok
        if not is_true (cfg_get $job enabled true)
            set status_ disabled
        else if job_due $job (cfg_get $job every 1d)
            set status_ due
        end
        printf '%-18s %-5s %-6s %-26s %-16s %s\n' $job (cfg_get $job compress zstd) (cfg_get $job every 1d) (cfg_get $job dest) $last $status_
    end
    echo
    echo "Drive root: $AB_DRIVE"
    echo "Log:        $AB_STATE/autobackup.log"
end

function cmd_add
    set -l name $argv[1]
    set -l pairs $argv[2..-1]
    if test -z "$name"
        read -P 'Job name (letters, digits, . _ -): ' name; or return 1
    end
    if not string match -qr '^[A-Za-z0-9._-]+$' -- $name
        echo "Invalid job name: '$name'" >&2
        return 1
    end
    if contains -- $name (cfg_jobs)
        echo "Job [$name] already exists in $AB_CONFIG. Edit it there (--edit)." >&2
        return 1
    end
    set -l lines "[$name]"
    set -l have_root 0
    set -l have_dest 0
    for p in $pairs
        if not string match -qr '^[A-Za-z_]+=' -- $p
            echo "Expected key=value, got: $p" >&2
            return 1
        end
        set -l kv (string split -m 1 = -- $p)
        set -a lines "$kv[1] = $kv[2]"
        test $kv[1] = root; and set have_root 1
        test $kv[1] = dest; and set have_dest 1
    end
    set -l v
    if test $have_root -eq 0
        read -P 'Source folder (root): ' v; or return 1
        test -n "$v"; or return 1
        set -a lines "root = $v"
    end
    if test $have_dest -eq 0
        read -P 'Drive subfolder under the drive root (e.g. Documents/Obsidian): ' v; or return 1
        test -n "$v"; or return 1
        set -a lines "dest = $v"
    end
    if test (count $pairs) -eq 0
        echo 'Paths inside root to include, one per line. Blank line = done (none = whole root).'
        while read -P '  include: ' v; and test -n "$v"
            set -a lines "include = $v"
        end
        echo 'Exclude patterns (e.g. node_modules, *.log, sub/dir). Blank line = done.'
        while read -P '  exclude: ' v; and test -n "$v"
            set -a lines "exclude = $v"
        end
        read -P "Compression: zstd, gzip, none or copy [default "(cfg_get global compress zstd)"]: " v
        test -n "$v"; and set -a lines "compress = $v"
        read -P "How often, e.g. 12h, 1d, 7d [default "(cfg_get global every 1d)"]: " v
        test -n "$v"; and set -a lines "every = $v"
        read -P 'One archive per subfolder of root? [y/N]: ' v
        is_true $v; and set -a lines "split = true"
    end
    printf '\n' >>$AB_CONFIG
    printf '%s\n' $lines >>$AB_CONFIG
    echo "Added to $AB_CONFIG:"
    printf '  %s\n' $lines
    echo "Test it: "(status filename)" --only $name --dry-run -v"
end

# ---------------------------------------------------------------- main

argparse 'c/config=' 'o/only=+' f/force n/dry-run l/list a/add e/edit v/verbose h/help -- $argv
or begin
    usage >&2
    exit 2
end
if set -q _flag_help
    usage
    exit 0
end
set -q _flag_config; and set AB_CONFIG (expand_path $_flag_config)
set -q _flag_force; and set opt_force 1
set -q _flag_dry_run; and set opt_dry 1
set -q _flag_verbose; and set opt_verbose 1
for o in $_flag_only
    set -a opt_only (string split , -- $o | string trim)
end

if not test -f $AB_CONFIG
    echo "Config not found: $AB_CONFIG" >&2
    exit 1
end

if set -q _flag_edit
    if test -n "$EDITOR"
        eval $EDITOR (string escape -- $AB_CONFIG)
    else
        open -t $AB_CONFIG
    end
    exit $status
end

cfg_load $AB_CONFIG
set AB_MACHINE (cfg_get global machine)
set -g AB_DRIVE (string trim -r -c / -- (expand_path (cfg_get global drive_root)))
set AB_STATE (expand_path (cfg_get global state ~/.local/state/autobackup))
set -g AB_STAGING (expand_path (cfg_get global staging ~/.cache/autobackup))

if set -q _flag_add
    cmd_add $argv
    exit $status
end

if test -z "$AB_MACHINE" -o -z "$AB_DRIVE"
    echo "[global] needs machine and drive_root in $AB_CONFIG" >&2
    exit 1
end
mkdir -p $AB_STATE/stamps

if set -q _flag_list
    cmd_list
    exit 0
end

# Refuse to run if the sync folder's parent is missing (Proton not installed/mounted).
if not test -d (dirname $AB_DRIVE)
    log ERROR "drive_root parent does not exist: "(dirname $AB_DRIVE)" (is Proton Drive running?)"
    test $opt_dry -eq 0; and notify "Drive folder missing; nothing backed up."
    exit 1
end

# Keep the log from growing forever.
set -l logf $AB_STATE/autobackup.log
if test -f $logf; and test (wc -c <$logf | string trim) -gt 1048576
    mv -f $logf $logf.1
end

if not lock_acquire
    vlog "another run is in progress; exiting"
    exit 0
end

set -l jobs (cfg_jobs)
if test (count $opt_only) -gt 0
    for o in $opt_only
        if not contains -- $o $jobs
            log ERROR "no job named [$o] in $AB_CONFIG"
            exit 1
        end
    end
    set jobs $opt_only
end

set -l failed
for job in $jobs
    run_job $job; or set -a failed $job
end

if test (count $failed) -gt 0
    test $opt_dry -eq 0; and notify "Failed: "(string join ', ' -- $failed)". See autobackup.log."
    exit 1
end
exit 0
