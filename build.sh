#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

# ── Load .env if it exists (all secrets/config live there, not in this script) ──
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi

# ── Config (defaults — overridden by .env) ────────────────────────────────────
# Bump these per release in .env. VERSION is semver (user-facing); BUILD is the
# integer CFBundleVersion.
VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-1}"

# APP_NAME is the executable/module name (Contents/MacOS/, CFBundleExecutable, pkill -x);
# DISPLAY_NAME is what the user sees (bundle name, dmg, volname).
APP_NAME="HarnessUsage"
DISPLAY_NAME="Harness Usage"
BUNDLE_ID="com.mikeben.harness-widget"
OUT="build/${DISPLAY_NAME}.app"
DMG="build/${DISPLAY_NAME}-${VERSION}.dmg"

# Signing + notarization. Defaults are mock — .env replaces them with real values.
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application: MOCK (MOCKTEAMID)}"
NOTARY_PROFILE="${NOTARY_PROFILE:-harness-usage-notary}"

# ── Format + lint ─────────────────────────────────────────────────────────────
echo "==> format + lint"
swift format format -i --recursive Sources Tests
swift format lint --strict --recursive Sources Tests

# ── Tests ─────────────────────────────────────────────────────────────────────
# Debug, single-arch, before the release build: `swift test` accepts neither the dual
# `--arch arm64 --arch x86_64` pair nor `-c release` cleanly with @testable imports.
#
# SKIP_TESTS=1 is the escape hatch for a machine with only the Command Line Tools installed.
# The suite is swift-testing, and CLT ships an incomplete copy of it — `Testing.framework` is
# there but `_Testing_Foundation` is not — so `swift test` cannot run at all without Xcode.
# It is deliberately loud, and deliberately not the default: a release built this way has had
# nothing but the compiler and the linter look at it.
if [[ "${SKIP_TESTS:-0}" == "1" ]]; then
  echo "==> test SKIPPED (SKIP_TESTS=1) — nothing has verified this build's behaviour"
else
  echo "==> test"
  swift test
fi

# ── Build ─────────────────────────────────────────────────────────────────────
# NATIVE_ONLY=1 is the second Command-Line-Tools escape hatch. The dual-arch build is driven by
# xcbuild, which only Xcode ships, so on a CLT-only machine the universal build cannot run at all.
# A native build installs and runs perfectly well on THIS Mac; it simply is not the artifact to
# hand to anyone else, which is why it is opt-in and says so.
if [[ "${NATIVE_ONLY:-0}" == "1" ]]; then
  echo "==> native-arch release build ($(uname -m), ${VERSION}) — not distributable to other Macs"
  swift build -c release
  BIN=".build/release/${APP_NAME}"
else
  echo "==> universal release build (${VERSION})"
  swift build -c release --arch arm64 --arch x86_64
  BIN=".build/apple/Products/Release/${APP_NAME}"
fi

echo "==> verify slices"
lipo -info "$BIN"   # universal expects: x86_64 arm64

# ── Assemble .app bundle ─────────────────────────────────────────────────────
echo "==> assemble ${OUT}"
rm -rf "$OUT"
mkdir -p "${OUT}/Contents/MacOS" "${OUT}/Contents/Resources"

cp "$BIN" "${OUT}/Contents/MacOS/${APP_NAME}"

cat > "${OUT}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleDisplayName</key><string>${DISPLAY_NAME}</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>${APP_NAME}</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST

