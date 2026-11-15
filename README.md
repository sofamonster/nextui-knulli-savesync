# SaveSync: TrimUI Brick (NextUI) <-> Anbernic RG28XX (Knulli)

A self-contained **NextUI Tool Pak (`SaveSync.pak`)** for the **TrimUI Brick (`tg5040`)** that bidirectionally synchronizes **real in-game save files** with an **Anbernic RG28XX running Knulli** over Wi-Fi using `rsync` and `ssh`, complete with an **on-device interactive UI and on-screen keyboard**.

---

## Key Features

1. **Interactive On-Device UI & On-Screen Keyboard**:
   - Powered by `minui-list`, `minui-keyboard`, and `minui-presenter` (native NextUI/MinUI `tg5040` theme-aware UI utilities).
   - Always launches directly into the interactive menu. Configure your **RG28XX IP / Hostname**, **SSH Port**, **SSH Username**, and **SSH Password** directly on the TrimUI Brick screen using the D-pad and buttons (`A` to select/type, `B` to cancel/back) without needing a computer to edit config files.
   - Includes a readable **On-Device Debug Log Viewer** that wraps long log lines into indented multi-line rows in the list view and supports pressing `A` for a small-font (`16pt`) full-screen view.
2. **Automatic SSH Login & First-Run Key Provisioning**:
   - Uses your RG28XX's built-in Knulli SSH server (`root@KNULLI.local` or IP address).
   - Automatically generates an Ed25519/RSA key pair (`SaveSync.pak/.ssh/id_save_sync`) on first launch, logs into Knulli using your configured password (`linux` by default), installs the public key into `~/.ssh/authorized_keys`, and calls `batocera-save-overlay` so passwordless login persists across RG28XX reboots.
   - Also supports password fallback via `sshpass` or `SSH_ASKPASS` if key persistence isn't used.
3. **Real In-Game Saves Only (No Save States)**:
   - Strictly syncs battery/SRAM/memory card and RTC files (`.sav`, `.srm`, `.rtc`, `.eep`, `.fla`, `.sra`, `.mcr`, `.mcd`, `.dsv`).
   - Excludes all emulator save states and metadata (`.state`, `.state*`, `.st0`, `.auto`, `.png`, `.xml`, `.cfg`).
4. **Smart System Folder & Filename Suffix Mapping**:
   - Translates between NextUI's system codes and ROM-extension save naming (`/Saves/GBA/Game.gba.sav`, `/Saves/SFC/Game.sfc.sav`) and Knulli's RetroArch folder/save naming (`/userdata/saves/gba/Game.srm`, `/userdata/saves/snes/Game.srm`).
   - When pulling a brand-new save from Knulli to NextUI for a system with multiple ROM extensions (e.g., `.sfc` vs `.smc`, or `.chd` vs `.pbp`), SaveSync inspects your `/Roms/` directory on the TrimUI Brick to match the exact ROM extension you have installed.
   - Includes `game_overrides.cfg` for per-game exact filename mapping when your ROM filenames differ between devices.
5. **Bidirectional "Newest Save Wins" Resolution**:
   - Compares modification timestamps (`mtime`) with a 2-second FAT32 tolerance window so the most recently played save on either handheld automatically updates the other.
6. **Rolling 3-Run Compressed Backups (`.tar.gz`)**:
   - Before modifying any files on either device, SaveSync creates compressed `.tar.gz` snapshots of both your **local NextUI saves** (`local_YYYYMMDD_HHMMSS.tar.gz`) and **remote Knulli saves** (`remote_YYYYMMDD_HHMMSS.tar.gz`) in `/Backups/SaveSync/` on your TrimUI SD card, automatically rotating older archives to keep the last 3 runs of each.

---

## Project Structure

```text
nextui-knulli-savesync/
├── README.md
├── fetch_ui_binaries.sh             # Helper script to pre-download tg5040 UI binaries
├── Tools/
│   └── tg5040/
│       └── SaveSync.pak/
│           ├── pak.json             # NextUI Tool Pak manifest
│           ├── launch.sh            # Main UI menu, keyboard handler, & sync script
│           ├── config.cfg           # SSH credentials, host, & backup settings
│           ├── mappings.cfg         # Folder & extension rules (NextUI <-> Knulli)
│           ├── game_overrides.cfg   # Optional per-game exact filename overrides
│           └── bin/                 # Folder for tg5040 UI binaries (minui-list, minui-keyboard, minui-presenter)
└── tests/
    └── test_sync.sh                 # Automated verification test suite
```

