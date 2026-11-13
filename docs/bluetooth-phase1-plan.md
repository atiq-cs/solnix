# Bluetooth phase 1 plan: ubt + netbt HCI core on illumos

Status: plan, not built. Written 2026-11-01 by the bt2 agent. Sources: NetBSD trunk 26c769bc and
FreeBSD main 9da2c05a (copies in /scratch/solnix/bt1/src), and the illumos gate lixi runs
(ac45d71fc2, on chef at /nix/store/7mfgs7bd7y3lqhiscbci5h11dvq0p481-illumos-gate-ac45d71fc2).
Every gate file:line below was read in that tree. "[read]" marks a claim taken from source and
not run. "[measured]" marks one seen on lixi.

Phase 1 is done when `btconfig ubt0 up` brings the unit up on lixi and `btconfig ubt0 inquiry`
lists devices in range (docs/design-bluetooth.md §7).

## 0. Four findings that change the design doc

1. **Phase 1 needs the HCI socket. The doc puts it in phase 3.** btconfig and libbluetooth reach a
   unit only through `socket(PF_BLUETOOTH, SOCK_RAW, BTPROTO_HCI)`, the `SIOC?BT*` ioctls on that
   socket, and bind/connect/send/recv/setsockopt (btconfig.c:241-500, bt_dev.c:97-884). So phase 1
   has to include a sockfs module for BTPROTO_HCI only, which ports hci_socket.c (952 lines).
   L2CAP, RFCOMM and SCO sockets stay in phase 3.
2. **Do not call `usb_clr_feature()` on an endpoint whose pipe is closed. It panics.** After a
   successful clear, `usba_sync_clear_feature` looks up the endpoint's pipe and reads
   `ph_data->p_ep.bmAttributes` with no NULL check (usbai_util.c:1641-1651). `usba_get_ph_data`
   returns NULL for a closed pipe (usbai_pipe_mgmt.c:117-130). No gate client calls
   `usb_clr_feature` at all. The xhci toggle hook it would reach is empty anyway
   (`xhci_hcdi_pipe_reset_data_toggle`, xhci_usba.c:749). bt1's fix sends the clear *before* it
   opens the interrupt endpoint, and that order was measured. So ubt sends a raw
   CLEAR_FEATURE(ENDPOINT_HALT) on the default pipe with `usb_pipe_sync_ctrl_xfer`, the same call
   USBA's own auto-clearing uses (hcdi.c:910-917), and then opens the interrupt pipe. §4 has the
   detail. [read]
3. **The bootloader gate is mandatory, not polish.** `hci_enable` starts with HCI_Reset and waits
   for initialisation (hci_unit.c:138-198). FreeBSD says that initialising the stack while an
   Intel controller is in its bootloader "locks the adapter hardly so it requires power on/off
   cycle to restore" (ng_ubt_intel.c:33-37). So in phase 1, ubt reads the image type (Intel
   0xfc05) in its enable path and refuses with EAGAIN unless it reads 0x03 (operational). Phase 0
   loads the firmware first, over ugen.
4. **ubt can bind at interface level and leave ugen in place.** That keeps the phase-0 loader
   working until phase 2. `usb_mid_create_children` binds interface children and then *still*
   creates device-level ugen when no child is ugen and the device has one configuration
   (usb_mid.c:1019-1038). lixi's 8087:0033 has one configuration with two interfaces and no IAD
   [measured, `usb-raw-cfg-descriptors`]. USBA allows one open per endpoint across the whole device
   (usbai_pipe_mgmt.c:911-920), so ubt and ugen can't both hold 0x81. They can coexist as long
   as only one of them has it open. NetBSD ubt opens its pipes in `ubt_enable` (ubt.c:984), not in
   attach, so a ubt that is attached but down leaves every endpoint free for the loader. [read]

Corrections to the design doc:
* §4 says to bind `usb,classe0.1.1`. That is a device-level name, and binding it would replace
  usb_mid and remove ugen. Both interfaces are also class e0/01/01, so the interface-class name
  `usbif,classe0.1.1` would attach ubt twice. Bind interface 0 by its exact name (§3).
