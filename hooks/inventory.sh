#!/bin/sh
# Writes app-inventory text files into $1 (default: ~/.local/state/autobackup/inventory).
# Used as the `pre` command of the [app-inventory] job on macOS and Linux.
# Output is deterministic (no timestamps) so unchanged inventories are not re-uploaded.
# Each file is written only when its tool exists.
#
#   macOS   Applications.tsv   every .app in /Applications and ~/Applications: path, version, bundle id, source
#           mas.txt            Mac App Store apps
#   Linux   apt-manual.txt     packages you installed with apt (not their dependencies)
#           dnf-user.txt       packages you installed with dnf
#           pacman-explicit.txt  packages you installed with pacman
#           flatpak.tsv, snap.txt
#   Both    Brewfile           brew bundle dump (formulae, casks, taps, mas apps, VS Code extensions)
#           npm-global.txt, pipx.txt, uv-tools.txt, cargo.txt   global CLI installs

out="${1:-$HOME/.local/state/autobackup/inventory}"
mkdir -p "$out" || exit 1
PATH="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export PATH HOMEBREW_NO_AUTO_UPDATE=1

# write NAME: stdin -> $out/NAME, replaced atomically; empty output removes the file.
write() {
    tmp="$out/.$1.tmp"
    cat >"$tmp"
    if [ -s "$tmp" ]; then mv -f "$tmp" "$out/$1"; else rm -f "$tmp" "$out/$1"; fi
}

has() { command -v "$1" >/dev/null 2>&1; }

if [ "$(uname -s)" = Darwin ]; then
    plist_get() {
        /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null
    }
    # .app bundles, including ones nested in vendor folders (e.g. /Applications/Utilities).
    for dir in /Applications "$HOME/Applications"; do
        [ -d "$dir" ] && find "$dir" -maxdepth 3 -name '*.app' -prune -print 2>/dev/null
    done | LC_ALL=C sort | while IFS= read -r app; do
        ver=$(plist_get "$app" CFBundleShortVersionString)
        bid=$(plist_get "$app" CFBundleIdentifier)
        src=other
        [ -e "$app/Contents/_MASReceipt" ] && src=appstore
        [ -L "$app" ] && src=symlink
        printf '%s\t%s\t%s\t%s\n' "$app" "${ver:--}" "${bid:--}" "$src"
    done | write Applications.tsv
    has mas && mas list 2>/dev/null | LC_ALL=C sort | write mas.txt
else
    has apt-mark && apt-mark showmanual 2>/dev/null | LC_ALL=C sort | write apt-manual.txt
    has dnf && dnf repoquery --userinstalled --qf '%{name}\n' 2>/dev/null | LC_ALL=C sort -u | write dnf-user.txt
    has pacman && pacman -Qqe 2>/dev/null | LC_ALL=C sort | write pacman-explicit.txt
    has flatpak && flatpak list --app --columns=application,version 2>/dev/null | LC_ALL=C sort | write flatpak.tsv
    has snap && snap list 2>/dev/null | write snap.txt
fi

if has brew; then
    tmp="$out/.Brewfile.dump"
    rm -f "$tmp"
    brew bundle dump --force --file="$tmp" >/dev/null 2>&1 && write Brewfile <"$tmp"
    rm -f "$tmp"
fi

has npm && npm ls -g --depth=0 2>/dev/null | write npm-global.txt
has pipx && pipx list --short 2>/dev/null | write pipx.txt
has uv && uv tool list 2>/dev/null | write uv-tools.txt
has cargo && cargo install --list 2>/dev/null | write cargo.txt

exit 0
