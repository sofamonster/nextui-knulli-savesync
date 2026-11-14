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
    STARTUP_MODE="${STARTUP_MODE:-menu}"
    BACKUP_KEEP_COUNT="${BACKUP_KEEP_COUNT:-3}"
    BACKUP_REMOTE="${BACKUP_REMOTE:-true}"
    DRY_RUN="${DRY_RUN:-false}"
    ALLOWED_SAVE_EXTS="${ALLOWED_SAVE_EXTS:-sav srm rtc eep fla sra mcr mcd dsv}"
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

# Allow CLI flag overrides (e.g., ./launch.sh --sync, --menu, --dry-run, --setup-auth)
CLI_MODE=""
for arg in "$@"; do
    case "$arg" in
        --sync)
            CLI_MODE="sync"
            ;;
        --menu|--ui)
            CLI_MODE="menu"
            ;;
        --dry-run|-n)
            DRY_RUN="true"
            ;;
        --setup-auth)
            CLI_MODE="setup-auth"
            ;;
    esac
done

# Initialize log file
mkdir -p "$(dirname "$LOG_FILE")"
: > "$LOG_FILE"

log() {
    _ts="$(date '+%Y-%m-%d %H:%M:%S')"
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

# Auto-fetch UI helper binaries and static rsync on first launch if missing and internet is reachable
ensure_binaries() {
    # Ensure NextUI .media and .res icon previews exist for SaveSync in Tools/tg5040/
    if [ -f "$PAK_DIR/icon.png" ]; then
        _tools_parent="$(dirname "$PAK_DIR")"
        for _art_dir in "$_tools_parent/.media" "$_tools_parent/.res"; do
            mkdir -p "$_art_dir" 2>/dev/null || true
            [ -f "$_art_dir/SaveSync.png" ] || cp "$PAK_DIR/icon.png" "$_art_dir/SaveSync.png" 2>/dev/null || true
            [ -f "$_art_dir/SaveSync.pak.png" ] || cp "$PAK_DIR/icon.png" "$_art_dir/SaveSync.pak.png" 2>/dev/null || true
        done
    fi

    mkdir -p "$PAK_DIR/bin"
    if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
        return 0
    fi

    # 1. Fetch static aarch64 rsync if rsync is not installed on TrimUI
    if ! command -v rsync >/dev/null 2>&1; then
        _rsync_dest="$PAK_DIR/bin/rsync"
        _rsync_url="https://raw.githubusercontent.com/ryanwoodsmall/static-binaries/master/aarch64/rsync"
        log "Attempting to auto-download static aarch64 rsync binary..."
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL -L --connect-timeout 5 "$_rsync_url" -o "$_rsync_dest" 2>/dev/null || true
        elif command -v wget >/dev/null 2>&1; then
            wget -q -T 5 -O "$_rsync_dest" "$_rsync_url" 2>/dev/null || true
        fi
        if [ -s "$_rsync_dest" ]; then
            chmod +x "$_rsync_dest"
            log "Installed static rsync binary to $_rsync_dest"
        else
            rm -f "$_rsync_dest"
        fi
    fi

    # 2. Fetch NextUI UI binaries if missing
    if [ -z "$LIST_BIN" ] || [ -z "$KEYBOARD_BIN" ]; then
        for _pair in "josegonzalez/minui-list:minui-list" "josegonzalez/minui-keyboard:minui-keyboard" "josegonzalez/minui-presenter:minui-presenter"; do
            _repo="${_pair%%:*}"
            _name="${_pair##*:}"
            _dest="$PAK_DIR/bin/$_name"
            [ -x "$_dest" ] && continue
            _url="https://github.com/${_repo}/releases/latest/download/${_name}-${PLATFORM}-nextui"
            if command -v curl >/dev/null 2>&1; then
                curl -fsSL -L --connect-timeout 4 "$_url" -o "$_dest" 2>/dev/null || true
            elif command -v wget >/dev/null 2>&1; then
                wget -q -T 4 -O "$_dest" "$_url" 2>/dev/null || true
            fi
            if [ -s "$_dest" ]; then
                chmod +x "$_dest"
            else
                rm -f "$_dest"
            fi
        done
        PRESENTER_BIN="$(find_ui_binary minui-presenter || true)"
        LIST_BIN="$(find_ui_binary minui-list || true)"
        KEYBOARD_BIN="$(find_ui_binary minui-keyboard || true)"
    fi
}

# --- On-Screen Display Helper ---
show_ui_message() {
    _msg="$1"
    _timeout="${2:-0}" # 0 = stay on screen in background, >0 = wait N seconds
    log "UI: $_msg"

    if [ -n "$PRESENTER_BIN" ]; then
        killall "$(basename "$PRESENTER_BIN")" >/dev/null 2>&1 || true
        if [ "$_timeout" -gt 0 ] 2>/dev/null; then
            "$PRESENTER_BIN" --message "$_msg" --timeout "$_timeout" >/dev/null 2>&1 || true
        else
            "$PRESENTER_BIN" --message "$_msg" --timeout -1 >/dev/null 2>&1 &
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
Dry-Run Sync (Test Only)
RG28XX IP / Host: $SSH_HOST
SSH Port: $SSH_PORT
SSH Username: $SSH_USER
SSH Password: $_pw_masked
Test & Setup SSH Key Auth
Startup Mode: $STARTUP_MODE
Backup Remote Saves: $BACKUP_REMOTE
Exit
EOF

        "$LIST_BIN" \
            --file "$_menu_file" \
            --format text \
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
                DRY_RUN="false"
                run_sync "sync" || true
                ;;
            "Dry-Run Sync"*)
                DRY_RUN="true"
                run_sync "sync" || true
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
            "Test & Setup SSH Key Auth")
                run_sync "setup-auth" || true
                ;;
            "Startup Mode:"*)
                if [ "$STARTUP_MODE" = "menu" ]; then
                    save_config_value "STARTUP_MODE" "auto"
                    show_ui_message "Startup Mode: auto (sync immediately)" 2
                else
                    save_config_value "STARTUP_MODE" "menu"
                    show_ui_message "Startup Mode: menu (show UI on launch)" 2
                fi
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

