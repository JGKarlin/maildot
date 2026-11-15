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
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" --scripts "$ROOT/Tools/installer/scripts" \
    --identifier org.jgkarlin.MailBridge.pkg --version "$VERSION" --install-location / "$WORK/MailDot-component.pkg" >/dev/null
sed "s/@VERSION@/$VERSION/g" "$ROOT/Tools/installer/distribution.xml" > "$WORK/distribution.xml"
# The welcome and closing pages, in every language the app is in.
python3 "$ROOT/Tools/installer/make-pages.py" "$WORK/resources" >/dev/null
productbuild --distribution "$WORK/distribution.xml" --resources "$WORK/resources" --package-path "$WORK" "$OUT/Mail-Dot-$VERSION.pkg" >/dev/null
print "$OUT/Mail-Dot-$VERSION.pkg"
