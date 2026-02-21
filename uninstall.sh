#!/bin/bash
#
# mic-guard uninstaller
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/yigitkonur/cli-disablemic/main/uninstall.sh | bash
#   — or —
#   ./uninstall.sh
#
set -euo pipefail

LABEL="com.local.mic-guard"
INSTALL_PATH="${HOME}/.local/bin/mic-guard"
PLIST_PATH="${HOME}/Library/LaunchAgents/${LABEL}.plist"
CONFIG_DIR="${HOME}/.config/mic-guard"

info()  { printf '\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$*"; }
ok()    { printf '\033[1;32m  ✓\033[0m %s\n' "$*"; }

info "mic-guard uninstaller"
echo ""

# Stop the agent
if launchctl list "${LABEL}" &>/dev/null; then
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null \
        || launchctl unload "${PLIST_PATH}" 2>/dev/null \
        || true
    ok "Stopped mic-guard"
else
    ok "mic-guard was not running"
fi

# Remove plist
if [[ -f "${PLIST_PATH}" ]]; then
    rm "${PLIST_PATH}"
    ok "Removed ${PLIST_PATH}"
fi

# Remove binary
if [[ -f "${INSTALL_PATH}" ]]; then
    rm "${INSTALL_PATH}"
    ok "Removed ${INSTALL_PATH}"
fi

# Remove config directory
if [[ -d "${CONFIG_DIR}" ]]; then
    rm -rf "${CONFIG_DIR}"
    ok "Removed ${CONFIG_DIR}"
fi

# Also check legacy /usr/local/bin location
if [[ -f "/usr/local/bin/mic-guard" ]]; then
    sudo rm "/usr/local/bin/mic-guard" 2>/dev/null || rm "/usr/local/bin/mic-guard" 2>/dev/null || true
    ok "Removed legacy /usr/local/bin/mic-guard"
fi

echo ""
info "mic-guard has been completely removed."
echo ""
