# modules/system/boot/init/smf.nix — THE init module.
#
# solnix analog of nixbsd's modules/system/boot/init/freebsd-rc.nix. Where nixbsd
# renders rc.conf + /etc/rc.d, solnix renders SMF XML manifests + method scripts
# and drives them through svc.startd/svc.configd via svccfg/svcadm.
#
# Design of record: docs/design-smf-init.md. This file implements §1 (the option
# surface, complete and correct) and folds `requires` into `dependencies` in the
# config section. The manifest/method GENERATION (§2) and ACTIVATION (§3) are
# deferred with clear TODOs — they need pkgs (writeText/writeScript/runCommand)
# from the nixpkgs fork and the pure helpers in lib/smf/xml.nix (design §6 file
# #1), neither of which exists yet.

{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkOption
    mkEnableOption
    types
    literalExpression
    filterAttrs
    mapAttrsToList
    concatStringsSep
    ;

  # A single dependency group (SMF <dependency>). §1.1.
  depType = types.submodule {
    options = {
      name = mkOption {
        type = types.str;
        description = "Dependency group name (unique within the service).";
      };
      grouping = mkOption {
        type = types.enum [
          "require_all"
          "require_any"
          "optional_all"
          "exclude_all"
        ];
        default = "require_all";
        description = "SMF dependency grouping.";
      };
      restartOn = mkOption {
        type = types.enum [
          "none"
          "error"
          "restart"
          "refresh"
        ];
        default = "none";
        description = "SMF restart_on: when this dep changes, what happens to us.";
      };
      fmris = mkOption {
        type = types.listOf types.str;
        example = literalExpression ''[ "svc:/milestone/network:default" ]'';
        description = ''
          Target FMRIs (or file:// paths) this group depends on.
          Milestones and files are both valid SMF dependency targets.
        '';
      };
    };
  };

  # SMF exec_method. §1.1.
  methodType = types.submodule {
    options = {
      exec = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Command line for the method. Either a literal shell fragment, or the
          SMF tokens ":true"/":kill"/":kill -SIGNAL" for stop. Rendered verbatim
          into exec_method/@exec (XML-escaped).
        '';
      };
      timeoutSeconds = mkOption {
        type = types.ints.unsigned;
        default = 60;
        description = "Method timeout. 0 = infinite (SMF convention).";
      };
    };
  };

  serviceType = types.submodule (
    { name, config, ... }:
    {
      options = {
        enable = mkEnableOption "this SMF service (sets the enabled property)";

        category = mkOption {
          type = types.str;
          default = "system";
          description = ''
            FMRI category segment: svc:/<category>/<name>. Common: system,
            network, application, milestone, site.
          '';
        };

        instance = mkOption {
          type = types.str;
          default = "default";
          description = "Instance name (the :<instance> part of the FMRI).";
        };

        description = mkOption {
          type = types.str;
          default = name;
          description = "Human-readable template/common_name.";
        };

        # --- service model -> startd/duration -------------------------------
        model = mkOption {
          type = types.enum [
            "contract"
            "transient"
            "wait"
          ];
          default = "contract";
          description = ''
            SMF service model, written as the startd/duration property:
              contract  = long-running daemon under a process contract (default);
              transient = run-once, no lingering process (oneshots);
              wait      = svc.startd waits on a child in the foreground.
          '';
        };

        # --- methods --------------------------------------------------------
        start = mkOption {
          type = methodType;
          description = "Start method (exec_method name=start).";
        };
        stop = mkOption {
          type = methodType;
          default = {
            exec = ":kill";
          };
          description = ''
            Stop method. Default ":kill" lets svc.startd tear down the contract.
            Set exec = ":true" for transient services that need no explicit stop.
          '';
        };
        refresh = mkOption {
          type = types.nullOr methodType;
          default = null;
          description = "Optional refresh method (SIGHUP-style reconfigure).";
        };

        # --- credentials (SMF method_credential) ----------------------------
        user = mkOption {
          type = types.str;
          default = "root";
          description = "method_credential/user.";
        };
        group = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "method_credential/group.";
        };

        # --- environment & cwd (method_context) -----------------------------
        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = {
            PATH = "/nix/store/.../bin";
            TZ = "UTC";
          };
          description = "method_environment name=value pairs.";
        };
        workingDirectory = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "method_context/@working_directory.";
        };

        # --- dependencies ---------------------------------------------------
        dependencies = mkOption {
          type = types.listOf depType;
          default = [ ];
          description = "SMF <dependency> groups this service declares.";
        };

        # Sugar: fold into one require_all group in config. Not a new concept.
        requires = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = ''
            Convenience: FMRIs folded into one require_all/restart_on=none
            dependency group named "solnix-requires".
          '';
        };

        # SMF <dependent>: make another service (typically a milestone) depend
        # on this one, so svc.startd starts this service whenever that milestone
        # is the target -- e.g. in `boot -s`, where only single-user's subgraph
        # runs (startd graph.c should_be_in_subgraph).
        dependents = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "svc:/milestone/single-user" ];
          description = ''
            FMRIs that get an optional_all dependency on this service
            (SMF <dependent>, restart_on none), one group per FMRI.
          '';
        };

        # --- application config ---------------------------------------------
        properties = mkOption {
          type = types.attrsOf (types.attrsOf types.str);
          default = { };
          example = {
            config = {
              port = "22";
              listen = "0.0.0.0";
            };
          };
          description = ''
            Property groups of type "application". Outer key = pg name, inner
            attrs = property name->value (all rendered as astring).
          '';
          # Values are all astring; typed props (count/boolean/time)
          # deferred until an actual service needs a non-string typed property.
        };

        # --- escape hatch ---------------------------------------------------
        extraManifestXML = mkOption {
          type = types.lines;
          default = "";
          description = ''
            Raw XML spliced into <instance> before </instance>. Escape hatch for
            SMF features the typed interface does not cover yet.
          '';
        };

        # --- computed (read-only) -------------------------------------------
        fmri = mkOption {
          type = types.str;
          readOnly = true;
          default = "svc:/${config.category}/${name}:${config.instance}";
          description = "Full FMRI, computed.";
        };

        # `dependencies` with the `requires` sugar folded in (§1.3). Computed
        # per-service via config.<name> so it does NOT re-read the top-level
        # smf.services option (that self-reference is infinite recursion). The
        # generator (§2, deferred) consumes this, not raw `dependencies`.
        allDependencies = mkOption {
          type = types.listOf depType;
          readOnly = true;
          default =
            config.dependencies
            ++ lib.optional (config.requires != [ ]) {
              name = "solnix-requires";
              grouping = "require_all";
              restartOn = "none";
              fmris = config.requires;
            };
          description = "dependencies + folded `requires`. Computed. Read by the generator.";
        };
      };
    }
  );
