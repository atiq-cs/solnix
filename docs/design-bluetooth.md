# Bluetooth for solnix: which BSD stack, what it needs on illumos, and the first step

Status: plan, 2026-11-01. The step-1 result (a firmware load and HCI version read on lixi) is in
§9. Measurements were made against NetBSD trunk 26c769bc (2026-11-01), FreeBSD main 9da2c05a
(2026-11-01) and the illumos gate lixi runs (ac45d71fc2). Working copies are under
/scratch/solnix/bt1/src and /scratch/solnix/bt1/ref.

## 0. Recommendation

1. **Kernel stack: NetBSD `sys/netbt`, not FreeBSD netgraph.** Keep netbt's protocol core
   (HCI, L2CAP, RFCOMM, SCO: 9,132 lines) and replace only its socket layer (2,543 lines) with
   an illumos sockfs socket module, built like `sockmod_pfp.c`. FreeBSD's stack is bigger
   (29,688 lines) and only runs inside netgraph, so the netgraph framework would have to be
   ported too (at least 6.7k more lines) for no gain.
2. **Intel firmware: take FreeBSD's loader.** Neither stack's driver loads Intel firmware.
   FreeBSD does it in userland (`usr.sbin/bluetooth/iwmbtfw`, BSD-2, 2,187 lines, over libusb).
   On illumos the device is already reachable from userland through ugen (§1), so step 1 ports
   that loader without changing the kernel. The loader moves into the kernel ubt driver later
   (phase 2), where `firmware_open()` reads the file the same way iwx does.
3. **Userland: NetBSD's tools (bthcid, btconfig, sdpd, btdevctl), plus a new daemon that serves
   the subset of BlueZ's `org.bluez` D-Bus API that COSMIC uses.** BlueZ cannot be used: its
   daemon is GPL and it needs Linux's mgmt socket API. COSMIC's applet reaches BlueZ only
   through `bluer`'s D-Bus client (§6), so a daemon that implements that interface is enough.
4. **The main gap is Bluetooth Low Energy.** netbt has no LE (§3.3). Many current mice,
   keyboards and earbuds are LE-only, so classic BR/EDR alone covers less than a user expects.
   LE is its own phase and its own estimate.

## 1. What lixi has (measured, read-only, 2026-11-01)

The AX211 is a combo card: Wi-Fi on PCIe (iwx, already working), Bluetooth on USB
`8087:0033` at `/pci@0,0/pci17aa,22f8@14/device@a`. Its device class is e0/01/01 (the
Bluetooth class), it is a full-speed device, and it has one configuration:

| interface | endpoints | HCI role |
|---|---|---|
| 0 | 0x81 interrupt IN, 64 B | HCI events |
| 0 | 0x02 bulk OUT / 0x82 bulk IN, 64 B | ACL data (and Intel firmware fragments) |
| 1, alt 0..6 | 0x03 / 0x83 isochronous, 0..63 B | SCO voice |
| control (ep 0) | class request bRequest 0 | HCI commands |

No driver claims the device, so **usb_mid attaches to it in ugen mode** (usb_mid(4D), ugen(4D)
"BINDING"). Every endpoint already has a node: `/dev/usb/8087.33/0/{cntrl0, if0in1, if0out2,
if0in2, if1.Nin3, if1.Nout3}` and their `*stat` nodes, all mode 0600 root (minor_perm
`ugen:* 0644 root sys`). ugen gives control transfers as write(setup+data)/read, interrupt-IN
as read/poll, and bulk as plain read/write (poll is not supported on bulk). All of that came from
`prtconf -v` (the raw configuration descriptor) and ugen.4d in the gate source.

**So userland can drive the HCI today, without a new kernel module.** This is what changed the
first step.

## 2. What illumos has

No Bluetooth. illumos-gate, OmniOS and Tribblix have no HCI, L2CAP or USB Bluetooth client
code (orchestrator survey, 2026-11-01). `AF_MAX` is 32 (`AF_PACKET`), so there is no
`AF_BLUETOOTH`. The pieces a port can build on are:

