#!/usr/bin/ksh93
# test-builder-identity.sh -- solnix-builder-identity offline, on illumos, with THROWAWAY keys only: the bodies carry the
# fields infra specified, and each signature verifies (ssh-keygen -Y verify -n solnix-builder) over the exact payload;
# NEG: a changed payload, the wrong key, the wrong namespace, a broken signature. Needs only what a solnix host has in
# /usr/bin (ksh93, ssh-keygen, nawk): no jq. Exits 1 if any check fails, and says so on its last line.
S=${1:-$(dirname "$0")/solnix-builder-identity}
W=$(mktemp -d /tmp/sbit.XXXXXX); trap 'find "$W" -depth -delete' EXIT
bad=0 n=0; ok() { n=$((n+1)); print "ok: $1"; }; no() { n=$((n+1)); print "FAIL: $1"; bad=1; }
# field <json> <key>: the string value of a top-level key ("" if absent), \n unescaped; nawk, so no jq on the host
field() { print -r -- "$1" | nawk -v k="\"$2\":" '{ i = index($0, k); if (!i) exit; s = substr($0, i + length(k))
	if (substr(s, 1, 1) != "\"") exit; s = substr(s, 2); o = ""
	while (length(s)) { c = substr(s, 1, 1); if (c == "\\") { d = substr(s, 2, 1); o = o (d == "n" ? "\n" : d); s = substr(s, 3); continue }
	  if (c == "\"") break; o = o c; s = substr(s, 2) } printf "%s", o }'; }
keys() { print -r -- "$1" | nawk '{ n = gsub(/"[a-z_]+":/, "&"); print n }'; }	# top-level keys (no nested objects here)
ssh-keygen -q -t ed25519 -N '' -C throwaway-A -f "$W/a"; ssh-keygen -q -t ed25519 -N '' -C throwaway-B -f "$W/b"
A=$(cut -d' ' -f1,2 "$W/a.pub"); B=$(cut -d' ' -f1,2 "$W/b.pub")
v() { # v <pubkey-line> <sig-armored> <payload-file> <namespace>
	print -r -- "x $1" > "$W/allowed"; print -r -- "$2" > "$W/s"
	ssh-keygen -q -Y verify -f "$W/allowed" -I x -n "$4" -s "$W/s" < "$3" >/dev/null 2>&1; }
e=$(IDENTITY_PAYLOAD_OUT=$W/pe ksh93 "$S" enroll "$W/a" x86_64-solaris test@example.org) || no "enroll ran"
[[ $e == '{"version":1,"kind":"builder_enroll",'* && $(keys "$e") == 7 && $(field "$e" arch) == x86_64-solaris && $(field "$e" flavor) == solnix && $(field "$e" email) == test@example.org ]] &&
  ok "enroll body: the 7 fields" || no "enroll body: $e"
[[ $(field "$e" sshid) == "$A" ]] && ok "enroll sshid = key A" || no "sshid: $(field "$e" sshid)"
[[ $(cat "$W/pe") == "$(printf 'solnix-builder-enroll-v1\n%s\nx86_64-solaris\nsolnix\ntest@example.org\n' "$A")" && $(tail -c1 "$W/pe" | od -An -c | tr -d ' ') == '\n' ]] && ok "enroll payload: 5 lines, newline after the last" || no "payload: $(od -c "$W/pe" | tail -3)"
es=$(field "$e" sig)
[[ $es == '-----BEGIN SSH SIGNATURE-----'*'-----END SSH SIGNATURE-----' ]] && ok "enroll sig is an armored SSHSIG" || no "sig form: ${es:0:60}"
v "$A" "$es" "$W/pe" solnix-builder && ok "enroll sig verifies (A, -n solnix-builder)" || no "enroll sig does not verify"
# NEG: a broken signature (one base64 character of the armored body changed) must not verify
bs=$(print -r -- "$es" | nawk 'NR == 3 { c = substr($0, 10, 1); $0 = substr($0, 1, 9) (c == "A" ? "B" : "A") substr($0, 11) } { print }')
[[ $bs != "$es" ]] && ! v "$A" "$bs" "$W/pe" solnix-builder && ok "NEG broken signature: does not verify" || no "NEG broken signature verified (or was not broken)"
cp "$W/pe" "$W/pt"; printf 'X' | dd of="$W/pt" bs=1 seek=5 conv=notrunc 2>/dev/null
v "$A" "$es" "$W/pt" solnix-builder && no "NEG tampered payload verified" || ok "NEG tampered payload: does not verify"
e2=$(ksh93 "$S" enroll "$W/a" x86_64-solaris); [[ $e2 != *'"email"'* && $(keys "$e2") == 6 ]] && ok "no email: key omitted" || no "email: $e2"
r=$(IDENTITY_PAYLOAD_OUT=$W/pr ksh93 "$S" rotate "$W/a" "$W/b") || no "rotate ran"
[[ $r == '{"version":1,"kind":"builder_rotate",'* && $(keys "$r") == 6 && $(field "$r" old_sshid) == "$A" && $(field "$r" new_sshid) == "$B" ]] && ok "rotate body: the 6 fields, old=A new=B" || no "rotate: $r"
[[ $(cat "$W/pr") == "$(printf 'solnix-builder-rotate-v1\n%s\n%s\n' "$A" "$B")" ]] && ok "rotate payload: domain/old/new" || no "rotate payload"
v "$A" "$(field "$r" sig_old)" "$W/pr" solnix-builder && ok "sig_old verifies under A" || no "sig_old does not verify"
v "$B" "$(field "$r" sig_new)" "$W/pr" solnix-builder && ok "sig_new verifies under B" || no "sig_new does not verify"
v "$B" "$(field "$r" sig_old)" "$W/pr" solnix-builder && no "NEG sig_old verified under B" || ok "NEG sig_old does not verify under B"
v "$A" "$(field "$r" sig_old)" "$W/pr" solnix-build-queue && no "NEG other namespace verified" || ok "NEG namespace solnix-build-queue: does not verify"
ksh93 "$S" rotate "$W/a" "$W/a" >/dev/null 2>&1 && no "NEG rotate to the same key accepted" || ok "NEG rotate to the same key refused"
ksh93 "$S" enroll "$W/a" x86_64-solaris 'a"b@c' >/dev/null 2>&1 && no "NEG quote in email accepted" || ok "NEG quote in email refused"
(( bad )) && print "RESULT: FAIL ($n checks, at least one failed)" || print "RESULT: PASS ($n/$n)"
exit $bad
