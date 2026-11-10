# solnix-power: UPower and power profiles for COSMIC

COSMIC reads the battery from UPower (org.freedesktop.UPower) and the power mode from power-profiles-daemon
(org.freedesktop.UPower.PowerProfiles). Both are GPL Linux daemons. Without them COSMIC Settings > Power says "Backend not
found" and the battery applet shows nothing. solnix-power (src/solnix-power, MIT) owns both bus names and answers from
illumos's own sources.

Turn it on with `services.solnix-power.enable = true;` (it needs `services.dbus.enable`, which the COSMIC desktop sets,
and svc:/system/power, which is on by default). It is off by default.

## Where the numbers come from

| COSMIC reads | from |
|---|---|
| battery percentage, state, time to empty/full | `kstat -p acpi_drv:0`: `battery BST0` (bst_rem_cap, bst_rate, bst_state: 1 discharging, 2 charging) over `battery BIF0` (bif_last_cap; bif_unit 0 = mWh, 1 = mAh times bif_voltage) |
| on battery, line power online | `acpi_drv:0:power:system power` (AC or battery) |
| model, serial, vendor, technology | bif_model, bif_serial, bif_oem_info, bif_type (LiP = lithium polymer) |
| the display device | the sum of the batteries, as UPower composes it |
| power mode | the `cpupm` line of /etc/power.conf: `disable` = performance, `enable` = balanced (the stock event mode), `enable poll-mode` = power-saver |

The kstats are read every 10 s; a change sends PropertiesChanged for what COSMIC watches (OnBattery, Percentage, State,
TimeToEmpty, Online, IconName). State is 1 charging, 2 discharging, 4 fully charged, or 5 (pending charge) on AC while
not charging below 99%.

## Changing the power mode

Setting ActiveProfile rewrites only the cpupm line of /etc/power.conf (every other line kept, its mode kept) and runs
pmconfig(8). Setting the profile already in force changes nothing. Root and members of the `seat` group may change it.
On NixOS, power-profiles-daemon's polkit rule lets any user in an active local session do it, and on solnix the desktop
user is in `seat` (services.seatd). Profile holds (HoldProfile) are not supported.

Until a change is asked for, solnix-power writes nothing.

## Not in this version

The lid state (LidIsClosed is always false; the lid node is acpi_drv's ioctl, not a kstat), keyboard backlight,
charge thresholds, history and statistics, and devices other than the system battery and AC. Whether power-saver
(poll-mode) saves measurable power on lixi is not yet measured; read bst_rate on battery per profile.

## Tests

- `cargo test` under `dbus-run-session`: the kstat parser on lines from lixi (on AC; discharging; mAh units; no
  battery), the power.conf rewrite, and the D-Bus side with a recorder backend. Every object's GetAll answers and the
  reads match the kstats; a seat member's power-saver rewrites the cpupm line once; a plain user gets AccessDenied and
  power.conf is unchanged. Sabotaging the caller check fails the last test.
- Read-only on lixi (private bus, as root): COSMIC's own client calls (upower_dbus at the rev cosmic-settings pins)
  find the power-profiles backend (balanced), a present battery at 74.3%, pending charge, the
  battery-level-70-charging icon, and AC online; /etc/power.conf is unchanged after. With no daemon the same calls fail
  with ServiceUnknown, which is what COSMIC shows as "Backend not found".
