# modules/config/users.nix — declarative users/groups that GENERATE the illumos
# /etc/{passwd,shadow,group} entries, the solnix analog of NixOS's users-groups
# module.
#
# T2.9. Options -> generated /etc:
#   users.users.<name> = { uid; group; home; shell; description;
#                          hashedPassword; isRoot; extraGroups;
#                          openssh.authorizedKeys.keys; }
#     -> one /etc/passwd, /etc/shadow, /etc/group line each (illumos formats),
#        MERGED over the base system accounts (root/daemon/bin/sys/... — the
#        stock ones the SMF stack needs, docs/design-make-be.md gotcha #9).
#   openssh.authorizedKeys.keys -> /etc/ssh/authorized_keys.d/<name> (NixOS's
#        sshd.nix: root-owned, 0444, listed in sshd_config's AuthorizedKeysFile).
#        Activation never writes into a home: /home is a dataset shared by every
#        boot environment, and a file written into a new BE's own /home made
#        `zfs mount -a` refuse to mount the real one ("directory is not empty").
#
# The generated files land in the solnix /etc overlay (activation folds them in).
# make-be already carries the stock proto accounts forward; this module OWNS the
# declared users on top and (for a from-scratch /etc) ships the essential base
# accounts as defaults so passwd/shadow/group are self-consistent from options.
#
# illumos field formats:
#   passwd: name:x:uid:gid:gecos:home:shell
#   shadow: name:hash:lastchg:min:max:warn:inactive:expire:flag
#           (hash "" = empty password / login without one; "*LK*" or "NP" locked)
#   group:  name:passwd:gid:members(comma-sep)

{ config, lib, pkgs, ... }:

let
  inherit (lib)
    mkOption
    types
    mkIf
    concatStringsSep
    mapAttrsToList
    filterAttrs
    literalExpression
    unique
    ;

  cfg = config.users;

  userType = types.submodule (
    { name, config, ... }:
    {
      options = {
        uid = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Numeric user id. Required unless isRoot.";
        };
        group = mkOption {
          type = types.str;
          default = "staff";
          description = "Primary group name (must exist in users.groups or the base set).";
        };
        description = mkOption {
          type = types.str;
          default = "";
          description = "GECOS field.";
        };
        home = mkOption {
          type = types.str;
          default = "/export/home/${name}";
          description = ''
            Home directory. Defaults to /export/home/<name>: on illumos /home is
            autofs-managed (automountd), so a real on-disk home lives under
            /export/home (autofs maps /home/<name> -> there). Using /home/<name>
            directly fails — mkdir /home/<name> is "Operation not applicable".
          '';
        };
        shell = mkOption {
          type = types.str;
          default = "/usr/bin/ksh93";
          description = "Login shell (ksh93 ships in the proto; bash may not).";
        };
        hashedPassword = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "$6$rounds=...$...";
          description = ''
            crypt(3) password hash written to /etc/shadow. null = no password set
            ("NP": passwordless, account NOT locked — ssh-key login still works,
            which is the common case for a key-only login user). "" = empty
            password (console login without one; matches the root default). Use
            "*LK*" explicitly to fully lock an account (PAM denies even key login).
          '';
        };
        isRoot = mkOption {
          type = types.bool;
          default = name == "root";
          description = "This is the root account (uid 0, gid 0). Sets sane root defaults.";
        };
        extraGroups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Supplementary groups (added to the members field of each).";
        };
        profiles = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "Primary Administrator" ];
          description = ''
            RBAC execution profiles (user_attr(5) `profiles=`). illumos has no wheel;
            "Primary Administrator" (prof_attr: uid=0;gid=0) makes `pfexec <cmd>`
            root-equivalent, the analog of NixOS's extraGroups = [ "wheel" ].
          '';
        };
        openssh.authorizedKeys.keys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = literalExpression ''[ "ssh-ed25519 AAAA... user@host" ]'';
          description = "SSH public keys written to /etc/ssh/authorized_keys.d/<name>.";
        };
      };
      config = mkIf config.isRoot {
        uid = lib.mkDefault 0;
        group = lib.mkDefault "root";
        home = lib.mkDefault "/root";
        shell = lib.mkDefault "/usr/bin/ksh93";
        # root has no declared password, as on NixOS (users-groups.nix declares
        # root with no hashedPassword): null -> "NP" in the generated shadow, and
        # install-be then KEEPS the password already on the system (set by the
        # installer or `passwd`). The default used to be "" (an empty password),
        # and since install-be replaces a declared hash, every switch and boot
        # reset root to passwordless: measured on the X1, solnix-2 and solnix-3
        # had an empty root field after solnix-1's root password was set. Only the
        # installer media wants an empty root password, and it sets one itself
        # (make-installer-image.sh 5b), as NixOS's installation-device.nix sets
        # initialHashedPassword = "".
        hashedPassword = lib.mkDefault null;
      };
    }
  );

  groupType = types.submodule {
    options = {
      gid = mkOption {
        type = types.int;
        description = "Numeric group id.";
      };
      members = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Extra members (declared user extraGroups are merged in).";
      };
    };
  };

  # gid lookup across declared + base groups (for a user's primary group -> gid).
  allGroups = cfg.groups;
  gidOf = gname: (allGroups.${gname} or { gid = 1; }).gid;

  # supplementary membership: for each group, the declared users that name it in
  # extraGroups, unioned with the group's own members list.
  membersOf =
    gname:
    unique (
      (allGroups.${gname}.members or [ ])
      ++ (mapAttrsToList (uname: u: uname) (
        filterAttrs (_: u: builtins.elem gname u.extraGroups) cfg.users
      ))
    );

  passwdLine =
    name: u:
    "${name}:x:${toString u.uid}:${toString (gidOf u.group)}:${u.description}:${u.home}:${u.shell}";

  # shadow: null hash -> "NP" (no password, account NOT locked — key login works;
  # illumos GATE B finding: "*LK*" LOCKS the account and PAM denies even a valid
  # ssh key). "" -> empty password. Anything else -> the literal hash/token.
  shadowLine =
    name: u:
    let
      h = if u.hashedPassword == null then "NP" else u.hashedPassword;
    in
    "${name}:${h}:::::::";

  groupLine = gname: g: "${gname}::${toString g.gid}:${concatStringsSep "," (membersOf gname)}";

  userAttrLine = name: u: "${name}::::type=normal;profiles=${concatStringsSep "," u.profiles}";
  userAttrFile = concatStringsSep "\n" (mapAttrsToList userAttrLine (filterAttrs (_: u: u.profiles != [ ]) cfg.users)) + "\n";
  passwdFile = concatStringsSep "\n" (mapAttrsToList passwdLine cfg.users) + "\n";
  shadowFile = concatStringsSep "\n" (mapAttrsToList shadowLine cfg.users) + "\n";
  groupFile = concatStringsSep "\n" (mapAttrsToList groupLine cfg.groups) + "\n";

  # authorized_keys: one /etc/ssh/authorized_keys.d/<name> per user that declares
  # keys, as NixOS's sshd.nix does. The user's own ~/.ssh/authorized_keys still works
  # (base.nix's AuthorizedKeysFile lists both).
  usersWithKeys = filterAttrs (_: u: u.openssh.authorizedKeys.keys != [ ]) cfg.users;
  authKeysEtc = lib.mapAttrs' (name: u:
    lib.nameValuePair "ssh/authorized_keys.d/${name}" (concatStringsSep "\n" u.openssh.authorizedKeys.keys + "\n")
  ) usersWithKeys;
