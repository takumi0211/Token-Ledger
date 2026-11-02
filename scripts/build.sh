#!/bin/zsh
set -eu
cd "${0:A:h:h}"
engine="$PWD/.build/engine"
zsh scripts/build-engine.sh
zstd_prefix=$(brew --prefix zstd)
swift build -c release
app="$PWD/build/Token Ledger.app"
# Always package into an empty generated directory.
[[ ! -d "$app" ]] || rm -rf "$app"
mkdir -p "$app/Contents/"{MacOS,Helpers,Resources,Frameworks}
cp .build/release/TokenLedger "$app/Contents/MacOS/"
cp Assets/Info.plist "$app/Contents/"
cp Assets/*.png Assets/provenance.json "$app/Contents/Resources/"
cp "$engine/CodexBarCLI" "$app/Contents/Helpers/"
ditto "$engine/CodexBar_CodexBarCore.bundle" "$app/Contents/Helpers/CodexBar_CodexBarCore.bundle"
cp "$engine/provenance.json" "$app/Contents/Resources/engine-provenance.json"
cp "$zstd_prefix/lib/libzstd.1.dylib" "$app/Contents/Frameworks/"
chmod u+w "$app/Contents/Frameworks/libzstd.1.dylib"
install_name_tool -id @rpath/libzstd.1.dylib "$app/Contents/Frameworks/libzstd.1.dylib"
cp LICENSE "$app/Contents/Resources/TokenLedger-LICENSE"
cp ThirdParty/NOTICES.txt "$app/Contents/Resources/"
cp ThirdParty/CodexBar-LICENSE "$app/Contents/Resources/"
cp "$zstd_prefix/LICENSE" "$app/Contents/Resources/Zstd-LICENSE"
cat > "$app/Contents/Resources/NOTICE.txt" <<'NOTICE'
Token Ledger (MIT)
https://github.com/takumi0211/Token-Ledger

Cost engine: CodexBar 0.77.0 by Peter Steinberger (MIT), with the bundled pricing patch.
https://github.com/steipete/CodexBar
See CodexBar-LICENSE, NOTICES.txt and Zstd-LICENSE for dependency licenses.
Provider trademarks belong to Anthropic and OpenAI.

Amounts are API-price estimates from local logs, not invoices or subscription charges.
NOTICE
codesign --force --sign - "$app/Contents/Frameworks/libzstd.1.dylib"
codesign --force --sign - "$app/Contents/Helpers/CodexBarCLI"
codesign --force --sign - "$app/Contents/Helpers/CodexBar_CodexBarCore.bundle"
python3 - "$app" <<'PYCODE'
import hashlib,json,sys
from pathlib import Path
app=Path(sys.argv[1])/"Contents"
path=app/"Resources/engine-provenance.json"
data=json.loads(path.read_text())
data["binary_sha256"]=hashlib.sha256((app/"Helpers/CodexBarCLI").read_bytes()).hexdigest()
path.write_text(json.dumps(data,indent=2)+"\n")
PYCODE
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
echo "$app"