* **USBA** (usb_pipe_{ctrl,intr,bulk,isoc}_xfer). ugen, usbprn and hid are in-tree clients.
  ugen shows that every transfer type a ubt driver needs already works on this host controller.
* **sockfs socket modules** (`modlsockmod`, `smod_reg_t`, `sock_downcalls_t`). A socket module
  is a kernel module plus a `sock2path.d` line, so a new address family needs no sockfs change.
  `sockmod_pfp.c` (1,562 lines) is the closest model: it is a non-IP protocol whose packets
  arrive from below.
* **firmload** (`firmware_open("ibt", name)` -> `/kernel/firmware/ibt/<name>`), as iwx uses.
* **The BSD-compat seams this repo already ports:** mbuf-over-mblk_t (iwx `iwx_mbuf*`, 120
  checks), the OpenBSD KPI layer (src/drm-port/obsd-compat), and the USBA/STREAMS client
  shape (src/ports/touchpad `ihid`, which is modelled on usb hid(4D)).

## 3. The two candidate stacks (measured)

### 3.1 NetBSD netbt (sys/netbt, 27 files)

| part | files | lines |
|---|---|---|
| protocol core: hci_{event,link,unit,misc,ioctl}, l2cap_{lower,misc,signal,upper}, rfcomm_{dlc,session,upper}, sco_upper, bt_proto, bt_sysctl | 16 .c | 9,132 |
| socket layer: hci_socket, l2cap_socket, rfcomm_socket, sco_socket | 4 .c | 2,543 |
| headers (hci.h 2,631, l2cap.h, rfcomm.h, sco.h, bluetooth.h, hci_le.h) | 6 .h | 4,154 |
| USB transport: sys/dev/usb/ubt.c | 1 | 1,853 |
| UART transports (btuart, bcsp, bth5) and in-kernel profiles (bthidev, btkbd, btms, btmagic, btsco, bthub) | 9 .c | 9,593 |

The licence is BSD (Iain Hibbert 2005, Itronix 2006). Each file carries 2 clauses plus a
no-endorsement clause and **no advertising clause** (`grep -c 'advertising materials'` is 0
on all 26 files). That is CDDL-compatible with attribution, the same position as iwx and
obsd-compat. It is maintained: 17 of the 27 RCS ids are dated 2024 or later.

The structure is what makes it portable. The protocol core talks down to the driver through
`struct hci_if` (enable, disable, output_cmd, output_acl, output_sco, get_stats) and up
through `struct btproto` (connecting, connected, disconnected, newconn, complete, linkmode,
input). The in-kernel profiles (bthidev, btsco) use btproto directly and never sockets.
So the socket layer is one replaceable layer on top, not something spread through the core.

What the core expects from the kernel, counted by call site: mbufs (m_copydata 72, m_adj 67,
m_freem 48, plus a few m_gethdr, m_copypacket, m_copyback, M_PREPEND, m_split and m_cat),
callouts (about 40 call sites), mutex and condvar, pool_get/put, sysctl_createv (24), kauth
(13), softint (7), and the socket-buffer API (so*/sb*, about 160 call sites, nearly all in the
four *_socket.c files).

### 3.2 FreeBSD netgraph Bluetooth (sys/netgraph/bluetooth)

| part | lines |
|---|---|
| hci node | 6,176 |
| l2cap node | 7,113 |
| socket layer (ng_btsocket_{hci_raw,l2cap,l2cap_raw,rfcomm,sco}) | 11,722 |
| include + common | 4,677 |
| drivers/ubt (ng_ubt.c, ng_ubt_intel.c, ng_ubt_rtl.c) | 2,803 |
| **plus netgraph itself** (ng_base.c 3,903, ng_socket.c 1,123, ng_parse, message headers; all of sys/netgraph is 47.7k) | at least 6.7k |

