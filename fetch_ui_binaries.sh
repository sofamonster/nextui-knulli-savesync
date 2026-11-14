#!/bin/sh
# ==============================================================================
# Download NextUI / MinUI UI Helper Binaries for TrimUI Brick (tg5040)
# ==============================================================================
# Fetches the latest official arm64 binaries for:
#   - minui-list      (interactive scrollable menu UI)
#   - minui-keyboard  (on-screen keyboard for entering IP, Username, Password)
#   - minui-presenter (on-screen status messages and notifications)
# and places them into Tools/tg5040/SaveSync.pak/bin/
# ==============================================================================

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/Tools/tg5040/SaveSync.pak/bin"
mkdir -p "$BIN_DIR"

download_ui_tool() {
    _repo="$1"
    _bin_name="$2"
    _target="$BIN_DIR/$_bin_name"

    echo "Fetching $_bin_name for tg5040 (NextUI) from $_repo..."
    if curl -fsSL -L "https://github.com/${_repo}/releases/latest/download/${_bin_name}-tg5040-nextui" -o "$_target" 2>/dev/null || \
       curl -fsSL -L "https://github.com/${_repo}/releases/latest/download/${_bin_name}-tg5040" -o "$_target" 2>/dev/null; then
        chmod +x "$_target"
        echo "  -> Installed $_target"
    else
        echo "  [WARN] Could not download $_bin_name automatically. Check network or https://github.com/${_repo}/releases"
    fi
}

download_ui_tool "josegonzalez/minui-list" "minui-list"
download_ui_tool "josegonzalez/minui-keyboard" "minui-keyboard"
download_ui_tool "josegonzalez/minui-presenter" "minui-presenter"

echo "Done! Binaries are ready in: $BIN_DIR"
