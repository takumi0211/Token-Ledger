#!/bin/zsh
set -eu
cd "${0:A:h:h}"
version=0.77.0
archive_sha=386c48851a80aad33b8de7d97607ea4548f875724c25e3c20dfe705000b72d91
source_dir="$PWD/.build/engine-source/CodexBar-$version"
output="$PWD/.build/engine"
if [[ -n "${SWIFT_TOOLCHAIN:-}" ]]; then
    export PATH="$SWIFT_TOOLCHAIN/usr/bin:$PATH"
    export SWIFT_EXEC="$SWIFT_TOOLCHAIN/usr/bin/swiftc"
fi
swift_version=$(swift --version | sed -n 's/.*Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)
[[ "$swift_version" == 6.<2->* || "$swift_version" == <7->.* ]] || {
    echo "The CodexBar helper requires Swift 6.2 or later." >&2; exit 1
}
mkdir -p "$output" "${source_dir:h}"
if [[ ! -f "$source_dir/.token-ledger-patch" ]]; then
    archive="$PWD/.build/engine-source/codexbar.tar.gz"
    curl --fail --location --retry 3 "https://github.com/steipete/CodexBar/archive/refs/tags/v$version.tar.gz" -o "$archive"
    echo "$archive_sha  $archive" | shasum -a 256 -c -
    [[ ! -e "$source_dir" ]] || { echo "Incomplete source checkout: remove $source_dir and retry." >&2; exit 1; }
    tar -xzf "$archive" -C "${source_dir:h}"
    patch --batch --forward -p1 -d "$source_dir" < patches/codexbar.patch
    shasum -a 256 patches/codexbar.patch | awk '{print $1}' > "$source_dir/.token-ledger-patch"
fi
expected_patch=$(shasum -a 256 patches/codexbar.patch | awk '{print $1}')
[[ "$(cat "$source_dir/.token-ledger-patch")" == "$expected_patch" ]] || {
    echo "Patch changed: remove $source_dir and rebuild." >&2; exit 1
}
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
# Swift 6.2.3 / macOS 15 SDK compatibility. Keep release optimization and SIL verification.
swift build --package-path "$source_dir" -c release --product CodexBarCLI --jobs 2 --force-resolved-versions \
    -Xswiftc -Xfrontend -Xswiftc -enable-lexical-lifetimes=false \
    -Xswiftc -Xfrontend -Xswiftc -disable-round-trip-debug-types \
    -Xlinker -weak-lswift_Concurrency
cp "$source_dir/.build/release/CodexBarCLI" "$output/"
ditto "$source_dir/.build/release/CodexBar_CodexBarCore.bundle" "$output/CodexBar_CodexBarCore.bundle"
python3 - <<'PYCODE'
import hashlib,json
from pathlib import Path
root=Path.cwd()
data={"project":"steipete/CodexBar","version":"0.77.0+token-ledger", "source_sha256":"386c48851a80aad33b8de7d97607ea4548f875724c25e3c20dfe705000b72d91"}
for name,path in {"binary_sha256":root/".build/engine/CodexBarCLI","patch_sha256":root/"patches/codexbar.patch"}.items():
    data[name]=hashlib.sha256(path.read_bytes()).hexdigest()
(root/".build/engine/provenance.json").write_text(json.dumps(data,indent=2)+"\n")
PYCODE
