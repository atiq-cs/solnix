# solnix-timedate: the time zone page of COSMIC Settings

COSMIC Settings > Time & language > Date & time asks systemd-timedated (org.freedesktop.timedate1 on the system bus) for
the list of zones, the current zone, and to set one (cosmic-settings 1.11 pages/time/date.rs: ListTimezones, Timezone,
SetTimezone, NTP, CanNTP, SetNTP). NixOS has timedated as part of systemd. illumos has no systemd, so without a
stand-in the page lists no zones (BE solnix-52: /run/current-system/sw/share/dbus-1/system-services was empty).

solnix-timedate (src/solnix-timedate, Rust with zbus, MIT) owns org.freedesktop.timedate1. It is on with the COSMIC
desktop (`services.solnix-timedate.enable`, default true there).

| call | answer |
|---|---|
| ListTimezones | every TZif file under /usr/share/lib/zoneinfo (illumos's zone tree), by name, sorted; posix/, right/ and posixrules left out. timedated reads tzdata.zi, which illumos does not ship |
| Timezone | TZ from /etc/default/init (illumos init and login read it there); "UTC" when unset |
| SetTimezone | root, or an RBAC administrator by solnix-accounts' rule (the Primary Administrator profile, the root role, or the sysadmin group). It rewrites the TZ= line of /etc/default/init (a temp file + rename, the other lines kept) and announces Timezone. Unknown or non-TZif names, and names with `..` or a leading `/`, answer org.freedesktop.timedate1.InvalidTimezone |
| NTP, CanNTP, LocalRTC | false |
| SetNTP, SetTime, SetLocalRTC | org.freedesktop.timedate1.NotSupported |

Departures from NixOS, and why:
- No polkit on solnix: the caller's uid comes from the bus (GetConnectionUnixUser) and is checked against RBAC, as
  solnix-nm and solnix-accounts do.
- A new zone applies to new logins and newly started services. Running processes keep the TZ they started with: on
  illumos the zone is the TZ variable, not /etc/localtime.
- As on NixOS with `time.timeZone` set, the declared zone comes back at the next switch: /etc/default/init is
  generated from `time.timeZone` (modules/config/first-boot-defaults.nix). Make a change from Settings permanent there.

Tests: `cargo test` under dbus-run-session (src/solnix-timedate/src/tests.rs), over a temp root and zone tree:
the list, TZ unset = UTC, an administrator's SetTimezone and its PropertiesChanged, a non-administrator refused with the
file unchanged (the negative control), bad names refused. Mutants (no admin check, no name check, posix/ not skipped)
each fail a test. Run against lixi's real zone tree it lists 598 zones.
