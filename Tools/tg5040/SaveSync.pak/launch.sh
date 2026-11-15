#!/bin/sh
# ==============================================================================
# SaveSync - Bidirectional In-Game Save Synchronizer + On-Device UI
# Target: TrimUI Brick (NextUI / tg5040) <-> Anbernic RG28XX (Knulli)
# ==============================================================================

set -u

PAK_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PATH="$PAK_DIR/bin:$PATH:/usr/TrimUI/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# --- Default Environment Fallbacks ---
SDCARD_PATH="${SDCARD_PATH:-/mnt/SDCARD}"
PLATFORM="${PLATFORM:-tg5040}"

CONFIG_FILE="${CONFIG_FILE:-$PAK_DIR/config.cfg}"
MAPPINGS_FILE="${MAPPINGS_FILE:-$PAK_DIR/mappings.cfg}"
OVERRIDES_FILE="${OVERRIDES_FILE:-$PAK_DIR/game_overrides.cfg}"
LOG_FILE="${LOG_FILE:-$PAK_DIR/savesync.log}"

# --- Load Configuration ---
load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "[ERROR] Missing configuration file: $CONFIG_FILE" >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    . "$CONFIG_FILE"

    SSH_HOST="${SSH_HOST:-KNULLI.local}"
    SSH_PORT="${SSH_PORT:-22}"
    SSH_USER="${SSH_USER:-root}"
    SSH_PASSWORD="${SSH_PASSWORD:-linux}"
    SSH_KEY_PATH="${SSH_KEY_PATH:-$PAK_DIR/.ssh/id_save_sync}"
    SSH_TIMEOUT="${SSH_TIMEOUT:-8}"

    LOCAL_SAVES_ROOT="${LOCAL_SAVES_ROOT:-$SDCARD_PATH/Saves}"
    REMOTE_SAVES_ROOT="${REMOTE_SAVES_ROOT:-/userdata/saves}"
    BACKUP_DIR="${BACKUP_DIR:-$SDCARD_PATH/Backups/SaveSync}"
    BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-3}"
    BACKUP_REMOTE="${BACKUP_REMOTE:-true}"
    ALLOWED_SAVE_EXTS="${ALLOWED_SAVE_EXTS:-sav srm rtc eep fla sra mcr mcd dsv ngf flash}"
}

load_config

# Update a key="value" entry inside config.cfg safely
save_config_value() {
    _key="$1"
    _val="$2"
    _escaped="$(printf '%s' "$_val" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    _tmp_cfg="${CONFIG_FILE}.tmp"

    if grep -q "^${_key}=" "$CONFIG_FILE" 2>/dev/null; then
        awk -v k="$_key" -v v="$_escaped" '
            index($0, k "=") == 1 { print k "=\"" v "\""; next }
            { print }
        ' "$CONFIG_FILE" > "$_tmp_cfg" && mv "$_tmp_cfg" "$CONFIG_FILE"
    else
        printf '\n%s="%s"\n' "$_key" "$_escaped" >> "$CONFIG_FILE"
    fi
    sync
}

# Optional CLI flags for automated testing (--sync, --menu, --setup-auth, --restore <ts>, --restore-mode <mode>)
CLI_MODE="menu"
RESTORE_TS=""
RESTORE_MODE="both"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --sync)
            CLI_MODE="sync"
            shift
            ;;
        --menu|--ui)
            CLI_MODE="menu"
            shift
            ;;
        --setup-auth)
            CLI_MODE="setup-auth"
            shift
            ;;
        --restore)
            CLI_MODE="restore"
            RESTORE_TS="${2:-latest}"
            shift 2 2>/dev/null || shift
            ;;
        --restore-mode)
            RESTORE_MODE="${2:-both}"
            shift 2 2>/dev/null || shift
            ;;
        *)
            shift
            ;;
    esac
done

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

log() {
    _ts="$(date '+%H:%M:%S')"
    echo "[$_ts] $*" | tee -a "$LOG_FILE"
}

# --- NextUI / MinUI UI Binary Resolver ---
find_ui_binary() {
    _base="$1"
    for _cand in \
        "$PAK_DIR/bin/${_base}-${PLATFORM}-nextui" \
        "$PAK_DIR/bin/${_base}-${PLATFORM}" \
        "$PAK_DIR/bin/${_base}" \
        "${_base}-${PLATFORM}-nextui" \
        "${_base}-${PLATFORM}" \
        "${_base}"; do
        if command -v "$_cand" >/dev/null 2>&1; then
            command -v "$_cand"
            return 0
        fi
    done
    return 1
}

PRESENTER_BIN="$(find_ui_binary minui-presenter || true)"
LIST_BIN="$(find_ui_binary minui-list || true)"
KEYBOARD_BIN="$(find_ui_binary minui-keyboard || true)"

