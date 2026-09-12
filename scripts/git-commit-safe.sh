#!/usr/bin/env bash
# Commit with a message read from a FILE, never from a shell heredoc.
#
# Backticks inside a heredoc are executed by the shell, which has now silently
# eaten facts from three commit messages in this project (2ffb4d218e lost the
# ROOTLINKS line and the silent-skip idiom; 7a673def09 lost a shell snippet that
# was the whole point of a finding). The message survives review, gets committed,
# and the loss is invisible until someone reads the log.
#
# Usage: git-commit-safe.sh <message-file> [git-commit-args...]
set -euo pipefail
msg="${1:?usage: git-commit-safe.sh <message-file> [git args...]}"; shift
[ -f "$msg" ] || { echo "no such message file: $msg" >&2; exit 2; }

# Warn if the message contains constructs the shell WOULD have mangled, so the
# author learns the habit rather than relying on this script forever.
if grep -q '`' "$msg"; then
  echo "note: message contains backticks -- safe here (read from file), fatal in a heredoc" >&2
fi
# Refuse an empty or whitespace-only message: an accidentally-truncated file is
# worse than no commit, because it looks deliberate afterwards.
[ -s "$msg" ] && grep -q '[^[:space:]]' "$msg" || {
  echo "message file is empty -- refusing to commit" >&2; exit 3; }

git commit --no-verify -F "$msg" "$@"