* §8 says the controller loses its firmware on a USB reset. That is not measured. FreeBSD's loader
  resets the device after a good load precisely so that ng_ubt re-probes and finds it operational
  (iwmbtfw main.c:818-823). That suggests a port reset keeps the firmware. Measure it before
  phase 2 depends on it either way.
* §8 (toggle) says `usb_clr_feature`. Use the raw control transfer instead (finding 2).

## 1. What gets ported (NetBSD 26c769bc unless stated otherwise)

| file | lines | licence | phase-1 use |
|---|---|---|---|
| sys/netbt/hci_unit.c | 579 | BSD, Iain Hibbert 2005 | unit attach/enable/disable, input queues, softint dispatch |
| sys/netbt/hci_event.c | 1,331 | BSD, Hibbert 2005 | event decode, the init sequence (reset, bdaddr, buffer size, features, version, commands), inquiry results |
| sys/netbt/hci_link.c | 1,061 | BSD, Hibbert 2005 | ACL/SCO link state. Inquiry does not need it, but hci_event.c calls into it, so it is compiled, with L2CAP and SCO stubbed (§2.4) |
| sys/netbt/hci_misc.c | 183 | BSD, Hibbert 2005 | the memo cache (inquiry results), route lookup |
| sys/netbt/hci_ioctl.c | 325 | BSD, Hibbert 2005 | SIOCGBTINFO/NBTINFO/SBTFLAGS/GBTFEAT/GBTSTATS and friends, which btconfig uses |
| sys/netbt/hci_socket.c | 952 | BSD, Hibbert 2005 | raw HCI PCB, filters, send/recv. Its pr_usrreqs move under sock_downcalls_t (§2.5) |
| sys/netbt/hci.h | 2,631 | BSD, Hibbert 2005 / Itronix 2006 / Yevmenkin 2001 | protocol constants, `struct hci_unit`, `struct hci_if`, `struct btreq` |
| sys/netbt/bluetooth.h | 161 | BSD, Hibbert 2005 / Itronix 2006 | bdaddr_t, sockaddr_bt, BTPROTO_*. The ABI header (§2.6) |
| sys/dev/usb/ubt.c | 1,853 | BSD, Itronix 2006 + NetBSD Foundation 2002-03 | rewritten, not compiled as is: the structure, state machine, buffer sizes and error paths are kept, and every usbd_* call is replaced (§2.1) |
| FreeBSD sys/netgraph/bluetooth/drivers/ubt/ng_ubt_intel.c | 290 | BSD-2, Kondratyev 2019-21 / Future Crew 2023 | the idea only: read the 0xfc05 image type, refuse in bootloader mode. Its code is netgraph, so about 40 lines get rewritten |
| usr.sbin/btconfig/btconfig.c | 1,141 | BSD, Itronix 2006 | the test tool, nearly unmodified |
| lib/libbluetooth/{bluetooth.c,bt_dev.c,bluetooth.h} | 373 + 899 + 197 | BSD, Yevmenkin 2001-09 / Hibbert 2009 | bt_devopen/bt_devreq/bt_devinquiry, which btconfig uses. The SDP part of libbluetooth waits for phase 3 |

Not ported in phase 1: bt_proto.c (134 lines, the NetBSD protosw table, replaced by the sockmod
registration) and bt_sysctl.c (262 lines; its few tunables become ubt.conf properties). l2cap_*,
rfcomm_* and sco_* wait for phase 3, behind stubs.

Total ported: 7,323 kernel lines (hci_* 4,431, headers 2,792, the 1,853-line ubt rewritten
rather than compiled) plus 2,610 userland lines. Licence check: `grep -c 'advertising materials'`
gives 0 on every file above, so there is no advertising clause. These are the same terms as
iwx and obsd-compat: keep each copyright block and list the files in PROVENANCE.md. **Do not open
Linux's btusb.c, btintel.c or net/bluetooth (GPL).** Everything above has a BSD source, and the
Intel specifics come from FreeBSD's BSD-2 files.

## 2. What each piece needs from illumos

### 2.1 ubt over USBA (new, about 900-1,100 lines)

