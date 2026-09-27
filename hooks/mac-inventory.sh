#!/bin/sh
# Writes app-inventory text files into $1 (default: ~/.local/state/autobackup/inventory).
# Used as the `pre` command of the [app-inventory] job in mac.conf.
# Output is deterministic (no timestamps) so unchanged inventories are not re-uploaded.
#
#   Applications.tsv   every .app in /Applications and ~/Applications: path, version, bundle id, source
#   Brewfile           brew bundle dump (formulae, casks, taps, mas apps, VS Code extensions)
#   mas.txt            Mac App Store apps (if `mas` is installed)
#   npm-global.txt, pipx.txt, uv-tools.txt, cargo.txt   global CLI installs, when those tools exist

out="${1:-$HOME/.local/state/autobackup/inventory}"
mkdir -p "$out" || exit 1
PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.cargo/bin:$HOME/.local/bin:$PATH"
export PATH HOMEBREW_NO_AUTO_UPDATE=1

# write NAME: stdin -> $out/NAME, replaced atomically; empty output removes the file.
write() {
    tmp="$out/.$1.tmp"
    cat >"$tmp"
    if [ -s "$tmp" ]; then mv -f "$tmp" "$out/$1"; else rm -f "$tmp" "$out/$1"; fi
}

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

if command -v brew >/dev/null 2>&1; then
    tmp="$out/.Brewfile.dump"
    rm -f "$tmp"
    brew bundle dump --force --file="$tmp" >/dev/null 2>&1 && write Brewfile <"$tmp"
    rm -f "$tmp"
fi

command -v mas >/dev/null 2>&1 && mas list 2>/dev/null | LC_ALL=C sort | write mas.txt
command -v npm >/dev/null 2>&1 && npm ls -g --depth=0 2>/dev/null | write npm-global.txt
command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | write pipx.txt
command -v uv >/dev/null 2>&1 && uv tool list 2>/dev/null | write uv-tools.txt
command -v cargo >/dev/null 2>&1 && cargo install --list 2>/dev/null | write cargo.txt

exit 0