# --- SSH / Rsync / Tar-over-SSH Transport Layer ---
SSH_CMD=""
RSYNC_RSH=""

setup_ssh_keys() {
    _key_dir="$(dirname "$SSH_KEY_PATH")"
    mkdir -p "$_key_dir"
    chmod 700 "$_key_dir"

    if [ ! -f "$SSH_KEY_PATH" ]; then
        log "Generating new SSH key at $SSH_KEY_PATH..."
        if command -v ssh-keygen >/dev/null 2>&1; then
            ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -q 2>>"$LOG_FILE" || \
            ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_PATH" -N "" -q 2>>"$LOG_FILE"
        elif command -v dropbearkey >/dev/null 2>&1; then
            dropbearkey -t ed25519 -f "$SSH_KEY_PATH" >>"$LOG_FILE" 2>&1
            dropbearkey -y -f "$SSH_KEY_PATH" | grep "^ssh-" > "${SSH_KEY_PATH}.pub"
        else
            log "ERROR: Neither ssh-keygen nor dropbearkey found to generate keys."
            return 1
        fi
        chmod 600 "$SSH_KEY_PATH"
    fi

    if [ ! -f "${SSH_KEY_PATH}.pub" ]; then
        if command -v ssh-keygen >/dev/null 2>&1; then
            ssh-keygen -y -f "$SSH_KEY_PATH" > "${SSH_KEY_PATH}.pub" 2>>"$LOG_FILE"
        elif command -v dropbearkey >/dev/null 2>&1; then
            dropbearkey -y -f "$SSH_KEY_PATH" | grep "^ssh-" > "${SSH_KEY_PATH}.pub"
        fi
    fi

    _pub_key="$(cat "${SSH_KEY_PATH}.pub" 2>/dev/null || true)"
    if [ -z "$_pub_key" ]; then
        log "ERROR: Failed to read public key ${SSH_KEY_PATH}.pub"
        return 1
    fi

    _remote_install_cmd="mkdir -p ~/.ssh && chmod 700 ~/.ssh && grep -qF '$_pub_key' ~/.ssh/authorized_keys 2>/dev/null || echo '$_pub_key' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && (batocera-save-overlay >/dev/null 2>&1 || true)"

    if ssh -p "$SSH_PORT" -i "$SSH_KEY_PATH" -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" "${SSH_USER}@${SSH_HOST}" "true" >/dev/null 2>&1; then
        log "SSH key authentication already working."
        return 0
    fi

    log "Attempting automatic SSH key deployment to ${SSH_USER}@${SSH_HOST}..."
    if command -v sshpass >/dev/null 2>&1 && [ -n "$SSH_PASSWORD" ]; then
        if SSHPASS="$SSH_PASSWORD" sshpass -e ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" "${SSH_USER}@${SSH_HOST}" "$_remote_install_cmd" >>"$LOG_FILE" 2>&1; then
            log "Successfully installed SSH public key to Knulli host via sshpass."
            return 0
        fi
    fi

    if [ -n "$SSH_PASSWORD" ]; then
        _askpass_script="$PAK_DIR/.ssh/askpass.sh"
        printf "#!/bin/sh\necho '%s'\n" "$SSH_PASSWORD" > "$_askpass_script"
        chmod 700 "$_askpass_script"
        if DISPLAY=":0" SSH_ASKPASS="$_askpass_script" SSH_ASKPASS_REQUIRE=force setsid ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout="$SSH_TIMEOUT" "${SSH_USER}@${SSH_HOST}" "$_remote_install_cmd" </dev/null >>"$LOG_FILE" 2>&1; then
            rm -f "$_askpass_script"
            log "Successfully installed SSH public key to Knulli host via SSH_ASKPASS."
            return 0
        fi
        rm -f "$_askpass_script"
    fi

    log "WARNING: Could not automatically copy SSH key without sshpass/SSH_ASKPASS."
    return 1
}

