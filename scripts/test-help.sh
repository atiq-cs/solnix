#!/usr/bin/bash
# test-help.sh -- getting help on an installed solnix system (help1): man in every context, the man index, info,
# and the desktop's man: handler and launcher plugin. Run ON the host as a normal user (dixi, lixi):
#   test-help.sh            the running system
#   test-help.sh --negctl   also run each check against the state it fixes and expect FAIL (a check that cannot
#                           fail is not a check)
# Each check prints PASS | FAIL | SKIP; exit 1 on any FAIL. Read-only except /tmp/test-help.* scratch files and,
# for the cron check, a crontab entry that is removed again (the user's crontab is saved and restored).
PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/usr/sbin:/sbin
pass=0 fail=0 skip=0
r() { printf '%-5s %-22s %s\n' "$1" "$2" "$3"; case $1 in PASS) pass=$((pass+1));; FAIL) fail=$((fail+1));; *) skip=$((skip+1));; esac; }
SW=/run/current-system/sw
T=$(mktemp -d /tmp/test-help.XXXXXX); trap 'find "$T" -depth -delete 2>/dev/null' EXIT
# bare: the environment cron and `ssh host cmd` give a command (cron.c envinit; sshd + /etc/default/login PATH)
bare() { env -i HOME="$HOME" LOGNAME="$LOGNAME" PATH="${BARE_PATH:-/usr/bin:}" SHELL=/usr/bin/sh TZ=UTC "$@"; }
# man output is overstruck (bold = c\bc); col -b gives plain text. illumos grep has no -m, env has no -u, there is no seq.
page() { col -b < "$1" | grep -q "$2" && ! grep -q 'No manual entry' "$1"; }

# 1. man with no MANPATH, the cron/ssh-command environment: /usr/share/man must be the system profile's
bare man ls > "$T/1" 2>&1; page "$T/1" 'list contents of directory' && r PASS man-no-manpath "man ls with PATH=/usr/bin: only" \
  || r FAIL man-no-manpath "$(head -1 "$T/1")"
# a profile package's page (not a base page) the same way
bare man curl > "$T/1b" 2>&1; page "$T/1b" 'transfer a URL' && r PASS man-pkg-no-manpath "man curl (a profile package)" \
  || r FAIL man-pkg-no-manpath "$(head -1 "$T/1b")"
# 2. through ssh's non-login shell and sudo, as a user runs them (bash -c is what `ssh host cmd` execs)
env -i HOME="$HOME" LOGNAME="$LOGNAME" PATH=/run/wrappers/bin:$SW/bin:/usr/bin:/usr/sbin:/sbin bash -c 'man zfs' > "$T/2" 2>&1
page "$T/2" 'zfs - configures ZFS' && r PASS man-ssh-cmd "bash -c 'man zfs', no MANPATH" || r FAIL man-ssh-cmd "$(head -1 "$T/2")"
if [ -r /proc/self/psinfo ] && sudo -n true > /dev/null 2>&1; then   # pfexec segfaults with no /proc (getexecname NULL)
  (unset MANPATH; sudo -n man ls) > "$T/2s" 2>&1
  page "$T/2s" 'list contents' && r PASS man-sudo "sudo man ls" || r FAIL man-sudo "$(head -1 "$T/2s")"
else r SKIP man-sudo "sudo -n not allowed for $LOGNAME"; fi
# 3. a real cron job (illumos cron gives jobs HOME LOGNAME PATH SHELL TZ, nothing from /etc/default/init)
# crontab -l exits 0 with no output for a user with no crontab (dixi), so its rc is the access test
if [ -z "${TEST_HELP_NO_CRON:-}" ] && crontab -l > "$T/ct" 2> /dev/null; then
  { cat "$T/ct"; echo "* * * * * man ls > $T/cron.out 2>&1"; } | crontab
  i=0; while [ $i -lt 75 ] && [ ! -s "$T/cron.out" ]; do sleep 1; i=$((i+1)); done; sleep 1
  crontab "$T/ct"
  page "$T/cron.out" 'list contents' && r PASS man-cron "a cron job's man ls" || r FAIL man-cron "$(head -1 "$T/cron.out" 2> /dev/null)"
