# Package universe: Hipster + OmniOS/SmartOS/Tribblix delta

Answers the "how many packages / what else to target / what's beyond Hipster"
questions. Numbers from docs/registry/hipster-packages.tsv (10,608-row inventory).

## Hipster (our primary upstream) — the numbers

| Status        | Count | Notes |
|---------------|-------|-------|
| **current**   | **5,920** | live packages — the real build target |
| renamed       | 485   | alias FMRIs -> current (not separate builds) |
| incorporation | 8     | version-lock meta-pkgs (not software) |
| obsolete      | 4,194 | dead/superseded — DO NOT build |
| **total rows**| 10,608 | the full IPS catalog we inventoried |

**Real target ≈ 5,920 current packages** (of which 5,371 userland, 503 osnet,
plus l10n/ips/install/cde/xvm). The "6,413 active" = current+renamed; renamed are
aliases so the build target is the 5,920 current.

## Beyond Hipster — other illumos distros' unique packages worth targeting

Hipster has the BROADEST IPS set, but each fork ships things Hipster doesn't.
Worth adding to the target universe (Phase 3 breadth):

### SmartOS / illumos-joyent (the biggest delta)
- **bhyve** — the illumos bhyve port (hardware VM). *Now also in OI, but SmartOS
  is the reference impl.* HIGH value (Phase 3 core-Solaris item).
- **KVM** — SmartOS-only illumos KVM port (NOT mainline). Verify before scoping;
  bhyve is the better long-term bet.
- **LX-branded zones** — run Linux ELF binaries. In-gate (from Joyent) but SmartOS
  exercises it most. HIGH value.
- **vmadm / imgadm** + the SmartOS VM/image tooling (JSON-driven zones/VMs).
- **pkgsrc** — SmartOS's primary userland is **pkgsrc** (NetBSD's), NOT IPS. That's
  a WHOLE SEPARATE ~20k-package universe (see below).

### OmniOS
- **Kayak** installer + **OmniOS-specific packaging** (they use IPS too, leaner set).
- Mostly a SUBSET of Hipster for userland, but their LTS/stable curation +
  server-focused extras (some networking/storage bits) differ.
- **ooce** (OmniOS Extra) publisher — a curated extra-packages repo; some pkgs
  packaged there but not in Hipster.

### Tribblix
- The **SPARC** build (our S1 source!) — Tribblix is the main live sparc illumos.
- **zap** package manager + Tribblix "overlays"; some retro/niche pkgs.

### The big one: pkgsrc (SmartOS + others)
- pkgsrc is a cross-platform source packaging system (NetBSD) with **~20,000
  packages**, many building on illumos. SmartOS ships pkgsrc binaries.
- This DWARFS the IPS set. DECISION: solnix packages natively via Nix (our
  mk-userland-pkg), so we target the SOFTWARE pkgsrc packages (upstream tarballs)
  directly, not pkgsrc-the-tool. But pkgsrc's illumos patch set is a GOLD MINE of
  "how to build $X on illumos" fixes — mine it for our heavy-tool patches.

## Recommendation
1. Finish the 5,920 Hipster current set (in progress: 2,004 cached).
2. Add the SmartOS core-virt delta (bhyve/LX-zones/vmadm) as Phase-3 features
   (not just packages — kernel/zone features).
3. Mine pkgsrc's illumos patches to unblock our heavy-tool tail (cmake/git/tmux).
4. OmniOS ooce + Tribblix zap: low-priority package-gap fill after Hipster is done.

## What to build from OmniOS/SmartOS/other illumos distros (server + desktop)

Gap-map (2026-07-28, distinct pkgs cached per category): desktop/GUI 0, mail 0,
storage/fs 0, container/virt 0, monitoring 0, web-server 1, dns 1, editors 1,
vcs 1 — vs lang-runtime 9, db-server 5. We're strong on runtimes/DB/base-libs,
THIN on the server+desktop application layer. That's the next breadth target.

### From OmniOS (server-focused, curated IPS + ooce extra repo)
- **ooce (OmniOS Extra) publisher** ships server apps we lack: nginx, haproxy,
  varnish, php-fpm, postgresql/mariadb (have core), redis, rabbitmq, mediawiki
  deps, node, go, rust (have), openjdk, tomcat, and networking (isc-dhcp, chrony,
  net-snmp, rsync). Mirror the ooce build recipes for the server tail.
- **OmniOS server stack:** Samba (CIFS), netatalk, NFS tooling, iSCSI target
  (stmf/COMSTAR — in-gate), the illumos-native ZFS admin tooling.
- Kayak installer patterns (ref for our T2.7 installer).

### From SmartOS / illumos-joyent (the biggest feature delta)
- **Virtualization FEATURES (not just pkgs — Phase-3/cloud-hardware work):**
  bhyve (HW VMs — now also in OI), LX-branded zones (run Linux ELF), KVM
  (SmartOS-only), vmadm/imgadm (JSON VM/image mgmt). These are kernel/zone
  features tracked in solnix-phase3-breadth T3.x + cloud-hardware, not simple pkgs.
- **pkgsrc (~20k pkgs)** = SmartOS's userland. We package natively via Nix, so we
  target the SOFTWARE (upstream tarballs) + MINE pkgsrc's illumos patches (already
  doing this — 7 family fixes derived from pkgsrc). The pkgsrc CATEGORY LIST is
  the best "what do people actually install" map: shells, editors, mail, web,
  databases, devel, sysutils, net, security, wip.

### Concrete next-wave targets (server + desktop application layer)
- **Web:** nginx, apache-httpd, haproxy, varnish, lighttpd(have), caddy(go-skip)
- **Mail:** postfix, dovecot, opensmtpd, rspamd, spamassassin, fetchmail
- **DNS:** bind9, nsd, knot-dns, dnsmasq, powerdns
- **Storage/FS/backup:** samba, netatalk, rsync(have), rclone(go-skip),
  restic(go-skip), borgbackup(py), rdiff-backup, minio(go-skip)
- **Monitoring:** collectd, net-snmp, nagios-plugins, telegraf(go-skip),
  prometheus-node-exporter(go-skip), htop(retry), sysstat
- **Editors/dev:** neovim (needs luajit/libuv — have libuv), emacs, vim(full),
  micro(go-skip), helix(rust-skip), ctags, cscope, the_silver_searcher(have)
- **Shells:** zsh(have), fish, bash(have), ksh93, mksh
- **VCS:** git(have), mercurial, subversion, fossil, cvs
- **Desktop/GUI (the big empty — needs the X11/Wayland stack FIRST):**
  Xorg-server + xorg libs, mesa (llvmpipe/softpipe — no GPU driver, SW render),
  cairo/pango(need)/fontconfig(have)/freetype(have), gtk3, qt5-base, then apps:
  xterm, st, alacritty(rust-skip), dwm/i3, firefox-skip-huge, mpv-skip, feh.
  Wayland: wayland/wayland-protocols, wlroots, sway, foot. This is a MULTI-wave
  effort; X11 stack is the prerequisite. NOTE: illumos Xorg exists (OI ships MATE
  desktop) — mine OI's Xorg/MATE build recipes.

### Recommendation
Server application layer FIRST (web/mail/dns/storage/monitoring/editors/shells/
vcs) — high value, mostly autotools, family fixes make them cheap. Desktop/GUI
(X11 stack -> toolkits -> apps) is a dedicated multi-wave track after; OI's MATE
desktop recipes are the reference (illumos Xorg is real, SW-rendered via mesa).