init_ssh_transport() {
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    chmod 700 "$(dirname "$SSH_KEY_PATH")"

    _base_ssh_opts="-p $SSH_PORT -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=$SSH_TIMEOUT"

    # 1. Check if key auth works right now
    if [ -f "$SSH_KEY_PATH" ]; then
        chmod 600 "$SSH_KEY_PATH" 2>/dev/null || true
        if ssh $_base_ssh_opts -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" "echo ok" >/dev/null 2>&1; then
            SSH_CMD="ssh $_base_ssh_opts -i \"$SSH_KEY_PATH\" -o BatchMode=yes"
            RSYNC_RSH="ssh $_base_ssh_opts -i $SSH_KEY_PATH -o BatchMode=yes"
            log "Connected to ${SSH_HOST} using SSH key ($SSH_KEY_PATH)."
            return 0
        fi
    fi

    # 2. Try auto-provisioning SSH key
    show_ui_message "Setting up SSH auth with $SSH_HOST..." 0
    if setup_ssh_keys; then
        if ssh $_base_ssh_opts -i "$SSH_KEY_PATH" -o BatchMode=yes "${SSH_USER}@${SSH_HOST}" "echo ok" >/dev/null 2>&1; then
            SSH_CMD="ssh $_base_ssh_opts -i \"$SSH_KEY_PATH\" -o BatchMode=yes"
            RSYNC_RSH="ssh $_base_ssh_opts -i $SSH_KEY_PATH -o BatchMode=yes"
            log "Connected to ${SSH_HOST} using newly provisioned SSH key."
            return 0
        fi
    fi

    # 3. Fallback to sshpass directly for all operations if key auth failed
    if command -v sshpass >/dev/null 2>&1 && [ -n "$SSH_PASSWORD" ]; then
        export SSHPASS="$SSH_PASSWORD"
        if sshpass -e ssh $_base_ssh_opts "${SSH_USER}@${SSH_HOST}" "echo ok" >/dev/null 2>&1; then
            SSH_CMD="sshpass -e ssh $_base_ssh_opts"
            RSYNC_RSH="sshpass -e ssh $_base_ssh_opts"
            log "Connected to ${SSH_HOST} using sshpass password authentication."
            return 0
        fi
    fi

    # 4. Fallback to SSH_ASKPASS wrapper if setsid + SSH_ASKPASS works
    if [ -n "$SSH_PASSWORD" ]; then
        _askpass_script="$PAK_DIR/.ssh/askpass.sh"
        printf "#!/bin/sh\necho '%s'\n" "$SSH_PASSWORD" > "$_askpass_script"
        chmod 700 "$_askpass_script"
        _ssh_wrap="$PAK_DIR/.ssh/ssh_wrap.sh"
        cat <<EOF > "$_ssh_wrap"
#!/bin/sh
export DISPLAY=":0"
export SSH_ASKPASS="$_askpass_script"
export SSH_ASKPASS_REQUIRE="force"
exec setsid ssh $_base_ssh_opts "\$@" </dev/null
EOF
        chmod 700 "$_ssh_wrap"
        if "$_ssh_wrap" "${SSH_USER}@${SSH_HOST}" "echo ok" >/dev/null 2>&1; then
            SSH_CMD="\"$_ssh_wrap\""
            RSYNC_RSH="$_ssh_wrap"
            log "Connected to ${SSH_HOST} using SSH_ASKPASS wrapper."
            return 0
        fi
    fi

    log "ERROR: Unable to connect or authenticate to ${SSH_USER}@${SSH_HOST}:${SSH_PORT}."
    return 1
}

