#!/bin/sh
# disable-victron-bluetooth.sh — Disable Victron's built-in BLE services on Venus OS
# Version: 1.0.0
#
# Copyright 2026 TechBlueprints
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Disables the two Victron Venus OS services that interfere with third-party
# BLE services:
#
#   1. dbus-ble-sensors  — Raw HCI scanning corrupts BlueZ discovery state,
#                          causing InProgress errors for all other BLE services.
#   2. vesmart-server    — Forcibly disconnects ALL BLE devices every ~60s and
#                          runs its own scan cycle causing further collisions.
#
# For each service this script will:
#   - Disable the service in the Venus OS UI via D-Bus settings
#   - Stop the service if running
#   - Make run/start scripts non-executable (prevents restart by daemontools
#     and by the bt-config udev hotplug script)
#
# The root partition is read-only on Venus OS. This script temporarily
# remounts it read-write to modify service scripts, then restores it.
# The /service/ directory is tmpfs (repopulated from /opt at boot), so
# both the live copies and the source templates must be modified.
#
# Usage:
#   sh disable-victron-bluetooth.sh           # disable both services
#   sh disable-victron-bluetooth.sh --restore # re-enable both services
#
# Can also be sourced and called as functions:
#   . ./disable-victron-bluetooth.sh
#   disable_victron_ble              # disable both
#   restore_victron_ble              # re-enable both
#   disable_service dbus-ble-sensors # disable one service

VERSION="1.0.0"
SERVICES="dbus-ble-sensors vesmart-server"
STATE_FILE="/data/disable-victron-bluetooth.state"

_log() { echo "[disable-victron-bt] $*"; }

is_venus_os() {
    [ -f /opt/victronenergy/version ]
}

_require_venus_os() {
    if ! is_venus_os; then
        _log "ERROR: This does not appear to be a Venus OS system."
        _log "       /opt/victronenergy/version not found."
        return 1
    fi
}

_is_root_ro() {
    grep -q ' / .*\bro\b' /proc/mounts
}

_DVB_DID_REMOUNT=0

_remount_root_rw() {
    if _is_root_ro; then
        _log "Remounting root filesystem read-write"
        if mount -o remount,rw / 2>/dev/null; then
            _DVB_DID_REMOUNT=1
        else
            _log "WARNING: Failed to remount root read-write."
            _log "         Scripts on the read-only root partition will not be modified."
            _log "         Changes may not persist across reboots."
        fi
    fi
}

_restore_root_ro() {
    if [ "$_DVB_DID_REMOUNT" = 1 ]; then
        _log "Restoring root filesystem to read-only"
        if ! mount -o remount,ro / 2>/dev/null; then
            _log "WARNING: Failed to restore root to read-only."
            _log "         Run 'mount -o remount,ro /' manually."
        fi
        _DVB_DID_REMOUNT=0
    fi
}

_cleanup() {
    _restore_root_ro
}

_is_service_up() {
    svstat "/service/$1" 2>/dev/null | grep -q ': up'
}

_dbus_set() {
    dbus-send --print-reply=literal --system --type=method_call \
        --dest=com.victronenergy.settings "$1" \
        com.victronenergy.BusItem.SetValue "variant:int32:$2" >/dev/null 2>&1
}

_dbus_get() {
    dbus-send --print-reply=literal --system --type=method_call \
        --dest=com.victronenergy.settings "$1" \
        com.victronenergy.BusItem.GetValue 2>/dev/null | \
        awk '/int32/ { print $3 }'
}

_all_scripts() {
    svc_name="$1"
    # Live copies (tmpfs, repopulated from /opt at boot)
    echo "/service/$svc_name/run"
    # Source templates (read-only root or overlay — persists across reboots)
    echo "/opt/victronenergy/service/$svc_name/run"
    echo "/opt/victronenergy/service-templates/$svc_name/run"
    # Start scripts invoked by the run scripts
    echo "/opt/victronenergy/$svc_name/start-ble-sensors.sh"
    echo "/opt/victronenergy/$svc_name/$svc_name.sh"
}

