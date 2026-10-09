#!/sbin/sh
# sudo -- sudo's command line over illumos RBAC (pfexec). Runs a command as root (or
# -u USER) when the caller's RBAC profiles allow it, as `sudo` does when sudoers
# allows it. There is no sudoers file and no password prompt: the authority is the
# user's profiles (Primary Administrator gives everything), as for pfexec.
#
#   sudo [-u user] [-E] [-n] [-H] [--] command [arg ...]
#   sudo -i [-u user]        login shell of the target user
#   sudo -s [-u user]        the caller's $SHELL as the target user
#   sudo -v | -k | -K        accepted; pfexec keeps no credential cache
#   sudo -l                  list the caller's RBAC profiles (profiles(1))
#
# The exit status is the command's. Unknown options are an error (status 1),
# as in sudo.
set -u
me=sudo
usage() {
  echo "usage: $me [-EHn] [-u user] [--] command [arg ...]" >&2
  echo "       $me -i | -s [-u user] [command [arg ...]]" >&2
  echo "       $me -v | -k | -K | -l | -h | -V" >&2
}
user=root; mode=cmd; keepenv=0
while [ $# -gt 0 ]; do
  case $1 in
    --) shift; break ;;
    -u) [ $# -ge 2 ] || { echo "$me: option requires an argument -- 'u'" >&2; usage; exit 1; }
        user=$2; shift 2 ;;
    -u*) user=${1#-u}; shift ;;
    -E|--preserve-env) keepenv=1; shift ;;
    --preserve-env=*) keepenv=1; shift ;;
    -n|--non-interactive|-H|--set-home|-S|--stdin|-b|--background) shift ;;
    -i|--login) mode=login; shift ;;
    -s|--shell) mode=shell; shift ;;
    -v|--validate|-k|--reset-timestamp|-K|--remove-timestamp)
      # pfexec keeps no cached credential, so there is nothing to validate or drop.
      [ $# -eq 1 ] && exit 0; shift ;;
    -l|--list) exec /usr/bin/profiles -l ;;
    -h|--help) usage; exit 0 ;;
    -V|--version) echo "solnix sudo (pfexec)"; exit 0 ;;
    -?*) echo "$me: invalid option -- '${1#-}'" >&2; usage; exit 1 ;;
    *) break ;;
  esac
done

# the target user must exist (sudo: "unknown user")
/usr/bin/getent passwd "$user" >/dev/null 2>&1 || { echo "$me: unknown user $user" >&2; exit 1; }

case $mode in
  login)
    # su - USER: the target's login shell, its profile and HOME, as sudo -i.
    if [ $# -eq 0 ]; then exec /usr/bin/pfexec /usr/bin/su - "$user"; fi
    exec /usr/bin/pfexec /usr/bin/su - "$user" -c 'exec "$0" "$@"' "$@" ;;
  shell)
    sh_=${SHELL:-/bin/sh}
    if [ $# -eq 0 ]; then
      [ "$user" = root ] && exec /usr/bin/pfexec "$sh_"
      exec /usr/bin/pfexec /usr/bin/su "$user" -c "exec $sh_"
    fi
    set -- "$sh_" -c "$*" ;;
esac
[ $# -gt 0 ] || { usage; exit 1; }

if [ "$user" = root ]; then
  # pfexec does not refuse a command the caller's profiles do not cover: it runs
  # it unprivileged (measured: as nobody, `pfexec id -u` prints 60001 and exits 0).
  # sudo refuses instead, and a script must not believe it got root, so check
  # that the profiles grant root at all, as `sudo` checks sudoers. (A profile
  # that covers only some commands still runs the others unprivileged.)
  if [ "$(/usr/bin/id -u)" != 0 ] && [ "$(/usr/bin/pfexec /usr/bin/id -u 2>/dev/null)" != 0 ]; then
    echo "$me: $(/usr/bin/id -un) may not run commands as root: no RBAC profile grants it (see profiles -l)" >&2
    exit 1
  fi
  # pfexec runs the command with the privileges the caller's profiles grant it,
  # keeping the environment as sudo -E does (pfexec has no env_reset).
  exec /usr/bin/pfexec "$@"
fi
# another user: su (non-login) runs a shell as USER; "$0" "$@" keeps every argument
# as one word. su resets PATH to its own default, so set it: the caller's with -E,
# else the system PATH (sudo's secure_path).
if [ $keepenv = 1 ]; then
  exec /usr/bin/pfexec /usr/bin/su "$user" -c 'PATH=$1; export PATH; shift; exec "$@"' sudo "$PATH" "$@"
fi
exec /usr/bin/pfexec /usr/bin/su "$user" -c 'PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/usr/sbin:/sbin; export PATH; exec "$0" "$@"' "$@"