else r SKIP man-cron "no crontab access (or TEST_HELP_NO_CRON)"; fi
# 4. the man index: man -k / apropos / whatis, with and without MANPATH
WH=${TEST_HELP_WHATIS:-$SW/share/man/whatis}
if [ -s "$WH" ]; then
  bare man -k checksum > "$T/4" 2>&1; bare whatis ls > "$T/4b" 2>&1
  grep -q '^cksum(1)' "$T/4" && grep -q '^ls(1) .*list contents' "$T/4b" && r PASS man-k "$(wc -l < "$WH" | tr -d ' ') entries; man -k + whatis" \
    || r FAIL man-k "$(head -1 "$T/4")"
else r FAIL man-k "no index at $WH"; fi
# 5. info: the reader, the dir node, a manual (bash's), with no INFOPATH
if command -v info > /dev/null; then
  bare info --output=- bash > "$T/5" 2>&1; bare info --output=- '(dir)Top' > "$T/5b" 2>&1
  grep -q 'Bash Features' "$T/5" && grep -q -i 'bash' "$T/5b" && r PASS info "info bash + the dir node, no INFOPATH" \
    || r FAIL info "$(head -1 "$T/5")"
else r FAIL info "no info on PATH"; fi
# 6. the man: URI handler and the launcher plugin (desktop systems; files only, no window opened)
if [ -e "$SW/share/applications/solnix-man.desktop" ]; then
  d=$(XDG_DATA_DIRS=$SW/share xdg-mime query default x-scheme-handler/man 2> /dev/null)
  c=$(SOLNIX_MAN_OPEN_PRINT=1 solnix-man-open 'man:printf(3c)' 2>&1)
  [ "$d" = solnix-man.desktop ] && [ "$c" = "man -s 3c printf" ] && r PASS man-uri "x-scheme-handler/man -> $d" \
    || r FAIL man-uri "default '$d', command '$c'"
  pr=/etc/pop-launcher/plugins/man/plugin.ron; b=$(sed -n 's/.*path: "\(.*\)".*/\1/p' $pr 2> /dev/null)
  o=$(printf '{"Search":"man ls"}\n"Exit"\n' | "$b" 2> /dev/null)
  [ -x "$b" ] && echo "$o" | grep -q '"name":"ls(1)' && r PASS launcher-man "pop-launcher plugin answers 'man ls'" \
    || r FAIL launcher-man "plugin '$b': $(echo "$o" | head -1)"
else r SKIP man-uri "no desktop (solnix-man.desktop)"; r SKIP launcher-man "no desktop"; fi

echo "test-help: $pass PASS $fail FAIL $skip SKIP"
[ "$1" = --negctl ] || exit $((fail > 0))

# negative controls: each fixed thing put back, the check must FAIL
echo "== negative controls =="; n=0 ok=0
neg() { n=$((n+1)); if eval "$2"; then echo "negctl MISS $1 passed on the broken state"; else ok=$((ok+1)); echo "negctl ok   $1 fails on the broken state"; fi; }
# man without /usr/share/man: MANPATH pointing at the world's usr/share (no man dir), what the old /usr/share gave
W=$(ls -ld /usr/share/lib | sed 's/.* -> //; s,/usr/share/lib$,,')
neg man-no-manpath "env -i PATH=/usr/bin: MANPATH=$W/usr/share/man man ls 2>&1 | grep -q 'list contents'"
neg man-k "env -i PATH=/usr/bin: MANPATH=$T man -k checksum 2>&1 | grep -q '^cksum(1)'"
neg info "env -i PATH=/usr/bin: INFOPATH=$T: info --output=- nosuchmanual 2>&1 | grep -q 'Bash Features'"
neg man-uri "SOLNIX_MAN_OPEN_PRINT=1 solnix-man-open 'man:ls;id' > /dev/null 2>&1"
echo "test-help negctl: $ok of $n failed as expected"
[ $fail -eq 0 ] && [ $ok -eq $n ]