The Bluetooth files are BSD-2 (Maksim Yevmenkin). netgraph core carries the Whistle licence,
which is permissive but has its own trademark clause. Each layer is a netgraph node that
exchanges `ng_mesg` control messages and mbuf data over hooks, so porting it means porting
netgraph's node/hook/queue machinery first. It has slightly more LE than netbt: ATT and SMP
CIDs in l2cap, and LE advertising-report parsing in hci.

### 3.3 Low Energy in either stack

netbt has **no LE**. `hci_le.h` (2024) only defines constants. No .c file handles LE Meta
events, LE connections, the ATT or SMP fixed channels, or LE pairing. FreeBSD has only part of
it: it parses LE advertising reports and knows the ATT and SMP CIDs, but has no SMP pairing in
the kernel and no GATT. **LE (SMP pairing plus a GATT client) is new code with either stack**,
and FreeBSD's head start is a few hundred lines. That does not make up for porting netgraph.

### 3.4 Verdict

netbt wins on all three counts: it is half the size, it has no framework under it, and its
socket layer is a clean seam. Choose FreeBSD only for its Intel firmware loader (§5) and its
`ng_ubt_intel.c` probe logic, both BSD-2.

## 4. What netbt needs on illumos

| piece | how | new lines (estimate) |
|---|---|---|
| **ubt**: USBA client driver for class e0/01/01 | Rewrite NetBSD ubt.c's usbd_* calls (create/setup/transfer/abort pipe, isoc) against usb_pipe_*_xfer. Bind with driver_aliases `usb,classe0.1.1` (and `usb8087,33` for lixi), the way ihid binds. Implements `struct hci_if`. | 1,500-2,000 |
| **mbuf over mblk_t** | Reuse the iwx layer (`iwx_m_*`, tested) and add m_copydata, m_copyback, m_copypacket, M_PREPEND, m_split, m_cat and the packet-header fields netbt reads. | 300-500 |
| **kernel KPI shims** | callout -> timeout(9F) or a taskq; pool -> kmem_cache; mutex/cv map directly; softint -> ddi_intr_add_softint or a taskq; sysctl -> a driver.conf property or kstat; kauth -> secpolicy (PRIV_SYS_NET_CONFIG for raw HCI). | 400-700 |
| **socket module(s)**: AF_BLUETOOTH plus BTPROTO_{HCI,L2CAP,RFCOMM,SCO} | One `modlsockmod` per protocol (or one module registering four sock2path entries). `sock_downcalls_t` handlers replace the four NetBSD *_socket.c files, mapping their pr_usrreqs onto su_* upcalls. Pick an AF number above 32 (illumos has no reserved number; this needs a <sys/socket.h> patch in the gate). | 1,500-2,500 |
| **L2CAP / RFCOMM** | netbt core, compiled as is behind the shims. | 0 new (6,000 ported) |
| **SCO voice** | netbt sco_* plus ubt's isochronous pipes (alt setting by voice codec). The sound side needs an audio(4I) or OSS endpoint (NetBSD btsco is an audio(9) driver). Last, and optional. | 800-1,200 |
| **HID** (keyboards, mice) | NetBSD bthidev, rewired to illumos hidparser plus a STREAMS node usbkbm/usbms can be pushed on, exactly the ihid route. Or do it in userland (FreeBSD bthidd, via a uinput-style device: illumos has none). | 800-1,500 |

**Kernel total: about 5-8k new lines plus about 9k ported.** That is several months of work for
one engineer to reach a paired, data-moving classic link, and longer with HID and SCO. LE (§3.3)
is extra: about 3-5k lines (SMP, the ATT bearer and the LE connection path in hci_link), or
put SMP and GATT in the userland daemon as BlueZ does and keep the kernel to the LE link and
fixed channels.

## 5. Intel firmware

lixi's controller boots into its bootloader and stays there until the host loads operational
firmware: an `.sfi` image (secure-boot signed, RSA or ECDSA header) and then a small `.ddc`
configuration. The file name comes from the controller (Intel vendor command 0xfc05 with a
TLV reply): `ibt-<cnvi_top>-<cnvr_top>.{sfi,ddc}` with each 32-bit value packed into 16 bits
(FreeBSD `iwmbt_get_fwname_tlv`). An AX211 (CNVi so/gf) is `ibt-0040-*`.

