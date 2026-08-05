# NixOS-vs-solnix first-boot defaults gap (beyond packages, ignoring Linux/illumos binaries)

What a freshly-installed NixOS host gets *by default* that makes it feel like a
complete, well-behaved system — audited against what solnix's base config sets
today. Excludes package content (covered in design-minimal-iso-parity.md) and
pure Linux-vs-illumos binary differences. This is the "system defaults" layer.

## Already set in solnix (parity or intentional equivalent)
- **hostname** — `networking.hostName` (mkDefault "solnix"). ✓
- **DNS / resolv.conf** — `networking.nameservers` → /etc/resolv.conf. ✓
- **primary NIC DHCP** — `networking.interfaces.ena0.dhcp`. ✓
- **admin escalation (sudo-equiv)** — illumos **RBAC**: gburd gets `profiles=Primary
  Administrator` in /etc/user_attr → `pfexec` = uid 0. (NixOS uses `sudo`; RBAC/pfexec
  is the native, correct illumos analog — keep it, but see "sudo-alias" below.) ✓
- **ssh key + hashed password** for the admin user; sshd under SMF. ✓
- **core-file policy** — coreadm → /var/cores, no CWD litter (we added; NixOS has
  systemd-coredump — same intent). ✓
- **edition marker** — /etc/solnix-release (os-release analog). ✓
- **Nix substituters + trusted key** (cache.solnix.io 5HAV). ✓
- **login PATH** (bash + ksh) incl the Nix profile + base OS. ✓ (just fixed the
  per-user-profile-bin gap)

## GAPS — NixOS sets these by default; solnix should adopt (native illumos means)
Ordered by how much they affect "feels complete / correct":

### Tier 1 — a system feels broken/foreign without these
1. **Time zone** — NixOS defaults `time.timeZone` (or UTC) + working `/etc/localtime`.
   solnix: unset → whatever the proto shipped. ADD: default TZ (UTC) via
   /etc/default/init `TZ=UTC` (illumos reads TZ there) + a `time.timeZone` option.
2. **Locale / LANG** — NixOS: `i18n.defaultLocale = "en_US.UTF-8"`, LANG/LC_* exported.
   solnix: unset → C/POSIX, mojibake on UTF-8 output. ADD: default `LANG=en_US.UTF-8`
   (+ ensure the locale exists; illumos ships en_US.UTF-8) via the login env +
   /etc/default/init.
3. **NTP / time sync** — NixOS: `services.timesyncd` on by default (clock stays correct).
   solnix: none → clock drifts (bad for TLS/nix sigs/logs). ADD: enable the illumos
   **`svc:/network/ntp`** (ntpd) or the sntp oneshot, pointed at pool/EC2 169.254.169.123.
4. **/etc/motd + /etc/issue** — NixOS sets a useful MOTD (version, docs link). solnix:
   proto default. ADD: a solnix MOTD (edition, "nix profile install <pkg>", docs URL).
5. **`sudo` alias to pfexec** — many users' muscle memory + scripts type `sudo`. NixOS
   ships sudo. solnix uses pfexec (correct). ADD: a `sudo` shim → `exec pfexec "$@"`
   in the profile (so `sudo <cmd>` works), documented as pfexec underneath.

### Tier 2 — hygiene / good-citizen defaults
6. **Nix GC + store optimise** — NixOS: weekly `nix-collect-garbage` timer +
   `nix.optimise`/`auto-optimise-store`. solnix: none → /nix grows unbounded. ADD:
   a periodic SMF timer running `nix-collect-garbage --delete-older-than 30d` +
   `auto-optimise-store = true` in nix.conf.
7. **Log rotation** — NixOS: logrotate/journald retention. solnix: illumos has
   **`logadm`** (native, /etc/logadm.conf) — ensure it covers /var/log + /var/cores.
   ADD: a logadm entry for /var/cores + any solnix logs.
8. **nsswitch** — NixOS tunes /etc/nsswitch. solnix inherits the proto's
   (files dns mdns — seen on the test host). Mostly fine; verify `hosts:` = `files dns`
   (drop mdns if no mdnsd) so DNS is snappy. VERIFY/ADD.
9. **/tmp policy** — NixOS: tmpfiles + optional tmpfs /tmp. illumos /tmp is tmpfs
   (swap) by default — OK; ensure /tmp is cleaned on boot (illumos does via
   svc:/system/filesystem/minimal). VERIFY.
10. **Default umask / shell rc** — NixOS sets a sane umask (022) + /etc/bashrc.
    solnix: ensure umask 022 + a minimal /etc/bashrc (aliases, PS1) so interactive
    shells are pleasant. ADD.

### Tier 3 — nice-to-have / later
11. **`nixos-help`/docs analog** — NixOS ships `nixos-help` + man. solnix: a
    `solnix-help` pointing at the docs + `nix profile install` usage. ADD (small).
12. **first-boot niceties** — NixOS regenerates ssh host keys on first boot (we do),
    grows the root fs (we do the rpool expand). VERIFY both in the image.
13. **`command-not-found`** — NixOS suggests the package for a missing command.
    Needs the pkg DB; defer.
14. **Firewall** — NixOS `networking.firewall` on by default. illumos has **ipfilter**
    (svc:/network/ipfilter). For a build host we've kept it off + relied on the EC2 SG;
    for a real release, consider a default-deny ipfilter with ssh open. DECISION needed.

## Recommended: adopt Tier 1 + Tier 2 as solnix base defaults
These are what make a fresh solnix boot feel like a finished OS rather than a
bare proto: correct time (TZ+NTP), UTF-8 locale, a helpful MOTD, `sudo`→pfexec,
Nix GC so /nix doesn't fill, logadm for cores. All via native illumos mechanisms
(/etc/default/init, svc:/network/ntp, logadm, SMF timers) — declared in the base
config so every image inherits them. Wire as new modules/config/*.nix
(time.nix, locale.nix, ntp.nix, motd.nix, nix-gc.nix) + the sudo shim in
shell-environment.