| NetBSD | illumos | notes |
|---|---|---|
| usbd_open_pipe_intr(0x81, 257-B buffer, ubt_recv_event) | `usb_pipe_xopen` + `usb_pipe_intr_xfer(USB_FLAGS_SLEEP)` with `intr_attributes = USB_ATTRS_SHORT_XFER_OK \| USB_ATTRS_AUTOCLEARING` and `intr_len = 64` (wMaxPacketSize) | ugen polls with intr_len = wMaxPacketSize (usba_ugen.c:2867), and bt1 measured events arriving as 64-B packets. So each callback is one packet, and ubt reassembles HCI events from their own length byte. bt1's tested `ugen_evq.c` (56 lines, libc-free apart from memcpy) does exactly that and can be lifted |
| usbd_setup_default_xfer (class request, UT_WRITE_CLASS_DEVICE, bRequest 0) | `usb_pipe_ctrl_xfer` on `dev_default_ph`, bmRequestType 0x20, bRequest 0, wIndex 0 | the same setup bt1 sends through cntrl0 |
| usbd_open_pipe(0x82) + usbd_transfer (ACL in) | `usb_pipe_bulk_xfer`, a 2,047-B request (UBT_BUFSIZ_ACL), re-armed from the callback | no ACL traffic during inquiry, but the unit init reads the buffer sizes, and the pipe is opened so the path exists |
| usbd_open_pipe(0x02) (ACL out) | `usb_pipe_bulk_xfer` | phase 3 is the first real user |
| isochronous SCO on if1 (ubt_set_isoc_config) | not in phase 1 | phase 7 |
| usbd_clear_endpoint_stall_async on a stalled bulk pipe | `USB_ATTRS_AUTOCLEARING` | USBA clears a functional stall itself (hcdi.c:892-930) |
| usbd_abort_pipe / close | `usb_pipe_stop_intr_polling` + `usb_pipe_close(USB_FLAGS_SLEEP)` | |
| config_found / device_t / sc_dying | dev_info_t, `usb_client_attach`, `usb_register_event_cbs` for disconnect | the ihid/hid(4D) attach shape (src/ports/touchpad/ihid.c) |

Locks: ubt callbacks run in USBA's callback thread, not in interrupt context. That is enough to
take a kmutex and to `ddi_intr_trigger_softint` (or taskq_dispatch) into netbt.

### 2.2 mbufs (new, about 350 lines + a unit test)

netbt treats mbufs as BSD mbufs. It writes `m_len` and `m_pkthdr.len` directly (hci_unit.c:319,
hci_link.c:503, l2cap_signal.c:1024-1047, rfcomm_session.c:1505-1698), chains through `m_next`
(rfcomm_session.c:1596), stores a context pointer in the packet header (M_GETCTX/M_SETCTX: 3 and 3
uses), and tags packets with `M_LINK0` and `M_PROTO1`. The iwx layer (src/ports/wifi/iwx/iwx_mbuf.h)
was built to *forbid* that (its points 1 and 2: no stored lengths, no re-windowing m_data), so it
can't be reused as is. A plain BSD-style `struct mbuf` is smaller and easier to get right: a
header with m_next, m_data, m_len, m_flags and m_pkthdr{len, ctx}, plus a kmem_cache of 256-byte
mbufs and 2-KB clusters. Copy to and from mblk_t only at the two edges (ubt's USB buffers, and the
socket upcall). The core uses m_copydata 72x, m_adj 67x, m_freem 44x, MBUFQ_* about 40x,
m_gethdr 5, m_copypacket 4, m_copyback 4, M_PREPEND 3, m_split 2, m_cat 2 and m_align 1 (counted
over hci+l2cap+sco+rfcomm, so phase 3 needs nothing more). Test it in userland like
iwx_mbuf_test.c, with negative controls: an off-by-one in m_copydata and m_adj on a chain
boundary.

### 2.3 KPI shims (new, about 300 lines)