# Ensure permissions and artwork previews
ensure_binaries() {
    if [ -f "$PAK_DIR/icon.png" ]; then
        _tools_parent="$(dirname "$PAK_DIR")"
        for _art_dir in "$_tools_parent/.media" "$_tools_parent/.res"; do
            mkdir -p "$_art_dir" 2>/dev/null || true
            [ -f "$_art_dir/SaveSync.png" ] || cp "$PAK_DIR/icon.png" "$_art_dir/SaveSync.png" 2>/dev/null || true
            [ -f "$_art_dir/SaveSync.pak.png" ] || cp "$PAK_DIR/icon.png" "$_art_dir/SaveSync.pak.png" 2>/dev/null || true
        done
    fi

    mkdir -p "$PAK_DIR/bin"
    chmod +x "$PAK_DIR/bin"/* 2>/dev/null || true

    PRESENTER_BIN="$(find_ui_binary minui-presenter || true)"
    LIST_BIN="$(find_ui_binary minui-list || true)"
    KEYBOARD_BIN="$(find_ui_binary minui-keyboard || true)"
}

# --- On-Screen Display Helper ---
show_ui_message() {
    _msg="$1"
    _timeout="${2:-0}" # 0 = stay on screen in background, >0 = wait N seconds
    log "UI: $_msg"

    if [ -n "$PRESENTER_BIN" ]; then
        killall "$(basename "$PRESENTER_BIN")" >/dev/null 2>&1 || true
        if [ "$_timeout" -gt 0 ] 2>/dev/null; then
            "$PRESENTER_BIN" --message "$_msg" --font-size-default 22 --timeout "$_timeout" >/dev/null 2>&1 || true
        else
            "$PRESENTER_BIN" --message "$_msg" --font-size-default 22 --timeout -1 >/dev/null 2>&1 &
        fi
    elif command -v show.elf >/dev/null 2>&1; then
        killall show.elf >/dev/null 2>&1 || true
        if [ "$_timeout" -gt 0 ] 2>/dev/null; then
            show.elf "$_msg" "$_timeout" >/dev/null 2>&1 || true
        else
            show.elf "$_msg" >/dev/null 2>&1 &
        fi
    fi
}

dismiss_ui_message() {
    if [ -n "$PRESENTER_BIN" ]; then
        killall "$(basename "$PRESENTER_BIN")" >/dev/null 2>&1 || true
    fi
    if command -v show.elf >/dev/null 2>&1; then
        killall show.elf >/dev/null 2>&1 || true
    fi
}

cleanup_ui() {
    dismiss_ui_message
    if [ -n "${STAGE_DIR:-}" ] && [ -d "${STAGE_DIR:-}" ]; then
        rm -rf "$STAGE_DIR"
    fi
}
trap cleanup_ui EXIT INT TERM

# --- Interactive On-Screen Keyboard & Menu UI ---
prompt_keyboard() {
    _title="$1"
    _init_val="$2"
    _out_file="$(mktemp "${TMPDIR:-/tmp}/savesync_kb.XXXXXX")"

    dismiss_ui_message
    if [ -n "$KEYBOARD_BIN" ]; then
        if "$KEYBOARD_BIN" --title "$_title" --initial-value "$_init_val" --write-location "$_out_file" --disable-auto-sleep >/dev/null 2>&1; then
            _res="$(cat "$_out_file" 2>/dev/null | tr -d '\r\n')"
            rm -f "$_out_file"
            printf '%s' "$_res"
            return 0
        fi
        rm -f "$_out_file"
        return 1
    elif [ -t 0 ]; then
        printf "%s [%s]: " "$_title" "$_init_val" >&2
        IFS= read -r _res
        rm -f "$_out_file"
        if [ -z "$_res" ]; then
            printf '%s' "$_init_val"
        else
            printf '%s' "$_res"
        fi
        return 0
    fi
    rm -f "$_out_file"
    return 1
}

mask_password() {
    _pw="$1"
    if [ -z "$_pw" ]; then
        echo "(empty)"
    else
        echo "********"
    fi
}

# Readable on-device Debug Log viewer:
# - Shows the last sync's "SYNCED FILES & WINNER" summary right at the top
# - Wraps long log lines into 42-char chunks so nothing is cut off by the large list font
# - Enables horizontal marquee scrolling (`--scroll-method wrap`) in minui-list
# - Pressing A opens a paginated small-font (16pt) full-screen view (A: Next Page, B: Back)
view_debug_logs() {
    dismiss_ui_message

    if [ -z "$LIST_BIN" ]; then
        cat "$LOG_FILE"
        return 0
    fi

    SUMMARY_FILE="$PAK_DIR/last_sync_summary.txt"

    while true; do
        _raw_combined="$(mktemp "${TMPDIR:-/tmp}/savesync_lograw.XXXXXX")"
        _log_view="$(mktemp "${TMPDIR:-/tmp}/savesync_logview.XXXXXX")"
        _sel_out="$(mktemp "${TMPDIR:-/tmp}/savesync_logout.XXXXXX")"
        : > "$_raw_combined"

        if [ -s "$SUMMARY_FILE" ]; then
            cat "$SUMMARY_FILE" >> "$_raw_combined"
            echo "--------------------------------------------" >> "$_raw_combined"
        fi

        if [ -s "$LOG_FILE" ]; then
            grep -v "^dbclient: Caution" "$LOG_FILE" | grep -v "^[[:space:]]*$" >> "$_raw_combined" || true
        fi

        if [ -s "$_raw_combined" ]; then
            awk '
                {
                    s = $0
                    if (length(s) <= 44) {
                        print s
                    } else {
                        print substr(s, 1, 44)
                        rest = substr(s, 45)
                        while (length(rest) > 0) {
                            print "  " substr(rest, 1, 42)
                            rest = substr(rest, 43)
                        }
                    }
                }
            ' "$_raw_combined" > "$_log_view"
        else
            echo "No log entries yet." > "$_log_view"
        fi

        "$LIST_BIN" \
            --file "$_log_view" \
            --format text \
            --scroll-method wrap \
            --title "Debug Log (A: Small Font View | B: Back)" \
            --write-location "$_sel_out" >/dev/null 2>&1
        _rc=$?
        rm -f "$_log_view" "$_sel_out"

        # If user pressed A (rc=0) and minui-presenter is available, show paginated small-font (16pt) view
        if [ "$_rc" -eq 0 ] && [ -n "$PRESENTER_BIN" ] && [ -s "$_raw_combined" ]; then
            _folded="$(mktemp "${TMPDIR:-/tmp}/savesync_folded.XXXXXX")"
            fold -s -w 58 "$_raw_combined" > "$_folded"
            _total_lines="$(wc -l < "$_folded" | tr -d ' ')"
            _page_size=15
            _start=1

            while [ "$_start" -le "$_total_lines" ]; do
                _end=$((_start + _page_size - 1))
                _page_txt="$(sed -n "${_start},${_end}p" "$_folded")"
                if [ "$_end" -lt "$_total_lines" ]; then
                    if "$PRESENTER_BIN" \
                        --message "$_page_txt" \
                        --font-size-default 16 \
                        --message-alignment top \
                        --confirm-show \
                        --confirm-button A \
                        --confirm-text "NEXT PAGE" \
                        --cancel-show \
                        --cancel-button B \
                        --cancel-text "BACK" \
                        --timeout 0 >/dev/null 2>&1; then
                        _start=$((_start + _page_size))
                    else
                        break
                    fi
                else
                    "$PRESENTER_BIN" \
                        --message "$_page_txt" \
                        --font-size-default 16 \
                        --message-alignment top \
                        --cancel-show \
                        --cancel-button B \
                        --cancel-text "BACK" \
                        --timeout 0 >/dev/null 2>&1 || true
                    break
                fi
            done
            rm -f "$_folded" "$_raw_combined"
        else
            rm -f "$_raw_combined"
            break
        fi
    done
}

# Run step-by-step connection diagnostics and show results in the on-device log viewer
run_connection_diagnostics() {
    load_config
    show_ui_message "Running diagnostics to $SSH_HOST..." 0
    log "=== DIAGNOSTICS START ==="
    log "Host: ${SSH_USER}@${SSH_HOST}:${SSH_PORT}"
    log "TrimUI IP: $(ip -4 addr show 2>/dev/null | awk '/inet / && !/127.0.0.1/ {print $2}' | tr '\n' ' ' || echo 'unknown')"

    for _b in ssh dbclient dropbearmulti sshpass rsync tar; do
        if command -v "$_b" >/dev/null 2>&1; then
            log "Bin [$_b]: OK"
        else
            log "Bin [$_b]: MISSING"
        fi
    done

    if ping -c 1 -W 3 "$SSH_HOST" >/dev/null 2>&1; then
        log "Ping [$SSH_HOST]: OK"
    else
        log "Ping [$SSH_HOST]: FAILED (Check Wi-Fi/IP)"
    fi

    if init_ssh_transport; then
        log "SSH Auth: SUCCESS!"
        _rem_check="$(run_remote_cmd "ls -ld '$REMOTE_SAVES_ROOT' 2>&1" 2>&1 || true)"
        log "Remote Dir: $_rem_check"
        show_ui_message "Diagnostics Passed! Connected to $SSH_HOST" 2
    else
        log "SSH Auth: FAILED (Check log above)"
        show_ui_message "Diagnostics Failed! Opening Debug Log..." 2
    fi
    log "=== DIAGNOSTICS END ==="
    view_debug_logs
}

# Wipe local & remote Knulli SSH keys using password login and generate a fresh pair
reset_and_reinstall_ssh_keys() {
    load_config
    show_ui_message "Resetting SSH keys on TrimUI & $SSH_HOST..." 0
    log "=== RESETTING SSH KEYS ==="

    rm -rf "$PAK_DIR/.ssh" /tmp/savesync_id_key
    mkdir -p "$PAK_DIR/.ssh"

    _clear_remote_cmd="rm -f ~/.ssh/authorized_keys /userdata/system/.ssh/authorized_keys /userdata/system/ssh/authorized_keys && (batocera-save-overlay >/dev/null 2>&1 || true)"
    if command -v sshpass >/dev/null 2>&1 && [ -n "$SSH_PASSWORD" ]; then
        export SSHPASS="$SSH_PASSWORD"
        if [ -x "$PAK_DIR/bin/dropbearmulti" ]; then
            sshpass -e "$PAK_DIR/bin/dropbearmulti" dbclient -p "$SSH_PORT" -y -y "${SSH_USER}@${SSH_HOST}" "$_clear_remote_cmd" </dev/null >>"$LOG_FILE" 2>&1 || true
        elif command -v ssh >/dev/null 2>&1; then
            sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" "${SSH_USER}@${SSH_HOST}" "$_clear_remote_cmd" </dev/null >>"$LOG_FILE" 2>&1 || true
        fi
        log "Cleared remote authorized_keys on $SSH_HOST."
    fi

    if setup_ssh_keys && init_ssh_transport; then
        show_ui_message "SSH Keys Reset & Verified with $SSH_HOST!" 3
        log "=== SSH KEY RESET SUCCESSFUL ==="
    else
        show_ui_message "Key reset failed! Opening Debug Log..." 3
        log "=== SSH KEY RESET FAILED ==="
        view_debug_logs
    fi
}

run_interactive_menu() {
    ensure_binaries

    if [ -z "$LIST_BIN" ]; then
        log "minui-list binary not found; falling back to direct sync."
        run_sync "sync"
        return $?
    fi

    while true; do
        load_config
        dismiss_ui_message

        _pw_masked="$(mask_password "$SSH_PASSWORD")"
        _menu_file="$(mktemp "${TMPDIR:-/tmp}/savesync_menu.XXXXXX")"
        _choice_file="$(mktemp "${TMPDIR:-/tmp}/savesync_choice.XXXXXX")"

        cat <<EOF > "$_menu_file"
Sync Saves Now ($SSH_HOST)
Restore from Backup
RG28XX IP / Host: $SSH_HOST
SSH Port: $SSH_PORT
SSH Username: $SSH_USER
SSH Password: $_pw_masked
Test Connection & Diagnose
Reset & Re-install SSH Keys
View Debug Log (savesync.log)
Backup Remote Saves: $BACKUP_REMOTE
Exit
EOF

        "$LIST_BIN" \
            --file "$_menu_file" \
            --format text \
            --scroll-method wrap \
            --title "SaveSync (NextUI <-> Knulli)" \
            --write-location "$_choice_file" >/dev/null 2>&1
        _rc=$?

        _selection="$(cat "$_choice_file" 2>/dev/null | head -n 1 | tr -d '\r\n')"
        rm -f "$_menu_file" "$_choice_file"

        if [ "$_rc" -ne 0 ] || [ -z "$_selection" ] || [ "$_selection" = "Exit" ]; then
            log "Exiting SaveSync UI menu."
            break
        fi

        case "$_selection" in
            "Sync Saves Now"*)
                if ! run_sync "sync"; then
                    view_debug_logs
                fi
                ;;
            "Restore from Backup"*)
                run_restore_menu
                ;;
            "RG28XX IP / Host:"*)
                if _new_host="$(prompt_keyboard "RG28XX IP or Hostname" "$SSH_HOST")"; then
                    if [ -n "$_new_host" ]; then
                        save_config_value "SSH_HOST" "$_new_host"
                        show_ui_message "Saved Host: $_new_host" 2
                    fi
                fi
                ;;
            "SSH Port:"*)
                if _new_port="$(prompt_keyboard "SSH Port (default 22)" "$SSH_PORT")"; then
                    if [ -n "$_new_port" ]; then
                        save_config_value "SSH_PORT" "$_new_port"
                        show_ui_message "Saved SSH Port: $_new_port" 2
                    fi
                fi
                ;;
            "SSH Username:"*)
                if _new_user="$(prompt_keyboard "SSH Username (default root)" "$SSH_USER")"; then
                    if [ -n "$_new_user" ]; then
                        save_config_value "SSH_USER" "$_new_user"
                        show_ui_message "Saved Username: $_new_user" 2
                    fi
                fi
                ;;
            "SSH Password:"*)
                if _new_pw="$(prompt_keyboard "SSH Password (default linux)" "$SSH_PASSWORD")"; then
                    save_config_value "SSH_PASSWORD" "$_new_pw"
                    show_ui_message "Saved SSH Password!" 2
                fi
                ;;
            "Test Connection & Diagnose"*)
                run_connection_diagnostics
                ;;
            "Reset & Re-install SSH Keys"*)
                reset_and_reinstall_ssh_keys
                ;;
            "View Debug Log"*)
                view_debug_logs
                ;;
            "Backup Remote Saves:"*)
                if [ "$BACKUP_REMOTE" = "true" ]; then
                    save_config_value "BACKUP_REMOTE" "false"
                    show_ui_message "Remote Backup: disabled (local only)" 2
                else
                    save_config_value "BACKUP_REMOTE" "true"
                    show_ui_message "Remote Backup: enabled (local + remote)" 2
                fi
                ;;
        esac
    done
}

# --- String / File Helper Functions ---
trim() {
    echo "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

is_save_state_or_ignored() {
    _fname="$1"
    case "$_fname" in
        *.state|*.state[0-9]*|*.state.auto|*.st[0-9]*|*.auto|*.png|*.bmp|*.jpg|*.txt|*.xml|*.cfg|.*|*.bak|*.tmp)
            return 0
            ;;
    esac
    return 1
}

is_allowed_save_file() {
    _fname="$1"
    if is_save_state_or_ignored "$_fname"; then
        return 1
    fi
    _ext="${_fname##*.}"
    _ext="$(echo "$_ext" | tr '[:upper:]' '[:lower:]')"
    for _allowed in $ALLOWED_SAVE_EXTS; do
        if [ "$_ext" = "$_allowed" ]; then
            return 0
        fi
    done
    return 1
}

get_mtime() {
    _file="$1"
    if [ ! -e "$_file" ]; then
        echo 0
        return
    fi
    if stat -c %Y "$_file" >/dev/null 2>&1; then
        stat -c %Y "$_file"
    elif stat -f %m "$_file" >/dev/null 2>&1; then
        stat -f %m "$_file"
    else
        date -r "$_file" +%s 2>/dev/null || echo 0
    fi
}

get_mtime_str() {
    _file="$1"
    if [ ! -e "$_file" ]; then
        echo "none"
        return
    fi
    date -r "$_file" '+%m-%d %H:%M:%S' 2>/dev/null || get_mtime "$_file"
}

# Create a BusyBox-compatible tar exclude file (-X) for save states & screenshots
get_tar_exclude_file() {
    _ex_file="/tmp/savesync_tar_excludes.txt"
    cat <<'EOF' > "$_ex_file"
*.state
*.state0
*.state1
*.state2
*.state3
*.state4
*.state5
*.state6
*.state7
*.state8
*.state9
*.state.auto
*.st0
*.st1
*.st2
*.st3
*.st4
*.st5
*.st6
*.st7
*.st8
*.st9
*.auto
*.png
*.jpg
*.bmp
*.txt
*.xml
*.cfg
*.bak
*.tmp
EOF
    echo "$_ex_file"
}

# --- SSH / Dropbear Transport Layer ---
SSH_EXEC_WRAP="/tmp/savesync_ssh_exec.sh"
SSH_PIPE_WRAP="/tmp/savesync_ssh_pipe.sh"

get_ssh_flavor() {
    if command -v ssh >/dev/null 2>&1; then
        if ssh -V 2>&1 | grep -qi "Dropbear"; then
            echo "dropbear-ssh"
            return 0
        fi
        echo "openssh"
        return 0
    fi
    if [ -x "$PAK_DIR/bin/dropbearmulti" ]; then
        echo "dropbearmulti"
        return 0
    fi
    if command -v dbclient >/dev/null 2>&1; then
        echo "dbclient"
        return 0
    fi
    echo "none"
    return 1
}

run_remote_cmd() {
    "$SSH_EXEC_WRAP" "${SSH_USER}@${SSH_HOST}" "$1" </dev/null
}

run_remote_pipe_in() {
    "$SSH_PIPE_WRAP" "${SSH_USER}@${SSH_HOST}" "$1"
}

setup_ssh_keys() {
    _flavor="$(get_ssh_flavor)"
    _key_dir="$(dirname "$SSH_KEY_PATH")"
    mkdir -p "$_key_dir"
    chmod 700 "$_key_dir" 2>/dev/null || true

    if [ "$_flavor" = "openssh" ]; then
        if [ ! -f "$SSH_KEY_PATH" ]; then
            log "Generating OpenSSH key..."
            if command -v ssh-keygen >/dev/null 2>&1; then
                ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q 2>>"$LOG_FILE" || \
                ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" -q 2>>"$LOG_FILE"
            else
                log "WARN: ssh-keygen not found."
                return 1
            fi
            chmod 600 "$SSH_KEY_PATH" 2>/dev/null || true
        fi
        if [ ! -f "${SSH_KEY_PATH}.pub" ] && command -v ssh-keygen >/dev/null 2>&1; then
            ssh-keygen -y -f "$SSH_KEY_PATH" > "${SSH_KEY_PATH}.pub" 2>>"$LOG_FILE" || true
        fi
    else
        SSH_KEY_PATH="${SSH_KEY_PATH}_dropbear"
        if [ ! -f "$SSH_KEY_PATH" ]; then
            log "Generating Dropbear SSH key..."
            if [ -x "$PAK_DIR/bin/dropbearmulti" ]; then
                "$PAK_DIR/bin/dropbearmulti" dropbearkey -t ed25519 -f "$SSH_KEY_PATH" >>"$LOG_FILE" 2>&1 || \
                "$PAK_DIR/bin/dropbearmulti" dropbearkey -t rsa -f "$SSH_KEY_PATH" >>"$LOG_FILE" 2>&1
                "$PAK_DIR/bin/dropbearmulti" dropbearkey -y -f "$SSH_KEY_PATH" | grep "^ssh-" > "${SSH_KEY_PATH}.pub"
            elif command -v dropbearkey >/dev/null 2>&1; then
                dropbearkey -t ed25519 -f "$SSH_KEY_PATH" >>"$LOG_FILE" 2>&1 || \
                dropbearkey -t rsa -f "$SSH_KEY_PATH" >>"$LOG_FILE" 2>&1
                dropbearkey -y -f "$SSH_KEY_PATH" | grep "^ssh-" > "${SSH_KEY_PATH}.pub"
            else
                log "WARN: dropbearkey not found."
                return 1
            fi
            chmod 600 "$SSH_KEY_PATH" 2>/dev/null || true
        fi
    fi

    _pub_key="$(cat "${SSH_KEY_PATH}.pub" 2>/dev/null || true)"
    if [ -z "$_pub_key" ]; then
        log "WARN: Could not read public key ${SSH_KEY_PATH}.pub"
        return 1
    fi

    _remote_install_cmd="mkdir -p ~/.ssh /userdata/system/.ssh && chmod 700 ~/.ssh /userdata/system/.ssh && for f in ~/.ssh/authorized_keys /userdata/system/.ssh/authorized_keys; do grep -qF '$_pub_key' \"\$f\" 2>/dev/null || echo '$_pub_key' >> \"\$f\"; chmod 600 \"\$f\" 2>/dev/null || true; done && (batocera-save-overlay >/dev/null 2>&1 || true)"

    log "Installing SSH key to ${SSH_USER}@${SSH_HOST}..."
    if command -v sshpass >/dev/null 2>&1 && [ -n "$SSH_PASSWORD" ]; then
        if [ "$_flavor" = "openssh" ]; then
            if SSHPASS="$SSH_PASSWORD" sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" "${SSH_USER}@${SSH_HOST}" "$_remote_install_cmd" </dev/null >>"$LOG_FILE" 2>&1; then
                log "Installed SSH key via sshpass + OpenSSH."
                return 0
            fi
        elif [ -x "$PAK_DIR/bin/dropbearmulti" ]; then
            if SSHPASS="$SSH_PASSWORD" sshpass -e "$PAK_DIR/bin/dropbearmulti" dbclient -p "$SSH_PORT" -y -y "${SSH_USER}@${SSH_HOST}" "$_remote_install_cmd" </dev/null >>"$LOG_FILE" 2>&1; then
                log "Installed SSH key via sshpass + dropbearmulti."
                return 0
            fi
        elif command -v dbclient >/dev/null 2>&1; then
            if SSHPASS="$SSH_PASSWORD" sshpass -e dbclient -p "$SSH_PORT" -y -y "${SSH_USER}@${SSH_HOST}" "$_remote_install_cmd" </dev/null >>"$LOG_FILE" 2>&1; then
                log "Installed SSH key via sshpass + dbclient."
                return 0
            fi
        fi
    fi

    log "WARN: Automatic key installation failed."
    return 1
}

init_ssh_transport() {
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    chmod 700 "$(dirname "$SSH_KEY_PATH")" 2>/dev/null || true

    _flavor="$(get_ssh_flavor)"
    log "SSH client: $_flavor"

    _runtime_key="/tmp/savesync_id_key"

    try_key_auth() {
        _cand_key="$1"
        [ -f "$_cand_key" ] || return 1
        cp "$_cand_key" "$_runtime_key"
        chmod 600 "$_runtime_key" 2>/dev/null || true

        if [ "$_flavor" = "openssh" ]; then
            cat <<EOF > "$SSH_EXEC_WRAP"
#!/bin/sh
exec ssh -n -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" -i "$_runtime_key" -o BatchMode=yes "\$@" </dev/null
EOF
            cat <<EOF > "$SSH_PIPE_WRAP"
#!/bin/sh
exec ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" -i "$_runtime_key" -o BatchMode=yes "\$@"
EOF
            chmod 700 "$SSH_EXEC_WRAP" "$SSH_PIPE_WRAP"
            if [ "$(run_remote_cmd "echo SAVESYNC_OK" 2>>"$LOG_FILE" | tr -d '\r\n')" = "SAVESYNC_OK" ]; then
                log "Connected to ${SSH_HOST} (OpenSSH key)."
                return 0
            fi
        elif [ -x "$PAK_DIR/bin/dropbearmulti" ]; then
            cat <<EOF > "$SSH_EXEC_WRAP"
#!/bin/sh
exec "$PAK_DIR/bin/dropbearmulti" dbclient -p "$SSH_PORT" -y -y -i "$_runtime_key" "\$@" </dev/null
EOF
            cat <<EOF > "$SSH_PIPE_WRAP"
#!/bin/sh
exec "$PAK_DIR/bin/dropbearmulti" dbclient -p "$SSH_PORT" -y -y -i "$_runtime_key" "\$@"
EOF
            chmod 700 "$SSH_EXEC_WRAP" "$SSH_PIPE_WRAP"
            if [ "$(run_remote_cmd "echo SAVESYNC_OK" 2>>"$LOG_FILE" | tr -d '\r\n')" = "SAVESYNC_OK" ]; then
                log "Connected to ${SSH_HOST} (Dropbear key)."
                return 0
            fi
        fi
        return 1
    }

    if try_key_auth "$SSH_KEY_PATH" || try_key_auth "${SSH_KEY_PATH}_dropbear"; then
        return 0
    fi

    if command -v sshpass >/dev/null 2>&1 && [ -n "$SSH_PASSWORD" ]; then
        export SSHPASS="$SSH_PASSWORD"
        log "Testing sshpass login to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}..."

        if [ "$_flavor" = "openssh" ]; then
            cat <<EOF > "$SSH_EXEC_WRAP"
#!/bin/sh
export SSHPASS='$SSH_PASSWORD'
exec "$(command -v sshpass)" -e ssh -n -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" "\$@" </dev/null
EOF
            cat <<EOF > "$SSH_PIPE_WRAP"
#!/bin/sh
export SSHPASS='$SSH_PASSWORD'
exec "$(command -v sshpass)" -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" "\$@"
EOF
            chmod 700 "$SSH_EXEC_WRAP" "$SSH_PIPE_WRAP"
            if [ "$(run_remote_cmd "echo SAVESYNC_OK" 2>>"$LOG_FILE" | tr -d '\r\n')" = "SAVESYNC_OK" ]; then
                log "Connected to ${SSH_HOST} (sshpass + OpenSSH)."
                setup_ssh_keys >/dev/null 2>&1 || true
                return 0
            fi
        fi

        if [ -x "$PAK_DIR/bin/dropbearmulti" ]; then
            cat <<EOF > "$SSH_EXEC_WRAP"
#!/bin/sh
export SSHPASS='$SSH_PASSWORD'
exec "$(command -v sshpass)" -e "$PAK_DIR/bin/dropbearmulti" dbclient -p "$SSH_PORT" -y -y "\$@" </dev/null
EOF
            cat <<EOF > "$SSH_PIPE_WRAP"
#!/bin/sh
export SSHPASS='$SSH_PASSWORD'
exec "$(command -v sshpass)" -e "$PAK_DIR/bin/dropbearmulti" dbclient -p "$SSH_PORT" -y -y "\$@"
EOF
            chmod 700 "$SSH_EXEC_WRAP" "$SSH_PIPE_WRAP"
            if [ "$(run_remote_cmd "echo SAVESYNC_OK" 2>>"$LOG_FILE" | tr -d '\r\n')" = "SAVESYNC_OK" ]; then
                log "Connected to ${SSH_HOST} (sshpass + dbclient)."
                setup_ssh_keys >/dev/null 2>&1 || true
                return 0
            fi
        fi
    fi

    show_ui_message "Setting up SSH auth with $SSH_HOST..." 0
    if setup_ssh_keys; then
        if try_key_auth "$SSH_KEY_PATH" || try_key_auth "${SSH_KEY_PATH}_dropbear"; then
            return 0
        fi
    fi

    log "ERROR: Auth failed for ${SSH_USER}@${SSH_HOST}:${SSH_PORT}."
    return 1
}

# --- Remote Pull & Push Helpers ---
pull_remote_saves() {
    _remote_folders="$1"
    for _k_folder in $_remote_folders; do
        mkdir -p "$REMOTE_STAGE/$_k_folder"
    done

    _flavor="$(get_ssh_flavor)"
    if [ "$_flavor" = "openssh" ] && command -v rsync >/dev/null 2>&1; then
        if run_remote_cmd "command -v rsync >/dev/null 2>&1" >>"$LOG_FILE" 2>&1; then
            log "Pulling saves via OpenSSH + rsync..."
            _filter_args="$(build_rsync_filter_args)"
            for _k_folder in $_remote_folders; do
                # shellcheck disable=SC2086
                rsync -rtz --no-perms --no-owner --no-group --modify-window=2 $_filter_args \
                    -e "$SSH_PIPE_WRAP" \
                    "${SSH_USER}@${SSH_HOST}:${REMOTE_SAVES_ROOT}/${_k_folder}/" \
                    "$REMOTE_STAGE/$_k_folder/" >>"$LOG_FILE" 2>&1 || true
            done
            return 0
        fi
    fi

    log "Pulling saves via tar-over-SSH..."
    _tmp_pull_tar="$STAGE_DIR/remote_pull.tar.gz"

    _remote_script="cd '$REMOTE_SAVES_ROOT' 2>/dev/null || exit 0; list=''; for d in $_remote_folders; do [ -d \"\$d\" ] && list=\"\$list \$d\"; done; [ -n \"\$list\" ] && tar -czf - \$list 2>/dev/null || true"

    run_remote_cmd "$_remote_script" > "$_tmp_pull_tar" 2>>"$LOG_FILE" || true

    if [ -s "$_tmp_pull_tar" ]; then
        tar -xzf "$_tmp_pull_tar" -C "$REMOTE_STAGE" 2>>"$LOG_FILE" || true
        log "Unpacked remote saves into staging."
    else
        log "No existing mapped saves on Knulli yet."
    fi
    rm -f "$_tmp_pull_tar"
}

push_remote_saves() {
    _remote_folders="$1"

    _flavor="$(get_ssh_flavor)"
    if [ "$_flavor" = "openssh" ] && command -v rsync >/dev/null 2>&1; then
        if run_remote_cmd "command -v rsync >/dev/null 2>&1" >>"$LOG_FILE" 2>&1; then
            log "Pushing saves via OpenSSH + rsync..."
            _filter_args="$(build_rsync_filter_args)"
            for _k_folder in $_remote_folders; do
                if [ -d "$REMOTE_STAGE/$_k_folder" ] && [ -n "$(ls -A "$REMOTE_STAGE/$_k_folder" 2>/dev/null)" ]; then
                    run_remote_cmd "mkdir -p '${REMOTE_SAVES_ROOT}/${_k_folder}'" >>"$LOG_FILE" 2>&1 || true
                    # shellcheck disable=SC2086
                    rsync -rtz --no-perms --no-owner --no-group --modify-window=2 $_filter_args \
                        -e "$SSH_PIPE_WRAP" \
                        "$REMOTE_STAGE/$_k_folder/" \
                        "${SSH_USER}@${SSH_HOST}:${REMOTE_SAVES_ROOT}/${_k_folder}/" >>"$LOG_FILE" 2>&1
                fi
            done
            return 0
        fi
    fi

    log "Uploading saves via tar-over-SSH..."
    _dirs_to_push=""
    for _k_folder in $_remote_folders; do
        if [ -d "$REMOTE_STAGE/$_k_folder" ] && [ -n "$(ls -A "$REMOTE_STAGE/$_k_folder" 2>/dev/null)" ]; then
            _dirs_to_push="$_dirs_to_push $_k_folder"
        fi
    done

    if [ -n "$_dirs_to_push" ]; then
        _tmp_push_tar="$STAGE_DIR/remote_push.tar.gz"
        # shellcheck disable=SC2086
        tar -czf "$_tmp_push_tar" -C "$REMOTE_STAGE" $_dirs_to_push 2>>"$LOG_FILE"
        if [ -s "$_tmp_push_tar" ]; then
            if ! run_remote_pipe_in "mkdir -p '$REMOTE_SAVES_ROOT' && tar -xzf - -C '$REMOTE_SAVES_ROOT' && sync" < "$_tmp_push_tar" >>"$LOG_FILE" 2>&1; then
                rm -f "$_tmp_push_tar"
                log "ERROR: Failed to unpack saves on Knulli."
                return 1
            fi
            log "Uploaded & unpacked saves on Knulli!"
        fi
        rm -f "$_tmp_push_tar"
    fi
    return 0
}

# --- Backup & Rotation Functions (Keep Last N Compressed Backups) ---
rotate_backups() {
    _prefix="$1"
    _keep="$BACKUP_KEEP_COUNT"

    _count=0
    for _archive in $(ls -1r "$BACKUP_DIR/${_prefix}_"*.tar.gz 2>/dev/null || true); do
        _count=$((_count + 1))
        if [ "$_count" -gt "$_keep" ]; then
            log "Rotate backup: rm $(basename "$_archive")"
            rm -f "$_archive"
        fi
    done
}

create_backups() {
    _run_ts="$1"
    _remote_stage_raw="$2"

    mkdir -p "$BACKUP_DIR"
    _ex_file="$(get_tar_exclude_file)"

    if [ -d "$LOCAL_SAVES_ROOT" ] && [ -n "$(ls -A "$LOCAL_SAVES_ROOT" 2>/dev/null)" ]; then
        _local_archive="$BACKUP_DIR/local_${_run_ts}.tar.gz"
        log "Backup local: $(basename "$_local_archive")"
        tar -czf "$_local_archive" -X "$_ex_file" -C "$LOCAL_SAVES_ROOT" . >>"$LOG_FILE" 2>&1 || \
        tar -czf "$_local_archive" -C "$LOCAL_SAVES_ROOT" . >>"$LOG_FILE" 2>&1 || true
        rotate_backups "local"
    fi

    if [ "$BACKUP_REMOTE" = "true" ] && [ -d "$_remote_stage_raw" ] && [ -n "$(ls -A "$_remote_stage_raw" 2>/dev/null)" ]; then
        _remote_archive="$BACKUP_DIR/remote_${_run_ts}.tar.gz"
        log "Backup remote: $(basename "$_remote_archive")"
        tar -czf "$_remote_archive" -X "$_ex_file" -C "$_remote_stage_raw" . >>"$LOG_FILE" 2>&1 || \
        tar -czf "$_remote_archive" -C "$_remote_stage_raw" . >>"$LOG_FILE" 2>&1 || true
        rotate_backups "remote"
    fi
}

# --- Core Mapping & Bidirectional Sync Engine ---
build_rsync_filter_args() {
    _args="--exclude=*.state --exclude=*.state* --exclude=*.st[0-9]* --exclude=*.auto --exclude=*.png --exclude=*.jpg --exclude=*.bmp --exclude=*.txt --exclude=*.xml --exclude=*.cfg --exclude=.*"
    echo "$_args"
}

copy_save_with_mtime() {
    _src="$1"
    _dst="$2"
    mkdir -p "$(dirname "$_dst")"
    cp -f "$_src" "$_dst"
    touch -r "$_src" "$_dst" 2>/dev/null || true
}

# Clamp or reset future timestamps (e.g. from NGPC emulator clock/TZ offset)
# - If a file has a future timestamp (> now + 60s) AND is unchanged compared to the last backup,
#   reset its mtime back to the last backup's timestamp so a newer save on the other device can win.
# - If a file has a future timestamp AND was newly modified since the last backup,
#   clamp its mtime to 'now' so it wins this sync cleanly without leaving a future timestamp behind.
sanitize_future_timestamps() {
    _now="$(date +%s)"
    _max_allowed=$((_now + 60))
    _prev_loc_tar="$(ls -1r "$BACKUP_DIR"/local_*.tar.gz 2>/dev/null | head -n 1 || true)"
    _prev_rem_tar="$(ls -1r "$BACKUP_DIR"/remote_*.tar.gz 2>/dev/null | head -n 1 || true)"
    _prev_loc_dir="$STAGE_DIR/prev_loc_check"
    _prev_rem_dir="$STAGE_DIR/prev_rem_check"

    if [ -d "$LOCAL_SAVES_ROOT" ]; then
        find "$LOCAL_SAVES_ROOT" -type f | while IFS= read -r _lf; do
            is_allowed_save_file "$(basename "$_lf")" || continue
            _mt="$(get_mtime "$_lf")"
            if [ "$_mt" -gt "$_max_allowed" ]; then
                if [ -n "$_prev_loc_tar" ] && [ -f "$_prev_loc_tar" ]; then
                    if [ ! -d "$_prev_loc_dir" ]; then
                        mkdir -p "$_prev_loc_dir"
                        tar -xzf "$_prev_loc_tar" -C "$_prev_loc_dir" 2>/dev/null || true
                    fi
                    _rel="${_lf#"$LOCAL_SAVES_ROOT"/}"
                    if [ -f "$_prev_loc_dir/$_rel" ] && cmp -s "$_lf" "$_prev_loc_dir/$_rel"; then
                        log "[TIME FIX] Reset leftover future local mtime: $(basename "$_lf")"
                        touch -r "$_prev_loc_tar" "$_lf" 2>/dev/null || touch "$_lf" 2>/dev/null || true
                        continue
                    fi
                fi
                log "[TIME FIX] Clamped future local mtime to now: $(basename "$_lf")"
                touch "$_lf" 2>/dev/null || true
            fi
        done
    fi

    if [ -d "$REMOTE_STAGE" ]; then
        find "$REMOTE_STAGE" -type f | while IFS= read -r _rf; do
            is_allowed_save_file "$(basename "$_rf")" || continue
            _mt="$(get_mtime "$_rf")"
            if [ "$_mt" -gt "$_max_allowed" ]; then
                : > "$STAGE_DIR/remote_time_fixed.flag"
                if [ -n "$_prev_rem_tar" ] && [ -f "$_prev_rem_tar" ]; then
                    if [ ! -d "$_prev_rem_dir" ]; then
                        mkdir -p "$_prev_rem_dir"
                        tar -xzf "$_prev_rem_tar" -C "$_prev_rem_dir" 2>/dev/null || true
                    fi
                    _rel="${_rf#"$REMOTE_STAGE"/}"
                    if [ -f "$_prev_rem_dir/$_rel" ] && cmp -s "$_rf" "$_prev_rem_dir/$_rel"; then
                        log "[TIME FIX] Reset leftover future remote mtime: $(basename "$_rf")"
                        touch -r "$_prev_rem_tar" "$_rf" 2>/dev/null || touch "$_rf" 2>/dev/null || true
                        continue
                    fi
                fi
                log "[TIME FIX] Clamped future remote mtime to now: $(basename "$_rf")"
                touch "$_rf" 2>/dev/null || true
            fi
        done
    fi
}

sync_file_pair() {
    _loc_file="$1"
    _rem_file="$2"
    _label="$3"

    _loc_exists=0
    _rem_exists=0
    [ -f "$_loc_file" ] && _loc_exists=1
    [ -f "$_rem_file" ] && _rem_exists=1

    if [ "$_loc_exists" -eq 0 ] && [ "$_rem_exists" -eq 0 ]; then
        return 0
    fi

    _loc_name="$(basename "$_loc_file")"
    _rem_name="$(basename "$_rem_file")"

    if [ "$_loc_exists" -eq 1 ] && [ "$_rem_exists" -eq 0 ]; then
        _loc_dt="$(get_mtime_str "$_loc_file")"
        _entry="[TrimUI WON] $_label: $_loc_name (New on TrimUI [$_loc_dt] -> Knulli)"
        log "$_entry"
        echo "$_entry" >> "$SYNC_RESULTS_FILE"
        copy_save_with_mtime "$_loc_file" "$_rem_file"
        PUSH_COUNT=$((PUSH_COUNT + 1))
        return 0
    fi

    if [ "$_loc_exists" -eq 0 ] && [ "$_rem_exists" -eq 1 ]; then
        _rem_dt="$(get_mtime_str "$_rem_file")"
        _entry="[Knulli WON] $_label: $_rem_name (New on Knulli [$_rem_dt] -> TrimUI)"
        log "$_entry"
        echo "$_entry" >> "$SYNC_RESULTS_FILE"
        copy_save_with_mtime "$_rem_file" "$_loc_file"
        PULL_COUNT=$((PULL_COUNT + 1))
        return 0
    fi

    _loc_mtime="$(get_mtime "$_loc_file")"
    _rem_mtime="$(get_mtime "$_rem_file")"
    _loc_dt="$(get_mtime_str "$_loc_file")"
    _rem_dt="$(get_mtime_str "$_rem_file")"
    _diff=$((_loc_mtime - _rem_mtime))

    if cmp -s "$_loc_file" "$_rem_file"; then
        if [ "$_diff" -gt 2 ] || [ "$_diff" -lt -2 ]; then
            # Align timestamps if one side had a future timestamp clamped
            if [ "$_loc_mtime" -le "$_rem_mtime" ]; then
                touch -r "$_loc_file" "$_rem_file" 2>/dev/null || true
            else
                touch -r "$_rem_file" "$_loc_file" 2>/dev/null || true
            fi
            PUSH_COUNT=$((PUSH_COUNT + 1))
        fi
        UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
        echo "[IN SYNC] $_label: $_loc_name (Identical [$_loc_dt])" >> "$UNCHANGED_RESULTS_FILE"
        return 0
    fi

    if [ "$_diff" -gt 2 ]; then
        _entry="[TrimUI WON] $_label: $_loc_name (TrimUI $_loc_dt > Knulli $_rem_dt)"
        log "$_entry"
        echo "$_entry" >> "$SYNC_RESULTS_FILE"
        copy_save_with_mtime "$_loc_file" "$_rem_file"
        PUSH_COUNT=$((PUSH_COUNT + 1))
    elif [ "$_diff" -lt -2 ]; then
        _entry="[Knulli WON] $_label: $_rem_name (Knulli $_rem_dt > TrimUI $_loc_dt)"
        log "$_entry"
        echo "$_entry" >> "$SYNC_RESULTS_FILE"
        copy_save_with_mtime "$_rem_file" "$_loc_file"
        PULL_COUNT=$((PULL_COUNT + 1))
    else
        _entry="[TIE/SKIP] $_label: $_loc_name (Same time [$_loc_dt])"
        log "$_entry"
        echo "$_entry" >> "$UNCHANGED_RESULTS_FILE"
        UNCHANGED_COUNT=$((UNCHANGED_COUNT + 1))
    fi
}

run_sync() {
    _action="${1:-sync}"
    load_config
    ensure_binaries

    show_ui_message "Connecting to $SSH_HOST..." 0
    if ! init_ssh_transport; then
        show_ui_message "Failed to connect to $SSH_HOST! Opening Debug Log..." 3
        return 1
    fi

    if [ "$_action" = "setup-auth" ]; then
        show_ui_message "SSH Auth Verified with $SSH_HOST!" 3
        return 0
    fi

    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/savesync_stage.XXXXXX")"
    REMOTE_STAGE="$STAGE_DIR/remote_saves"
    PROCESSED_KEYS_FILE="$STAGE_DIR/processed_pairs.txt"
    SYNC_RESULTS_FILE="$STAGE_DIR/sync_results.txt"
    UNCHANGED_RESULTS_FILE="$STAGE_DIR/unchanged_results.txt"
    mkdir -p "$REMOTE_STAGE" "$LOCAL_SAVES_ROOT"
    : > "$PROCESSED_KEYS_FILE"
    : > "$SYNC_RESULTS_FILE"
    : > "$UNCHANGED_RESULTS_FILE"

    _remote_folders=""
    for _cfg in "$OVERRIDES_FILE" "$MAPPINGS_FILE"; do
        [ -f "$_cfg" ] || continue
        while IFS='|' read -r _f_nextui _f_knulli _s_nextui _s_knulli || [ -n "$_f_nextui" ]; do
            _f_nextui="$(trim "$_f_nextui")"
            case "$_f_nextui" in ""|\#*) continue ;; esac
            _f_knulli="$(trim "$_f_knulli")"
            if [ -n "$_f_knulli" ]; then
                case " $_remote_folders " in
                    *" $_f_knulli "*) ;;
                    *) _remote_folders="$_remote_folders $_f_knulli" ;;
                esac
            fi
        done < "$_cfg"
    done

    show_ui_message "Fetching saves from Knulli ($SSH_HOST)..." 0
    log "Pulling saves from ${SSH_HOST}:${REMOTE_SAVES_ROOT}..."

    run_remote_cmd "mkdir -p '$REMOTE_SAVES_ROOT'" >>"$LOG_FILE" 2>&1 || true

    pull_remote_saves "$_remote_folders"

    find "$REMOTE_STAGE" -type f | while IFS= read -r _rf; do
        if ! is_allowed_save_file "$(basename "$_rf")"; then
            rm -f "$_rf"
        fi
    done

    sanitize_future_timestamps

    RUN_TS="$(date '+%Y%m%d_%H%M%S')"
    show_ui_message "Creating rolling backup ($RUN_TS)..." 0
    create_backups "$RUN_TS" "$REMOTE_STAGE"

    show_ui_message "Synchronizing mapped saves..." 0
    PUSH_COUNT=0
    PULL_COUNT=0
    UNCHANGED_COUNT=0

    if [ -f "$OVERRIDES_FILE" ]; then
        while IFS='|' read -r _n_dir _k_dir _n_file _k_file || [ -n "$_n_dir" ]; do
            _n_dir="$(trim "$_n_dir")"
            case "$_n_dir" in ""|\#*) continue ;; esac
            _k_dir="$(trim "$_k_dir")"
            _n_file="$(trim "$_n_file")"
            _k_file="$(trim "$_k_file")"

            _loc_path="$LOCAL_SAVES_ROOT/$_n_dir/$_n_file"
            _rem_path="$REMOTE_STAGE/$_k_dir/$_k_file"

            sync_file_pair "$_loc_path" "$_rem_path" "Ovr($_n_dir)"
            echo "LOC:$_loc_path" >> "$PROCESSED_KEYS_FILE"
            echo "REM:$_rem_path" >> "$PROCESSED_KEYS_FILE"
        done < "$OVERRIDES_FILE"
    fi

    if [ -f "$MAPPINGS_FILE" ]; then
        while IFS='|' read -r _n_dir _k_dir _n_suf _k_suf || [ -n "$_n_dir" ]; do
            _n_dir="$(trim "$_n_dir")"
            case "$_n_dir" in ""|\#*) continue ;; esac
            _k_dir="$(trim "$_k_dir")"
            _n_suf="$(trim "$_n_suf")"
            _k_suf="$(trim "$_k_suf")"

            _loc_sys_dir="$LOCAL_SAVES_ROOT/$_n_dir"
            _rem_sys_dir="$REMOTE_STAGE/$_k_dir"

            if [ -d "$_loc_sys_dir" ]; then
                for _loc_f in "$_loc_sys_dir"/*; do
                    [ -f "$_loc_f" ] || continue
                    _bname="$(basename "$_loc_f")"
                    is_allowed_save_file "$_bname" || continue

                    if grep -qF "LOC:$_loc_f" "$PROCESSED_KEYS_FILE" 2>/dev/null; then
                        continue
                    fi

                    case "$_bname" in
                        *"$_n_suf")
                            _game_base="${_bname%"$_n_suf"}"
                            [ -n "$_game_base" ] || continue
                            _target_rem_f="$_rem_sys_dir/${_game_base}${_k_suf}"

                            sync_file_pair "$_loc_f" "$_target_rem_f" "$_n_dir"
                            echo "LOC:$_loc_f" >> "$PROCESSED_KEYS_FILE"
                            echo "REM:$_target_rem_f" >> "$PROCESSED_KEYS_FILE"
                            ;;
                    esac
                done
            fi

            if [ -d "$_rem_sys_dir" ]; then
                for _rem_f in "$_rem_sys_dir"/*; do
                    [ -f "$_rem_f" ] || continue
                    _bname="$(basename "$_rem_f")"
                    is_allowed_save_file "$_bname" || continue

                    if grep -qF "REM:$_rem_f" "$PROCESSED_KEYS_FILE" 2>/dev/null; then
                        continue
                    fi

                    case "$_bname" in
                        *"$_k_suf")
                            _game_base="${_bname%"$_k_suf"}"
                            [ -n "$_game_base" ] || continue

                            _existing_loc="$(find_existing_local_save "$_k_dir" "$_game_base" "$_k_suf")"
                            if [ -n "$_existing_loc" ]; then
                                sync_file_pair "$_existing_loc" "$_rem_f" "$_n_dir"
                                echo "LOC:$_existing_loc" >> "$PROCESSED_KEYS_FILE"
                                echo "REM:$_rem_f" >> "$PROCESSED_KEYS_FILE"
                            else
                                _best_loc="$(resolve_new_local_save_path "$_k_dir" "$_game_base" "$_k_suf" "$_n_dir" "$_n_suf")"
                                sync_file_pair "$_best_loc" "$_rem_f" "$_n_dir"
                                echo "LOC:$_best_loc" >> "$PROCESSED_KEYS_FILE"
                                echo "REM:$_rem_f" >> "$PROCESSED_KEYS_FILE"
                            fi
                            ;;
                    esac
                done
            fi
        done < "$MAPPINGS_FILE"
    fi

    if [ "$PUSH_COUNT" -gt 0 ] || [ -f "$STAGE_DIR/remote_time_fixed.flag" ]; then
        show_ui_message "Uploading $PUSH_COUNT save(s) to Knulli..." 0
        log "Pushing $PUSH_COUNT save(s) to ${SSH_HOST}..."
        if ! push_remote_saves "$_remote_folders"; then
            rm -rf "$STAGE_DIR"
            STAGE_DIR=""
            show_ui_message "Upload failed! Opening Debug Log..." 3
            return 1
        fi
    fi

    # Write human-readable summary of synced files and winners for the log viewer
    SUMMARY_FILE="$PAK_DIR/last_sync_summary.txt"
    {
        echo "=== LAST SYNC SUMMARY ($(date '+%H:%M:%S')) ==="
        echo "Knulli Won (Pulled): $PULL_COUNT | TrimUI Won (Pushed): $PUSH_COUNT | Unchanged: $UNCHANGED_COUNT"
        if [ -s "$SYNC_RESULTS_FILE" ]; then
            echo "--- Updated Saves & Winning Device ---"
            cat "$SYNC_RESULTS_FILE"
        else
            echo "--- No Saves Changed (Both Devices in Sync) ---"
        fi
        if [ -s "$UNCHANGED_RESULTS_FILE" ]; then
            echo "--- Already In Sync ---"
            cat "$UNCHANGED_RESULTS_FILE"
        fi
    } > "$SUMMARY_FILE"

    log "=== SYNCED FILES & WINNERS ==="
    if [ -s "$SYNC_RESULTS_FILE" ]; then
        while IFS= read -r _sline; do
            log "$_sline"
        done < "$SYNC_RESULTS_FILE"
    else
        log "No files needed updating ($UNCHANGED_COUNT save(s) already identical)."
    fi

    rm -rf "$STAGE_DIR"
    STAGE_DIR=""
    sync
    _summary="Sync Complete! Pulled: $PULL_COUNT | Pushed: $PUSH_COUNT"
    show_ui_message "$_summary" 3
    log "$_summary"
    return 0
}

find_existing_local_save() {
    _target_k_dir="$1"
    _game_base="$2"
    _target_k_suf="$3"

    while IFS='|' read -r _nd _kd _ns _ks || [ -n "$_nd" ]; do
        _nd="$(trim "$_nd")"
        case "$_nd" in ""|\#*) continue ;; esac
        _kd="$(trim "$_kd")"
        _ns="$(trim "$_ns")"
        _ks="$(trim "$_ks")"

        if [ "$_kd" = "$_target_k_dir" ] && [ "$_ks" = "$_target_k_suf" ]; then
            _cand="$LOCAL_SAVES_ROOT/$_nd/${_game_base}${_ns}"
            if [ -f "$_cand" ]; then
                echo "$_cand"
                return 0
            fi
        fi
    done < "$MAPPINGS_FILE"
    return 1
}

resolve_new_local_save_path() {
    _target_k_dir="$1"
    _game_base="$2"
    _target_k_suf="$3"
    _fallback_n_dir="$4"
    _fallback_n_suf="$5"

    _roms_root="$SDCARD_PATH/Roms"
    if [ -d "$_roms_root" ]; then
        while IFS='|' read -r _nd _kd _ns _ks || [ -n "$_nd" ]; do
            _nd="$(trim "$_nd")"
            case "$_nd" in ""|\#*) continue ;; esac
            _kd="$(trim "$_kd")"
            _ns="$(trim "$_ns")"
            _ks="$(trim "$_ks")"

            if [ "$_kd" = "$_target_k_dir" ] && [ "$_ks" = "$_target_k_suf" ]; then
                _rom_ext="${_ns%.*}"
                if [ -n "$_rom_ext" ] && [ "$_rom_ext" != "$_ns" ]; then
                    for _rom_dir in "$_roms_root/$_nd" "$_roms_root"/*"($_nd)"*; do
                        if [ -d "$_rom_dir" ] && [ -f "$_rom_dir/${_game_base}${_rom_ext}" ]; then
                            echo "$LOCAL_SAVES_ROOT/$_nd/${_game_base}${_ns}"
                            return 0
                        fi
                    done
                fi
            fi
        done < "$MAPPINGS_FILE"
    fi

    echo "$LOCAL_SAVES_ROOT/$_fallback_n_dir/${_game_base}${_fallback_n_suf}"
}

# --- Backup Listing & Restore Engine (Overwrite Both Devices) ---
list_backup_timestamps() {
    if [ ! -d "$BACKUP_DIR" ]; then
        return 0
    fi
    for _f in "$BACKUP_DIR"/local_*.tar.gz "$BACKUP_DIR"/remote_*.tar.gz; do
        [ -f "$_f" ] || continue
        _b="$(basename "$_f")"
        _ts="${_b#local_}"
        _ts="${_ts#remote_}"
        _ts="${_ts%.tar.gz}"
        echo "$_ts"
    done | sort -r -u
}

format_backup_ts() {
    _raw="$1"
    echo "$_raw" | sed 's/^\([0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)_\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)$/\1-\2-\3 \4:\5:\6/'
}

get_mapped_remote_folders() {
    _folders=""
    for _cfg in "$OVERRIDES_FILE" "$MAPPINGS_FILE"; do
        [ -f "$_cfg" ] || continue
        while IFS='|' read -r _f_nextui _f_knulli _s_nextui _s_knulli || [ -n "$_f_nextui" ]; do
            _f_nextui="$(trim "$_f_nextui")"
            case "$_f_nextui" in ""|\#*) continue ;; esac
            _f_knulli="$(trim "$_f_knulli")"
            if [ -n "$_f_knulli" ]; then
                case " $_folders " in
                    *" $_f_knulli "*) ;;
                    *) _folders="$_folders $_f_knulli" ;;
                esac
            fi
        done < "$_cfg"
    done
    echo "$_folders"
}

clean_local_allowed_saves() {
    if [ -d "$LOCAL_SAVES_ROOT" ]; then
        find "$LOCAL_SAVES_ROOT" -type f | while IFS= read -r _lf; do
            if is_allowed_save_file "$(basename "$_lf")"; then
                rm -f "$_lf"
            fi
        done
    fi
}

clean_remote_allowed_saves() {
    _rem_folders="$1"
    _ext_expr=""
    for _ext in $ALLOWED_SAVE_EXTS; do
        if [ -z "$_ext_expr" ]; then
            _ext_expr="-name '*.${_ext}'"
        else
            _ext_expr="$_ext_expr -o -name '*.${_ext}'"
        fi
    done
    _remote_clean_cmd="cd '$REMOTE_SAVES_ROOT' 2>/dev/null || exit 0; for d in $_rem_folders; do [ -d \"\$d\" ] && find \"\$d\" -type f \\( $_ext_expr \\) -exec rm -f {} \\; 2>/dev/null; done; true"
    run_remote_cmd "$_remote_clean_cmd" >>"$LOG_FILE" 2>&1 || true
}

map_local_stage_to_remote_stage() {
    _src_local_root="$1"
    _dst_remote_root="$2"
    _done_keys="$STAGE_DIR/restore_mapped_loc.txt"
    : > "$_done_keys"

    if [ -f "$OVERRIDES_FILE" ]; then
        while IFS='|' read -r _n_dir _k_dir _n_file _k_file || [ -n "$_n_dir" ]; do
            _n_dir="$(trim "$_n_dir")"
            case "$_n_dir" in ""|\#*) continue ;; esac
            _k_dir="$(trim "$_k_dir")"
            _n_file="$(trim "$_n_file")"
            _k_file="$(trim "$_k_file")"

            _loc_p="$_src_local_root/$_n_dir/$_n_file"
            _rem_p="$_dst_remote_root/$_k_dir/$_k_file"
            if [ -f "$_loc_p" ]; then
                copy_save_with_mtime "$_loc_p" "$_rem_p"
                echo "LOC:$_loc_p" >> "$_done_keys"
            fi
        done < "$OVERRIDES_FILE"
    fi

    if [ -f "$MAPPINGS_FILE" ]; then
        while IFS='|' read -r _n_dir _k_dir _n_suf _k_suf || [ -n "$_n_dir" ]; do
            _n_dir="$(trim "$_n_dir")"
            case "$_n_dir" in ""|\#*) continue ;; esac
            _k_dir="$(trim "$_k_dir")"
            _n_suf="$(trim "$_n_suf")"
            _k_suf="$(trim "$_k_suf")"

            _loc_sys="$_src_local_root/$_n_dir"
            _rem_sys="$_dst_remote_root/$_k_dir"
            if [ -d "$_loc_sys" ]; then
                for _loc_f in "$_loc_sys"/*; do
                    [ -f "$_loc_f" ] || continue
                    _bname="$(basename "$_loc_f")"
                    is_allowed_save_file "$_bname" || continue
                    grep -qF "LOC:$_loc_f" "$_done_keys" 2>/dev/null && continue
                    case "$_bname" in
                        *"$_n_suf")
                            _game_base="${_bname%"$_n_suf"}"
                            [ -n "$_game_base" ] || continue
                            copy_save_with_mtime "$_loc_f" "$_rem_sys/${_game_base}${_k_suf}"
                            echo "LOC:$_loc_f" >> "$_done_keys"
                            ;;
                    esac
                done
            fi
        done < "$MAPPINGS_FILE"
    fi
}

map_remote_stage_to_local_stage() {
    _src_remote_root="$1"
    _dst_local_root="$2"
    _done_keys="$STAGE_DIR/restore_mapped_rem.txt"
    : > "$_done_keys"

    if [ -f "$OVERRIDES_FILE" ]; then
        while IFS='|' read -r _n_dir _k_dir _n_file _k_file || [ -n "$_n_dir" ]; do
            _n_dir="$(trim "$_n_dir")"
            case "$_n_dir" in ""|\#*) continue ;; esac
            _k_dir="$(trim "$_k_dir")"
            _n_file="$(trim "$_n_file")"
            _k_file="$(trim "$_k_file")"

            _loc_p="$_dst_local_root/$_n_dir/$_n_file"
            _rem_p="$_src_remote_root/$_k_dir/$_k_file"
            if [ -f "$_rem_p" ]; then
                copy_save_with_mtime "$_rem_p" "$_loc_p"
                echo "REM:$_rem_p" >> "$_done_keys"
            fi
        done < "$OVERRIDES_FILE"
    fi

    if [ -f "$MAPPINGS_FILE" ]; then
        while IFS='|' read -r _n_dir _k_dir _n_suf _k_suf || [ -n "$_n_dir" ]; do
            _n_dir="$(trim "$_n_dir")"
            case "$_n_dir" in ""|\#*) continue ;; esac
            _k_dir="$(trim "$_k_dir")"
            _n_suf="$(trim "$_n_suf")"
            _k_suf="$(trim "$_k_suf")"

            _rem_sys="$_src_remote_root/$_k_dir"
            if [ -d "$_rem_sys" ]; then
                for _rem_f in "$_rem_sys"/*; do
                    [ -f "$_rem_f" ] || continue
                    _bname="$(basename "$_rem_f")"
                    is_allowed_save_file "$_bname" || continue
                    grep -qF "REM:$_rem_f" "$_done_keys" 2>/dev/null && continue
                    case "$_bname" in
                        *"$_k_suf")
                            _game_base="${_bname%"$_k_suf"}"
                            [ -n "$_game_base" ] || continue
                            _existing_loc="$(find_existing_local_save "$_k_dir" "$_game_base" "$_k_suf")"
                            if [ -n "$_existing_loc" ]; then
                                _rel_loc="${_existing_loc#"$LOCAL_SAVES_ROOT"/}"
                                _target_loc="$_dst_local_root/$_rel_loc"
                            else
                                _best_loc="$(resolve_new_local_save_path "$_k_dir" "$_game_base" "$_k_suf" "$_n_dir" "$_n_suf")"
                                _rel_loc="${_best_loc#"$LOCAL_SAVES_ROOT"/}"
                                _target_loc="$_dst_local_root/$_rel_loc"
                            fi
                            copy_save_with_mtime "$_rem_f" "$_target_loc"
                            echo "REM:$_rem_f" >> "$_done_keys"
                            ;;
                    esac
                done
            fi
        done < "$MAPPINGS_FILE"
    fi
}

restore_backup() {
    _req_ts="${1:-latest}"
    _mode="${2:-both}"
    load_config
    ensure_binaries

    if [ "$_req_ts" = "latest" ] || [ -z "$_req_ts" ]; then
        _req_ts="$(list_backup_timestamps | head -n 1)"
    fi

    if [ -z "$_req_ts" ]; then
        show_ui_message "No backups found to restore!" 3
        log "ERROR: No backup timestamps found in $BACKUP_DIR"
        return 1
    fi

    _loc_tar="$BACKUP_DIR/local_${_req_ts}.tar.gz"
    _rem_tar="$BACKUP_DIR/remote_${_req_ts}.tar.gz"
    _pretty_ts="$(format_backup_ts "$_req_ts")"

    if [ ! -f "$_loc_tar" ] && [ ! -f "$_rem_tar" ]; then
        show_ui_message "Backup $_pretty_ts not found!" 3
        log "ERROR: Backup archives missing for $_req_ts"
        return 1
    fi

    log "=== RESTORING BACKUP $_req_ts (mode=$_mode) ==="
    show_ui_message "Connecting to $SSH_HOST for restore..." 0
    if ! init_ssh_transport; then
        show_ui_message "Failed to connect to $SSH_HOST! Opening Debug Log..." 3
        return 1
    fi

    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/savesync_restore.XXXXXX")"
    RESTORE_LOC_STAGE="$STAGE_DIR/local_saves"
    REMOTE_STAGE="$STAGE_DIR/remote_saves"
    mkdir -p "$RESTORE_LOC_STAGE" "$REMOTE_STAGE" "$LOCAL_SAVES_ROOT"

    show_ui_message "Unpacking backup ($_pretty_ts)..." 0
    case "$_mode" in
        local)
            if [ ! -f "$_loc_tar" ]; then
                log "ERROR: Local backup missing: $_loc_tar"
                rm -rf "$STAGE_DIR"; STAGE_DIR=""
                show_ui_message "Local backup archive missing!" 3
                return 1
            fi
            tar -xzf "$_loc_tar" -C "$RESTORE_LOC_STAGE" 2>>"$LOG_FILE"
            map_local_stage_to_remote_stage "$RESTORE_LOC_STAGE" "$REMOTE_STAGE"
            ;;
        remote)
            if [ ! -f "$_rem_tar" ]; then
                log "ERROR: Remote backup missing: $_rem_tar"
                rm -rf "$STAGE_DIR"; STAGE_DIR=""
                show_ui_message "Remote backup archive missing!" 3
                return 1
            fi
            tar -xzf "$_rem_tar" -C "$REMOTE_STAGE" 2>>"$LOG_FILE"
            map_remote_stage_to_local_stage "$REMOTE_STAGE" "$RESTORE_LOC_STAGE"
            ;;
        both|*)
            if [ -f "$_loc_tar" ]; then
                tar -xzf "$_loc_tar" -C "$RESTORE_LOC_STAGE" 2>>"$LOG_FILE"
            fi
            if [ -f "$_rem_tar" ]; then
                tar -xzf "$_rem_tar" -C "$REMOTE_STAGE" 2>>"$LOG_FILE"
            fi
            if [ -f "$_loc_tar" ] && [ ! -f "$_rem_tar" ]; then
                map_local_stage_to_remote_stage "$RESTORE_LOC_STAGE" "$REMOTE_STAGE"
            elif [ ! -f "$_loc_tar" ] && [ -f "$_rem_tar" ]; then
                map_remote_stage_to_local_stage "$REMOTE_STAGE" "$RESTORE_LOC_STAGE"
            fi
            ;;
    esac

    # Strip any non-allowed save files from both staging trees
    for _tree in "$RESTORE_LOC_STAGE" "$REMOTE_STAGE"; do
        find "$_tree" -type f | while IFS= read -r _f; do
            if ! is_allowed_save_file "$(basename "$_f")"; then
                rm -f "$_f"
            fi
        done
    done

    _remote_folders="$(get_mapped_remote_folders)"

    show_ui_message "Overwriting TrimUI saves ($_pretty_ts)..." 0
    log "Restoring local saves to $LOCAL_SAVES_ROOT..."
    clean_local_allowed_saves
    if [ -d "$RESTORE_LOC_STAGE" ]; then
        find "$RESTORE_LOC_STAGE" -type f | while IFS= read -r _f; do
            _rel="${_f#"$RESTORE_LOC_STAGE"/}"
            copy_save_with_mtime "$_f" "$LOCAL_SAVES_ROOT/$_rel"
        done
    fi
    _loc_restored="$(find "$LOCAL_SAVES_ROOT" -type f 2>/dev/null | wc -l | tr -d ' ')"
    log "Restored local save file(s) on TrimUI (total files: $_loc_restored)."

    show_ui_message "Overwriting Knulli saves ($SSH_HOST)..." 0
    log "Restoring remote saves to ${SSH_HOST}:${REMOTE_SAVES_ROOT}..."
    run_remote_cmd "mkdir -p '$REMOTE_SAVES_ROOT'" >>"$LOG_FILE" 2>&1 || true
    clean_remote_allowed_saves "$_remote_folders"

    if ! push_remote_saves "$_remote_folders"; then
        rm -rf "$STAGE_DIR"
        STAGE_DIR=""
        show_ui_message "Remote restore failed! Opening Debug Log..." 3
        return 1
    fi

    rm -rf "$STAGE_DIR"
    STAGE_DIR=""
    sync
    _msg="Restored Backup $_pretty_ts to Both Devices!"
    show_ui_message "$_msg" 3
    log "=== $_msg ==="
    return 0
}

run_restore_menu() {
    dismiss_ui_message
    _timestamps="$(list_backup_timestamps)"

    if [ -z "$_timestamps" ]; then
        show_ui_message "No backups found in Backups/SaveSync!" 3
        return 0
    fi

    while true; do
        _bmenu="$(mktemp "${TMPDIR:-/tmp}/savesync_bmenu.XXXXXX")"
        _bchoice="$(mktemp "${TMPDIR:-/tmp}/savesync_bchoice.XXXXXX")"
        : > "$_bmenu"

        for _ts in $_timestamps; do
            _has_loc=0
            _has_rem=0
            [ -f "$BACKUP_DIR/local_${_ts}.tar.gz" ] && _has_loc=1
            [ -f "$BACKUP_DIR/remote_${_ts}.tar.gz" ] && _has_rem=1

            if [ "$_has_loc" -eq 1 ] && [ "$_has_rem" -eq 1 ]; then
                _tag="Local+Remote"
            elif [ "$_has_loc" -eq 1 ]; then
                _tag="Local Only"
            else
                _tag="Remote Only"
            fi
            _pretty="$(format_backup_ts "$_ts")"
            echo "$_pretty ($_tag) [$_ts]" >> "$_bmenu"
        done
        echo "Back" >> "$_bmenu"

        "$LIST_BIN" \
            --file "$_bmenu" \
            --format text \
            --scroll-method wrap \
            --title "Select Backup to Restore (A: Select | B: Back)" \
            --write-location "$_bchoice" >/dev/null 2>&1
        _rc=$?

        _sel="$(cat "$_bchoice" 2>/dev/null | head -n 1 | tr -d '\r\n')"
        rm -f "$_bmenu" "$_bchoice"

        if [ "$_rc" -ne 0 ] || [ -z "$_sel" ] || [ "$_sel" = "Back" ]; then
            return 0
        fi

        _chosen_ts="$(echo "$_sel" | sed -n 's/.*\[\([0-9_]*\)\]$/\1/p')"
        if [ -z "$_chosen_ts" ]; then
            return 0
        fi

        _pretty_chosen="$(format_backup_ts "$_chosen_ts")"
        _cmenu="$(mktemp "${TMPDIR:-/tmp}/savesync_cmenu.XXXXXX")"
        _cchoice="$(mktemp "${TMPDIR:-/tmp}/savesync_cchoice.XXXXXX")"

        _has_loc=0
        _has_rem=0
        [ -f "$BACKUP_DIR/local_${_chosen_ts}.tar.gz" ] && _has_loc=1
        [ -f "$BACKUP_DIR/remote_${_chosen_ts}.tar.gz" ] && _has_rem=1

        if [ "$_has_loc" -eq 1 ] && [ "$_has_rem" -eq 1 ]; then
            cat <<EOF > "$_cmenu"
Confirm: Restore Both (Local & Remote)
Use Local Backup for Both Devices
Use Remote Backup for Both Devices
Cancel
EOF
        elif [ "$_has_loc" -eq 1 ]; then
            cat <<EOF > "$_cmenu"
Confirm: Restore Local Backup to Both Devices
Cancel
EOF
        else
            cat <<EOF > "$_cmenu"
Confirm: Restore Remote Backup to Both Devices
Cancel
EOF
        fi

        "$LIST_BIN" \
            --file "$_cmenu" \
            --format text \
            --scroll-method wrap \
            --title "Overwrite Both Devices ($_pretty_chosen)?" \
            --write-location "$_cchoice" >/dev/null 2>&1
        _crc=$?

        _csel="$(cat "$_cchoice" 2>/dev/null | head -n 1 | tr -d '\r\n')"
        rm -f "$_cmenu" "$_cchoice"

        if [ "$_crc" -ne 0 ] || [ -z "$_csel" ] || [ "$_csel" = "Cancel" ]; then
            continue
        fi

        _rmode="both"
        case "$_csel" in
            "Confirm: Restore Both"*)
                _rmode="both"
                ;;
            *"Local Backup"*)
                _rmode="local"
                ;;
            *"Remote Backup"*)
                _rmode="remote"
                ;;
        esac

        if restore_backup "$_chosen_ts" "$_rmode"; then
            return 0
        else
            view_debug_logs
            return 1
        fi
    done
}

# --- Main Entrypoint (Always opens interactive menu unless CLI flag passed) ---
case "$CLI_MODE" in
    sync)
        run_sync "sync"
        ;;
    restore)
        restore_backup "$RESTORE_TS" "$RESTORE_MODE"
        ;;
    setup-auth)
        run_connection_diagnostics
        ;;
    menu|ui|*)
        run_interactive_menu
        ;;
esac