disable_service() {
    svc_name="$1"
    _log "Disabling $svc_name"

    if _is_service_up "$svc_name"; then
        _log "  Stopping $svc_name"
        svc -d "/service/$svc_name" 2>/dev/null
    fi

    for script in $(_all_scripts "$svc_name"); do
        if [ -x "$script" ]; then
            _log "  Making non-executable: $script"
            chmod a-x "$script" 2>/dev/null || \
                _log "  WARNING: Could not chmod $script (read-only filesystem?)"
        fi
    done

    _log "  $svc_name disabled"
}

restore_service() {
    svc_name="$1"
    _log "Restoring $svc_name"

    for script in $(_all_scripts "$svc_name"); do
        if [ -f "$script" ] && [ ! -x "$script" ]; then
            _log "  Making executable: $script"
            chmod a+x "$script" 2>/dev/null || \
                _log "  WARNING: Could not chmod $script (read-only filesystem?)"
        fi
    done

    if [ -d "/service/$svc_name" ]; then
        _log "  Starting $svc_name"
        svc -u "/service/$svc_name" 2>/dev/null
    fi

    _log "  $svc_name restored"
}

_save_settings() {
    prev_ble=$(_dbus_get /Settings/Services/BleSensors)
    prev_bt=$(_dbus_get /Settings/Services/Bluetooth)

    if [ -n "$prev_ble" ] || [ -n "$prev_bt" ]; then
        _log "Saving previous settings to $STATE_FILE"
        echo "BleSensors=${prev_ble:-1}" > "$STATE_FILE"
        echo "Bluetooth=${prev_bt:-1}" >> "$STATE_FILE"
    else
        _log "WARNING: Could not read current settings (localsettings not running?)"
    fi
}

_read_saved_setting() {
    if [ -f "$STATE_FILE" ]; then
        value=$(grep "^$1=" "$STATE_FILE" 2>/dev/null | cut -d= -f2)
    fi
    echo "${value:-$2}"
}

disable_victron_ble() {
    _require_venus_os || return 1

    _save_settings

    _log "Disabling BLE Sensors in Venus OS settings"
    _dbus_set /Settings/Services/BleSensors 0 || \
        _log "WARNING: Could not update BleSensors setting (localsettings not running?)"

    _log "Disabling Bluetooth in Venus OS settings"
    _dbus_set /Settings/Services/Bluetooth 0 || \
        _log "WARNING: Could not update Bluetooth setting (localsettings not running?)"

    _remount_root_rw
    trap _cleanup EXIT
    for svc_name in $SERVICES; do
        disable_service "$svc_name"
    done
    _restore_root_ro
    trap - EXIT
}

restore_victron_ble() {
    _require_venus_os || return 1

    restore_ble=$(_read_saved_setting BleSensors 1)
    restore_bt=$(_read_saved_setting Bluetooth 1)

    _log "Restoring BLE Sensors setting to $restore_ble"
    _dbus_set /Settings/Services/BleSensors "$restore_ble" || \
        _log "WARNING: Could not update BleSensors setting (localsettings not running?)"

    _log "Restoring Bluetooth setting to $restore_bt"
    _dbus_set /Settings/Services/Bluetooth "$restore_bt" || \
        _log "WARNING: Could not update Bluetooth setting (localsettings not running?)"

    _remount_root_rw
    trap _cleanup EXIT
    for svc_name in $SERVICES; do
        restore_service "$svc_name"
    done
    _restore_root_ro
    trap - EXIT

    if [ -f "$STATE_FILE" ]; then
        rm -f "$STATE_FILE"
    fi
}

_main() {
    case "${1:-}" in
        --restore|-r)
            restore_victron_ble
            ;;
        --version|-v|-V)
            echo "disable-victron-bluetooth $VERSION"
            ;;
        --help|-h)
            echo "disable-victron-bluetooth $VERSION"
            echo "Usage: disable-victron-bluetooth.sh [--restore|--version]"
            echo "  Disable (or restore) Victron's built-in BLE services on Venus OS."
            echo "  Services: $SERVICES"
            ;;
        *)
            disable_victron_ble
            ;;
    esac
}

# Run _main when executed directly or piped. Skip when sourced.
if [ -n "${BASH_VERSION:-}" ]; then
    if [ -z "${BASH_SOURCE:-}" ] || [ "${BASH_SOURCE}" = "$0" ]; then
        _main "$@"
    fi
else
    case "$(basename "$0")" in
        disable-victron-bluetooth*|sh|dash|ash) _main "$@" ;;
    esac
fi