---

## Installation & Setup

### 1. Bundle the UI Binaries (Optional on PC, or Auto-Fetched on Device)
Before copying `SaveSync.pak` to your SD card, you can run:
```sh
./fetch_ui_binaries.sh
```
This downloads the official `tg5040-nextui` binaries (`minui-list`, `minui-keyboard`, `minui-presenter`) into `Tools/tg5040/SaveSync.pak/bin/`. *(If you skip this step, `launch.sh` will also attempt to auto-download them on first launch if the TrimUI Brick is connected to Wi-Fi.)*

### 2. Copy the Pak to your TrimUI Brick SD Card
Copy the `Tools/tg5040/SaveSync.pak` folder onto your TrimUI Brick MicroSD card at:
```text
<SD_CARD_ROOT>/Tools/tg5040/SaveSync.pak/
```

### 3. Configure & Sync Directly on the TrimUI Brick UI
1. Turn on your **RG28XX (Knulli)** and ensure Wi-Fi is connected.
2. Turn on your **TrimUI Brick (NextUI)**, navigate to **Tools -> SaveSync (Knulli)**, and press **A**.
3. Use the on-screen menu to configure or run:
   - **Sync Saves Now (`<Host>`)**: Runs the backup and bidirectional save synchronization.
   - **Restore from Backup**: Pick any of the rolling 3-run compressed backups (`YYYY-MM-DD HH:MM:SS`) to overwrite saves on **both** devices (TrimUI Brick + Knulli RG28XX) and roll back to that older state. You can choose to restore the paired backup (`Local & Remote`), apply the `Local Backup` to both devices, or apply the `Remote Backup` to both devices.
   - **RG28XX IP / Host**: Opens the on-screen keyboard to enter your RG28XX IP address (e.g. `192.168.1.50` or `KNULLI.local`).
   - **SSH Port**: Opens the on-screen keyboard to edit the SSH port (default `22`).
   - **SSH Username**: Opens the on-screen keyboard to edit the SSH username (default `root`).
   - **SSH Password**: Opens the on-screen keyboard to edit the SSH password (default `linux`).
   - **Test Connection & Diagnose**: Runs step-by-step Wi-Fi/SSH diagnostics and displays the results.
   - **Reset & Re-install SSH Keys**: Clears cached local/remote keys and reprovisions fresh SSH key authentication on your RG28XX.
   - **View Debug Log (`savesync.log`)**: Inspects the latest sync log with wrapped lines (`Up`/`Down` to scroll, `A` for small-font full-screen view, `B` to go back).
   - **Backup Remote Saves (`true` / `false`)**: Toggle whether Knulli remote saves are backed up alongside local NextUI saves.

---

## Restoring from a Backup
You can restore any of the last 3 backups directly from the TrimUI Brick screen:
1. Open **SaveSync** and select **Restore from Backup**.
2. Pick the backup timestamp you want to roll back to (`YYYY-MM-DD HH:MM:SS`).
3. Choose how to apply the backup across both devices:
   - **Confirm: Restore Both (Local & Remote)**: Restores `local_<timestamp>.tar.gz` to your TrimUI Brick and `remote_<timestamp>.tar.gz` to your Knulli RG28XX.
   - **Use Local Backup for Both Devices**: Overwrites both TrimUI and Knulli (with automatic folder/extension mapping) using the `local_<timestamp>.tar.gz` snapshot.
   - **Use Remote Backup for Both Devices**: Overwrites both Knulli and TrimUI (with automatic folder/extension mapping) using the `remote_<timestamp>.tar.gz` snapshot.

Backups are stored on your TrimUI Brick SD card at:
- `/Backups/SaveSync/local_<timestamp>.tar.gz` (NextUI `/Saves/` structure)
- `/Backups/SaveSync/remote_<timestamp>.tar.gz` (Knulli `/userdata/saves/` structure)
