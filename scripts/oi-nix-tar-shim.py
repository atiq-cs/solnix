#!/usr/bin/python3
# tar-shim: minimal GNU-tar-compatible shim for the crackers illumos build hosts.
#
# WHY: the crackers hosts have Solaris tar (chokes on GitHub's pax global
# headers: "typeflag 'g' not recognized") and no GNU tar. Nix 2.3.16 shells out
# to `tar` from $PATH for `nix-prefetch-url --unpack` and for source unpacks.
# Python's tarfile handles pax transparently. Put this first on PATH as `tar`:
#     mkdir -p /root/shim/bin && cp tar-shim.py /root/shim/bin/tar && chmod +x ...
#     export PATH=/root/shim/bin:/nix-tools/bin:$PATH
#
# Handles the subset Nix uses: `tar xf -`, `tar xf FILE -C DIR`, `tar xzf FILE`,
# clustered flags (`xzf`), and `tar cf`/`czf` for completeness. Compression is
# auto-detected via tarfile's `r|*` / `r:*` stream mode.
import sys, os, tarfile

args = sys.argv[1:]
mode_extract = create = list_mode = False
filename = None
chdir = None
compress = None
rest = []
filename_expected = 0
idx = 0
while idx < len(args):
    a = args[idx]
    if a == '-C':
        idx += 1
        chdir = args[idx]
    elif a.startswith('-') and len(a) > 1 and a[1] != '-':
        for ch in a[1:]:
            if ch == 'x': mode_extract = True
            elif ch == 'c': create = True
            elif ch == 't': list_mode = True
            elif ch in 'zjJ': compress = ch
            elif ch == 'f': filename_expected += 1
    elif not a.startswith('-'):
        if (filename_expected == 0 and not (mode_extract or create or list_mode)
                and all(c in 'xctzjJfvp' for c in a)):
            for ch in a:
                if ch == 'x': mode_extract = True
                elif ch == 'c': create = True
                elif ch == 't': list_mode = True
                elif ch in 'zjJ': compress = ch
                elif ch == 'f': filename_expected += 1
        elif filename_expected > 0 and filename is None:
            filename = a
            filename_expected -= 1
        else:
            rest.append(a)
    idx += 1

if mode_extract or list_mode:
    # Resolve the archive path relative to the ORIGINAL cwd before -C chdir
    # (GNU tar semantics): -f FILE is relative to where tar was invoked.
    if filename is not None and filename != '-':
        filename = os.path.abspath(filename)
    if chdir:
        os.makedirs(chdir, exist_ok=True)
        os.chdir(chdir)
    if filename is None or filename == '-':
        tf = tarfile.open(fileobj=sys.stdin.buffer, mode='r|*')
    else:
        tf = tarfile.open(filename, mode='r:*')
    if list_mode:
        for m in tf:
            print(m.name)
    else:
        try:
            tf.extractall(filter='tar')
        except TypeError:
            tf.extractall()
    tf.close()
elif create:
    if filename is not None and filename != '-':
        filename = os.path.abspath(filename)
    if chdir:
        os.makedirs(chdir, exist_ok=True)
        os.chdir(chdir)
    smode = {'z': 'w:gz', 'j': 'w:bz2', 'J': 'w:xz'}.get(compress, 'w')
    pmode = {'z': 'w|gz', 'j': 'w|bz2', 'J': 'w|xz'}.get(compress, 'w|')
    if filename is None or filename == '-':
        tf = tarfile.open(fileobj=sys.stdout.buffer, mode=pmode)
    else:
        tf = tarfile.open(filename, mode=smode)
    for p in rest:
        tf.add(p)
    tf.close()
else:
    sys.stderr.write("tar-shim: unsupported invocation: %r\n" % (args,))
    sys.exit(2)