# --- Remote Pull & Push Helpers (Supports Rsync OR Built-in Tar-over-SSH Fallback) ---
# Pulls mapped system folders from Knulli into $REMOTE_STAGE
pull_remote_saves() {
    _remote_folders="$1"
    _filter_args="$(build_rsync_filter_args)"

    if command -v rsync >/dev/null 2>&1; then
        log "Using rsync transport to pull remote saves..."
        for _k_folder in $_remote_folders; do
            mkdir -p "$REMOTE_STAGE/$_k_folder"
            # shellcheck disable=SC2086
            rsync -rtz --modify-window=2 $_filter_args \
                -e "$RSYNC_RSH" \
                "${SSH_USER}@${SSH_HOST}:${REMOTE_SAVES_ROOT}/${_k_folder}/" \
                "$REMOTE_STAGE/$_k_folder/" >>"$LOG_FILE" 2>&1 || true
        done
    else
        log "rsync binary not present locally; using native tar-over-SSH transport to pull saves..."
        # Create folder directories locally and stream existing remote folders via tar over SSH
        for _k_folder in $_remote_folders; do
            mkdir -p "$REMOTE_STAGE/$_k_folder"
        done
        eval "$SSH_CMD \"${SSH_USER}@${SSH_HOST}\" \"tar -cf - -C '$REMOTE_SAVES_ROOT' --ignore-failed-read --exclude='*.state*' --exclude='*.st[0-9]*' --exclude='*.auto' --exclude='*.png' --exclude='*.jpg' --exclude='*.bmp' --exclude='*.txt' --exclude='*.xml' --exclude='*.cfg' $_remote_folders 2>/dev/null || tar -cf - -C '$REMOTE_SAVES_ROOT' . 2>/dev/null\"" | tar -xf - -p -C "$REMOTE_STAGE" 2>>"$LOG_FILE" || true
    fi
}

# Pushes updated saves in $REMOTE_STAGE back to Knulli
push_remote_saves() {
    _remote_folders="$1"
    _filter_args="$(build_rsync_filter_args)"

    if command -v rsync >/dev/null 2>&1; then
        log "Using rsync transport to push updated saves..."
        for _k_folder in $_remote_folders; do
            if [ -d "$REMOTE_STAGE/$_k_folder" ] && [ -n "$(ls -A "$REMOTE_STAGE/$_k_folder" 2>/dev/null)" ]; then
                # shellcheck disable=SC2086
                rsync -rtz --modify-window=2 -u $_filter_args \
                    -e "$RSYNC_RSH" \
                    "$REMOTE_STAGE/$_k_folder/" \
                    "${SSH_USER}@${SSH_HOST}:${REMOTE_SAVES_ROOT}/${_k_folder}/" >>"$LOG_FILE" 2>&1
            fi
        done
    else
        log "rsync binary not present locally; using native tar-over-SSH transport to push saves..."
        _dirs_to_push=""
        for _k_folder in $_remote_folders; do
            if [ -d "$REMOTE_STAGE/$_k_folder" ] && [ -n "$(ls -A "$REMOTE_STAGE/$_k_folder" 2>/dev/null)" ]; then
                _dirs_to_push="$_dirs_to_push $_k_folder"
            fi
        done
        if [ -n "$_dirs_to_push" ]; then
            # shellcheck disable=SC2086
            tar -cf - -C "$REMOTE_STAGE" $_dirs_to_push 2>>"$LOG_FILE" | \
                eval "$SSH_CMD \"${SSH_USER}@${SSH_HOST}\" \"mkdir -p '$REMOTE_SAVES_ROOT' && tar -xf - -p -C '$REMOTE_SAVES_ROOT'\"" >>"$LOG_FILE" 2>&1
        fi
    fi
}

# --- Backup & Rotation Functions (Keep Last N Compressed Backups) ---
rotate_backups() {
    _prefix="$1"
    _keep="$BACKUP_KEEP_COUNT"

    _count=0
    for _archive in $(ls -1r "$BACKUP_DIR/${_prefix}_"*.tar.gz 2>/dev/null || true); do
        _count=$((_count + 1))
        if [ "$_count" -gt "$_keep" ]; then
            log "Rotating old backup: removing $(basename "$_archive")"
            rm -f "$_archive"
        fi
    done
}

