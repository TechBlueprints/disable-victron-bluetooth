#!/usr/bin/env python3
"""
disable-victron-bluetooth.py — Disable Victron's built-in BLE services on Venus OS
Version: 1.0.0

Copyright 2026 TechBlueprints

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

Disables the two Victron Venus OS services that interfere with third-party
BLE services:

  1. dbus-ble-sensors  — Raw HCI scanning corrupts BlueZ discovery state,
                         causing InProgress errors for all other BLE services.
  2. vesmart-server    — Forcibly disconnects ALL BLE devices every ~60s and
                         runs its own scan cycle causing further collisions.

For each service this script will:
  - Disable the service in the Venus OS UI via D-Bus settings
  - Stop the service if running
  - Make run/start scripts non-executable (prevents restart by daemontools
    and by the bt-config udev hotplug script)

The root partition is read-only on Venus OS. This script temporarily
remounts it read-write to modify service scripts, then restores it.
The /service/ directory is tmpfs (repopulated from /opt at boot), so
both the live copies and the source templates must be modified.

Usage:
  python3 disable-victron-bluetooth.py           # disable both services
  python3 disable-victron-bluetooth.py --restore  # re-enable both services

Can also be imported and called as functions:
  from disable_victron_bluetooth import disable_victron_ble, restore_victron_ble
"""

import logging
import os
import stat
import subprocess
import sys

log = logging.getLogger(__name__)

VERSION = "1.0.0"
SERVICES = ("dbus-ble-sensors", "vesmart-server")

DBUS_SETTINGS = {
    "BleSensors": "/Settings/Services/BleSensors",
    "Bluetooth": "/Settings/Services/Bluetooth",
}

STATE_FILE = "/data/disable-victron-bluetooth.state"


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def is_venus_os() -> bool:
    return os.path.isfile("/opt/victronenergy/version")


def _require_venus_os() -> None:
    if not is_venus_os():
        raise SystemExit(
            "[disable-victron-bt] ERROR: This does not appear to be a Venus OS system.\n"
            "       /opt/victronenergy/version not found."
        )


def _is_root_ro() -> bool:
    with open("/proc/mounts") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 4 and parts[1] == "/":
                return "ro" in parts[3].split(",")
    return False


class _RootRemount:
    """Context manager that remounts root rw if needed, restores ro on exit."""

    def __init__(self):
        self._did_remount = False

    def __enter__(self):
        if _is_root_ro():
            log.info("Remounting root filesystem read-write")
            result = _run(["mount", "-o", "remount,rw", "/"])
            if result.returncode == 0:
                self._did_remount = True
            else:
                log.warning(
                    "Failed to remount root read-write. "
                    "Scripts on the read-only root partition will not be modified. "
                    "Changes may not persist across reboots."
                )
        return self

    def __exit__(self, *exc):
        if self._did_remount:
            log.info("Restoring root filesystem to read-only")
            result = _run(["mount", "-o", "remount,ro", "/"])
            if result.returncode != 0:
                log.warning(
                    "Failed to restore root to read-only. "
                    "Run 'mount -o remount,ro /' manually."
                )
            self._did_remount = False
        return False


def _dbus_set(path: str, value: int) -> bool:
    result = _run([
        "dbus-send", "--print-reply=literal", "--system", "--type=method_call",
        "--dest=com.victronenergy.settings", path,
        "com.victronenergy.BusItem.SetValue", f"variant:int32:{value}",
    ])
    return result.returncode == 0


def _dbus_get(path: str) -> int | None:
    result = _run([
        "dbus-send", "--print-reply=literal", "--system", "--type=method_call",
        "--dest=com.victronenergy.settings", path,
        "com.victronenergy.BusItem.GetValue",
    ])
    if result.returncode != 0:
        return None
    for part in result.stdout.split():
        try:
            return int(part)
        except ValueError:
            continue
    return None


