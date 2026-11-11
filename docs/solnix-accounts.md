# solnix-accounts: who COSMIC Settings > Users shows as an administrator

COSMIC Settings > Users asks AccountsService (org.freedesktop.Accounts, the accounts-daemon) for each listed user's
account type and icon. accounts-daemon is a Linux daemon that calls a user an administrator when they are root or in
the admin group (wheel on NixOS). solnix has neither the daemon nor a wheel group. Without the service the page falls
back to "an administrator is a member of the group sudo", so every user was shown as a standard user, the desktop's Primary Administrator included.

solnix-accounts (src/solnix-accounts, Rust with zbus, MIT) owns org.freedesktop.Accounts and answers from the illumos
account files. Turn it on with `services.solnix-accounts.enable = true;` (it needs `services.dbus.enable`). It is off by
default; the COSMIC desktop turns it on, as NixOS's cosmic module turns on accounts-daemon.

## Who is an administrator

AccountType is 1 (Administrator) when any of these holds, and 0 (Standard) otherwise:

| rule | where | NixOS analog |
|---|---|---|
| uid 0 | /etc/passwd | the same |
| the `Primary Administrator` profile | /etc/user_attr `profiles=` (users.users.<name>.profiles) | extraGroups = [ "wheel" ] |
| the `root` role | /etc/user_attr `roles=` | none (illumos role) |
| member of `sysadmin` (gid 14) | /etc/group, primary or supplementary | wheel |

These are the users that `pfexec` (and solnix's sudo) let run anything as root. `profiles=All` alone is not
administration: All grants no privileges, and policy.conf gives every user Basic Solaris User and All
(`profiles <user>` lists all three). Profiles nested inside other profiles in prof_attr, and profiles granted to everyone by
policy.conf's PROFS_GRANTED, are not followed.

## What it answers

The files are read on every call, so a change from activation or `usermod` shows on the next read.

| D-Bus | from |
|---|---|
| `/org/freedesktop/Accounts/User<uid>`, one object per passwd uid | /etc/passwd (re-read every 10 s and on each Find call) |
| `FindUserById`, `FindUserByName` | /etc/passwd |
| `ListCachedUsers` | people only: a uid in /etc/login.defs UID_MIN..UID_MAX and a shell other than false/nologin (accounts-daemon's rule) |
| `UserName`, `Uid`, `HomeDirectory`, `Shell` | /etc/passwd |
| `RealName` | GECOS up to the first comma ("Last, First" is kept whole, as accounts-daemon does) |
| `AccountType` | the rules above |
| `IconFile` | ~/.face if it exists (accounts-daemon's default icon); otherwise the read fails and COSMIC shows its default icon |
| `Locked` | /etc/shadow: a hash starting with `*LK*` (passwd -l) |
| `SystemAccount`, `LocalAccount` | the people rule above; always true |

Signals UserAdded and UserDeleted go out when a person's uid appears in or leaves /etc/passwd.

## Not supported yet: changing accounts

Every method that would change an account answers `org.freedesktop.Accounts.Error.NotSupported`: SetAccountType (the
Administrator switch), SetPassword, SetRealName, SetUserName, SetIconFile, SetLanguage, CreateUser and DeleteUser. So
in Settings > Users the switches and fields show the current state but changes do not apply. It is NotSupported, not
PermissionDenied, because on PermissionDenied COSMIC would ask polkit (which solnix doesn't have) and try again.
Change accounts in the system configuration (`users.users`) instead. Other User properties (Language, Email, Session,
login history and so on) are not served.

The greeter does not use this service: cosmic-greeter reads its icons from /var/lib/AccountsService/icons/<name> itself.

## Tests

- `cargo test` under `dbus-run-session` (5 D-Bus tests + 1 parser test), over a temporary copy of /etc with lixi's
  user_attr lines. The reads go through a proxy built the way COSMIC's accounts_zbus builds one (lazy cache, so GetAll
  comes first). A Primary Administrator gets 1. A user with only Basic Solaris User and All gets 0. A sysadmin
  member, a root-role user and root get 1; nixbld gets 0. Negative control: the same user with the profile removed from
  user_attr gets 0, and putting it back gives 1. With no ~/.face, IconFile fails and GetAll still answers. Every
  mutating method returns NotSupported and the files are unchanged. Making every user an administrator, or ignoring
  the profile, fails the tests.
- Read-only on a desktop on a private bus: Settings > Users' own reload() (accounts_zbus at the rev cosmic-settings
  1.11 pins). With no daemon, the Primary Administrator user shows admin=false: account_type fails with ServiceUnknown,
  then the sudo-group fallback. With solnix-accounts over the real /etc, admin=true (AccountType 1). Over a copy of
  /etc without the profile, admin=false. /etc is unchanged afterwards.