in
{
  options.smf.services = mkOption {
    type = types.attrsOf serviceType;
    default = { };
    description = "SMF services managed by solnix.";
  };

  config =
    let
      # The pure SMF renderers (design §2, lib/smf/xml.nix). pkgs-agnostic by
      # injection — we hand it the fork's writers. Bound INSIDE config (not the
      # top-level let) so a bare/options-only import of this module does not force
      # `pkgs`; only realising the config touches the writers/runCommand.
      smfXml = import ../../../../lib/smf/xml.nix {
        inherit lib;
        inherit (pkgs) writeText writeScript runtimeShell;
      };

      # The illumos service_bundle DTD, for the build-time validation gate (§2.6).
      # It ships in the world's proto area (pkgs.solnix.gate) at
      # usr/share/lib/xml/dtd/service_bundle.dtd.1; the on-target <!DOCTYPE> still
      # references the standard /usr/share path (correct on the running system).
      # VERIFY(§5.4): the exact pkgs.solnix attr that should expose it — for now
      # read it out of the gate proto store path.
      # From the world (the same file, relocated with the userland), not the gate
      # proto: a config built on the installer media has the world but not the
      # 680 MB proto, and xmllint below is the from-source libxml2's, not the host's.
      dtdFile = "${pkgs.solnix.world}/usr/share/lib/xml/dtd/service_bundle.dtd.1";

      # only enabled services get manifests + methods generated.
      enabledServices = filterAttrs (_: s: s.enable) config.smf.services;

      # per-service manifest XML store path (design §2.4). mkManifest consumes
      # `allDependencies` (the read-only option that folds `requires`) via
      # svc.allDependencies, and emits the method scripts as a side effect
      # (referenced by absolute store path from the XML).
      manifestOf = name: svc: smfXml.mkManifest name svc;

      # the manifest DIRECTORY (design §2.5): copy each service's XML under
      # $out/manifest/solnix/<name>.xml. This is what the etc/path module stages
      # at /lib/svc/manifest/solnix (design §5.3) and activation imports (§3).
      smfManifests = pkgs.runCommand "solnix-smf-manifests" { } ''
        mkdir -p $out/manifest/solnix
        ${concatStringsSep "\n" (mapAttrsToList
          (name: svc: "cp ${manifestOf name svc} $out/manifest/solnix/${name}.xml")
          enabledServices)}
      '';

      # build-time DTD validation gate (design §2.6): every generated manifest
      # must pass xmllint --dtdvalid against the illumos service_bundle.dtd.1, so
      # a malformed manifest fails the BUILD, not the boot. Proven on the host:
      # lib/smf/tests.nix builds the sshd+oneshot manifests and this exact
      # xmllint invocation PASSES (GATE 2).
      checkedManifests = pkgs.runCommand "solnix-smf-manifests-checked" { } ''
        cp -r ${smfManifests} $out
        chmod -R u+w $out
        for m in $out/manifest/solnix/*.xml; do
          echo "validating $m" >&2
          ${pkgs.solnix.libxml2}/bin/xmllint --noout --dtdvalid ${dtdFile} "$m"
        done
      '';
    in
    {
      # `requires` sugar is folded per-service into the read-only `allDependencies`
      # option above (§1.3); the generator reads that, not raw `dependencies`.

      # Manifest + method generation (design §2), wired via lib/smf/xml.nix.
      # Exposed under an internal attr the etc/path module (design §5.3, T1.11
      # file #3) and the SMF activation snippet (design §3.1, T1.12 file #5)
      # consume. Kept out of a user-facing option — it is a computed artifact.
      system.build.smfManifests = checkedManifests;

      # TODO(T1.11 file #3): stage `checkedManifests` at /lib/svc/manifest/solnix
      # via the etc/path module (design §5.3). Reuse that module; don't invent one.
      # TODO(T1.12 file #5): render system/activation/smf-activate.sh — svccfg
      # import each manifest, apply enable/disable deltas, svcadm milestone
      # multi-user-server (design §3.1). Removal-on-switch deferred to P2.1.
      #
      # Both need the fork's module set (system.build.*, the etc module) to be
      # present; the GENERATION above (the T1.11 core) is complete and its output
      # is DTD-validated at build time.
    };
}