create_backups() {
    _run_ts="$1"
    _remote_stage_raw="$2"

    mkdir -p "$BACKUP_DIR"

    if [ -d "$LOCAL_SAVES_ROOT" ]; then
        _local_archive="$BACKUP_DIR/local_${_run_ts}.tar.gz"
        log "Creating compressed local backup: $_local_archive"
        tar -czf "$_local_archive" \
            --exclude="*.state*" \
            --exclude="*.st[0-9]*" \
            --exclude="*.auto" \
            --exclude="*.png" \
            -C "$LOCAL_SAVES_ROOT" . >>"$LOG_FILE" 2>&1 || true
        rotate_backups "local"
    fi

    if [ "$BACKUP_REMOTE" = "true" ] && [ -d "$_remote_stage_raw" ]; then
        _remote_archive="$BACKUP_DIR/remote_${_run_ts}.tar.gz"
        log "Creating compressed remote backup: $_remote_archive"
        tar -czf "$_remote_archive" \
            --exclude="*.state*" \
            --exclude="*.st[0-9]*" \
            --exclude="*.auto" \
            --exclude="*.png" \
            -C "$_remote_stage_raw" . >>"$LOG_FILE" 2>&1 || true
        rotate_backups "remote"
    fi
}

# --- Core Mapping & Bidirectional Sync Engine ---
build_rsync_filter_args() {
    _args="--exclude=*.state --exclude=*.state* --exclude=*.st[0-9]* --exclude=*.auto --exclude=*.png --exclude=*.jpg --exclude=*.bmp --exclude=*.txt --exclude=*.xml --exclude=*.cfg --exclude=.*"
    echo "$_args"
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

    if [ "$_loc_exists" -eq 1 ] && [ "$_rem_exists" -eq 0 ]; then
        log "[PUSH NEW] $_label: NextUI -> Knulli ($(basename "$_loc_file") -> $(basename "$_rem_file"))"
        if [ "$DRY_RUN" != "true" ]; then
            mkdir -p "$(dirname "$_rem_file")"
            cp -p "$_loc_file" "$_rem_file"
        fi
        PUSH_COUNT=$((PUSH_COUNT + 1))
        return 0
    fi

    if [ "$_loc_exists" -eq 0 ] && [ "$_rem_exists" -eq 1 ]; then
        log "[PULL NEW] $_label: Knulli -> NextUI ($(basename "$_rem_file") -> $(basename "$_loc_file"))"
        if [ "$DRY_RUN" != "true" ]; then
            mkdir -p "$(dirname "$_loc_file")"
            cp -p "$_rem_file" "$_loc_file"
        fi
        PULL_COUNT=$((PULL_COUNT + 1))
        return 0
    fi

    if cmp -s "$_loc_file" "$_rem_file"; then
        return 0
    fi

    _loc_mtime="$(get_mtime "$_loc_file")"
    _rem_mtime="$(get_mtime "$_rem_file")"
    _diff=$((_loc_mtime - _rem_mtime))

    if [ "$_diff" -gt 2 ]; then
        log "[PUSH UPDATE] $_label: NextUI is newer ($_loc_mtime > $_rem_mtime) -> updating Knulli ($(basename "$_rem_file"))"
        if [ "$DRY_RUN" != "true" ]; then
            cp -p "$_loc_file" "$_rem_file"
        fi
        PUSH_COUNT=$((PUSH_COUNT + 1))
    elif [ "$_diff" -lt -2 ]; then
        log "[PULL UPDATE] $_label: Knulli is newer ($_rem_mtime > $_loc_mtime) -> updating NextUI ($(basename "$_loc_file"))"
        if [ "$DRY_RUN" != "true" ]; then
            cp -p "$_rem_file" "$_loc_file"
        fi
        PULL_COUNT=$((PULL_COUNT + 1))
    else
        log "[SKIP] $_label: Timestamps within 2s tolerance ($_loc_mtime vs $_rem_mtime), keeping both as-is."
    fi
}