* **Licence.** linux-firmware `LICENCE.ibt_firmware` permits redistribution of unmodified
  binaries with the notice, and forbids reverse engineering. It is unfree but redistributable,
  so it goes behind `acceptFirmwareLicense` with the licence file installed next to the
  blobs, exactly like `pkgs/illumos/iwx-firmware.nix`. The package is
  `pkgs/illumos/ibt-firmware.nix` (step 1).
* **Where the loader runs.** FreeBSD loads it from userland: devd runs `iwmbtfw -d ugenX.Y`
  on attach, then `libusb_reset_device()` makes the device re-enumerate and ng_ubt binds
  only when the image type reads back as operational (ng_ubt_intel.c `ubt_intel_probe`).
  Linux does it in the kernel (btintel.c, GPL; not looked at). On illumos:
  * phase 0 (step 1): the userland loader over ugen. No kernel change.
  * phase 2: the same sequence inside ubt's attach. The host-side work is 200-300 lines
    (fragment loop, boot-param parse, reset and wait for the vendor event), with
    `firmware_open("ibt", ...)` reading `/kernel/firmware/ibt/`. It belongs in the kernel
    because the controller drops back to its bootloader on every power cycle and suspend, and
    ubt must not offer an HCI to netbt until the firmware is operational.

## 6. Userland and COSMIC

**BlueZ cannot be used.** Its daemon is GPL. That alone is allowed in userland, but it is
written against Linux's `AF_BLUETOOTH` socket ABI and the mgmt control channel
(`HCI_CHANNEL_CONTROL`), which netbt does not have. Emulating mgmt means writing a second
stack.

**What the BSDs use** (NetBSD sizes; all BSD-licensed):

| tool | lines | job |
|---|---|---|
| libbluetooth | 5,661 | bdaddr helpers, HCI request helpers, SDP client |
| btconfig | 1,141 | power, scan modes, name, class (hciconfig) |
| bthcid | 1,132 | PIN and link-key daemon (answers the HCI link-key and PIN requests) |
| btkey | 824 | link-key store |
| sdpd | 3,324 | SDP server |
| btdevctl | 1,403 | attach a remote HID or audio device to the in-kernel profile |
| btpand | 2,618 | PAN (Bluetooth networking), optional |

**What COSMIC needs.** `cosmic-applet-bluetooth` (878 + 541 lines) uses `bluer` 0.17 with
features `bluetoothd` and `id` only. It never opens a Bluetooth socket. Everything goes over
D-Bus to `org.bluez`. bluer is BSD-2. Its only hard block is
`#[cfg(not(target_os = "linux"))] compile_error!` (lib.rs:92), and with those two features its
`sys.rs` is just bdaddr types. **So COSMIC needs a one-line bluer patch plus a daemon that
serves the part of the org.bluez interface the applet calls:**

* `org.freedesktop.DBus.ObjectManager` on `/` (adapters and devices appearing and going away)
* `org.bluez.Adapter1`: Powered (get/set), Discovering, StartDiscovery/StopDiscovery,
  Address, Name, Alias
* `org.bluez.Device1`: Address, Name, Alias, Icon, Paired, Trusted (get/set), Connected,
  Pair, Connect, Disconnect; `org.bluez.Battery1`: Percentage
* `org.bluez.AgentManager1` RegisterAgent/RequestDefaultAgent, and calls back into the
  applet's `org.bluez.Agent1`: RequestPinCode, RequestPasskey, RequestConfirmation,
  RequestAuthorization

`cosmic-settings`' bluetooth page uses `bluez-zbus` against the same interfaces.

**`solnix-btd`** (new) runs as an SMF service on the system bus. It sits on netbt's HCI socket
(inquiry, connect, link keys, SSP events) and replaces bthcid's agent role with the D-Bus
Agent1 calls. It reuses libbluetooth's SDP client and runs sdpd beside it. Rust with zbus fits
the COSMIC stack. Estimate: 2,500-4,000 lines for the subset above, with classic BR/EDR
pairing (SSP numeric comparison and legacy PIN). Device "Connect" has to mean something per
profile: HID through btdevctl's in-kernel attach, audio through SCO and A2DP (A2DP needs an
SBC codec and an audio sink; that is a later phase).

