#!/bin/bash
#
# mic-guard — install, configure, or uninstall
#
# One command does everything:
#   curl -fsSL https://raw.githubusercontent.com/yigitkonur/macapp-noairpodsmic/main/install.sh | bash
#
# First run:  installs mic-guard and lets you choose a mode
# Re-run:     lets you change mode or uninstall
#
set -euo pipefail

REPO_RAW="https://raw.githubusercontent.com/yigitkonur/macapp-noairpodsmic/main"
LABEL="com.local.mic-guard"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/mic-guard"
PLIST_DIR="${HOME}/Library/LaunchAgents"
PLIST_PATH="${PLIST_DIR}/${LABEL}.plist"
CONFIG_DIR="${HOME}/.config/mic-guard"
MODE_FILE="${CONFIG_DIR}/mode"
BUILD_DIR="$(mktemp -d)"

trap 'rm -rf "${BUILD_DIR}"' EXIT

# ---------- helpers ----------

info()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m  !\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31m  ✗\033[0m %s\n' "$*"; exit 1; }

# Read input from /dev/tty so it works when piped through curl | bash
ask() {
    local prompt="$1"
    printf '%s' "${prompt}"
    read -r REPLY < /dev/tty || fail "Cannot read input. Run this in a terminal."
}

# ---------- detect existing installation ----------

is_installed() {
    [[ -f "${INSTALL_PATH}" ]] && launchctl list "${LABEL}" &>/dev/null
}

current_mode() {
    if [[ -f "${MODE_FILE}" ]]; then
        cat "${MODE_FILE}" 2>/dev/null | tr -d '[:space:]'
    else
        echo "strict"
    fi
}

mode_label() {
    case "$1" in
        strict) echo "always block" ;;
        smart)  echo "respect manual override" ;;
        *)      echo "$1" ;;
    esac
}

# ---------- preflight checks ----------

info "mic-guard"
echo ""

[[ "$(uname)" == "Darwin" ]] || fail "mic-guard only runs on macOS."

MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "${MACOS_MAJOR}" -lt 12 ]]; then
    fail "Requires macOS 12 (Monterey) or later. You have $(sw_vers -productVersion)."
fi

# ---------- already installed? ----------

if is_installed; then
    MODE="$(current_mode)"
    MODE_DISPLAY="$(mode_label "${MODE}")"

    info "mic-guard is installed and running (mode: ${MODE_DISPLAY})"
    echo ""

    if [[ "${MODE}" == "strict" ]]; then
        OTHER_MODE="smart"
        OTHER_LABEL="respect manual override"
        OTHER_DESC="Blocks Bluetooth mic, but if you switch back to AirPods"
        OTHER_DESC2="within 10 seconds, mic-guard pauses for 1 hour."
    else
        OTHER_MODE="strict"
        OTHER_LABEL="always block"
        OTHER_DESC="Your Mac's built-in mic is always the default."
        OTHER_DESC2="AirPods and Bluetooth mics are never used as input."
    fi

    echo "    1) Switch to \"${OTHER_LABEL}\" mode"
    echo "       ${OTHER_DESC}"
    echo "       ${OTHER_DESC2}"
    echo ""
    echo "    2) Uninstall mic-guard"
    echo ""
    ask "    Choose [1/2]: "
    echo ""

    case "${REPLY}" in
        1)
            # Switch mode
            mkdir -p "${CONFIG_DIR}"
            echo "${OTHER_MODE}" > "${MODE_FILE}"
            ok "Mode changed to: ${OTHER_LABEL}"

            # Restart daemon to pick up new mode
            launchctl kickstart -k "gui/$(id -u)/${LABEL}" 2>/dev/null \
                || { launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
                     launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null; } \
                || true
            ok "Daemon restarted"
            echo ""
            info "Done! mic-guard is now in \"${OTHER_LABEL}\" mode."
            echo ""
            ;;
        2)
            # Uninstall
            info "Uninstalling..."
            launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null \
                || launchctl unload "${PLIST_PATH}" 2>/dev/null \
                || true
            ok "Stopped mic-guard"

            [[ -f "${PLIST_PATH}" ]] && rm "${PLIST_PATH}" && ok "Removed ${PLIST_PATH}"
            [[ -f "${INSTALL_PATH}" ]] && rm "${INSTALL_PATH}" && ok "Removed ${INSTALL_PATH}"
            [[ -d "${CONFIG_DIR}" ]] && rm -rf "${CONFIG_DIR}" && ok "Removed ${CONFIG_DIR}"

            # Legacy location
            if [[ -f "/usr/local/bin/mic-guard" ]]; then
                sudo rm "/usr/local/bin/mic-guard" 2>/dev/null \
                    || rm "/usr/local/bin/mic-guard" 2>/dev/null \
                    || true
                ok "Removed legacy /usr/local/bin/mic-guard"
            fi

            echo ""
            info "mic-guard has been completely removed."
            echo ""
            ;;
        *)
            fail "Invalid choice. Run the command again."
            ;;
    esac
    exit 0