def _save_settings() -> None:
    values = {}
    for key, path in DBUS_SETTINGS.items():
        val = _dbus_get(path)
        if val is not None:
            values[key] = val

    if values:
        log.info("Saving previous settings to %s", STATE_FILE)
        with open(STATE_FILE, "w") as f:
            for key, val in values.items():
                f.write(f"{key}={val}\n")
    else:
        log.warning("Could not read current settings (localsettings not running?)")


def _load_saved_settings() -> dict[str, int]:
    saved = {}
    if os.path.isfile(STATE_FILE):
        with open(STATE_FILE) as f:
            for line in f:
                line = line.strip()
                if "=" in line:
                    key, val = line.split("=", 1)
                    try:
                        saved[key] = int(val)
                    except ValueError:
                        pass
    return saved


def _is_service_up(name: str) -> bool:
    result = _run(["svstat", f"/service/{name}"])
    return ": up" in result.stdout


def _all_scripts(name: str) -> list[str]:
    return [
        f"/service/{name}/run",
        f"/opt/victronenergy/service/{name}/run",
        f"/opt/victronenergy/service-templates/{name}/run",
        f"/opt/victronenergy/{name}/start-ble-sensors.sh",
        f"/opt/victronenergy/{name}/{name}.sh",
    ]


def _chmod_off(path: str) -> bool:
    try:
        st = os.stat(path)
        os.chmod(path, st.st_mode & ~(stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))
        return True
    except OSError as e:
        log.warning("  Could not chmod %s: %s", path, e)
        return False


def _chmod_on(path: str) -> bool:
    try:
        st = os.stat(path)
        os.chmod(path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        return True
    except OSError as e:
        log.warning("  Could not chmod %s: %s", path, e)
        return False


def disable_service(name: str) -> None:
    log.info("Disabling %s", name)

    if _is_service_up(name):
        log.info("  Stopping %s", name)
        _run(["svc", "-d", f"/service/{name}"])

    for path in _all_scripts(name):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            log.info("  Making non-executable: %s", path)
            _chmod_off(path)

    log.info("  %s disabled", name)


def restore_service(name: str) -> None:
    log.info("Restoring %s", name)

    for path in _all_scripts(name):
        if os.path.isfile(path) and not os.access(path, os.X_OK):
            log.info("  Making executable: %s", path)
            _chmod_on(path)

    if os.path.isdir(f"/service/{name}"):
        log.info("  Starting %s", name)
        _run(["svc", "-u", f"/service/{name}"])

    log.info("  %s restored", name)


def disable_victron_ble() -> None:
    _require_venus_os()

    _save_settings()

    for key, path in DBUS_SETTINGS.items():
        log.info("Disabling %s in Venus OS settings", key)
        if not _dbus_set(path, 0):
            log.warning("Could not update %s setting (localsettings not running?)", key)

    with _RootRemount():
        for name in SERVICES:
            disable_service(name)


def restore_victron_ble() -> None:
    _require_venus_os()

    saved = _load_saved_settings()

    for key, path in DBUS_SETTINGS.items():
        value = saved.get(key, 1)
        log.info("Restoring %s setting to %d", key, value)
        if not _dbus_set(path, value):
            log.warning("Could not update %s setting (localsettings not running?)", key)

    with _RootRemount():
        for name in SERVICES:
            restore_service(name)

    if os.path.isfile(STATE_FILE):
        os.remove(STATE_FILE)


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="[disable-victron-bt] %(message)s",
    )
    if "--version" in sys.argv or "-v" in sys.argv or "-V" in sys.argv:
        print(f"disable-victron-bluetooth {VERSION}")
    elif "--restore" in sys.argv or "-r" in sys.argv:
        restore_victron_ble()
    elif "--help" in sys.argv or "-h" in sys.argv:
        print(f"disable-victron-bluetooth {VERSION}")
        print(f"Usage: {sys.argv[0]} [--restore|--version]")
        print("  Disable (or restore) Victron's built-in BLE services on Venus OS.")
        print(f"  Services: {', '.join(SERVICES)}")
    else:
        disable_victron_ble()
