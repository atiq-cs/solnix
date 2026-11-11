# COSMIC on illumos: the integration points that differ from Linux, and how each is tested

COSMIC is written for Linux. On solnix it runs on illumos, so every place where COSMIC (or a crate it vendors) touches the OS
is a place it can break differently than upstream ever sees. This file lists those places. Each one gives the Linux
mechanism, the illumos one, the defect we actually hit (with the commit that fixed it), and the automated check that keeps
it fixed. Every check has a **negative control**: a build or store path that still has the defect, and the check must fail
on it. A check that has never failed is not a check.

The suite lives in `scripts/cosmic-itest/` and runs on lixi (the reference laptop: ThinkPad X1 Extreme Gen 5, i915 ADL-P).
- **tier 0:** no desktop session. Static checks of ELF objects and kernel modules, and syscall/ABI probes on the test's own
  file descriptors. Safe while someone uses the machine.
- **tier 1:** a test session as `cosmictest`, started through greetd's IPC socket (cosmic5's `lrun.sh`), with the
  8 GB kernel-memory guard (`kwatch.sh`) running. Only while nobody is logged in. The account is the test's own: t1
  creates it at start (uid in UID_MIN..UID_MAX, home under /var/tmp, a random password it hands greetd) and deletes it,
  home included, when it ends. It is never declared in a desktop config and never left behind. The first cosmictest was
  made by hand on lixi; install-be.sh's account merge keeps undeclared lines, so it rode along into later BEs with a
  live password until desk1 locked it (2026-11-10).
