#!/bin/bash
# Copies OpenAI's tunnel client and its license into Vendor/tunnel-client, from which the build embeds it in
# Mail Dot.app/Contents/Helpers. Vendor/ is not in the repository. Usage: Tools/vendor-tunnel-client.sh [prefix]
# where prefix is a tunnel-client installation (default: Homebrew's, from `brew install openai/tools/tunnel-client`).
set -euo pipefail
PREFIX="${1:-$(brew --prefix tunnel-client 2>/dev/null || true)}"
[ -n "$PREFIX" ] && [ -x "$PREFIX/libexec/tunnel-client" ] || { echo "No tunnel-client installation found. Install it with: brew install openai/tools/tunnel-client" >&2; exit 1; }
DEST="$(cd "$(dirname "$0")/.." && pwd)/Vendor/tunnel-client"
mkdir -p "$DEST"
cp "$PREFIX/libexec/tunnel-client" "$DEST/tunnel-client"
cp "$PREFIX/LICENSE" "$PREFIX/NOTICE" "$DEST/"
"$DEST/tunnel-client" --version 2>/dev/null | head -1 > "$DEST/VERSION" || true
echo "Vendored tunnel-client from $PREFIX into $DEST"