## 7. Phases

| phase | deliverable | depends on | size |
|---|---|---|---|
| **0** | userland Intel firmware load + HCI version read over ugen (step 1, §9) | nothing | about 1,000 new lines (shim, wrapper, self-test) + 2,187 vendored |
| 1 | ubt USBA driver + mbuf/KPI shims + netbt HCI core; `btconfig` brings the unit up, inquiry lists devices | 0 | 3-4k new + 4k ported |
| 2 | Intel firmware load moves into ubt attach (firmload, survives suspend/re-plug) | 1 | 300 |
| 3 | AF_BLUETOOTH socket module (HCI, L2CAP, RFCOMM), bthcid/btkey, sdpd; pair and use RFCOMM | 1 | 2-3k new + 5k ported |
| 4 | HID (keyboard and mouse) through bthidev->usbkbm/usbms, the ihid route | 3 | 1-1.5k |
| 5 | solnix-btd (org.bluez subset) + the bluer cfg patch; the COSMIC applet and settings page | 3 | 2.5-4k |
| 6 | LE: LE link, ATT/SMP fixed channels, SMP pairing, GATT (for LE mice, keyboards and earbuds) | 3, 5 | 3-5k |
| 7 | SCO + A2DP audio | 3, sound stack | 2-3k + codec |

The project's driver ports show the risk: iwx took about five sessions from first compile to
association.

## 8. Risks

* **The AF number.** illumos has no `AF_BLUETOOTH`. Reserving one is a gate header change
  that userland (libbluetooth, solnix-btd) compiles against. Pick it once.
* **ugen and ubt cannot both own the device.** In phase 0 usb_mid's ugen mode owns it. When
  ubt is bound, ugen goes away, so the phase-0 tool is only for bring-up and as a reference,
  not something phase 1 builds on.
* **Interrupt-endpoint toggle across reopen (measured, §9).** illumos xhci unconfigures
  periodic endpoints on close, so any driver that closes and reopens its interrupt-IN pipe
  (ubt on detach/attach, suspend/resume, or when netbt disables and re-enables the unit) must
  send CLEAR_FEATURE(ENDPOINT_HALT) first, or it loses events on alternate opens.
* **Firmware state across resets.** The controller loses its firmware on a USB reset or a
  power-cycle. If a load goes wrong partway, the controller may stay in its bootloader until
  the next cold boot. FreeBSD's tool rejects a bad header before it sends anything.
* **LE coverage.** See §3.3. Classic-only Bluetooth covers older HID and audio devices but not
  most new ones.

## 9. Step 1 result: Intel firmware load and HCI version over ugen on lixi (2026-11-01)

Code: `src/ports/bluetooth/iwmbtfw/` (PROVENANCE.md). Firmware: `pkgs/illumos/ibt-firmware.nix`
(`pkgs.solnix.ibtFirmware`, throws unless `acceptFirmwareLicense`). Built on chef (gcc 14.3,
`-Wall -Wextra -Werror`). `make check`: self-test PASS, and 6/6 negative controls are caught.
The controls break event framing, the control-setup wLength, the direction bit, the HCI
return-parameter offset, the toggle reset and le32dec, and each one fails the self-test. Run log:
/scratch/solnix/bt1/lixi-run.log. Nothing on lixi changed persistently: the files lived in
/tmp (tmpfs), and the firmware sits in controller RAM.

