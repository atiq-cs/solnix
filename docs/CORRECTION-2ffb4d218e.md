# Correction to `2ffb4d218e` — two facts eaten by the shell

The commit message for `2ffb4d218e` contained backticks, which the shell executed inside the heredoc. Two
substantive facts were silently deleted from the record. (This is the second time this exact trap has cost
this project facts; the rule is: **no backticks in commit messages written from a shell heredoc.**)

## The eaten facts

**1. The `ROOTLINKS` line.** The commit meant to quote `usr/src/cmd/halt/Makefile:40`, which reads:

```
ROOTLINKS = $(ROOTUSRSBIN)/poweroff $(ROOTUSRSBIN)/reboot
```

Together with `halt.c:49` ("argv[0] to determine which behavior to exhibit"), this establishes that
**`reboot` and `poweroff` are hardlinks to the single `halt` binary**, not separate programs. That is why
staging `halt` alone produced a system with no way to reboot — and why the fix synthesises the links rather
than trying to find two more binaries.

**2. The silent-skip idiom.** The staging loop was:

```sh
[ -e "$SRC/$pp" ] && echo "$pp" >> /tmp/solnix-tools.list
```

The `&&` means a missing file is **skipped with no warning and no non-zero exit**. That is the mechanism by
which `reboot` and `poweroff` vanished without a trace in the build log — the same shape as the hardcoded
12-name `/dev` allowlist that omitted `/dev/zfs`, and the nix `lib/*.so` copy that swallowed failures.

## Why it matters

Both facts are the *reason* the fix takes the form it does. Without them the commit reads as "added some
missing binaries" rather than "identified an argv[0]-dispatch design and a silent-skip idiom". The code is
correct either way; the record was not.
