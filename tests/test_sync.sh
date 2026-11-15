#!/bin/sh
# ==============================================================================
# Automated Test Suite for SaveSync (NextUI <-> Knulli) + On-Device UI
# ==============================================================================
# Simulates:
#   1. Interactive UI menu (`minui-list`) and On-Screen Keyboard (`minui-keyboard`)
#      for editing RG28XX IP/Host, SSH Username, and SSH Password in config.cfg
#   2. Local NextUI SD Card (/Saves, /Roms, /Backups)
#   3. Remote Knulli RG28XX (/userdata/saves) via mock ssh & rsync wrapper
#   4. Folder & extension mapping (.gba.sav <-> .srm, .smc.sav <-> .srm)
#   5. Per-game filename overrides (game_overrides.cfg)
#   6. Save state exclusion (.state, .state.auto, .st0, .png)
#   7. Bidirectional newest-wins conflict resolution
#   8. Rolling 3-run compressed backup rotation (local + remote)
#   9. Native tar-over-SSH fallback when rsync binary is missing on TrimUI
# ==============================================================================

set -eu

PROJECT_ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
PAK_SRC="$PROJECT_ROOT/Tools/tg5040/SaveSync.pak"
TEST_SANDBOX="$(mktemp -d /tmp/savesync_test.XXXXXX)"

cleanup() {
    rm -rf "$TEST_SANDBOX"
}
trap cleanup EXIT INT TERM

echo "=== Setting up SaveSync test sandbox in $TEST_SANDBOX ==="

SDCARD_MOCK="$TEST_SANDBOX/sdcard"
REMOTE_MOCK="$TEST_SANDBOX/knulli_remote/userdata/saves"
MOCK_BIN="$TEST_SANDBOX/mock_bin"

mkdir -p "$SDCARD_MOCK/Tools/tg5040"
cp -r "$PAK_SRC" "$SDCARD_MOCK/Tools/tg5040/SaveSync.pak"
TEST_PAK="$SDCARD_MOCK/Tools/tg5040/SaveSync.pak"
rm -f "$TEST_PAK/bin"/*

mkdir -p "$SDCARD_MOCK/Saves/GBA" \
         "$SDCARD_MOCK/Saves/SFC" \
         "$SDCARD_MOCK/Roms/Super Nintendo (SFC)" \
         "$REMOTE_MOCK/gba" \
         "$REMOTE_MOCK/snes" \
         "$MOCK_BIN"

# --- Test 0: Mock minui-list and minui-keyboard to test the On-Device UI ---
UI_STEP_FILE="$TEST_SANDBOX/ui_step.txt"
echo "0" > "$UI_STEP_FILE"

cat <<EOF > "$MOCK_BIN/minui-list"
#!/bin/sh
write_loc=""
while [ "\$#" -gt 0 ]; do
    if [ "\$1" = "--write-location" ]; then
        write_loc="\$2"
        shift 2
        continue
    fi
    shift
done

step="\$(cat "$UI_STEP_FILE")"
next_step=\$((step + 1))
echo "\$next_step" > "$UI_STEP_FILE"

case "\$step" in
    0) echo "RG28XX IP / Host: KNULLI.local" > "\$write_loc"; exit 0 ;;
    1) echo "SSH Username: root" > "\$write_loc"; exit 0 ;;
    2) echo "SSH Password: ********" > "\$write_loc"; exit 0 ;;
    3) echo "Exit" > "\$write_loc"; exit 0 ;;
esac
exit 2
EOF
chmod +x "$MOCK_BIN/minui-list"

cat <<EOF > "$MOCK_BIN/minui-keyboard"
#!/bin/sh
title=""
write_loc=""
while [ "\$#" -gt 0 ]; do
    case "\$1" in
        --title) title="\$2"; shift 2 ;;
        --write-location) write_loc="\$2"; shift 2 ;;
        *) shift ;;
    esac
done

case "\$title" in
    *"IP or Hostname"*) echo "192.168.1.88" > "\$write_loc" ;;
    *"Username"*)       echo "knulliuser" > "\$write_loc" ;;
    *"Password"*)       echo "secretpass123" > "\$write_loc" ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/minui-keyboard"

# Stub curl/wget in test sandbox so ensure_binaries doesn't try network calls
cat <<EOF > "$MOCK_BIN/curl"
#!/bin/sh
exit 1
EOF
chmod +x "$MOCK_BIN/curl"
cp "$MOCK_BIN/curl" "$MOCK_BIN/wget"

echo "=== Testing Interactive On-Device UI (IP, Username, Password Entry) ==="
PATH="$MOCK_BIN:$PATH" SDCARD_PATH="$SDCARD_MOCK" "$TEST_PAK/launch.sh" --menu

grep -q '^SSH_HOST="192.168.1.88"$' "$TEST_PAK/config.cfg" && echo "[PASS] UI updated SSH_HOST to 192.168.1.88"
grep -q '^SSH_USER="knulliuser"$' "$TEST_PAK/config.cfg" && echo "[PASS] UI updated SSH_USER to knulliuser"
grep -q '^SSH_PASSWORD="secretpass123"$' "$TEST_PAK/config.cfg" && echo "[PASS] UI updated SSH_PASSWORD to secretpass123"

sed -i 's/^SSH_HOST=.*/SSH_HOST="KNULLI.local"/' "$TEST_PAK/config.cfg"
sed -i 's/^SSH_USER=.*/SSH_USER="root"/' "$TEST_PAK/config.cfg"

