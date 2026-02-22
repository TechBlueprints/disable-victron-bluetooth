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

  1. dbus-ble-sensors  — Holds BlueZ discovery sessions causing InProgress
                         collisions for any other BLE service on the adapter.
  2. vesmart-server    — Forcibly disconnects ALL BLE devices every ~60s and
                         runs its own scan cycle causing further collisions.

For each service this script will:
  - Remove daemontools supervision (if supervised)
  - Stop the service (if running)
  - Make the run script non-executable (prevents restart on reboot)

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


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True)


def is_supervised(name: str) -> bool:
    path = f"/service/{name}"
    return os.path.islink(path) and os.path.isdir(path)


def is_running(name: str) -> bool:
    result = _run(["svstat", f"/service/{name}"])
    return ": up" in result.stdout


def _run_script_paths(name: str) -> list[str]:
    return [
        f"/opt/victronenergy/service/{name}/run",
        f"/opt/victronenergy/{name}/run",
    ]


def disable_service(name: str) -> None:
    log.info("Disabling %s", name)

    if is_supervised(name):
        log.info("  Removing supervision for %s", name)
        os.remove(f"/service/{name}")

    if is_running(name):
        log.info("  Stopping %s", name)
        _run(["svc", "-d", f"/service/{name}"])

    for path in _run_script_paths(name):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            log.info("  Making non-executable: %s", path)
            st = os.stat(path)
            os.chmod(path, st.st_mode & ~(stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH))

    log.info("  %s disabled", name)


def restore_service(name: str) -> None:
    log.info("Restoring %s", name)

    for path in _run_script_paths(name):
        if os.path.isfile(path) and not os.access(path, os.X_OK):
            log.info("  Making executable: %s", path)
            st = os.stat(path)
            os.chmod(path, st.st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    svc_dir = f"/opt/victronenergy/service/{name}"
    link_path = f"/service/{name}"
    if os.path.isdir(svc_dir) and not os.path.islink(link_path):
        log.info("  Re-supervising %s", name)
        os.symlink(svc_dir, link_path)

    if is_supervised(name) and not is_running(name):
        log.info("  Starting %s", name)
        _run(["svc", "-u", f"/service/{name}"])

    log.info("  %s restored", name)


def disable_victron_ble() -> None:
    for name in SERVICES:
        disable_service(name)


def restore_victron_ble() -> None:
    for name in SERVICES:
        restore_service(name)


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
