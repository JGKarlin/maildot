#!/bin/zsh
# Builds the signed, notarized installer for a public release: the app, its Mail extension and its helpers are
# signed with Developer ID Application and the hardened runtime, the installer with Developer ID Installer, and
# the installer is notarized and stapled. Needs both certificates in the login Keychain and a notarytool profile:
#   xcrun notarytool store-credentials maildot-notary --team-id <TEAMID>
#   Tools/build-release.sh [notary profile, default maildot-notary]
# Mail must be quit: building registers the new Mail extension.
set -euo pipefail
ROOT=${0:A:h:h}
PROFILE=${1:-maildot-notary}
cd "$ROOT"
pgrep -x Mail >/dev/null && { print -u2 "Quit Mail first."; exit 1 }
APP_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
PKG_ID=$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer: [^"]*\)".*/\1/p' | head -1)
[[ -n $APP_ID ]] || { print -u2 "No Developer ID Application certificate in the Keychain."; exit 1 }
[[ -n $PKG_ID ]] || { print -u2 "No Developer ID Installer certificate in the Keychain."; exit 1 }
DERIVED=$ROOT/build-release
xcodebuild -project MailDot.xcodeproj -scheme MailDot -configuration Release -derivedDataPath "$DERIVED" \
    CODE_SIGN_IDENTITY="$APP_ID" OTHER_CODE_SIGN_FLAGS="--timestamp" build >&2
APP="$DERIVED/Build/Products/Release/Mail Dot.app"
# The built copy is not the installed one: Mail must never find its extension.
pluginkit -r "$APP/Contents/PlugIns/MailDotExtension.appex" 2>/dev/null || true
# Sparkle's helpers come signed by its project; a Developer ID release signs them again, innermost first, then the
# framework and the app, whose seal covers them (Sparkle's documented order).
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# Only the downloader keeps its entitlements; Autoupdate's com.apple.application-identifier would make launchd refuse it
# under a Developer ID signature without a profile, so it and the others are signed with none (Sparkle's own steps).
codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$APP_ID" "$SPARKLE"/XPCServices/Downloader.xpc >&2
for item in "$SPARKLE"/XPCServices/Installer.xpc "$SPARKLE"/Autoupdate "$SPARKLE"/Updater.app "$APP/Contents/Frameworks/Sparkle.framework"; do
    codesign --force --options runtime --timestamp --sign "$APP_ID" "$item" >&2
done
codesign --force --options runtime --timestamp --preserve-metadata=entitlements,requirements,flags --sign "$APP_ID" "$APP" >&2
codesign --verify --deep --strict --verbose=2 "$APP" >&2
for item in "$APP" "$APP"/Contents/PlugIns/*.appex "$APP"/Contents/Helpers/* "$APP"/Contents/Frameworks/* \
        "$SPARKLE"/XPCServices/* "$SPARKLE"/Autoupdate "$SPARKLE"/Updater.app; do
    info=$(codesign -dvv "$item" 2>&1)
    [[ $info == *"Authority=Developer ID Application"* && $info == *"Timestamp="* && $info == *"(runtime)"* ]] \
        || { print -u2 "Not signed for release: $item"; exit 1 }
    # Without a provisioning profile, a Developer ID signature may not carry this entitlement: launchd refuses the code.
    codesign -d --entitlements - "$item" 2>/dev/null | grep -q "com.apple.application-identifier" \
        && { print -u2 "Restricted entitlement without a profile: $item"; exit 1 }
done
MAILDOT_INSTALLER_IDENTITY="$PKG_ID" MAILDOT_NOTARY_PROFILE="$PROFILE" zsh Tools/build-installer.sh "$APP"
# The automatic update: the same app, stapled, in a signed archive, and the update list that names it. Both go on the
# release whose tag is v<version>; the list is found at releases/latest/download/appcast.xml.
zsh Tools/make-appcast.sh "$APP"