run_sync() {
    _action="${1:-sync}"
    load_config
    ensure_binaries

    show_ui_message "Connecting to $SSH_HOST..." 0
    if ! init_ssh_transport; then
        show_ui_message "Failed to connect to $SSH_HOST! Check IP/User/Pass." 4
        return 1
    fi

    if [ "$_action" = "setup-auth" ]; then
        show_ui_message "SSH Auth Verified with $SSH_HOST!" 3
        return 0
    fi

    STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/savesync_stage.XXXXXX")"
    REMOTE_STAGE="$STAGE_DIR/remote_saves"
    PROCESSED_KEYS_FILE="$STAGE_DIR/processed_pairs.txt"
    mkdir -p "$REMOTE_STAGE" "$LOCAL_SAVES_ROOT"
    : > "$PROCESSED_KEYS_FILE"

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
    log "Pulling remote saves from ${SSH_USER}@${SSH_HOST}:${REMOTE_SAVES_ROOT} into staging..."

    eval "$SSH_CMD \"${SSH_USER}@${SSH_HOST}\" \"mkdir -p '$REMOTE_SAVES_ROOT'\"" >>"$LOG_FILE" 2>&1 || true

    pull_remote_saves "$_remote_folders"

    find "$REMOTE_STAGE" -type f | while IFS= read -r _rf; do
        if ! is_allowed_save_file "$(basename "$_rf")"; then
            rm -f "$_rf"
        fi
    done

    RUN_TS="$(date '+%Y%m%d_%H%M%S')"
    if [ "$DRY_RUN" != "true" ]; then
        show_ui_message "Creating rolling backup ($RUN_TS)..." 0
        create_backups "$RUN_TS" "$REMOTE_STAGE"
    else
        log "[DRY-RUN] Skipping backup archive creation."
    fi

    show_ui_message "Synchronizing mapped saves..." 0
    PUSH_COUNT=0
    PULL_COUNT=0

    if [ -f "$OVERRIDES_FILE" ]; then
        while IFS='|' read -r _n_dir _k_dir _n_file _k_file || [ -n "$_n_dir" ]; do
            _n_dir="$(trim "$_n_dir")"
            case "$_n_dir" in ""|\#*) continue ;; esac
            _k_dir="$(trim "$_k_dir")"
            _n_file="$(trim "$_n_file")"
            _k_file="$(trim "$_k_file")"

            _loc_path="$LOCAL_SAVES_ROOT/$_n_dir/$_n_file"
            _rem_path="$REMOTE_STAGE/$_k_dir/$_k_file"

            sync_file_pair "$_loc_path" "$_rem_path" "Override($_n_dir<->$_k_dir)"
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

                            sync_file_pair "$_loc_f" "$_target_rem_f" "$_n_dir<->$_k_dir"
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
                                sync_file_pair "$_existing_loc" "$_rem_f" "$_n_dir<->$_k_dir"
                                echo "LOC:$_existing_loc" >> "$PROCESSED_KEYS_FILE"
                                echo "REM:$_rem_f" >> "$PROCESSED_KEYS_FILE"
                            else
                                _best_loc="$(resolve_new_local_save_path "$_k_dir" "$_game_base" "$_k_suf" "$_n_dir" "$_n_suf")"
                                sync_file_pair "$_best_loc" "$_rem_f" "$_n_dir<->$_k_dir"
                                echo "LOC:$_best_loc" >> "$PROCESSED_KEYS_FILE"
                                echo "REM:$_rem_f" >> "$PROCESSED_KEYS_FILE"
                            fi
                            ;;
                    esac
                done
            fi
        done < "$MAPPINGS_FILE"
    fi

    if [ "$DRY_RUN" != "true" ] && [ "$PUSH_COUNT" -gt 0 ]; then
        show_ui_message "Uploading $PUSH_COUNT save(s) to Knulli..." 0
        log "Pushing $PUSH_COUNT updated save(s) to ${SSH_USER}@${SSH_HOST}:${REMOTE_SAVES_ROOT}..."
        push_remote_saves "$_remote_folders"
    fi

    rm -rf "$STAGE_DIR"
    STAGE_DIR=""
    sync
    _summary="Sync Complete! Pulled: $PULL_COUNT | Pushed: $PUSH_COUNT"
    [ "$DRY_RUN" = "true" ] && _summary="[DRY RUN] Pulled: $PULL_COUNT | Pushed: $PUSH_COUNT"
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

# --- Main Entrypoint ---
EFFECTIVE_MODE="${CLI_MODE:-$STARTUP_MODE}"
case "$EFFECTIVE_MODE" in
    menu|ui)
        run_interactive_menu
        ;;
    setup-auth)
        run_sync "setup-auth"
        ;;
    sync|auto|*)
        if ! run_sync "sync"; then
            if [ -n "$LIST_BIN" ]; then
                run_interactive_menu
            else
                exit 1
            fi
        fi
        ;;
esac