| NetBSD | illumos | trap |
|---|---|---|
| mutex_init/enter/exit, kmutex_t, `bt_lock` | kmutex_t, MUTEX_DRIVER | NetBSD passes an IPL. Drop it |
| cv_init/cv_broadcast | the same | |
| cv_timedwait_sig(cv, lock, ticks), relative, returns 0/EWOULDBLOCK/EINTR | `cv_reltimedwait_sig(cv, lock, ticks, TR_CLOCK_TICK)`, returns >0/-1/0 | illumos's `cv_timedwait_sig` takes an **absolute** time (condvar.h:101). A one-line wrapper with the return-value translation, plus a unit test, because hci_enable's 5 s wait depends on it |
| callout_init/setfunc/schedule/stop/invoking/ack/destroy (about 47 uses over all of netbt, 10 in hci_link.c) | timeout(9F)/untimeout(9F) behind a 6-function struct callout | obsd-compat's `timeout_*` (src/drm-port/obsd-compat/obsd_kern.c:202-320) already solved the "untimeout waits for a running handler" semantics. Copy that pattern. callout_invoking/ack become a flag set under bt_lock |
| softint_establish/schedule/disestablish (7) | `ddi_intr_add_softint` on ubt's dip, or a single-thread taskq | the taskq is simpler and has no dip dependency in the core |
| pool_get/put (l2cap_pdu, hci memo) | kmem_cache | |
| malloc/free(M_BLUETOOTH) | kmem_zalloc/kmem_free with a size | NetBSD free has no size argument. Cache the size in the 3 structures that use it |
| kauth_authorize_device / kauth_cred_dup (13 in netbt, 4 in hci_socket.c/hci_ioctl.c) | `secpolicy_net_config(cr, B_FALSE)` for the privileged set ioctls and unfiltered commands; `crhold`/`crfree` for hp_cred | the raw-HCI policy is: non-root may read events and send the safe-command list (hci_socket.c's `hci_cmds` filter), root may send anything. Map that policy one-for-one |
| sys/queue.h LIST/TAILQ/SIMPLEQ | illumos sys/queue.h has all three [read] | |
| device_xname(dev) | `"ubt%d"` from ddi_get_instance | unit names are what btconfig prints |
| microtime (3) | uniqtime/gethrestime | |

### 2.4 Phase-1 stubs (about 60 lines)

hci_link.c calls l2cap_close, l2cap_recv_frame, l2cap_request_free, l2cap_send_config_req,
l2cap_send_connect_req, l2cap_send_connect_rsp, l2cap_start and sco_detach_pcb, and reads
l2cap_active_list/l2cap_listen_list and the rfcomm_session lists. Phase 1 compiles a stub file
with empty lists. The stubs refuse an inbound connection (hci_acl_newconn finds no listener and
rejects it, which is what NetBSD does with no listener). Each stub is tagged STUB in the source
and in STATUS.md, so a stub can't be mistaken for an implementation.

(Callback context, [read]: for non-isochronous pipes, USBA delivers callbacks from a per-interface
taskq (hcdi.c:553-583), not from interrupt context. Only USE_SOFT_INTR pipes, which means
isochronous, run in a soft interrupt.)

### 2.5 The HCI socket module (new glue about 500-700 lines, plus hci_socket.c ported)

* **Family number.** illumos has AF_MAX = 32 = AF_PACKET (sys/socket.h:308-310). Nothing in sockfs,
  the syscall layer or libsocket range-checks the family. `so_socket` passes it to
  `socket_create`, and `sockparams_create` and soconfig's parse_params take any int (soconfig.c:301-312,
  sockparams.c:187-210) [read]. So `AF_BLUETOOTH 33` needs only a gate header line, for
  userland's benefit, and a sock2path entry. Pick it once (design doc §8). FreeBSD uses 36 and
  NetBSD 31. Neither number carries an ABI that matters to us.
