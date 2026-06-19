#!/usr/bin/env bash
# Build the Flutter web dashboard and stage it for Yocto/BitBake.
#
# Run this before bitbaking:
#   ./scripts/build-frontend.sh
#
# Flutter SDK is downloaded automatically into .flutter/ on first run.
#
# Outputs:
#   yocto/layers/meta-custom/recipes-dashboard/m33-dashboard/files/frontend-web.tar.gz
#   yocto/layers/meta-custom/recipes-dashboard/m33-dashboard/files/rpmsg-ws-server.py
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FRONTEND_DIR="$REPO_ROOT/frontend"
RECIPE_FILES="$REPO_ROOT/yocto/layers/meta-custom/recipes-dashboard/m33-dashboard/files"
FLUTTER_DIR="$REPO_ROOT/.flutter"
FLUTTER_BIN="$FLUTTER_DIR/bin/flutter"

# ── Flutter SDK bootstrap ─────────────────────────────────────────────────────

FLUTTER_VERSION="3.32.2"
FLUTTER_ARCHIVE="flutter_linux_${FLUTTER_VERSION}-stable.tar.xz"
FLUTTER_URL="https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/${FLUTTER_ARCHIVE}"

if [ ! -x "$FLUTTER_BIN" ]; then
    echo "==> Flutter SDK not found — downloading ${FLUTTER_VERSION}..."
    TMPFILE="$(mktemp --suffix=.tar.xz)"
    trap 'rm -f "$TMPFILE"' EXIT
    curl -fL --progress-bar -o "$TMPFILE" "$FLUTTER_URL"
    echo "==> Extracting to $FLUTTER_DIR ..."
    mkdir -p "$REPO_ROOT"
    tar xf "$TMPFILE" -C "$REPO_ROOT"
    # The archive extracts to a directory called 'flutter'
    mv "$REPO_ROOT/flutter" "$FLUTTER_DIR"
    echo "==> Flutter SDK ready."
fi

export PATH="$FLUTTER_DIR/bin:$PATH"

# Silence the first-run analytics prompt
flutter config --no-analytics 2>/dev/null || true

# ── Build ─────────────────────────────────────────────────────────────────────

echo "==> Building Flutter web frontend (${FLUTTER_VERSION})..."
cd "$FRONTEND_DIR"
flutter pub get
flutter build web --release

# ── Stage for Yocto ──────────────────────────────────────────────────────────

echo "==> Packaging for Yocto..."
mkdir -p "$RECIPE_FILES"

tar czf "$RECIPE_FILES/frontend-web.tar.gz" -C "$FRONTEND_DIR/build" web/
cp "$REPO_ROOT/scripts/rpmsg-ws-server.py" "$RECIPE_FILES/rpmsg-ws-server.py"
cp "$REPO_ROOT/scripts/motor_control.py"   "$RECIPE_FILES/motor_control.py"
cp "$REPO_ROOT/scripts/m33ctl.py"          "$RECIPE_FILES/m33ctl.py"

echo "==> Done."
echo "    $RECIPE_FILES/frontend-web.tar.gz"
echo "    $RECIPE_FILES/rpmsg-ws-server.py"
echo "    $RECIPE_FILES/motor_control.py"
echo "    $RECIPE_FILES/m33ctl.py"
echo ""
echo "Now run:  cd yocto && bitbake stm32mp257f-custom-image"