| check | result |
|---|---|
| Intel Read Version (0xfc05, read-only), cold, 3 runs over two boots | 3/3: bootloader (img_type 0x01), hw_variant 0x18, ECDSA secure boot, cnvi_top 0x00080400 / cnvr_top 0x00400410 -> `ibt-0040-0041` |
| load `.sfi` + Intel Reset + `.ddc` + event mask (upstream `handle_9260` unmodified), one run per boot | **2/2** (two boots), 2 s wall: "Firmware download complete" -> "Firmware operational", img_type 0x03, firmware 2024.33 build 81755 |
| HCI_Read_Local_Version, same process right after the load | HCI version 12 (Bluetooth 5.3), manufacturer 0x0002 (Intel), LMP subversion 0x375b |
| Wi-Fi on the same combo card afterwards | iwx0 up, gateway ping 3/3 |
| HCI_Read_Local_Version in **separate** later processes, before the fix | 1/8 then 7 failures in a row (session 1); exact alternation, 4/8 (session 2) |
| the same after the fix (toggle reset at open) | **28/28 commands in 20 sessions**, and 6/6 `-r -V` sessions; the control (same binary, `-C`) still alternates, 5/9, and fails 0/4 on `-r -V` |

**Cause (measured): the interrupt-IN data toggle falls out of sync across a reopen.** illumos
xhci unconfigures an interrupt or isochronous endpoint when its pipe closes
(`xhci_usba.c` `xhci_hcdi_pipe_close`; bulk and control endpoints stay configured). The next
ugen open adds endpoint 0x81 again, with the host's sequence at DATA0. The controller keeps its
own toggle. After a session that took an odd number of event packets, the first packet of the
next session carries the wrong toggle: the host ACKs it and drops it (USB 2.0 §8.6.4), and the
device flips its toggle anyway. So the packet parity of one session decides the next one.

Three hypotheses were refuted on the way, each with a measurement:
(a) ugen polling restarts on every open (dtrace: `start_polling rv=0` in failing runs, with no
completion before close);
(b) there is no PM transition (no `usb_mid_power` call in any trace, and devstat is ONLINE);
(c) the controller is healthy (20/20 reads on one handle).

The parity model was written down before each run and held in every one. With `-n 2` sessions
a desynced device gives 1/2 per session, the second read succeeding on the same handle, and
stays desynced; one single-read session moves it back into sync; after that every session is
2/2.

**Fix.** `libusb_open` sends CLEAR_FEATURE(ENDPOINT_HALT) to 0x81 before it opens `if0in1`. That
resets the device's toggle to DATA0 (USB 2.0 §9.4.5), the value the re-added host endpoint
starts at. The kernel ubt (phase 1) needs the same step every time it opens the interrupt pipe:
a raw CLEAR_FEATURE(ENDPOINT_HALT, 0x81) through `usb_pipe_sync_ctrl_xfer` on the default pipe, before the
interrupt pipe is opened. Not `usb_clr_feature()`: on an endpoint with no open pipe it dereferences NULL
(usbai_util.c:1641-1651, read, not run; docs/bluetooth-phase1-plan.md). The problem affects any ugen client of an
interrupt endpoint that reopens it, not just Bluetooth; it is worth a note to illumos.

Cold path with the fix, run on lixi solnix-32 (2026-11-01, bt2), controller fresh from boot: `-r` bootloader,
ibt-0040-0041; load, then 20/20 reads on one handle; 8/8 separate runs. 43/43 commands across 15 sessions. The `-C`
control (warm controller) alternated FAIL/OK as predicted.

**Phase 1 is planned in docs/bluetooth-phase1-plan.md.** It changes this doc in six places, all read in source, not
run:
- the HCI socket moves into phase 1;
- the clear goes over the control pipe, as above;
- ubt refuses a controller still in its bootloader;
- ubt binds interface 0 only (`usbif8087,33.config1.0`), so usb_mid keeps the ugen nodes for the loader;
- "a USB reset loses the firmware" is unmeasured;
- illumos needs its own SOCK_RAW value (4), a sockaddr_bt without bt_len, and an mbuf type of its own.
Where that plan and this doc disagree, the plan is newer.
Only the reopen path is measured with the fix.

The step proves the approach. USBA plus ugen carries every HCI transfer type the Intel boot
sequence needs, and FreeBSD's BSD-2 loader runs unmodified over a 507-line shim (ugen_usb.c + ugen_evq.c).
