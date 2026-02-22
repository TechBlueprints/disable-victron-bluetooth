# disable-victron-bluetooth

Disable Victron's built-in BLE services on Venus OS to prevent them from
interfering with third-party Bluetooth services.

## Why

Two stock Venus OS services cause serious problems for any third-party
BLE service:

| Service | Problem |
|---|---|
| `dbus-ble-sensors` | Uses raw HCI sockets to scan, bypassing BlueZ entirely. This corrupts BlueZ's internal discovery state, causing `org.bluez.Error.InProgress` for any other service using the D-Bus API — even when `Discovering` is `False`. The corruption is continuous (re-applied every 10 seconds) and the only recovery is an adapter power-cycle or bluetoothd restart, both of which drop all BLE connections. |
| `vesmart-server` | Forcibly disconnects **all** BLE devices every ~60 seconds and runs its own scan cycle, causing further InProgress collisions and connection drops. |

Upstream issues:

- [victronenergy/venus#1587](https://github.com/victronenergy/venus/issues/1587) — vesmart forcibly disconnects all BLE devices
- [victronenergy/venus#1597](https://github.com/victronenergy/venus/issues/1597) — dbus-ble-sensors raw HCI scanning corrupts BlueZ discovery state

## What it does

1. **Saves current D-Bus settings** (`/Settings/Services/BleSensors` and
   `/Settings/Services/Bluetooth`) to `/data/disable-victron-bluetooth.state`
2. **Disables both services in the Venus OS UI** via D-Bus (sets to 0)
3. **Stops** each service if running (`svc -d`)
4. **Makes run/start scripts non-executable** so they can't be restarted
   by daemontools or the `bt-config` udev hotplug script

`--restore` reverses all of this: re-enables the scripts, starts the
services, and restores the D-Bus settings to their **original values**
(read from the saved state file, not hardcoded).

The root partition is read-only on Venus OS — the script temporarily
remounts it read-write, modifies the scripts, and restores read-only.
All steps are idempotent — safe to run repeatedly.

## Quick start

Run directly on the Cerbo without downloading:

```bash
wget -qO- https://raw.githubusercontent.com/TechBlueprints/disable-victron-bluetooth/main/disable-victron-bluetooth.sh | sh
```

To restore:

```bash
wget -qO- https://raw.githubusercontent.com/TechBlueprints/disable-victron-bluetooth/main/disable-victron-bluetooth.sh | sh -s -- --restore
```

Or copy a file to the Cerbo and run it:

```bash
# Bash version
scp disable-victron-bluetooth.sh root@cerbo:/tmp/
ssh root@cerbo 'sh /tmp/disable-victron-bluetooth.sh'

# Python version
scp disable-victron-bluetooth.py root@cerbo:/tmp/
ssh root@cerbo 'python3 /tmp/disable-victron-bluetooth.py'
```

To re-enable both services:

```bash
sh disable-victron-bluetooth.sh --restore
# or
python3 disable-victron-bluetooth.py --restore
```

## Include in your project

Both scripts are designed to be easy to embed. Each file contains the full
Apache 2.0 license header so it can be used standalone.

### Bash — source and call

```bash
. /path/to/disable-victron-bluetooth.sh
disable_victron_ble          # disable both services
restore_victron_ble          # re-enable both services
disable_service dbus-ble-sensors  # disable just one
```

### Python — import and call

```python
from disable_victron_bluetooth import disable_victron_ble, restore_victron_ble

disable_victron_ble()        # disable both services
restore_victron_ble()        # re-enable both services
```

Or call individual services:

```python
from disable_victron_bluetooth import disable_service, restore_service

disable_service("dbus-ble-sensors")
restore_service("vesmart-server")
```

## Note on firmware updates

Venus OS firmware updates restore the read-only root partition, which
re-enables these services. You should call `disable_victron_ble` on boot
(e.g., from `/data/rc.local` or from your service's install script) to
keep them disabled after updates.

## License

Apache License 2.0 — see [LICENSE](LICENSE).