fi

# ---------- fresh install ----------

info "How should mic-guard handle Bluetooth microphones?"
echo ""
echo "    1) Always block"
echo "       Your Mac's built-in mic is always the default."
echo "       AirPods and Bluetooth mics are never used as input."
echo ""
echo "    2) Block, but respect manual override"
echo "       Same as above, but if you switch back to AirPods"
echo "       within 10 seconds, mic-guard pauses for 1 hour"
echo "       so you can use them for a call."
echo ""
ask "    Choose [1/2]: "
echo ""

case "${REPLY}" in
    1) CHOSEN_MODE="strict" ;;
    2) CHOSEN_MODE="smart"  ;;
    *) fail "Invalid choice. Run the command again." ;;
esac

# ---------- check for Swift compiler ----------

if ! command -v swiftc &>/dev/null; then
    warn "Swift compiler not found."
    info "Installing Xcode Command Line Tools (this is a one-time Apple download)..."
    xcode-select --install 2>/dev/null || true
    echo ""
    echo "    A system dialog should appear. After installation completes,"
    echo "    re-run this command."
    echo ""
    exit 1
fi

SWIFT_VERSION="$(swiftc --version 2>&1 | head -1)"
ok "Swift compiler: ${SWIFT_VERSION}"
ok "macOS $(sw_vers -productVersion)"

# ---------- get source ----------

info "Getting source..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)" || SCRIPT_DIR=""

if [[ -n "${SCRIPT_DIR}" && -f "${SCRIPT_DIR}/main.swift" ]]; then
    cp "${SCRIPT_DIR}/main.swift" "${BUILD_DIR}/main.swift"
    ok "Using local source: ${SCRIPT_DIR}/main.swift"
else
    curl -fsSL "${REPO_RAW}/main.swift" -o "${BUILD_DIR}/main.swift" \
        || fail "Failed to download main.swift from GitHub."
    ok "Downloaded source from GitHub"
fi

# ---------- compile ----------

info "Compiling..."
swiftc -O \
    -o "${BUILD_DIR}/mic-guard" \
    "${BUILD_DIR}/main.swift" \
    -framework CoreAudio \
    -framework Foundation \
    2>&1 || fail "Compilation failed."
ok "Built mic-guard binary"

# ---------- stop existing instance (safety) ----------

if launchctl list "${LABEL}" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null \
        || launchctl unload "${PLIST_PATH}" 2>/dev/null \
        || true
    ok "Stopped existing mic-guard"
fi

# ---------- install binary ----------

info "Installing..."
mkdir -p "${INSTALL_DIR}"
cp "${BUILD_DIR}/mic-guard" "${INSTALL_PATH}"
chmod 755 "${INSTALL_PATH}"
ok "Binary: ${INSTALL_PATH}"

# ---------- write mode config ----------

mkdir -p "${CONFIG_DIR}"
echo "${CHOSEN_MODE}" > "${MODE_FILE}"
ok "Mode: $(mode_label "${CHOSEN_MODE}")"

# ---------- install launch agent ----------

mkdir -p "${PLIST_DIR}"
cat > "${PLIST_PATH}" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>Program</key>
    <string>${INSTALL_PATH}</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ProcessType</key>
    <string>Background</string>
    <key>LowPriorityBackgroundIO</key>
    <true/>
    <key>Nice</key>
    <integer>10</integer>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <key>StandardOutPath</key>
    <string>/dev/null</string>
    <key>StandardErrorPath</key>
    <string>/dev/null</string>
</dict>
</plist>
PLIST
ok "Launch agent: ${PLIST_PATH}"

# ---------- load ----------

info "Starting mic-guard..."
launchctl bootstrap "gui/$(id -u)" "${PLIST_PATH}" 2>/dev/null \
    || launchctl load "${PLIST_PATH}" 2>/dev/null \
    || fail "Failed to load launch agent."

sleep 1
if launchctl list "${LABEL}" &>/dev/null; then
    ok "mic-guard is running"
else
    fail "mic-guard failed to start. Check: log stream --predicate 'subsystem == \"${LABEL}\"'"
fi

# ---------- done ----------

CHOSEN_LABEL="$(mode_label "${CHOSEN_MODE}")"
echo ""
info "Done! mic-guard is installed (mode: ${CHOSEN_LABEL})."
echo ""
echo "    Your Mac's built-in mic is now the default input."
echo "    AirPods and other Bluetooth mics are blocked automatically."

if [[ "${CHOSEN_MODE}" == "smart" ]]; then
    echo ""
    echo "    Smart override: if mic-guard switches you back to the built-in"
    echo "    mic and you switch to AirPods again within 10 seconds,"
    echo "    mic-guard will pause for 1 hour so you can use them."
fi

echo ""
echo "    Logs:       log stream --predicate 'subsystem == \"${LABEL}\"' --style compact"
echo "    Status:     ${INSTALL_PATH} status"
echo "    Re-run this command to change mode or uninstall."
echo ""
