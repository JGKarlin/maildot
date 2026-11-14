#!/bin/zsh
# Removes Mail Dot from this Mac: the app and its Mail extension, the background helper, its settings and what
# it has stored. Everything is moved to a folder in the Trash, so nothing is lost until the Trash is emptied.
# Mail must be closed. Double-click this file, or run it in Terminal.
set -u
ID=org.jgkarlin.MailBridge
APP=${MAILDOT_APP:-/Applications/Mail Dot.app}
DRY=${MAILDOT_REMOVE_DRY_RUN:-}
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# What changes the system outside the user's folders; a dry run only names it.
sys() { if [[ -n $DRY ]]; then print "would run: $*"; else "$@" >/dev/null 2>&1; fi; return 0 }

if [[ -z $DRY ]] && pgrep -x Mail >/dev/null; then print "Quit Mail, then run this again."; exit 1; fi
print -n "Remove Mail Dot and its saved settings from this Mac? Type yes and press Return: "
read answer
[[ $answer == yes ]] || { print "Nothing was removed."; exit 0 }

TRASH="$HOME/.Trash/Mail Dot removed $(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$TRASH" || { print "Could not make a folder in the Trash."; exit 1 }
left=()
move() {
    [[ -e $1 ]] || return 0
    local target="$TRASH/${2:-${1:t}}"
    mv "$1" "$target" 2>/dev/null || left+=("$1")
}

# Stop what is running, and take the extension away from Mail.
sys launchctl bootout "gui/$UID/$ID.Runtime"
for name in "Mail Dot" MailDotRuntime MailDotAgent MailDotExtension; do sys pkill -x "$name"; done
sys pkill -f "$APP/Contents/Helpers/tunnel-client"
sys pluginkit -r "$APP/Contents/PlugIns/MailDotExtension.appex"
sys "$LSREGISTER" -u "$APP"

# The app, then what it stored.
move "$APP"
move "$HOME/Library/Application Support/Mail Dot" "Application Support - Mail Dot"
move "$HOME/Library/Application Support/tunnel-client/health/mail-dot.url"
move "$HOME/Library/Application Support/tunnel-client/logs/mail-dot.log"
for group in "$HOME/Library/Group Containers/"*.$ID(N); do move "$group" "Group Container - ${group:t}"; done
for container in "$HOME/Library/Containers/"$ID*(N); do move "$container" "Container - ${container:t}"; done
for plist in "$HOME/Library/Preferences/"$ID*.plist(N); do move "$plist"; done
for id in $ID $ID.MailExtension $ID.Runtime $ID.Agent; do sys defaults delete "$id"; done
sys security delete-generic-password -s "$ID.tunnel-key"

# Mail Dot's entry in ChatGPT's local tools, if it has one. The file as it was goes to the Trash folder too.
CODEX="$HOME/.codex/config.toml"
if [[ -f $CODEX ]] && grep -q '^\[mcp_servers\.maildot\]' "$CODEX"; then
    cp "$CODEX" "$TRASH/codex-config-before-removal.toml"
    awk '/^\[mcp_servers\.maildot[].]/{skip=1; next} /^\[/{skip=0} !skip' "$CODEX" > "$CODEX.maildot-new" && mv "$CODEX.maildot-new" "$CODEX"
fi

print "Mail Dot has been removed. What it kept is in the Trash, in “${TRASH:t}”."
if (( ${#left} )); then
    print "macOS would not let this be moved; drag it to the Trash yourself:"
    for item in $left; do print "  $item"; done
fi
