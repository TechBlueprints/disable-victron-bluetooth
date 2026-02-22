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
#   1. dbus-ble-sensors  — Holds BlueZ discovery sessions causing InProgress
#                          collisions for any other BLE service on the adapter.
#   2. vesmart-server    — Forcibly disconnects ALL BLE devices every ~60s and
#                          runs its own scan cycle causing further collisions.
#
# For each service this script will:
#   - Remove daemontools supervision (if supervised)
#   - Stop the service (if running)
#   - Make the run script non-executable (prevents restart on reboot)
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

_log() { echo "[disable-victron-bt] $*"; }

is_supervised() {
    [ -d "/service/$1" ] && [ -L "/service/$1" ]
}

is_running() {
    svstat "/service/$1" 2>/dev/null | grep -q ': up'
}

is_executable() {
    [ -x "/service/$1/run" ] || [ -x "/opt/victronenergy/service/$1/run" ]
}

disable_service() {
    svc_name="$1"
    _log "Disabling $svc_name"

    if is_supervised "$svc_name"; then
        _log "  Removing supervision for $svc_name"
        rm -f "/service/$svc_name"
    fi

    if is_running "$svc_name"; then
        _log "  Stopping $svc_name"
        svc -d "/service/$svc_name" 2>/dev/null
    fi

    for run_script in \
        "/opt/victronenergy/service/$svc_name/run" \
        "/opt/victronenergy/$svc_name/run"; do
        if [ -x "$run_script" ]; then
            _log "  Making non-executable: $run_script"
            chmod a-x "$run_script"
        fi
    done

    _log "  $svc_name disabled"
}

restore_service() {
    svc_name="$1"
    _log "Restoring $svc_name"

    for run_script in \
        "/opt/victronenergy/service/$svc_name/run" \
        "/opt/victronenergy/$svc_name/run"; do
        if [ -f "$run_script" ] && [ ! -x "$run_script" ]; then
            _log "  Making executable: $run_script"
            chmod a+x "$run_script"
        fi
    done

    svc_dir="/opt/victronenergy/service/$svc_name"
    if [ -d "$svc_dir" ] && [ ! -L "/service/$svc_name" ]; then
        _log "  Re-supervising $svc_name"
        ln -s "$svc_dir" "/service/$svc_name"
    fi

    if is_supervised "$svc_name" && ! is_running "$svc_name"; then
        _log "  Starting $svc_name"
        svc -u "/service/$svc_name" 2>/dev/null
    fi

    _log "  $svc_name restored"
}

disable_victron_ble() {
    for svc_name in $SERVICES; do
        disable_service "$svc_name"
    done
}

restore_victron_ble() {
    for svc_name in $SERVICES; do
        restore_service "$svc_name"
    done
}

if [ "$(basename "$0")" = "disable-victron-bluetooth.sh" ]; then
    case "${1:-}" in
        --restore|-r)
            restore_victron_ble
            ;;
        --version|-v|-V)
            echo "disable-victron-bluetooth $VERSION"
            ;;
        --help|-h)
            echo "disable-victron-bluetooth $VERSION"
            echo "Usage: $0 [--restore|--version]"
            echo "  Disable (or restore) Victron's built-in BLE services on Venus OS."
            echo "  Services: $SERVICES"
            ;;
        *)
            disable_victron_ble
            ;;
    esac
fi
