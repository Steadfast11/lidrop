#!/bin/bash
# Build dist/lidrop.exe from windows/: one file, no installer, tunnel inside. Everything comes from crates.io and
# rustup; no GitHub and no CI involved. Needs Rust and mingw-w64 (macOS: brew install mingw-w64).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TARGET=x86_64-pc-windows-gnu
DUMBPIPE=0.40.1
cd "$ROOT/windows"

command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "mingw-w64 is missing (macOS: brew install mingw-w64)" >&2; exit 1; }
rustup target add "$TARGET" >/dev/null 2>&1 || true

# the tunnel, built from source at the exact version the phones run
if [ ! -f vendor/dumbpipe.exe ]; then
    cargo install dumbpipe --version "=$DUMBPIPE" --locked --target "$TARGET" --root target/dumbpipe --target-dir target/dumbpipe-build
    mkdir -p vendor
    cp target/dumbpipe/bin/dumbpipe.exe vendor/dumbpipe.exe
fi

cargo test -p lidrop-core
cargo build -p lidrop --release --target "$TARGET"
EXE="target/$TARGET/release/lidrop.exe"

# a stray mingw runtime DLL would stop the .exe from starting on a clean PC, with no way to see why here
BAD="$(x86_64-w64-mingw32-objdump -p "$EXE" | grep 'DLL Name' | grep -iE 'libgcc|libstdc|libwinpthread' || true)"
[ -z "$BAD" ] || { echo "lidrop.exe would need DLLs a PC does not have:" >&2; echo "$BAD" >&2; exit 1; }
# TaskDialogIndirect exists only in common controls 6, which only the manifest asks for
grep -aq 'Microsoft.Windows.Common-Controls' "$EXE" || { echo "lidrop.exe has no manifest" >&2; exit 1; }

mkdir -p "$ROOT/dist"
cp "$EXE" "$ROOT/dist/lidrop.exe"
echo "Built $ROOT/dist/lidrop.exe ($(du -h "$ROOT/dist/lidrop.exe" | cut -f1))"