in
{
  options.users = {
    users = mkOption {
      type = types.attrsOf userType;
      default = { };
      description = "Declarative user accounts (generate /etc/passwd + /etc/shadow).";
    };
    groups = mkOption {
      type = types.attrsOf groupType;
      default = { };
      description = "Declarative groups (generate /etc/group).";
    };

    # internal carriers the activation module folds into its /etc + a seed script.
    generatedEtc = mkOption {
      type = types.attrsOf types.str;
      internal = true;
      default = { };
      description = "user-derived /etc files (passwd, shadow, group, user_attr, ssh/authorized_keys.d/*). Read by activation.";
    };
  };

  config = {
    # Essential base groups/users the SMF stack + a login need (gotcha #9).
    # Shipped as defaults so a from-scratch /etc from options is self-consistent;
    # a config's own users.users.<name> merges on top (attrset merge). make-be
    # ALSO carries the full stock proto passwd forward, so this is belt-and-braces
    # for the declarative /etc, not the only account source.
    users.groups = {
      root.gid = lib.mkDefault 0;
      other.gid = lib.mkDefault 1;
      bin.gid = lib.mkDefault 2;
      sys.gid = lib.mkDefault 3;
      adm.gid = lib.mkDefault 4;
      daemon.gid = lib.mkDefault 12;
      staff.gid = lib.mkDefault 10;
      sshd.gid = lib.mkDefault 22;
      # pkg(5) creates smmsp from the sendmail manifest (it is not in the gate's
      # stock group); var/spool/clientmqueue is smmsp:smmsp 0770.
      smmsp.gid = lib.mkDefault 25;
      nobody.gid = lib.mkDefault 60001;
    };
    users.users = {
      root = {
        isRoot = true;
        description = lib.mkDefault "Super-User";
      };
      daemon = {
        uid = lib.mkDefault 1;
        group = lib.mkDefault "daemon";
        home = lib.mkDefault "/";
        shell = lib.mkDefault "";
        hashedPassword = lib.mkDefault null;
      };
      bin = {
        uid = lib.mkDefault 2;
        group = lib.mkDefault "bin";
        home = lib.mkDefault "/usr/bin";
        shell = lib.mkDefault "";
        hashedPassword = lib.mkDefault null;
      };
      sys = {
        uid = lib.mkDefault 3;
        group = lib.mkDefault "sys";
        home = lib.mkDefault "/";
        shell = lib.mkDefault "";
        hashedPassword = lib.mkDefault null;
      };
      # sshd privsep account (gotcha #9: sshd FAILS without it).
      sshd = {
        uid = lib.mkDefault 22;
        group = lib.mkDefault "sshd";
        description = lib.mkDefault "sshd privsep";
        home = lib.mkDefault "/var/empty";
        shell = lib.mkDefault "/bin/false";
        hashedPassword = lib.mkDefault null;
      };
      # sendmail's message submission account (service-network-smtp-sendmail.p5m
      # `user username=smmsp uid=25 group=smmsp password=NP`).
      smmsp = {
        uid = lib.mkDefault 25;
        group = lib.mkDefault "smmsp";
        description = lib.mkDefault "SendMail Message Submission Program";
        home = lib.mkDefault "/";
        shell = lib.mkDefault "";
        hashedPassword = lib.mkDefault null;
      };
      nobody = {
        uid = lib.mkDefault 60001;
        group = lib.mkDefault "nobody";
        home = lib.mkDefault "/";
        shell = lib.mkDefault "";
        hashedPassword = lib.mkDefault null;
      };
    };

    users.generatedEtc = {
      passwd = passwdFile;
      shadow = shadowFile;
      group = groupFile;
      user_attr = userAttrFile;
    } // authKeysEtc;
  };
}
