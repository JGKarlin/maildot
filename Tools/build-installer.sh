#!/bin/zsh
# Builds Mail Dot's installer from a built copy of the app: one .pkg that asks the user to quit Mail, puts
# Mail Dot in Applications, registers the extension and opens Mail Dot's window.
#   Tools/build-installer.sh [path to Mail Dot.app] [output folder]
set -euo pipefail
ROOT=${0:A:h:h}
APP=${1:-$ROOT/build/Build/Products/Release/Mail Dot.app}
OUT=${2:-$ROOT/work/release}
[[ -d $APP ]] || { print -u2 "No app at $APP. Build the MailDot scheme first."; exit 1 }
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
WORK=$(mktemp -d -t maildot-installer)
mkdir -p "$WORK/root/Applications" "$OUT"
ditto "$APP" "$WORK/root/Applications/Mail Dot.app"
# Not relocatable: the installer must write to Applications, never update some other copy of the app it finds.
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$WORK/component.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$WORK/component.plist"
# The scripts go in without their extended attributes, which pkgbuild would otherwise pack beside them as ._ files.
mkdir -p "$WORK/scripts"
for script in preinstall postinstall; do
    cp -X "$ROOT/Tools/installer/scripts/$script" "$WORK/scripts/$script"
    chmod 755 "$WORK/scripts/$script"
done
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts "$WORK/scripts" \
    --identifier org.jgkarlin.MailBridge.pkg --version "$VERSION" --install-location / "$WORK/MailDot-component.pkg" >/dev/null
sed "s/@VERSION@/$VERSION/g" "$ROOT/Tools/installer/distribution.xml" > "$WORK/distribution.xml"
# The welcome and closing pages, in every language the app is in.
python3 "$ROOT/Tools/installer/make-pages.py" "$WORK/resources" >/dev/null
PKG="$OUT/Mail-Dot-$VERSION.pkg"
# A release is signed with a Developer ID Installer certificate (MAILDOT_INSTALLER_IDENTITY, for example
# "Developer ID Installer: Your Name (TEAMID)") and notarized with a notarytool keychain profile (MAILDOT_NOTARY_PROFILE).
SIGN=()
[[ -n ${MAILDOT_INSTALLER_IDENTITY:-} ]] && SIGN=(--sign "$MAILDOT_INSTALLER_IDENTITY" --timestamp)
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" $SIGN "$PKG" >/dev/null
if [[ -n ${MAILDOT_NOTARY_PROFILE:-} ]]; then
    xcrun notarytool submit "$PKG" --keychain-profile "$MAILDOT_NOTARY_PROFILE" --wait >&2
    xcrun stapler staple "$PKG" >&2
fi
print "$PKG"