# Create mock ssh that also executes remote commands locally (replacing /userdata/saves with $REMOTE_MOCK)
cat <<EOF > "$MOCK_BIN/ssh"
#!/bin/sh
for last_arg in "\$@"; do :; done
case "\$last_arg" in
    "echo ok"|"true")
        echo "ok"
        exit 0
        ;;
    "echo SAVESYNC_OK")
        echo "SAVESYNC_OK"
        exit 0
        ;;
    *)
        rewritten_cmd="\$(echo "\$last_arg" | sed "s|/userdata/saves|$REMOTE_MOCK|g")"
        eval "\$rewritten_cmd"
        exit \$?
        ;;
esac
EOF
chmod +x "$MOCK_BIN/ssh"

REAL_RSYNC="$(command -v rsync)"
cat <<EOF > "$MOCK_BIN/rsync"
#!/bin/sh
args=""
skip_next=0
for arg in "\$@"; do
    if [ "\$skip_next" -eq 1 ]; then
        skip_next=0
        continue
    fi
    if [ "\$arg" = "-e" ]; then
        skip_next=1
        continue
    fi
    rewritten="\$(echo "\$arg" | sed "s|root@KNULLI.local:/userdata/saves|$REMOTE_MOCK|g")"
    args="\$args \"\$rewritten\""
done
eval "$REAL_RSYNC \$args"
EOF
chmod +x "$MOCK_BIN/rsync"

mkdir -p "$TEST_PAK/.ssh"
touch "$TEST_PAK/.ssh/id_save_sync" "$TEST_PAK/.ssh/id_save_sync.pub"
chmod 600 "$TEST_PAK/.ssh/id_save_sync"

cat <<EOF >> "$TEST_PAK/game_overrides.cfg"
GBA | gba | Pokemon - Emerald Version (USA).gba.sav | Pokemon Emerald (U).srm
EOF

# --- Populate Test Data ---
echo "metroid_save_v1" > "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.gba.sav"
touch -d "2026-11-14 10:00:00" "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.gba.sav"

touch "$SDCARD_MOCK/Roms/Super Nintendo (SFC)/Super Mario World.smc"
echo "smw_knulli_save_v1" > "$REMOTE_MOCK/snes/Super Mario World.srm"
touch -d "2026-11-14 11:00:00" "$REMOTE_MOCK/snes/Super Mario World.srm"