* **Shape.** One module, `sockbt`, with an `smod_reg_t` (SOCKMOD_VERSION) and a `sock_downcalls_t`,
  modelled on sockmod_pfp.c (1,562 lines; its create path checks `secpolicy_net_rawaccess` at line
  277 and delivers with `su_recv` at line 554). The sock2path entry is `33 4 1 sockbt` (SOCK_RAW is 4 on illumos,
  socket.h:115, not BSD's 3; BTPROTO_HCI 1). It registers SOCK_RAW/HCI only in phase 1.
* **Mapping.** hci_socket.c's usrreqs map onto downcalls: attach -> sd_activate/create, bind ->
  sd_bind, connect -> sd_connect, send -> sd_send (the mblk is copied to an mbuf), ctloutput ->
  sd_setsockopt/sd_getsockopt (SO_HCI_EVT_FILTER, SO_HCI_PKT_FILTER, SO_HCI_DIRECTION), ioctl ->
  sd_ioctl -> hci_ioctl_pcb. Receive is `sbappendaddr` -> `su_recv` with the source sockaddr_bt as
  a T_UNITDATA_IND header, the way pfp builds one (sockmod_pfp.c:499). The 4 `kauth_*` uses in
  hci_socket.c become the secpolicy calls from §2.3.
* **ioctl sizes.** struct btreq is about 56 bytes, under IOCPARM_MASK 0xff (ioccom.h:54). The
  `_IOWR('b', n, struct btreq)` numbers can be kept as they are.

### 2.6 The userland ABI header

NetBSD's `struct sockaddr_bt` begins `uint8_t bt_len; sa_family_t bt_family;` (bluetooth.h:92-99).
illumos has no sa_len, and its sa_family_t is 16 bits. The illumos header drops bt_len and keeps
the rest in order, as `{ sa_family_t bt_family; bdaddr_t bt_bdaddr; uint16_t bt_psm; uint8_t
bt_channel; uint8_t bt_zero[5]; }`. The 9 `bt_len` references (hci_socket.c 6, bt_dev.c 2,
btconfig.c 1) become `#ifdef` or `sizeof`. Ship the headers as `<netbt/bluetooth.h>` and
`<netbt/hci.h>` from the driver package, kernel-only parts under `_KERNEL`. A gate change to
`<sys/socket.h>` (AF_BLUETOOTH) is deferred: userland defines `AF_BLUETOOTH 33` in
`<netbt/bluetooth.h>` until the number is settled.

### 2.7 Userland (about 150 lines of compat)

btconfig + libbluetooth (bt_dev.c, bluetooth.c) need `getprogname`, `strlcpy` (both present in
illumos libc), `<util.h>` (NetBSD; btconfig uses only `snprintb`, once, for the flags line, so a 40-line local copy),
`__RCSID`/`__dead` (empty macros), and `bluetooth.h` from §2.6. They build as one derivation
(`pkgs.solnix.btconfig`), like `pkgs.solnix.touchpad-driver`.

## 3. Attach and binding: opt-in, unbound by default

**Project rule: new drivers ship unbound.** ubt follows hardware.wirelessIwx
(modules/config/wireless-iwx.nix): a `hardware.bluetoothUbt` option set with `enable`
(puts the module, `ubt.conf` and the sockbt module in the closure and in the BE kernel tree, and
gives ubt a major and `minor_perm`) and `attachAtBoot` (default **false**; when true it writes the
driver_aliases line). `onMedia` lays the modules in with no alias, as wirelessIntel.onMedia does.

**Which name to bind.** The interface child for interface 0 gets these compatible names
(usba.c:2683-2735, [read]): `usbif8087,33.<rev>.config1.0`, `usbif8087,33.config1.0`,
`usbif8087,classe0.1.1`, ..., `usbif,classe0.1.1`. lixi's alias is
**`"usbif8087,33.config1.0"`**: the exact device, interface 0 only. Do not use:
* `usb8087,33` or `usb,classe0.1.1`: device level. ubt would replace usb_mid, ugen would go away,
  and the phase-0 loader would stop working.
* `usbif,classe0.1.1` or `usbif8087,classe0.1.1`: interface 1 (the SCO alternates) is also
  e0/01/01, so ubt would attach twice. If a generic class alias is wanted later, ubt's attach
  must return DDI_FAILURE on any interface other than the one carrying the 0x81 interrupt
  endpoint, and that has to be tested first.

**What stays working.** With ubt bound to interface 0, usb_mid still owns the device and still
creates device-level ugen (usb_mid.c:1023-1038), so `/dev/usb/8087.33/0/*` stays [read; verify
with prtconf after the first attach]. The loader then works as long as ubt is **down**. ubt opens
pipes only in `ubt_enable` (`btconfig ubt0 up`) and closes them in `ubt_disable`. While ubt is up,
the loader's `open(if0in1)` fails with EBUSY (usbai_pipe_mgmt.c:911-920). That is the correct
outcome, and it is one of the tests. ugen's control filter refuses host-to-device
device-recipient requests only from a non-owner (usba_ugen.c:2485-2496), and usb_mid is the owner,
so the loader's class commands keep working.

**Phase-1 operating order** (phase 2 folds steps 1-2 into attach):
1. boot. usb_mid + ugen on device@a, ubt attached to interface 0 and down.
2. `btintelfw -l` loads the firmware over ugen (bt1's tool, unchanged).
3. `btconfig ubt0 up`. ubt_enable sends 0xfc05 on the default pipe and reads img_type. If it is not
   0x03, ubt_enable returns EAGAIN (bootloader guard, §0.3). Otherwise it sends the toggle reset
   (§4), opens the pipes, and hci_enable runs the init sequence.
4. `btconfig ubt0 inquiry`.

## 4. CLEAR_FEATURE on every interrupt-pipe open

bt1 measured the cause (design doc §9). xhci unconfigures interrupt and isochronous endpoints on
close (xhci_usba.c:595-625), so each reopen goes through Configure Endpoint and the host's
sequence restarts at DATA0. The device keeps its own toggle, so after an odd number of packets the
next session's first packet is dropped. In ubt the reopen happens on every `down`/`up`, every
detach/attach and every suspend/resume.

What ubt does, in `ubt_enable`, **before** `usb_pipe_xopen(0x81)`:

    usb_pipe_sync_ctrl_xfer(dip, dev_default_ph,
        USB_DEV_REQ_HOST_TO_DEV | USB_DEV_REQ_RCPT_EP,   /* 0x02 */
        USB_REQ_CLEAR_FEATURE, 0 /* ENDPOINT_HALT */, 0x81, 0, NULL, 0, &cr, &cbf, USB_FLAGS_SLEEP);

Why this call and not `usb_clr_feature`: §0.2. usb_clr_feature with the pipe closed is a NULL
dereference, and with the pipe open the clear comes after the host endpoint was configured. bt1
measured clear-then-open, not the reverse. This is the same raw request USBA's auto-clearing sends
(hcdi.c:910-917). Failure is logged and is not fatal, because the reset may still be in sync.
Bulk and control endpoints stay configured across close (xhci_usba.c:600-606), and reopening one
re-uses the configured endpoint with a Set TR Dequeue (xhci_usba.c:185-212) [read]. So 0x82/0x02
are not affected the same way, and the plan does not clear them. That is a hypothesis, and §5 test
U6 checks it.

The negative control is a `ubt.conf` property `ubt-no-toggle-reset=1` that skips the clear, so
the same binary can show the alternation (§5).

## 5. Testing, mostly without rebooting lixi

What can be loaded without a persistent change, [read] and to be confirmed on the first try:
* **netbt core as a misc module, and sockbt as a socket module.** Neither needs a major number:
  only drivers do (mod_installdrv, modconf.c:567-572). `modload /tmp/bt3/netbt` and
  `modload /tmp/bt3/sockbt` from tmpfs, then `soconfig 33 4 1 sockbt`. soconfig without -f talks
  to the kernel only (soconfig.c:301-372), and sockfs finds an already-loaded module by name
  before it tries `modload("socketmod/...")` (sock_conf.c:223-249). `soconfig 33 4 1` with no
  module, then `modunload`, undoes it. A reboot clears it too.
* **The ubt driver needs a major, an alias, and an attach.** `drvconfig -b -i ubt -m <maj> -a
  '"usbif8087,33.config1.0"'` does the MODADDMAJBIND with no /etc write (devfsadm.c:595-725;
  this is what add_drv runs after it edits the files, drvsubr.c:1225-1262). But
  `i_ddi_bind_devs` only rebinds nodes that exist (modctl.c:690-697), and lixi has **no
  interface-0 node today**: ugen created device-level nodes with REMOVE_CHILDREN
  (usba_ugen.c:395-410). So the attach needs a re-enumeration (`cfgadm -c unconfigure/configure
  usb1/10`, the BT port [measured: usb1/10 = device@a]), and an attach writes `/etc/path_to_inst`
  and /dev links. **So every ubt attach on lixi happens in a boot-once BE**
  (docs/boot-environment-safety.md): `beadm create solnix-32-bt`, add the driver files and the
  alias inside it, `beadm activate -t`, reboot, test, and the next reboot returns to solnix-32.
  That needs the orchestrator's approval, and the maintainer must not be logged in.

**Tiers (each tier passes before the next starts):**

| tier | where | what it proves | negative control |
|---|---|---|---|
| T0 unit | chef, userland | mbuf shim (copydata/adj/split/cat over chain boundaries), callout shim, cv_reltimedwait return mapping, HCI event reassembly from 64-B packets | an off-by-one in each, which must flip the test (the bt1 `negative-controls.sh` pattern) |
| T1 core in userland on fixtures | chef | netbt hci_unit+hci_event+hci_misc compiled against a userland KPI shim, fed a recorded event stream (reset -> bdaddr -> buffer size -> features -> version -> commands -> inquiry results). Ends in BTF_INIT clear, the right bdaddr, and N memo entries | corrupt a Command Complete opcode: init must not finish; drop one inquiry result: N-1 |
| **T2 core in userland on lixi** | lixi /tmp, no kernel change | the **same** T1 binary with bt1's ugen transport (ugen_usb.c + ugen_evq.c) in place of the fixture: real init and a real inquiry against the AX211 | firmware not loaded (after a reboot, before `-l`): T2 must refuse on img_type 0x01 and must not send HCI_Reset |
| T3 modules load | lixi /tmp | `modload netbt`, `modload sockbt`, `soconfig 33 4 1 sockbt`. `socket(33, SOCK_RAW, 1)` succeeds; with no unit, `ioctl(SIOCNBTINFO)` returns ENXIO; modunload is clean | `socket(33, SOCK_RAW, 2)` -> EPROTONOSUPPORT (only HCI is registered) |
| T4 ubt attach | lixi boot-once BE | ubt0 attaches to interface 0. `/dev/usb/8087.33/0/*` still exists. `btintelfw -l` still loads the firmware with ubt down. `btconfig` lists ubt0 | ubt up + loader `-V` -> EBUSY, not a hang |
| T5 up + inquiry | lixi boot-once BE | `btconfig ubt0 up` -> the adapter's bdaddr, e.g. 00:00:5e:00:53:39 (bt1's OTP read), `btconfig ubt0 inquiry` lists at least one device the maintainer puts in discoverable mode | `btconfig ubt0 up` *before* the load -> EAGAIN (bootloader guard), and the controller still answers `btintelfw -r` afterwards |
| T6 toggle | lixi boot-once BE | `down`/`up` x8, with one HCI command per cycle: 8/8 | `ubt-no-toggle-reset=1` -> alternation |

T2 is the step that makes lixi reboots rare: protocol bugs surface in userland, and the boot-once
BE only has to test the USBA transport and the attach. Judge T5 and T6 by rate over at least 8
cycles, as bt1 did. The toggle bug only showed up across sessions.

Hazards on lixi while testing: check `ps -u gburd | grep cosmic-session` before every step; run
every command under an on-host exact-pid watchdog (lixi has no timeout(1)); read devstat nodes only
with O_NONBLOCK; don't touch pchsmbus, tzmon or the dGPU; dtrace/mdb need
LIBCTF_DECOMPRESSOR=/run/current-system/world/lib-64/libz.so.1. A kernel module bug in T3-T6 can
panic lixi, so arm `dumpadm` and keep the session on the wired link (usbecm0).

## 6. Pieces, order and size

Each piece is small enough to have its own check, and none needs the next one to be tested.
Lines are new or rewritten lines. Ported files compile with as few edits as possible, and each
edit is marked `/* solnix: */` so a rebase against NetBSD stays mechanical. Layout:
`src/ports/bluetooth/netbt/upstream/` (vendored, read-only, like iwmbtfw/upstream), `compat/`,
`ubt/`, `sockbt/`, `userland/`.

| # | piece | new lines | check | needs lixi? |
|---|---|---|---|---|
| P1 | vendor NetBSD files (§1) read-only + PROVENANCE.md (rev, sha256 per file, licence blocks) | 0 (+7.3k vendored) | `repo-integrity-check.sh`; licence grep = 0 advertising clauses; a sha256 manifest | no |
| P2 | mbuf shim + userland test | 350 + 250 test | T0, with 2 negative controls | no |
| P3 | KPI shim (mutex/cv/callout/softint/pool/malloc/kauth/xname) in a kernel and a userland flavour | 300 | T0: callout cancel-while-running, cv_reltimedwait mapping | no |
| P4 | **netbt core in userland** (hci_unit/event/misc/link/ioctl + stubs §2.4) with a fixture transport | 200 glue | T1, with 2 negative controls | no |
| P5 | **P4 on lixi over bt1's ugen transport** (`hcitest -i`: init + inquiry) | 150 | T2, with the bootloader negative control | lixi /tmp only, warm or cold controller |
| P6 | netbt as a kernel misc module (the same sources, kernel shim flavour) | 80 Makefile/modlinkage | builds `-Werror` against the gate proto; `modload`/`modunload` on chef (an EC2 instance) | no (chef) |
| P7 | sockbt socket module, HCI only (§2.5) | 600 | T3 on chef: socket/bind/ioctl ENXIO with no unit; EPROTONOSUPPORT control | no (chef) |
| P8 | btconfig + libbluetooth (bt_dev.c, bluetooth.c) userland + ABI header (§2.6, §2.7) | 150 | `btconfig` builds; on chef with P6+P7 loaded, `btconfig -l` prints nothing and exits 0 | no (chef) |
| P9 | ubt USBA driver (§2.1, §3, §4): attach on if0, enable/disable, cmd/event/ACL, the bootloader guard, the toggle reset | 1,000 | builds; attach/detach on chef against a QEMU usb-host passthrough is NOT available (no BT dongle on EC2), so the first real attach is T4 | **boot-once BE** |
| P10 | `hardware.bluetoothUbt` module + pkgs (ubt-driver, netbt modules, btconfig), unbound by default | 150 nix | `nix eval`: attachAtBoot=false renders no driver_aliases line, true renders exactly `ubt "usbif8087,33.config1.0"` | no |
| P11 | T4-T6 on lixi | 0 | the tier table | boot-once BE, 1-2 reboots |

Total: about 3,200 new lines + 7,300 vendored kernel + 2,600 vendored userland. That is in the
design doc's phase-1 range (3-4k new + 4k ported). The ported number is higher because hci.h and
hci_socket.c are now included.

Dependencies: P2, P3 -> P4 -> P5; P4 -> P6 -> P7 -> P8; P6 + P8 -> P9 -> P11; P10 runs alongside
P9. P5 and P6-P8 are independent and can be handed to two agents.

Expected trouble, so it is planned for, not discovered:
* hci_event.c's init sequence asks for Read Local Supported Commands and the extended features
  pages. The AX211 is BT 5.3 and will answer, but it may also send LE Meta events or
  Intel vendor events (0xff) that netbt drops. P5 logs every dropped event code, so T5 isn't
  blamed on them.
* `hci_enable` sleeps on bt_lock while ubt callbacks run on USBA's taskq. The ordering (bt_lock
  before the ubt softc lock, never the reverse) is written down in P9 before the code.
