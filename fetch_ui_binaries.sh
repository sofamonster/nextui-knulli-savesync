#!/bin/sh
# ==============================================================================
# Download NextUI / MinUI Binaries & Static Rsync/SSH/SSHPass for TrimUI Brick
# ==============================================================================
# Fetches the latest arm64 (aarch64) binaries for:
#   - rsync           (static aarch64 binary for TrimUI Brick Linux)
#   - sshpass         (arm64 binary for automatic SSH password login)
#   - dropbearmulti   (static aarch64 SSH client `dbclient` + keygen `dropbearkey`)
#   - minui-list      (interactive scrollable menu UI)
#   - minui-keyboard  (on-screen keyboard for entering IP, Username, Password)
#   - minui-presenter (on-screen status messages and notifications)
# and places them into Tools/tg5040/SaveSync.pak/bin/
# ==============================================================================

set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/Tools/tg5040/SaveSync.pak/bin"
mkdir -p "$BIN_DIR"

echo "1. Fetching static aarch64 rsync binary..."
if curl -fsSL -L "https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/aarch64/rsync" -o "$BIN_DIR/rsync" 2>/dev/null; then
    chmod +x "$BIN_DIR/rsync"
    echo "  -> Installed $BIN_DIR/rsync"
else
    echo "  [WARN] Could not download static rsync automatically."
fi

echo "2. Fetching static aarch64 dropbearmulti (dbclient & dropbearkey)..."
if curl -fsSL -L "https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/aarch64/dropbearmulti" -o "$BIN_DIR/dropbearmulti" 2>/dev/null; then
    chmod +x "$BIN_DIR/dropbearmulti"
    echo "  -> Installed $BIN_DIR/dropbearmulti"
else
    echo "  [WARN] Could not download static dropbearmulti automatically."
fi

echo "3. Fetching arm64 sshpass binary..."
TMP_DEB="$(mktemp -d /tmp/sshpass_deb.XXXXXX)"
if curl -fsSL -L "http://ftp.debian.org/debian/pool/main/s/sshpass/sshpass_1.09-1_arm64.deb" -o "$TMP_DEB/sshpass.deb" 2>/dev/null; then
    (
        cd "$TMP_DEB"
        ar x sshpass.deb
        tar -xf data.tar.*
        cp usr/bin/sshpass "$BIN_DIR/sshpass"
        chmod +x "$BIN_DIR/sshpass"
    )
    echo "  -> Installed $BIN_DIR/sshpass"
else
    echo "  [WARN] Could not download arm64 sshpass automatically."
fi
rm -rf "$TMP_DEB"

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