echo "zelda_old_local" > "$SDCARD_MOCK/Saves/GBA/Zelda Minish Cap.gba.sav"
touch -d "2026-11-14 09:00:00" "$SDCARD_MOCK/Saves/GBA/Zelda Minish Cap.gba.sav"
echo "zelda_newer_remote" > "$REMOTE_MOCK/gba/Zelda Minish Cap.srm"
touch -d "2026-11-14 12:00:00" "$REMOTE_MOCK/gba/Zelda Minish Cap.srm"

echo "emerald_newer_local" > "$SDCARD_MOCK/Saves/GBA/Pokemon - Emerald Version (USA).gba.sav"
touch -d "2026-11-14 14:00:00" "$SDCARD_MOCK/Saves/GBA/Pokemon - Emerald Version (USA).gba.sav"
echo "emerald_old_remote" > "$REMOTE_MOCK/gba/Pokemon Emerald (U).srm"
touch -d "2026-11-14 08:00:00" "$REMOTE_MOCK/gba/Pokemon Emerald (U).srm"

echo "state_data" > "$REMOTE_MOCK/gba/Metroid Fusion.state"
echo "state_auto" > "$REMOTE_MOCK/gba/Metroid Fusion.state.auto"
echo "screenshot" > "$REMOTE_MOCK/gba/Metroid Fusion.png"
echo "local_state" > "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.st0"

echo "=== Running SaveSync (Run #1 - with rsync) ==="
PATH="$MOCK_BIN:$PATH" SDCARD_PATH="$SDCARD_MOCK" "$TEST_PAK/launch.sh" --sync

assert_file_content() {
    _file="$1"
    _expected="$2"
    if [ ! -f "$_file" ]; then
        echo "[FAIL] Expected file does not exist: $_file"
        exit 1
    fi
    _actual="$(cat "$_file")"
    if [ "$_actual" != "$_expected" ]; then
        echo "[FAIL] Content mismatch in $_file: expected '$_expected', got '$_actual'"
        exit 1
    fi
    echo "[PASS] Verified $_file == '$_expected'"
}

assert_file_missing() {
    _file="$1"
    if [ -e "$_file" ]; then
        echo "[FAIL] Excluded file should NOT exist: $_file"
        exit 1
    fi
    echo "[PASS] Verified excluded file is absent: $(basename "$_file")"
}

assert_file_content "$REMOTE_MOCK/gba/Metroid Fusion.srm" "metroid_save_v1"
assert_file_content "$SDCARD_MOCK/Saves/SFC/Super Mario World.smc.sav" "smw_knulli_save_v1"
assert_file_content "$SDCARD_MOCK/Saves/GBA/Zelda Minish Cap.gba.sav" "zelda_newer_remote"
assert_file_content "$REMOTE_MOCK/gba/Pokemon Emerald (U).srm" "emerald_newer_local"

assert_file_missing "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.state"
assert_file_missing "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.state.auto"
assert_file_missing "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.png"
assert_file_missing "$REMOTE_MOCK/gba/Metroid Fusion.st0"

# --- Test Fallback When rsync Binary is Missing ---
echo "=== Testing Native Tar-over-SSH Fallback (when rsync binary is missing) ==="
rm -f "$MOCK_BIN/rsync"
# Create a restricted bin directory without rsync
NO_RSYNC_BIN="$TEST_SANDBOX/no_rsync_bin"
mkdir -p "$NO_RSYNC_BIN"
for tool in sh basename dirname cat cp rm mkdir mktemp date stat cmp grep sed awk tr head ls find tar gzip tee chmod sync sleep touch wc; do
    if command -v "$tool" >/dev/null 2>&1; then
        ln -sf "$(command -v "$tool")" "$NO_RSYNC_BIN/$tool"
    fi
done
ln -sf "$MOCK_BIN/ssh" "$NO_RSYNC_BIN/ssh"
ln -sf "$MOCK_BIN/curl" "$NO_RSYNC_BIN/curl"
ln -sf "$MOCK_BIN/wget" "$NO_RSYNC_BIN/wget"

# Update launch.sh PATH inside test pak so it doesn't find host /usr/bin/rsync
sed -i "s|export PATH=.*|export PATH=\"\$PAK_DIR/bin:$NO_RSYNC_BIN\"|" "$TEST_PAK/launch.sh"