* With ubt up, usb_mid PM could suspend the device. The config descriptor's bmAttributes is
  0xe0, remote wakeup (usb_mid.c:1390-1425). bt1 saw no usb_mid_power calls with ugen open. ubt
  raises its PM component while it is up (`pm_busy_component`), the way hid(4D) does.

## 7. Recommendation: build P4 + P5 first

Build the netbt HCI core in userland and run it on lixi over the ugen transport bt1 already
proved. Reasons:
* It tests the largest and least known part (4.4k lines of hci_*.c behind new shims) against the
  real AX211, with no kernel module, no BE and no reboot. The firmware stays loaded until a
  reboot, so P5 can run any number of times on a warm controller, and on a cold one after
  whatever the next reboot is.
* It needs nothing new from illumos. P2-P4 run on chef. P5 re-uses ugen_usb.c and ugen_evq.c,
  which are tested and have 6/6 negative controls.
* A pass gives phase 1 its acceptance shape early: `hcitest -i` prints the bdaddr, the buffer sizes,
  the features and the inquiry list. A later T5 that differs from it points at ubt or sockbt, not
  the core.
* It costs about 800 lines (P2 + P3 + P4 + P5) before any kernel code exists, and P2/P3 are
  needed by the kernel build anyway.

Then P6-P8 on chef, then P9 + P10, then one boot-once BE session on lixi for P11.
