# Binding the Intel wifi drivers at run time (installer media)

The installer image carries both Intel wifi drivers and their firmware:

| driver | hardware | PCI ids |
|---|---|---|
| `iwm` | AC 7260 .. 9560 (the X1's AC 9560 is `8086:a370`) | `pciex8086,a370` |
| `iwx` | AX210 / AX211 (the X1E's AX211 is `8086:51f0`) | `pciex8086,2725` `2726` `51f0` `51f1` `54f0` `7a70` `7af0` `7e40` `7f70` |

Each driver has a major number and a `minor_perm` entry on the media, but **no `driver_aliases` line**, so neither
attaches at boot (`hardware.wirelessIntel.onMedia`, modules/config/wireless-iwx.nix). Neither has a proven attach on
every chip it lists, and a panic at boot would make the media unusable. You bind the one your machine needs, once,
from the live shell.

## Bind

Find your card's id, then bind that id only:

    prtconf -v | grep -B2 -A2 'pci8086,'          # or: scanpci / lspci-style output from prtconf -pv
    update_drv -a -i '"pciex8086,51f0"' iwx        # the X1E's AX211
    update_drv -a -i '"pciex8086,a370"' iwm        # the X1's AC 9560

Check:

    dladm show-phys              # iwx0 (or iwm0) appears
    dmesg | tail -20             # firmware load: "iwx0: hw rev ..., fw ..., address xx:xx:..."

## Join a WPA2 network

The drivers run OpenBSD's in-kernel WPA2 supplicant; `wpad` is not used. `wpa-pmk` derives the PMK from the
passphrase in userland and hands it to the driver as the private link property `_wpa_psk`:

    dladm scan-wifi iwx0
    wpa-pmk '<ssid>' iwx0                     # reads the passphrase on stdin; ESSID-only (no -b)
    dladm show-wifi iwx0                      # status: connected
    ipadm create-addr -T dhcp iwx0/v4

WPA2-PSK with CCMP is the supported mode (proven on iwm, the X1). WPA3/SAE, WPA-Enterprise (802.1X) and WEP are not.

## Back out

    update_drv -d -i "pciex8086,51f0" iwx      # NO quotes around the id: a quoted id exits 0 and removes nothing
    reboot

On the live image the alias lives only in the ramdisk, so a reboot also removes it.