echo "castlevania_local_v1" > "$SDCARD_MOCK/Saves/GBA/Castlevania Aria.gba.sav"
touch -d "2026-11-14 15:00:00" "$SDCARD_MOCK/Saves/GBA/Castlevania Aria.gba.sav"
echo "ff6_remote_v1" > "$REMOTE_MOCK/snes/Final Fantasy III.srm"
touch -d "2026-11-14 15:30:00" "$REMOTE_MOCK/snes/Final Fantasy III.srm"

PATH="$NO_RSYNC_BIN" SDCARD_PATH="$SDCARD_MOCK" "$TEST_PAK/launch.sh" --sync

assert_file_content "$REMOTE_MOCK/gba/Castlevania Aria.srm" "castlevania_local_v1"
assert_file_content "$SDCARD_MOCK/Saves/SFC/Final Fantasy III.sfc.sav" "ff6_remote_v1"

echo "=== Testing Rolling 3-Run Backup Rotation ==="
for i in 3 4; do
    sleep 1
    PATH="$NO_RSYNC_BIN" SDCARD_PATH="$SDCARD_MOCK" "$TEST_PAK/launch.sh" --sync >/dev/null
done

LOCAL_BACKUP_COUNT="$(ls -1 "$SDCARD_MOCK/Backups/SaveSync/local_"*.tar.gz 2>/dev/null | wc -l)"
REMOTE_BACKUP_COUNT="$(ls -1 "$SDCARD_MOCK/Backups/SaveSync/remote_"*.tar.gz 2>/dev/null | wc -l)"

if [ "$LOCAL_BACKUP_COUNT" -ne 3 ] || [ "$REMOTE_BACKUP_COUNT" -ne 3 ]; then
    echo "[FAIL] Expected exactly 3 local and 3 remote backups, got local=$LOCAL_BACKUP_COUNT remote=$REMOTE_BACKUP_COUNT"
    exit 1
fi
echo "[PASS] Verified rolling backup rotation keeps exactly 3 local and 3 remote .tar.gz archives!"

echo "=== Testing Restore from Backup (Overwriting Both Devices to Older State) ==="
# Pick the oldest of the 3 rolling backups (taken before Castlevania/FF3 were modified further)
OLDEST_TS="$(ls -1 "$SDCARD_MOCK/Backups/SaveSync/local_"*.tar.gz | head -n 1 | sed 's/.*local_//; s/\.tar\.gz//')"
echo "Selected backup timestamp to restore: $OLDEST_TS"

# Corrupt/modify current saves on both devices AND add a post-backup save file
echo "corrupted_metroid_save" > "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.gba.sav"
echo "corrupted_metroid_remote" > "$REMOTE_MOCK/gba/Metroid Fusion.srm"
echo "post_backup_new_game" > "$SDCARD_MOCK/Saves/GBA/NewPostBackupGame.gba.sav"
echo "post_backup_new_remote" > "$REMOTE_MOCK/gba/NewPostBackupGame.srm"

# Restore the backup across both devices
PATH="$NO_RSYNC_BIN" SDCARD_PATH="$SDCARD_MOCK" "$TEST_PAK/launch.sh" --restore "$OLDEST_TS" --restore-mode both

# Verify both devices were rolled back to the backup state and post-backup saves were cleaned
assert_file_content "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.gba.sav" "metroid_save_v1"
assert_file_content "$REMOTE_MOCK/gba/Metroid Fusion.srm" "metroid_save_v1"
assert_file_missing "$SDCARD_MOCK/Saves/GBA/NewPostBackupGame.gba.sav"
assert_file_missing "$REMOTE_MOCK/gba/NewPostBackupGame.srm"
# Verify save states on both devices were NOT deleted during restore
assert_file_content "$SDCARD_MOCK/Saves/GBA/Metroid Fusion.st0" "local_state"
assert_file_content "$REMOTE_MOCK/gba/Metroid Fusion.state" "state_data"

echo "=== ALL SAVESYNC TESTS PASSED SUCCESSFULLY ==="
