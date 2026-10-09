# iwm (Intel AC 7260..9560, OpenBSD iwm(4)) on illumos: claim ladder

Target: the X1 "dixi". Its wifi is an Intel Wireless-AC 9560, PCI 8086:a370 subsystem 8086:0030, rev 0x10, CNVi
(Jefferson Peak on a Cannon Lake PCH), device family 9000, firmware iwm-9000-46 (Linux
iwlwifi-9000-pu-b0-jf-b0-46.ucode). It is not an AX201, and OpenBSD iwx(4) has no a370 entry. Evidence:
dixi:/var/tmp/streamD/prtconf-v.txt, OpenBSD if_iwm.c:11628/11855, Linux iwlwifi drv.c.

Tags: REAL = measured, with the command and where the output is. BUILT = compiles and links, never executed.
GATED = deliberately fails closed (ENOTSUP / refused). PLANNED = not written.

## Ladder

| # | Claim | State | Evidence |
|---|-------|-------|----------|
| 1 | Vendored OpenBSD sources: if_iwm.c 1.419, if_iwmreg.h 1.70, if_iwmvar.h 1.79; licence ISC + Intel dual BSD/GPLv2 | REAL | openbsd-orig/, header text |
| 2 | Patched driver source generated without patch(1): 16 count-checked replacements, 15 hunks | REAL | gen-illumos-src.py, patches/if_iwm.illumos.patch |
| 3 | Native build on dixi with the gate kernel flags (solnix-dev gcc 14.3.0 + gas 2.46.1, gate-proto headers) | REAL | `IWM_DIXI_DIR=/var/tmp/streamD2/solnix/src IWM_DIXI_OUT=/var/tmp/streamD2 ./build-dixi.sh`, exit 0 |
| 4 | Byte-reproducible: a fresh clone of 4d7064ee built the same module as the previous run (sha1 e5d7355b...) | REAL | dixi:/var/tmp/streamD2 vs /var/tmp/streamD |
| 5 | Every undefined symbol resolves against the RUNNING unix+genunix+misc/mac (127 undefined, 0 unresolved) | REAL | dixi:/var/tmp/streamD2/iwm-unresolved.txt (empty); negative control: an injected bogus reference is reported (previous run) |
| 6 | No module global shares a name with any loaded kernel module except _init/_fini/_info (krtld would rebind it, kobj.c do_symbols) | REAL | defined vs all of /dev/ksyms (25245 globals) |
| 7 | Only R_AMD64_64/PC32/32S relocations, no GOT, no TLS, no init_array | REAL | elfdump -r / -c |
| 8 | Load with no major number fails cleanly: ENXIO, "mod_installdrv: no major number for iwm", no threads left | REAL | 17/17 modloads over two builds |
| 9 | (fixed) _init failure with no major used to NULL-deref in dld_fini_ops: mac_init_ops returns early with no major (mac.c:515), cb_str stays NULL, dld_fini_ops dereferences it (dld_str.c:536) | REAL (fix) | dixi disassembly of dld_fini_ops; iwm_gld_fini_ops now skips mac_fini_ops when cb_str is NULL. Not sabotage-tested: the control would panic dixi |
| 10 | With a major bound and NO alias: modload + modinfo + modunload clean, mac_init_ops marks the driver GLDv3/NETWORK, one systq thread while loaded and 0 after (thread_join), no node binds | REAL | 13/13 cycles (9 on fbc5f4e3, 4 on aaced5c6); prtconf -D: no iwm; a370 node unbound |
| 11 | /etc returns byte-identical after `rem_drv iwm` (+ removing the /reconfigure that add_drv creates) | REAL | cmp against dixi:/var/tmp/streamD2/etc-before/ |
| 12 | Firmware package: iwm-9000-46, 1519568 B, sha256 9a0c5d93..., licence gate | REAL (built) | /nix/store/k8nx230y4p2n0cbfib5hp48585ry7bba-iwm-firmware-20241017 |
| 13 | loadfirmware -> firmware_open("iwm", name) -> module path "firmware/iwm/<name>", giant dropped around the IO | BUILT | n80211_giant.c; the blob is not installed on dixi |
| 14 | Attach: the unmodified OpenBSD iwm_match/iwm_attach under the giant lock, then iwm_attach_hook (firmware + NVM MAC), then mac_register (wifi plugin) | BUILT | iwm_attach.c; never run (no alias) |
| 15 | mc_tx: wifi-plugin 802.11+LLC -> Ethernet with 64 B headroom (mac_header_info), then if_snd + iwm_start -> ieee80211_encap | BUILT | iwm_gld.c iwm_wifi_to_ether, iwm_attach.c iwm_il_tx |
| 16 | RX: OpenBSD Ethernet -> 802.11 FROMDS + RFC 1042 LLC/SNAP before mac_rx, giant dropped | BUILT | iwm_gld_rx_frame via n80211_rx_xlate |
| 17 | Plugin TX header data (BSSID) pushed with mac_pdata_update + mac_tx_update before link up | BUILT | iwm_gld_link_hook; skipped from interrupt context (only the gated WPA path raises link up there) |
| 18 | WLDP: mc_ioctl WLAN_COMMAND WL_SCAN (starts the radio if needed, waits for one all-band pass up to 10 s, snapshots the node tree because dladm closes the link before reading ESS_LIST), WL_DISASSOCIATE | BUILT | iwm_m_ioctl, iwm_il_scan |
| 19 | WLDP get: ESSID, BSSID, LINKSTATUS, ESS_LIST (wifi_read_ap format), RSSI (0..15), DESIRED_RATES, ENCRYPTION, AUTH_MODE, BSSTYPE, CAPABILITY (0) | BUILT | iwm_m_getprop |
| 20 | WLDP set: ESSID (SIOCS80211NWID semantics + restart); ENCRYPTION=none, AUTH_MODE=open, BSSTYPE=BSS accepted | BUILT | iwm_m_setprop |
| 21 | WPA/WPA2 (MAC_PROP_WL_WPA/KEY/DELKEY/SETOPTIE/MLME, wpad door), WEP, channel pinning (PHY_CONFIG), IBSS, rate setting, WLAN_GET/SET_PARAM ioctls | GATED | ENOTSUP; CAPABILITY reports no WEP/WPA, so `dladm connect-wifi -k` stops early |
| 22 | detach once attached | GATED | iwm_il_detach refuses; a live attach is backed out by removing the alias and rebooting |
| 23 | suspend/resume, quiesce beyond stop-DMA | GATED | DDI_RESUME refused |
| 24 | Attach on dixi | PLANNED | needs the dump device (maintainer) and an alias approval; /tmp/streamD2-attach-plan.md |
| 25 | Declarative module (name_to_major/aliases/minor_perm + kernel/drv + kernel/firmware in the BE) | PLANNED | attach plan section 6 |

## How the ladder was checked

The WLDP surface is what libdladm sends at gate rev ac45d71f (read in libdlwlan.c and linkprop.c): only WL_SCAN and
WL_DISASSOCIATE go through the legacy STREAMS ioctl; every parameter is a mac property. The illumos iwn driver
delegates the same calls to illumos net80211 (if_iwn.c:4073-4160), whose handlers (net80211_ioctl.c) define the
wire format reproduced here.

None of rungs 13-21 has run. The first attach is the first execution of OpenBSD iwm code on illumos.
