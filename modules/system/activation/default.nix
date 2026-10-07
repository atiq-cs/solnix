# modules/system/activation/default.nix — system.build.toplevel + activation.
#
# solnix analog of NixOS's system/activation (activatable-system.nix +
# top-level.nix). The toplevel is the derivation whose closure IS the bootable
# world: the composed solnix systemPath + the solnix-generated SMF manifests +
# an SMF activation script (design-smf-init.md §3.1: svccfg import each manifest,
# apply enable/disable, svcadm to the target milestone) + a small /etc generation.
#
# It is NOT a full disk image — lib/make-be.nix consumes this toplevel and lays
# it into a bootable ZFS-root BE (the make-be boundary; some steps need root+ZFS
# on the host). The toplevel is the reproducible, store-resident part; make-be is
# the host-side assembly that turns it into a disk.
#
# ADD-not-replace (design-smf-init §5.1): the world's stock manifests come from
# the proto (make-be lays the proto as root). solnix's toplevel adds systemPath
# (the composed slices) + its own manifests + the activate script.

{ config, lib, pkgs, ... }:

let
  inherit (lib) mkOption types concatStringsSep mapAttrsToList filterAttrs optionalString;

  cfg = config.system;

  # target milestone the activation script drives to (Phase-1 gate).
  targetMilestone = "svc:/milestone/multi-user-server:default";

  enabledServices = filterAttrs (_: s: s.enable) config.smf.services;

  # SMF site profile enabling our services + the disable/enable deltas the boot
  # gotchas require (design-make-be §5 gotcha #16 + the site profile in
  # oi-make-be.sh §8). Generated from smf.services.* so the config drives it,
  # rather than the hand-written XML in the script. sendmail/hal/keymap/intrd/
  # ipmp/ipsecalgs are peripheral services that fail cleanly on headless EC2;
  # network/location drives dns/client online. These are NOT in smf.services
  # (they are world-stock), so they stay as fixed profile lines here.
  siteProfile = pkgs.writeText "solnix-site.xml" ''
    <?xml version="1.0"?>
    <!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
    <service_bundle type="profile" name="solnix">
    ${concatStringsSep "\n" (mapAttrsToList (name: svc:
      "  <service name='${svc.category}/${name}' version='1' type='service'><instance name='${svc.instance}' enabled='${if svc.enable then "true" else "false"}'/></service>")
      config.smf.services)}
      <service name="network/location" version="1" type="service"><instance name="default" enabled="true"/></service>
      <service name="network/smtp" version="1" type="service"><instance name="sendmail" enabled="false"/></service>
      <service name="network/sendmail-client" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/hal" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/keymap" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/intrd" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/ipmp" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/ipsec/ipsecalgs" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/ipsec/policy" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/filesystem/rmvolmgr" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/filesystem/autofs" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/rpc/smserver" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="network/ssh" version="1" type="service"><instance name="default" enabled="false"/></service>
      <service name="system/power" version="1" type="service"><instance name="default" enabled="true"/></service>
    </service_bundle>
  '';

  # The SMF activation script (design-smf-init §3.1). Runs ON-TARGET (svc.startd/
  # configd are already up). Idempotent: svccfg import is create-or-update.
  # `svcadm enable` per enabled service (import sets initial state; enforce so a
  # config flip takes effect). Removal-on-switch deferred to P2.1 (generation
  # diff) — a stale enabled service does not block the milestone gate.
  activate = pkgs.writeScript "solnix-activate" ''
    #!/sbin/sh
    # solnix activation — switch-to-configuration analog (design-smf-init §3.1).
    set -u
    SYS="''${1:-@toplevel@}"    # the toplevel store path (this system)

    # 1. Apply the solnix site profile (enable/disable deltas).
    /usr/sbin/svccfg apply ${siteProfile} 2>&1 || true

    # 2. Import / reconcile our generated manifests (idempotent).
    for m in "$SYS/manifest/solnix"/*.xml; do
      [ -e "$m" ] || continue
      /usr/sbin/svccfg import "$m" 2>&1 || true
    done

    # 3. Enforce enabled state for solnix-declared services.
    ${concatStringsSep "\n    " (mapAttrsToList (name: svc:
      "/usr/sbin/svcadm ${if svc.enable then "enable" else "disable"} ${svc.fmri} 2>/dev/null || true")
      config.smf.services)}

    # 4. Bring the system to the target milestone (idempotent).
    /usr/sbin/svcadm milestone '${targetMilestone}' 2>&1 || true

    echo "solnix activation complete (milestone ${targetMilestone})"
  '';

  # THE SWITCH-TO-CONFIGURATION SCRIPT (T2.5) — NixOS's switch-to-configuration
  # analog, placed in the toplevel at bin/switch-to-configuration. It maps a Nix
  # generation onto a ZFS boot environment (steering pillar 5): a solnix
  # generation = a `rpool/ROOT/<be>` BE, /nix/store lives inside the BE, switch
  # activates SMF live, boot creates a new BE for next reboot, rollback = beadm
  # activate the previous BE. See docs/design-generations.md.
  #
  # It takes the TARGET toplevel as $2 (so it can switch to any generation, not
  # just its own build-time self), and calls that target's own `activate` script
  # — the shared activation logic (svccfg import + svcadm) is not duplicated here.
  #
  # /sbin/sh + beadm + cp + nix-env. The generation registry is the NixOS one:
  # `nix-env -p /nix/var/nix/profiles/system --set <toplevel>` makes
  # system-<N>-link (a GC root until `nix-collect-garbage -d`), and generation N
  # boots from BE <pool>/ROOT/solnix-<N>.
  switchToConfiguration = pkgs.writeScript "switch-to-configuration" ''
    #!/sbin/sh
    # solnix switch-to-configuration (T2.5). NixOS analog, illumos/beadm-native.
    #   switch  <toplevel>   activate now (live SMF reconcile) + register + set boot
    #   test    <toplevel>   activate now, do NOT touch the boot default / BE
    #   boot    <toplevel>   create a new BE with <toplevel>, activate it for next boot
    #   list-generations     list the generation registry + beadm BEs
    # <toplevel> defaults to this script's own system (@toplevel@).
    set -u
    PATH=/usr/sbin:/usr/bin:/sbin:$PATH
    PROFILES=/nix/var/nix/profiles
    # the pool holding <pool>/ROOT/<be>: the running root's pool, not a fixed name
    # (a fixed "spool" made `boot` look up bootfs on a pool that does not exist).
    _rootds=$(zfs list -H -o name / 2>/dev/null)
    POOL="''${SOLNIX_POOL:-''${_rootds%%/*}}"
    BEROOT_MP="''${SOLNIX_BEROOT:-/a}"      # temp mountpoint for a new BE

    # helpers (defined before use — POSIX sh needs this order).
    # illumos `ln -sfn` silently FOLLOWS an existing symlink-to-directory (does
    # nothing, rc=0) unlike GNU; always rm -f then ln -s. relink() does it.
    relink() { rm -f "$2" 2>/dev/null; ln -s "$1" "$2"; }
    # this minimal proto has NO readlink(1); derive the target from `ls -l`.
    _readlink() { [ -h "$1" ] || return 1; ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'; }

    # SELF = this system's toplevel. bin/switch-to-configuration lives at
    # <toplevel>/bin/, so the toplevel is two dirs up from $0; fall back to
    # /run-current-system. (A derivation can't embed its own out-path, so we
    # discover it at runtime — NixOS uses the same trick.)
    _self_from_argv0() {
      d=$(dirname "$0"); case "$d" in */bin) dirname "$d";; *) echo "";; esac
    }
    SELF="$(_self_from_argv0)"
    [ -n "$SELF" ] && [ -e "$SELF/activate" ] || SELF="$(_readlink /run-current-system 2>/dev/null || true)"

    action="''${1:-}"; target="''${2:-$SELF}"
    [ -n "$action" ] || { echo "usage: switch-to-configuration switch|boot|test|list-generations [toplevel]" >&2; exit 1; }
    # list-generations needs no target; the rest do.
    case "$action" in
      list-generations|list) : ;;
      *)
        [ -d "''${SOLNIX_STORE_ROOT:-}$target" ] || { echo "FATAL: target toplevel '$target' not found" >&2; exit 1; }
        [ -e "''${SOLNIX_STORE_ROOT:-}$target/activate" ] || { echo "FATAL: $target has no activate script" >&2; exit 1; }
        ;;
    esac

    # --- generation registry: the nix profile, as NixOS -----------------------
    # nix-env adds system-<N>-link (N = last + 1; none if <toplevel> is already
    # the last generation) and points `system` at it; sets $gen to N.
    register_generation() {   # $1 = toplevel path
      ne=$(command -v nix-env 2>/dev/null); [ -n "$ne" ] || ne="$1/sw/bin/nix-env"
      [ -x "$ne" ] || { echo "FATAL: no nix-env to record the generation" >&2; exit 1; }
      "$ne" -p "$PROFILES/system" --set "$1" || { echo "FATAL: nix-env --set $1 failed" >&2; exit 1; }
      gen=$(_readlink "$PROFILES/system" | sed -n 's,^system-\([0-9]*\)-link$,\1,p')
      [ -n "$gen" ] && [ "$(_readlink "$PROFILES/system-$gen-link")" = "$1" ] \
        || { echo "FATAL: $PROFILES/system does not name a generation of $1" >&2; exit 1; }
      echo "generation $gen -> $1"
    }

    list_generations() {
      echo "== solnix generations ($PROFILES) =="
      for l in "$PROFILES"/system-*-link; do
        [ -L "$l" ] || continue
        n=$(echo "$l" | sed -n 's,.*/system-\([0-9]*\)-link$,\1,p')
        cur=""; [ "$(_readlink "$PROFILES/system" 2>/dev/null)" = "system-$n-link" ] && cur=" (current)"
        printf '  %3s  %s%s\n' "$n" "$(_readlink "$l")" "$cur"
      done
      echo "== beadm boot environments =="
      beadm list 2>&1 || true
    }

    # --- switch/test: activate SMF live (no reboot) --------------------------
    do_activate() {   # $1 = toplevel
      echo "== activating $1 (live SMF reconcile) =="
      /sbin/sh "$1/activate" "$1"
    }

    set_current_system() {   # $1 = toplevel  (the running root, not a new BE)
      relink "$1" /run-current-system 2>/dev/null || \
        { mkdir -p /run 2>/dev/null; relink "$1" /run-current-system; }
    }

    # --- boot: new BE per generation (steering pillar 5) ---------------------
    # beadm on our image needs the pool mounted + a menu.lst present (libbe
    # "Invalid path for menu.lst" otherwise); ensure_menu fixes that idempotently.
    ensure_menu() {
      mp=$(zfs get -H -o value mountpoint "$POOL" 2>/dev/null)
      if [ "$mp" = "none" ] || [ -z "$mp" ]; then
        zfs set mountpoint="/$POOL" "$POOL" 2>/dev/null || true
        mp="/$POOL"
      fi
      mkdir -p "$mp/boot" 2>/dev/null || true
      if [ ! -f "$mp/boot/menu.lst" ]; then
        # _mbe, not be: POSIX sh has no locals, and do_boot's $be must survive this
        # (measured: an empty bootfs made be="." and `beadm create .` ran).
        bootfs=$(zpool get -H -o value bootfs "$POOL" 2>/dev/null)
        [ -n "$bootfs" ] || { echo "FATAL: pool $POOL has no bootfs" >&2; exit 1; }
        _mbe=$(basename "$bootfs")
        printf 'title %s\nbootfs %s\n' "$_mbe" "$bootfs" > "$mp/boot/menu.lst"
      fi
    }

    do_boot() {   # $1 = toplevel
      register_generation "$1"
      be="solnix-$gen"
      ensure_menu
      # generation N is BE solnix-N. The running BE already is this generation
      # when <toplevel> is the running one (nix-env added nothing): only make it
      # the boot default. Any other BE of that name is stale and is re-created.
      running_be=$(beadm list -H 2>/dev/null | awk -F';' '$3 ~ /N/ {print $1}' | head -1)
      if [ "$be" = "$running_be" ]; then
        [ "$(_readlink /run/current-system)" = "$1" ] \
          || { echo "FATAL: generation $gen is $1 but the running BE $be runs $(_readlink /run/current-system)" >&2; exit 1; }
        beadm activate "$be" || { echo "FATAL: beadm activate $be failed" >&2; exit 1; }
        echo "== generation $gen (running BE $be) is the boot default =="
        return
      fi
      echo "== creating boot environment $be for generation $gen =="
      beadm list "$be" >/dev/null 2>&1 && { echo "BE $be exists; destroying to re-create"; beadm destroy -f -F "$be" 2>/dev/null || true; }
      beadm create "$be" || { echo "FATAL: beadm create $be failed" >&2; exit 1; }

      # mount the new BE and lay the target closure into ITS /nix/store, set its
      # run-current-system, install the target's SMF manifests + activate.
      mkdir -p "$BEROOT_MP"
      beadm mount "$be" "$BEROOT_MP" || { echo "FATAL: beadm mount $be failed" >&2; exit 1; }

      # the same step install and image use (IFACE-1): early set into the BE's own
      # /nix, links into the shared store, /etc, SMF, /boot, boot_archive.
      SOLNIX_ROOT="$BEROOT_MP" SOLNIX_STORE_ROOT="" SOLNIX_POOL="$POOL" SOLNIX_BE="$be" \
        /sbin/sh "$1/bin/install-be" "$1" || { echo "FATAL: install-be failed for $be" >&2; exit 1; }
      relink "$1" "$BEROOT_MP/run-current-system" 2>/dev/null || true

      # stage the target's SMF manifests + site profile + activate into the BE so
      # first boot of the new BE imports them (add-not-replace; design-smf §5).
      # First drop stale solnix-generated manifests the target no longer declares
      # (removal-on-switch across BEs), keeping the boot-plumbing hello/netcfg.
      if [ -d "$BEROOT_MP/lib/svc/manifest/solnix" ] && [ -d "$1/manifest/solnix" ]; then
        for old in "$BEROOT_MP/lib/svc/manifest/solnix/"*.xml; do
          [ -e "$old" ] || continue
          b=$(basename "$old")
          case "$b" in solnix-hello.xml|solnix-netcfg.xml) continue;; esac
          [ -e "$1/manifest/solnix/$b" ] || rm -f "$old"
        done
      fi
      if [ -d "$1/manifest/solnix" ]; then
        mkdir -p "$BEROOT_MP/lib/svc/manifest/solnix"
        cp "$1/manifest/solnix/"*.xml "$BEROOT_MP/lib/svc/manifest/solnix/" 2>/dev/null || true
      fi
      # ⚠️ NO `cp -L` HERE. illumos cp REJECTS -L unless -r/-R is also given:
      # usr/src/cmd/mv/mv.c:271 sets errflg when (Hflg||Lflg||Pflg) && !(Rflg||rflg),
      # which falls through to usage() and exits 2 without creating the file. The
      # usage string (mv.c:1339) spells it out: cp [-r|-R [-H|-L|-P]] ...
      #
      # MEASURED CONSEQUENCE: `switch-to-configuration boot` registered a generation,
      # created the BE, ran bootadm, and `beadm activate` SUCCEEDED -- so the BE became
      # the boot default -- while /lib/svc/method/solnix-activate was NEVER STAGED and
      # the script exited reporting success. A machine bootable-but-broken is worse than
      # one that fails loudly. The `|| true` on these lines is what made it silent.
      #
      # -L was never needed anyway: bare cp DEREFERENCES a source symlink by default,
      # verified rc=0 with real 1184 B content. (`cp -RL` also works and is the
      # illumos-legal spelling, but it is not required for a single file.)
      if [ -e "$1/site-profile.xml" ]; then
        mkdir -p "$BEROOT_MP/etc/svc/profile/site"
        cp "$1/site-profile.xml" "$BEROOT_MP/etc/svc/profile/site/solnix.xml" \
          || { echo "FATAL: failed to stage site-profile.xml into $BEROOT_MP" >&2; exit 1; }
      fi
      if [ -e "$1/activate" ]; then
        mkdir -p "$BEROOT_MP/lib/svc/method"
        cp "$1/activate" "$BEROOT_MP/lib/svc/method/solnix-activate" \
          || { echo "FATAL: failed to stage the activate method into $BEROOT_MP" >&2; exit 1; }
        chmod 0555 "$BEROOT_MP/lib/svc/method/solnix-activate" \
          || { echo "FATAL: could not chmod the staged activate method" >&2; exit 1; }
        # POST-CHECK, not a trusted exit status. The bug this replaces did not fail
        # here at all: cp exited 2, the `&&` chain simply stopped, and the run went on
        # to `beadm activate` -- making a BE the boot default with no activate method
        # and printing success. So assert the file is really there before continuing.
        [ -s "$BEROOT_MP/lib/svc/method/solnix-activate" ] \
          || { echo "FATAL: activate method absent after staging -- refusing to activate a broken BE" >&2; exit 1; }
      fi
      bootadm update-archive -f -R "$BEROOT_MP" 2>&1 | tail -3 || true

      beadm unmount "$be" 2>/dev/null || beadm unmount -f "$be" 2>/dev/null || true
      echo "-- activating $be for next boot"
      beadm activate "$be" || { echo "FATAL: beadm activate $be failed" >&2; exit 1; }
      echo "== generation $gen is the boot default (BE $be). Reboot to run it. =="
      beadm list 2>&1 || true
    }

    case "$action" in
      switch)
        do_activate "$target"
        set_current_system "$target"
        do_boot "$target"
        echo "== switch complete: generation active now AND set for next boot =="
        ;;
      test)
        # as nixos-rebuild test: no new profile generation (it would have no BE).
        do_activate "$target"
        set_current_system "$target"
        echo "== test complete: active now; boot default UNCHANGED =="
        ;;
      boot)
        do_boot "$target"
        ;;
      list-generations|list)
        list_generations
        ;;
      install-be)
        # IFACE-1: populate SOLNIX_ROOT from $target, read through SOLNIX_STORE_ROOT.
        exec /sbin/sh "$(dirname "$0")/install-be" "$target"
        ;;
      *)
        echo "unknown action: $action (switch|boot|test|install-be|list-generations)" >&2; exit 1;;
    esac
  '';

  # solnix-rebuild (T2.5): the convenience wrapper (switch|boot|test|rollback|
  # list-generations). rollback = beadm activate the PREVIOUS BE (+ live-activate
  # the previous toplevel if present) — NixOS's `nixos-rebuild --rollback` analog.
  solnixRebuild = pkgs.writeScript "solnix-rebuild" ''
    #!/sbin/sh
    # solnix-rebuild — convenience over switch-to-configuration + beadm.
    #   solnix-rebuild switch|boot|test [toplevel]   (default toplevel = system profile)
    #   solnix-rebuild rollback                       (beadm activate previous BE)
    #   solnix-rebuild list-generations
    set -u
    PATH=/usr/sbin:/usr/bin:/sbin:$PATH
    # STC = sibling switch-to-configuration in the same bin/ dir.
    STC="$(dirname "$0")/switch-to-configuration"
    [ -x "$STC" ] || STC="$(dirname "$0")/switch-to-configuration"
    PROFILES=/nix/var/nix/profiles
    action="''${1:-switch}"; shift 2>/dev/null || true

    # default toplevel: the highest registered generation, else run-current-system.
    # this minimal proto has no readlink(1); derive target via ls -l.
    _readlink() { [ -h "$1" ] || return 1; ls -ld "$1" 2>/dev/null | sed -n 's/.* -> //p'; }
    default_top() {
      s=$(_readlink "$PROFILES/system" 2>/dev/null)
      [ -n "$s" ] && _readlink "$PROFILES/$s" 2>/dev/null && return
      _readlink /run-current-system 2>/dev/null
    }

    case "$action" in
      switch|boot|test)
        top="''${1:-$(default_top)}"
        [ -n "$top" ] || { echo "no toplevel given and no registered generation" >&2; exit 1; }
        exec /sbin/sh "$STC" "$action" "$top"
        ;;
      rollback)
        # find the previous BE = the non-active BE that boots (highest solnix-<n>
        # below the active one, or the other BE if only two). Simplest correct
        # rule: the BE with the second-newest creation that is NOT active-on-reboot.
        active_reboot=$(beadm list -H 2>/dev/null | awk -F';' '$3 ~ /R/ {print $1}')
        prev=$(beadm list -H 2>/dev/null | awk -F';' -v a="$active_reboot" '$1!=a {print $1" "$6}' | sort -k2 | tail -1 | awk '{print $1}')
        [ -n "$prev" ] || { echo "no previous BE to roll back to" >&2; beadm list 2>&1; exit 1; }
        echo "rolling back: beadm activate $prev (was: $active_reboot)"
        beadm activate "$prev" || { echo "FATAL: beadm activate $prev failed" >&2; exit 1; }
        echo "== rolled back to BE $prev. Reboot to run it. =="
        beadm list 2>&1 || true
        ;;
      list-generations|list)
        exec /sbin/sh "$STC" list-generations
        ;;
      *)
        echo "usage: solnix-rebuild switch|boot|test|rollback|list-generations [toplevel]" >&2; exit 1;;
    esac
  '';

  # solnix-install (T2.7) — the nixos-install analog. Lays THIS toplevel (or any
  # given one) onto a BLANK target disk's ZFS root, run from a booted solnix
  # "installer environment". Pure /sbin/sh + illumos tools (no nix at runtime),
  # base world = the running root (a proven-booting proto-derived world). The
  # script body lives in scripts/solnix-install (also usable standalone on the
  # build host); embedded here so it ships in the toplevel + on /usr/bin.
  solnixInstall = pkgs.writeScript "solnix-install"
    (builtins.readFile ../../../scripts/solnix-install);

  # /etc generation: the config-driven /etc bits, ALL derived from module options
  # (T2.9). The bulk of /etc still comes from the proto (make-be lays it down);
  # this is the solnix-owned overlay staged by make-be, which now includes the
  # networking + users modules' generated files:
  #   nodename        <- networking.hostName
  #   resolv.conf     <- networking.nameservers
  #   defaultrouter   <- networking.defaultGateway
  #   passwd/group    <- users.users / users.groups
  #   shadow          <- users.users.*.hashedPassword (0400, root-only)
  # networking.generatedEtc / users.generatedEtc are the internal carriers the
  # config-surface modules populate; folded in here so the toplevel /etc is a
  # pure function of the options, not hardcoded. shell-environment + nix add
  # their own carriers (profile.d/solnix-env.sh, nix/nix.conf) — nested paths, so
  # the copy loop mkdir -p's each file's dirname (design §B).
  configEtc =
    (config.networking.generatedEtc or { })
    // (config.users.generatedEtc or { })
    // (config.environment.generatedEtc or { })
    // (config.nix.generatedEtc or { });
  etc = pkgs.runCommand "solnix-etc" { } ''
    mkdir -p $out/etc
    printf '%s\n' '${config.networking.hostName}' > $out/etc/nodename
    printf 'solnix system toplevel\nhostname: %s\n' '${config.networking.hostName}' > $out/etc/solnix-release
    ${concatStringsSep "\n    " (mapAttrsToList (fname: content:
      "mkdir -p $out/etc/$(dirname ${fname}); cp ${pkgs.writeText "solnix-etc-${builtins.replaceStrings ["/"] ["-"] fname}" content} $out/etc/${fname}")
      configEtc)}
    # TLS trust store (NixOS security/ca.nix: environment.etc."ssl/certs/ca-certificates.crt"
    # and "ssl/certs/ca-bundle.crt" from the cacert package). illumos ships per-CA PEMs
    # and no bundle; curl, git and openssl look for these names.
    mkdir -p $out/etc/ssl/certs
    ln -s ${pkgs.solnix.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-certificates.crt
    ln -s ${pkgs.solnix.nixChain.cacert}/etc/ssl/certs/ca-bundle.crt $out/etc/ssl/certs/ca-bundle.crt
    # /etc/shadow must be root-only (0400) or login refuses it.
    [ -e $out/etc/shadow ] && chmod 0400 $out/etc/shadow || true
  '';

  # users.users.*.openssh.authorizedKeys seed script (T2.9): a store-path shell
  # snippet make-be sources to write each user's authorized_keys under $ROOT.
  # Driven by the users module option, not a hand-written ROOT_AUTHKEY copy.
  authKeysSetupScript = pkgs.writeScript "solnix-seed-authorized-keys" ''
    #!/usr/bin/env bash
    # solnix authorized_keys seed (T2.9). ROOT = the BE root (default /).
    set -eu
    ROOT="''${ROOT:-/}"
    ${config.users.authorizedKeysSetup or ""}
  '';

  # THE TOPLEVEL — the derivation whose closure is the bootable world.
  #   $out/systemPath      -> composed illumos world (kernel + rtld + libc + ld
  #                           + base-tools + externalLibs), the current-system sw.
  #   $out/manifest/solnix -> DTD-validated generated SMF manifests (smf.nix).
  #   $out/activate        -> the SMF activation script (svccfg import + milestone).
  #   $out/site-profile.xml-> the enable/disable site profile.
  #   $out/etc             -> solnix-owned /etc overlay.
  #   $out/kernel, $out/platform -> symlinks into systemPath so a make-be /
  #                           closure walker finds the kernel by a stable name
  #                           (mirrors NixOS's system/toplevel exposing `kernel`).
  # assertionsChecked is `true` or a throw (modules/config/assertions.nix). Forcing
  # it in the toplevel's NAME is what makes `assertions` load-bearing rather than
  # decorative: a false assertion aborts eval before any derivation is produced.
  # (Interpolating it here rather than in the script body means it is forced during
  # EVALUATION, so `nix eval .#dixiToplevel` fails too, not just `nix build`.)
  # install-be (IFACE-1): populate a BE from this toplevel. One script, called by
  # lib/make-be.nix, scripts/solnix-install and do_boot below.
  installBe = pkgs.writeScript "solnix-install-be" (builtins.readFile ./install-be.sh);

  toplevel = assert config.system.assertionsChecked;
    pkgs.runCommand "solnix-system-${config.networking.hostName}" {
      # closure of the boot-time set: what install-be copies as real files into
      # each generation's BE (the kernel goes in as real trees separately).
      exportReferencesGraph = [ "early-graph" pkgs.solnix.early "sw-graph" config.system.path ];
      # build-only inputs that must never reach the runtime closure (the analog of
      # nixpkgs' disallowedReferences): the gate proto (219 MB, build headers and
      # link libs) and the from-source compiler. Checked over the sw closure below.
      # Names only (context discarded): interpolating them would make the gate and
      # the from-source gcc BUILD INPUTS of every toplevel, so a config built on the
      # installer media would have to build gcc there (no stage0 compiler on it).
      disallowed = builtins.unsafeDiscardStringContext "${pkgs.solnix.gate} ${pkgs.solnix.gcc}";
    } ''
    mkdir -p $out
    grep -h '^/nix/store/' early-graph | grep -v '\.drv$' | sort -u > $out/early-paths
    for x in $disallowed; do
      if grep -qx "$x" early-graph sw-graph; then echo "FATAL: runtime closure contains build-only $x" >&2; exit 1; fi
    done
    ln -s ${pkgs.solnix.world}   $out/world
    ln -s ${pkgs.solnix.kernel}  $out/kernel-slice
    ln -s ${pkgs.solnix.early}   $out/early
    ln -s ${pkgs.solnix.drivers} $out/drivers
    ln -s ${pkgs.solnix.stock}   $out/stock
    # sw: the composed userland profile (environment.systemPackages via buildEnv)
    # -> /run/current-system/sw. SEPARATE from systemPath so a broken package set
    # can't drop the kernel (design §B). shell-environment puts sw/bin first on PATH.
    ln -s ${config.system.path}                     $out/sw
    ln -s ${config.system.build.smfManifests}/manifest/solnix $out/manifest/solnix 2>/dev/null || \
      { mkdir -p $out/manifest; ln -s ${config.system.build.smfManifests}/manifest/solnix $out/manifest/solnix; }
    ln -s ${activate}                                 $out/activate
    ln -s ${siteProfile}                              $out/site-profile.xml
    ln -s ${etc}/etc                                  $out/etc
    # users.users.*.openssh.authorizedKeys seed script (T2.9). make-be runs it
    # against the BE root ($ROOT) to seed ~/.ssh/authorized_keys per user, from
    # the OPTIONS (replacing the ad-hoc ROOT_AUTHKEY path).
    ln -s ${authKeysSetupScript}                      $out/seed-authorized-keys
    # bin/: the switch-to-configuration + solnix-rebuild runtime tools (T2.5).
    mkdir -p $out/bin
    ln -s ${switchToConfiguration}                    $out/bin/switch-to-configuration
    ln -s ${solnixRebuild}                            $out/bin/solnix-rebuild
    ln -s ${solnixInstall}                            $out/bin/solnix-install
    ln -s ${installBe}                                $out/bin/install-be
    # kernel + platform: stable-named entrypoints into systemPath (the closure
    # walker / make-be reads $out/kernel + $out/platform to find unix/genunix).
    ln -s ${pkgs.solnix.kernel}/kernel               $out/kernel
    ln -s ${pkgs.solnix.kernel}/platform             $out/platform
    # a manifest of what this system is (for `nix-store -q --tree` legibility).
    cat > $out/system-manifest <<EOF
    hostName=${config.networking.hostName}
    milestone=${targetMilestone}
    world=${pkgs.solnix.world}
    smfManifests=${config.system.build.smfManifests}
    EOF
    # sanity: the closure must have the kernel + a service manager + libc.
    [ -e $out/platform/i86pc/kernel/amd64/unix ]            || { echo "FATAL: no unix in toplevel" >&2; exit 1; }
    [ -e $out/kernel/amd64/genunix ]                        || { echo "FATAL: no genunix in toplevel" >&2; exit 1; }
    [ -e $out/world/lib/svc/bin/svc.startd ]                || { echo "FATAL: no svc.startd in toplevel" >&2; exit 1; }
    [ -e $out/world/lib/amd64/libc.so.1 ]                   || { echo "FATAL: no libc in toplevel" >&2; exit 1; }
    [ -e $out/sw/bin/nix ]                                  || { echo "FATAL: no nix on the system PATH" >&2; exit 1; }
    [ -e $out/activate ]                                    || { echo "FATAL: no activate script" >&2; exit 1; }
    [ -e $out/bin/switch-to-configuration ]                 || { echo "FATAL: no switch-to-configuration" >&2; exit 1; }
    [ -e $out/bin/solnix-rebuild ]                          || { echo "FATAL: no solnix-rebuild" >&2; exit 1; }
    [ -e $out/bin/solnix-install ]                          || { echo "FATAL: no solnix-install" >&2; exit 1; }
  '';
in
{
  options.system.build = {
    toplevel = mkOption {
      type = types.package;
      description = ''
        The full solnix system: a derivation whose closure is the bootable world
        (systemPath + generated SMF manifests + activation script + /etc). The
        NixOS system.build.toplevel analog. lib/make-be.nix consumes this.
      '';
    };
    activate = mkOption {
      type = types.package;
      description = "The SMF activation script (svccfg import + svcadm milestone).";
    };
    etc = mkOption {
      type = types.package;
      description = "The solnix-owned /etc overlay.";
    };
    smfSiteProfile = mkOption {
      type = types.package;
      description = "The generated SMF site profile (enable/disable deltas).";
    };
    smfManifests = mkOption {
      type = types.package;
      description = ''
        The DTD-validated generated SMF manifest directory (set by smf.nix).
        Declared here so smf.nix's `system.build.smfManifests` has a home.
      '';
    };
    switchToConfiguration = mkOption {
      type = types.package;
      description = "The switch-to-configuration runtime tool (T2.5).";
    };
    solnixRebuild = mkOption {
      type = types.package;
      description = "The solnix-rebuild convenience wrapper (switch|boot|test|rollback).";
    };
    solnixInstall = mkOption {
      type = types.package;
      description = "The solnix-install tool (nixos-install analog; install to a blank disk).";
    };
    seedAuthorizedKeys = mkOption {
      type = types.package;
      description = "The users.users.*.openssh.authorizedKeys seed script (T2.9).";
    };
  };

  config.system.build = {
    inherit toplevel activate etc switchToConfiguration solnixRebuild solnixInstall;
    smfSiteProfile = siteProfile;
    seedAuthorizedKeys = authKeysSetupScript;
  };
}
