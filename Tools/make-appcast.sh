#!/bin/zsh
# Makes Mail Dot's automatic-update files for one release (owner's approval of automatic updates, 18 November 2026):
# work/release/Mail-Dot-<version>.zip, the notarized app stapled and archived, and work/release/appcast.xml, the
# update list naming it with its EdDSA signature. Sparkle's sign_update reads the signing key from the login
# Keychain (account "maildot", made with generate_keys); the key never leaves it. Both files are uploaded to the
# GitHub release tagged v<version>, so that releases/latest/download/appcast.xml always names the newest build.
#   Tools/make-appcast.sh "<path to the notarized Mail Dot.app>"
set -euo pipefail
ROOT=${0:A:h:h}
APP=${1:?give the notarized Mail Dot.app}
SIGN=${MAILDOT_SIGN_UPDATE:-$ROOT/work/sparkle-2.10.1/bin/sign_update}
OUT=$ROOT/work/release
INFO="$APP/Contents/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")
BUILD=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")
MINIMUM=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")
# The installer's notarization covers the app inside it; the app carries its own ticket so that it opens offline.
xcrun stapler staple "$APP" >&2
ZIP="$OUT/Mail-Dot-$VERSION.zip"
STAGED="$OUT/.Mail-Dot-$VERSION.zip.part"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$STAGED"
mv -f "$STAGED" "$ZIP"
SIGNATURE=$("$SIGN" --account maildot "$ZIP")
[[ $SIGNATURE == *'sparkle:edSignature="'* ]] || { print -u2 "sign_update gave no signature."; exit 1 }
URL="https://github.com/JGKarlin/maildot/releases/download/v$VERSION/Mail-Dot-$VERSION.zip"
DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
cat > "$OUT/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Mail Dot</title>
    <item>
      <title>Mail Dot $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <enclosure url="$URL" type="application/octet-stream" $SIGNATURE/>
    </item>
  </channel>
</rss>
XML
print "Update archive: $ZIP"
print "Update list:    $OUT/appcast.xml"