- **tier 2:** apps and integrations inside a session.
Each check prints `PASS`, `FAIL`, `GAP` (an integration solnix doesn't have yet) or `SKIP`. The suite writes JSON and one
summary line.

## 1. Kernel graphics (the i915 port: OpenBSD inteldrm on illumos)

| point | Linux | illumos / solnix | defect seen | fix | check (tier) | negative control |
|---|---|---|---|---|---|---|
| errno values returned to userland | Linux errnos | the module is built against OpenBSD's linux/errno.h, which aliased ETIME to ETIMEDOUT | a timed-out syncobj wait returned -145; Mesa's iris_bo_busy compares with -62, so every busy batch BO read as idle and was reused while the GPU ran it: rcs0 CS errors, 24+ resets, panel crashes | b46be77 | t0: disassemble `drm_syncobj_array_wait_timeout` in the installed module; the timeout constant must be -62. A probe on its own render fd: a timeout-0 wait on an unsignalled syncobj returns -ETIME (62) and a signalled one returns 0 | module b04e9fd6 (-145) |
| every errno in the module | — | the same header aliased ENODATA, ECHRNG, ENOPKG, EMULTIHOP, EBADSLT, ENOLINK, EREMCHG and EBADRQC | (latent) | b46be77 | t0: the patched linux/errno.h has no alias for an errno illumos defines; built with `_Static_assert(ETIME == 62)` | the unpatched header |
| interrupt barrier | `synchronize_irq` waits for running handlers | the port's `intr_barrier` toggled MSI enable with `ddi_intr_disable`/`enable` on every GT park | a lost MSI edge stopped every display interrupt: flip_done timeouts, then a greeter EBUSY loop leaking about 5 MB/s of kernel memory | 4dfacc1 | t0: the module has no `ddi_intr_disable`/`ddi_intr_enable` relocation in `intr_barrier`; t1: 0 flip_done timeouts over N sessions | module 29b36fb5 (has the relocations) |
| frontbuffer refcount | RCU-protected lookup | no RCU in the compat layer (kfree_rcu frees at once) | a use-after-free wedge under cosmic-term's execbuf | f10d463 (obsd-norcu.patch) | t1: 0 panics and 0 frontbuffer warnings over N sessions | — |
| GPU resets | — | — | (the errno defect above) | b46be77 | t1: 0 "context reset due to GPU hang" lines in /var/adm/messages per compositor start, over at least 8 starts | solnix-27 measured 4 of 4 starts with resets |
| kernel SIMD | — | a module may use SIMD only inside kernel-FPU sections | two early modules had 6120 SIMD instructions outside FPU sections | d75ae48 | t0: `simd-gate.sh` over every GPU module | module 614a0cba |
| render-compressed scanout | CCS_CC modifiers are fine | (suspected) one of two swapchain buffers scanned out wrong: flicker on pointer motion | stopgap INTEL_DEBUG=noccs | fa7305e | t1: the primary plane's PLANE_CTL has render decompression off, and the maintainer reports no flicker | the session without noccs |

## 2. Event loops (calloop, polling, mio, tokio)

| point | Linux | illumos | defect | fix | check | negative control |
|---|---|---|---|---|---|---|
| `polling`'s backend | epoll | event ports by default, which have no level-triggered mode | calloop re-associated each fd before dispatch, a ping pipe fired again, and the channel pinged itself forever: every client grew to 3-4 GB in about 2 minutes, and the greeter sat at 100% CPU | 73c4cf7 (vendor fixup item 11: epoll on illumos) | t0: every COSMIC ELF that contains `polling` symbols has 0 `7polling4port` and at least 1 `7polling5epoll` mangled symbol (`.symtab`); t1: every client's RSS stays flat over 10 min | cosmic-applets 3danjnp8 (6 port symbols, 0 epoll) |
| an epoll fd nested in an event port | wakes the parent | `devpoll`'s `dppoll()` gives no pollhead, so an epoll fd inside an event port never wakes it | the compositor never read a client request | the same fixup (compositor first) | t1: a client connects and its first frame is drawn | — |
| timerfd, eventfd | Linux syscalls | illumos has both; rustix needs its illumos arms | — | vendor fixups | t0: a probe creates a timerfd and an eventfd and reads them | — |

## 3. Wayland and IPC

| point | Linux | illumos | defect | fix | check | negative control |
|---|---|---|---|---|---|---|
| wayland sockets | `MSG_CMSG_CLOEXEC` on recvmsg | not supported | fd passing failed | vendor fixup item 2 | t1: a client receives a dmabuf or keymap fd | — |
| shm_open names | any name | needs a leading `/` | softbuffer and smithay's SealedFile failed | items 7 and 9 | t1: cosmic-term draws through softbuffer | — |
| the DRM device node | `major == 226` (Linux) | the illumos minor-number layout | smithay rejected /dev/dri/card0 | item 8 | t1: the compositor opens card0 | — |
| no udev | libudev | none | smithay's UdevBackend | item 6 (lists /dev/dri itself) | t1: the compositor finds the GPU | — |
| ioctl encoding | `_IOC` | rustix's solarish arm used the BSD encoding, while the port uses Linux's | DRM ioctls returned ENOTTY | item 1 | t0: a probe issues DRM_IOCTL_VERSION on the render node | — |
| D-Bus | systemd session bus | dbus-daemon started by start-cosmic | — | 890855e | t1: the session bus answers ListNames | — |
| logout order | systemd stops clients, then the compositor | cosmic-session stops everything at once, and the panel never stops its applets | about 16 cores per logout (applets, panel buttons, cosmic-term). cosmic-term's sctk thread sends a destroy on a freed wl_display (use-after-free in wl_map_insert_at) | core pruning 19c25cb now; the order fix and the iced_winit join in wave4 | t1: 0 new cores per logout | today's build: 16 per logout |

## 4. Input

| point | Linux | illumos | defect | fix | check | negative control |
|---|---|---|---|---|---|---|
| keyboard and pointer | libinput over evdev | the compositor reads consms and conskbd (illumos_input.rs) | — | d35f8cd | t1: injected key and motion events reach the compositor | — |
| touchpad | i2c-hid via libinput, multitouch | dwiic + ihid (polled; GSI 56 unusable) linked under consms, in mouse mode | the touchpad didn't move the pointer until the driver was installed | fa7305e | t0: ihid kstat polls are increasing and errors are 0; t1: reports reach consms | a BE without the touchpad option |
| precision touchpad mode | hid-multitouch sets Input Mode 3 and parses the Finger collections | ihid parses the PTP collection (hidptp.c, FreeBSD hmt(4) frame logic); feature report 3 = Input Mode, set to 3 only while an evdev client holds the node, back to 0 (mouse, under consms) on the last close | lixi's ELAN 04f3:320d ran in mouse mode only: one relative pointer, no contacts | tpad4 | build: hidptp_test on lixi's real descriptor (`src/ports/touchpad/elan-04f3-320d.rdesc.hex`), 14 checks incl. a 2-contact hybrid frame -> contact count 2 and slot 1; t0: touchpad-ptp (ihid has the input_mode kstat); live: kstat input_mode 0 -> 3 while open -> 0 after close | sabotaged hybrid count -> 6 FAIL, sabotaged confidence -> 1 FAIL; a mouse-mode report (id 1) is rejected; input_mode 0 with no client |
| evdev contact device | the kernel's evdev, /dev/input/event* | ihid's own evdev minor (STREAMS, clone open per client): the 16 ioctls libevdev uses, 24-byte input_event, MT protocol B, SYN_DROPPED, EVIOCREVOKE; devlink.tab `type=ddi_input:evdev` -> /dev/input/event\N0 | no evdev on illumos | tpad4 | evcat (libevdev_set_fd's ioctl set): IOCTLS OK; the store libevdev's libevdev_new_from_fd: 5 slots, X 0..3528 res 31, buttonpad; t0: touchpad-evdev-node | evcat on /dev/null: 22 bad ioctls; ITEST_TOUCHPAD_INPUT_DIR=/nonexistent |
| udev | systemd-udevd + libudev | libudev-solnix (src/ports/libudev-solnix, MIT): /dev/input/event* and the driver's `udev-properties` devinfo prop; no udevd, no hotplug | the link-only libudev stub made udev_new() NULL, so Settings never listed a Touchpad page and libinput could not start | tpad4 | udevtest (cosmic-settings' system_has_touchpad() logic + libinput's path-seat lookups): touchpad yes; t0: touchpad-udev | LIBUDEV_SOLNIX_INPUT_DIR=/nonexistent -> touchpad no (the package's build check) |
| libinput | libinput over evdev and udev | libinput 1.28.1 + libevdev 1.13.4 + mtdev 1.1.7 (MIT; FreeBSD BSD-2 input headers, not the bundled GPL ones) over ihid's node | none | tpad4 | `libinput debug-events --device`: DEVICE_ADDED "ELAN 04F3:320D Touchpad" cap:pg 114x65mm tap scroll-2fg-edge clickfinger | GAP: device quirks off (init_dmi has no illumos arm) |
| pointer acceleration, multitouch and gestures | libinput | libinput, once cosmic-comp uses it on illumos (next) | slow touchpad | — | GAP | — |

## 5. Memory and allocators

| point | Linux | illumos | defect | fix | check | negative control |
|---|---|---|---|---|---|---|
| mimalloc 2.x | user addresses are below 2^47 | user addresses are 0xfffffc7f…, negative as intptr_t | `_mi_ptr_segment` returned NULL for every segment, and pop-launcher died at its first malloc | 72f6a23 | t0: start pop-launcher with "Exit" on stdin: rc 0, no core | pop-launcher mj98i4x4 (crashes 3 of 3) |
| libumem | glibc malloc | UMEM_OPTIONS=backend=mmap for cosmic-term | — | 0f051d2 | t1: cosmic-term's RSS is flat | — |

## 6. Session, login, files

| point | Linux | illumos | check |
|---|---|---|---|
| greetd and PAM | Linux-PAM | Solaris PAM ("other" stack), pam-sys fixup item 10 | t1: a greetd IPC login of cosmictest succeeds; a wrong password fails |
| seat | logind | seatd with a `seat` group | t1: the compositor gets DRM master through libseat |
| which accounts are people | /etc/login.defs UID_MIN..UID_MAX (shadow-utils); cosmic-settings' Users page and cosmic-greeter filter on it, and assume 1000..60000 (greeter: 65000) when it is missing | security.loginDefs.settings writes NixOS's ranges (1000..29999, system 400..999); solnix's fixed system accounts are 30000 and up. Without the file, Users listed nixbld1-32, cosmic-greeter and messagebus | t0 users-uid-range: no account with a false/nologin shell or a /var/empty home inside the range. negctl: ITEST_LOGINDEFS=/nonexistent |
| XDG data and cursors | systemd environment generators | profile-relative XDG_DATA_DIRS and XCURSOR_PATH (fa7305e) | t0: the session environment lists sw/share; t2: the app library lists more than 50 entries |
| time zone | timedatectl | /etc/default/init TZ (time.timeZone) | t0: TZ is set |
| fonts | fontconfig | fontdb reads /etc/fonts/fonts.conf | t2: the panel renders text (a screenshot is not blank) |

## 7. Devices and services

| point | Linux | illumos | state | check |
|---|---|---|---|---|
| audio | PipeWire over ALSA | audiohd (by id, 19c25cb) and the audio(4I) framework; no PipeWire backend | the driver plays and records; COSMIC's applet doesn't work yet | t0: /dev/sound/audiohd:1 exists and audioplay of a 1 s tone takes 1 s ±0.2; t2: GAP until the cosmic-settings-daemon audio(4I) backend |
| power, battery, lid | upower, logind | acpi_drv kstats | GAP | — |
| network applet | NetworkManager D-Bus | dladm/ipadm, solnix-netd | GAP | — |
| backlight | sysfs backlight | none registered by the i915 port | GAP | — |
| Bluetooth | BlueZ | none yet (bt1 track) | GAP | — |
| camera | PipeWire/v4l2 | usbvc /dev/video0,1 | GAP (no app) | — |
| portal, keyring, notifications | xdg-desktop-portal, gnome-keyring, libnotify | not yet (need glib) | GAP | — |

## 8. Apps

| app | check |
|---|---|
| cosmic-term | t1: opens a pty (alacritty_terminal: openpty, TIOCSCTTY, setsid); `echo marker` appears in its grid (a screenshot or DRM read-back); logout leaves no core |
| launcher (pop-launcher) | t1: searching "set" returns Settings entries |
| settings | t2: every page opens without a crash |
| files | t2: lists $HOME |

## Running it

`scripts/cosmic-itest/run.sh [t0|t1|t2|all] [--negctl]`, on lixi. `--negctl` re-runs each check against its
negative-control store path and expects FAIL. t1 and t2 refuse to start while a non-test user has a session
(`ps -u gburd`). The results go to `/var/tmp/cosmic-itest/<time>.json`, with one summary line:
`cosmic-itest t0: 9 PASS 0 FAIL 6 GAP (negctl 5/5 failed as expected)`.

## Order of work

1. tier 0 with its negative controls: none of it needs a session.
2. tier 1 in a nightly run on lixi while it's idle, after the maintainer logs out.
3. tier 2 as each GAP closes.
4. Every new illumos fix adds a row here, and a check with its negative control, in the same commit.
