# solnix-nm: the NetworkManager D-Bus interface for COSMIC

COSMIC's network applet and the Network & Wi-Fi page of COSMIC Settings talk to NetworkManager over the system bus
(through the nmrs crate). NetworkManager itself is GPL and built on Linux netlink, so solnix doesn't ship it. solnix-nm
(src/solnix-nm, MIT) answers on the same bus name, org.freedesktop.NetworkManager, with the part of the interface COSMIC
uses, and does the work with dladm, ipadm, wpa-pmk and solnix-netd.

Turn it on with `services.solnix-nm.enable = true;` (it needs `services.dbus.enable`, which the COSMIC desktop sets). It
is off by default.

## What it does

| COSMIC asks | solnix-nm does |
|---|---|
| list devices, networks, the active connection, addresses | `dladm show-phys`, `dladm scan-wifi` (every 60 s, or on RequestScan), `dladm show-wifi`, `ipadm show-addr` |
| connect to a WPA2-PSK network with a password | writes `/etc/wifi/<ssid>.psk` (root, 0600, the passphrase on the first line), lists it in `/var/lib/solnix-nm/networks`, joins with `wpa-pmk` (WPA2's 4-way in the kernel, as solnix-wifi-join does); solnix-netd's DHCP takes it from there |
| connect to a saved or open network | the same join with the saved file, or `dladm connect-wifi` for an open one |
| forget a network | removes its file and its line (declared networks are refused: remove them from the configuration) |
| disconnect, turn wifi off | `dladm disconnect-wifi` and `/var/run/solnix-nm/<link>.down`, which tells solnix-netd to leave that link alone until a connect or wifi-on clears it |
| register a secret agent | accepted. COSMIC asks for the password itself and passes it in the connect call, so nothing ever calls the agent |

Networks declared in `hardware.wirelessIwx.networks` or `hardware.wirelessIwm.networks` show as saved, read-only
profiles. Networks saved from COSMIC are rejoined by solnix-netd after a reboot or roam: its join script tries them
after the declared ones (only when solnix-nm is on). GetSettings never returns a passphrase, as with NetworkManager.

## Who may change things

Anyone may read. Connecting, forgetting, disconnecting and the wifi switch need root or membership in the
`networkmanager` group (gid 57, as on NixOS). Add a desktop user with `users.users.<name>.extraGroups = [ "networkmanager" ];`.
solnix-nm asks the bus for the caller's uid (GetConnectionUnixUser), so a refused call writes nothing.

## Not in this version

WPA-Enterprise (802.1X), WPA3-SAE, hidden networks, VPN profiles, editing wired links (they are solnix-netd's and
`networking.interfaces`), IPv6 details. The calls return NotSupported or an empty list, and COSMIC shows nothing for them.

## Tests

- `cargo test` under `dbus-run-session`: the dladm/ipadm parsers on lines measured on lixi, the saved-network store, and
  the join path against a recorder backend on a private bus. A connect from a networkmanager member writes the file
  0600 and joins that SSID with it; a wrong passphrase ends Deactivated; a plain user gets AccessDenied and nothing is
  written; a 7-character passphrase is refused before any write. Each guard was sabotaged once to confirm its test
  fails.
- Read-only on lixi (private bus, as root): COSMIC's own client, nmrs 3.5.7 `snapshot()`, lists iwx0 as activated,
  18 access points, the connected BSSID as `dladm show-wifi` reports it, and connectivity Full. With no solnix-nm on the
  bus the same call fails with ServiceUnknown.
- Not yet: a real join from the panel. That test happens at the maintainer's desk, in a boot-once BE.