# ── App icon ──────────────────────────────────────────────────────────────────
echo "==> app icon"
ICON_LIGHT="Resources/icon-light.png"
ICON_DARK="Resources/icon-dark.png"
if [[ -f "$ICON_LIGHT" ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for sz in 16 32 128 256 512; do
    sips -z "$sz" "$sz" "$ICON_LIGHT" --out "${ICONSET}/icon_${sz}x${sz}.png" >/dev/null
    sips -z "$((sz * 2))" "$((sz * 2))" "$ICON_LIGHT" --out "${ICONSET}/icon_${sz}x${sz}@2x.png" >/dev/null
  done
  if [[ -f "$ICON_DARK" ]]; then
    for sz in 16 32 128 256 512; do
      sips -z "$sz" "$sz" "$ICON_DARK" --out "${ICONSET}/icon_${sz}x${sz}-dark.png" >/dev/null
      sips -z "$((sz * 2))" "$((sz * 2))" "$ICON_DARK" --out "${ICONSET}/icon_${sz}x${sz}-dark@2x.png" >/dev/null
    done
  fi
  iconutil -c icns "$ICONSET" -o "${OUT}/Contents/Resources/AppIcon.icns"
  rm -rf "$ICONSET"
fi

# ── Bundle mock data (for --mock mode in release builds) ──────────────────────
echo "==> bundle mock data"
cp -R MockData "${OUT}/Contents/Resources/MockData"

# ── Code signing ──────────────────────────────────────────────────────────────
echo "==> codesign"
# Two questions, not one. Does the identity exist in the keychain, and is it the KIND that ships?
# `find-identity` prints the certificate's full common name, so a Development or Apple Distribution
# certificate is distinguishable from a Developer ID Application one — and only the last of those
# produces a bundle another Mac will run. Signing with the wrong kind used to succeed silently and
# carry the "won't pass Gatekeeper" warning only on the ad-hoc path.
IDENTITY_LINE="$(security find-identity -p codesigning -v 2>/dev/null | grep -F "$SIGN_IDENTITY" | head -1 || true)"
DISTRIBUTABLE=0
case "$IDENTITY_LINE" in
  *"Developer ID Application"*) DISTRIBUTABLE=1 ;;
esac

if [[ -n "$IDENTITY_LINE" ]]; then
  echo "    signing with: $SIGN_IDENTITY"
  if [[ "$DISTRIBUTABLE" -eq 0 ]]; then
    echo "    WARNING: '$SIGN_IDENTITY' is not a Developer ID Application certificate"
    echo "    (the app runs locally but won't pass Gatekeeper on other Macs)"
  fi
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "${OUT}/Contents/MacOS/${APP_NAME}"
  codesign --force --options runtime --sign "$SIGN_IDENTITY" "$OUT"
else
  echo "    WARNING: '$SIGN_IDENTITY' not found — falling back to ad-hoc sign"
  echo "    (the app runs locally but won't pass Gatekeeper on other Macs)"
  codesign --force --options runtime --sign - "${OUT}/Contents/MacOS/${APP_NAME}"
  codesign --force --options runtime --sign - "$OUT"
fi

# ── Notarization ──────────────────────────────────────────────────────────────
# Skipped without a Developer ID Application signature, and skipped if the notarytool keychain profile
# doesn't exist (dev machines without stored credentials). The app still works — it's just not notarized.
echo "==> notarize"
if [[ "$DISTRIBUTABLE" -eq 0 ]]; then
  echo "    skipped: nothing here carries a Developer ID Application signature"
  echo "    (notarytool rejects an ad-hoc or Development-signed bundle, and this script runs under"
  echo "     'set -e' — so submitting one would abort the build before the DMG is written)"
elif xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
  echo "    submitting to Apple for notarization…"
  xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$OUT"
  echo "    notarized + stapled"
else
  echo "    WARNING: notarytool profile '$NOTARY_PROFILE' not found — skipping notarization"
  echo "    (set up with: xcrun notarytool store-credentials '$NOTARY_PROFILE' --apple-id YOU --team-id TEAMID)"
fi

# ── .dmg ──────────────────────────────────────────────────────────────────────
echo "==> create .dmg"
rm -f "$DMG"
# Create a temporary DMG, copy the app, then convert to compressed read-only.
TMP_DMG="build/${APP_NAME}-tmp.dmg"
STAGING="build/${APP_NAME}-dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$OUT" "$STAGING/"
# A symlink to /Applications for drag-to-install
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$STAGING" -fs HFS+ "$TMP_DMG" >/dev/null
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP_DMG"
rm -rf "$STAGING"

# Sign the DMG too (if we have the identity)
if [[ -n "$IDENTITY_LINE" ]]; then
  codesign --sign "$SIGN_IDENTITY" "$DMG"
fi

echo "==> done:"
echo "    .app: $OUT"
echo "    .dmg: $DMG"
echo "    version: $VERSION (build $BUILD)"
