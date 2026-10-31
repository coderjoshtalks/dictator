#!/bin/zsh
# Builds Dictator.app into ./dist (with the llama.cpp runtime bundled) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")/.."
LLAMA_BUILD=b11669
LLAMA_SHA=dbed55493d72bc1ba2babc8770d669c2289b5bc4ee9fb2a4dfc158d45b7d13fd

swift build -c release

# llama.cpp runtime: cached in .vendor, verified against the release digest.
VENDOR=.vendor/llama-$LLAMA_BUILD
if [[ ! -x "$VENDOR/llama-server" ]]; then
  mkdir -p .vendor
  curl -fsSL -o .vendor/llama.tar.gz "https://github.com/ggml-org/llama.cpp/releases/download/$LLAMA_BUILD/llama-$LLAMA_BUILD-bin-macos-arm64.tar.gz"
  echo "$LLAMA_SHA  .vendor/llama.tar.gz" | shasum -a 256 -c -
  tar -xzf .vendor/llama.tar.gz -C .vendor
  rm .vendor/llama.tar.gz
fi

APP=dist/Dictator.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/llama"
cp .build/release/Dictator "$APP/Contents/MacOS/Dictator"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R Resources/licenses "$APP/Contents/Resources/licenses"

# Only what llama-server links against (symlinks resolved).
cp "$VENDOR/llama-server" "$APP/Contents/Resources/llama/"
for lib in libllama-server-impl.dylib libllama-common.0.dylib libmtmd.0.dylib libllama.0.dylib libggml.0.dylib \
           libggml-cpu.0.dylib libggml-blas.0.dylib libggml-metal.0.dylib libggml-rpc.0.dylib libggml-base.0.dylib; do
  cp -L "$VENDOR/$lib" "$APP/Contents/Resources/llama/$lib"
done

if [[ ! -f dist/AppIcon.icns ]]; then
  ICONSET=$(mktemp -d)/AppIcon.iconset; mkdir -p "$ICONSET"
  swift scripts/make-icon.swift "$ICONSET/base.png"
  for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) "$ICONSET/base.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  rm "$ICONSET/base.png"
  iconutil -c icns "$ICONSET" -o dist/AppIcon.icns
fi
cp dist/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Sign inside-out with a stable identity so macOS keeps Microphone/Accessibility permissions across builds.
# Order: $SIGN_IDENTITY (e.g. "Developer ID Application: …") → the local Dictator signing keychain → ad-hoc.
IDENTITY="${SIGN_IDENTITY:-}"
KEYCHAIN_OPTS=()
SIGNING_KC="$HOME/Library/Keychains/dictator-signing.keychain-db"
if [[ -z "$IDENTITY" && -f "$SIGNING_KC" && -f "$HOME/.dictator-signing/keychain-password" ]]; then
  security unlock-keychain -p "$(cat "$HOME/.dictator-signing/keychain-password")" "$SIGNING_KC"
  IDENTITY=$(security find-certificate -c "Dictator Signing" -Z "$SIGNING_KC" | awk '/SHA-1 hash/ {print $3; exit}')
  KEYCHAIN_OPTS=(--keychain "$SIGNING_KC")
fi
[[ -z "$IDENTITY" ]] && { IDENTITY="-"; echo "warning: no signing certificate found; using ad-hoc signing (permissions reset on every build)"; }
OPTS=(--force "${KEYCHAIN_OPTS[@]}" --sign "$IDENTITY" --timestamp=none)
[[ "$IDENTITY" == Developer\ ID* ]] && OPTS=(--force --sign "$IDENTITY" --timestamp --options runtime)
for f in "$APP"/Contents/Resources/llama/*; do codesign "${OPTS[@]}" "$f"; done
codesign "${OPTS[@]}" --identifier app.dictator.Dictator "$APP"
codesign --verify --deep --strict "$APP"

mkdir -p ~/Applications
rm -rf ~/Applications/Dictator.app
cp -R "$APP" ~/Applications/Dictator.app
echo "Built $APP ($(du -sh "$APP" | cut -f1)) and installed ~/Applications/Dictator.app"
