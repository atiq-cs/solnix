#!/usr/bin/env python3
"""python-fixup.py: the fixups buildPythonPackage (pkgs/illumos/python.nix) runs after the PyPA installer, nixpkgs' hooks as one script.
  deps <wheel> <site>...  nixpkgs python-runtime-deps-check-hook.py: every Requires-Dist of the wheel (markers evaluated) is installed
                          in <site>... (this out's site-packages + its dependencies' closure) at a matching version. Needs packaging.
  wrap <out> <site>...    nixpkgs wrapPythonPrograms (wrap.sh), without the bash wrapper: each executable bin/ script whose #! is a
                          python gets the preamble line that site.addsitedir()s <site>... (so it finds its own package and its
                          dependencies), before its first statement (after a docstring and `from __future__` imports), and `-s` on
                          a bare #! (PYTHONNOUSERSITE, which nixpkgs' wrapper sets: no ~/.local site-packages).
  pyc <out>               the c-dev.nix python3 rule: a .py that names <out> ships as source only (its checked-hash pyc hashes the
                          scratch out's text under an unsandboxed --check), and every .pyc left is checked-hash (PEP 552 flags 3).
The self-test (the negative control) runs on every call: a docstring + __future__ script gets the preamble after them, a timestamp
pyc is caught, a checked-hash one passes.
"""
import ast, os, sys, tempfile

PRE = "import sys; import site; import functools; functools.reduce(lambda k, p: site.addsitedir(p, k), {!r}, site._init_pathinfo())\n"


def insert_at(src):
    """0-based line index before which the preamble goes: after the docstring and __future__ imports, else before the first statement
    (its decorators included), so the coding comment and the leading comments stay where they are."""
    body = ast.parse(src).body
    i = 0
    if body and isinstance(body[0], ast.Expr) and isinstance(getattr(body[0], "value", None), ast.Constant) and isinstance(body[0].value.value, str):
        i = 1
    while i < len(body) and isinstance(body[i], ast.ImportFrom) and body[i].module == "__future__":
        i += 1
    if i > 0:
        return body[i - 1].end_lineno
    if not body:
        return len(src.splitlines())
    n = body[0]
    return min([n.lineno] + [d.lineno for d in getattr(n, "decorator_list", [])]) - 1


def wrap_file(path, sites):
    with open(path, "rb") as f:
        data = f.read()
    lines = data.splitlines(keepends=True)
    if not lines or not lines[0].startswith(b"#!"):
        return False
    words = lines[0][2:].split()
    if not words or not os.path.basename(words[0]).decode().startswith("python"):
        return False
    if len(words) == 1:
        lines[0] = b"#!" + words[0] + b" -s\n"
    k = insert_at(data)
    lines.insert(k, PRE.format(list(sites)).encode())
    with open(path, "wb") as f:
        f.write(b"".join(lines))
    return True


def wrap(out, sites):
    b = os.path.join(out, "bin")
    n = 0
    for e in sorted(os.listdir(b)) if os.path.isdir(b) else []:
        p = os.path.join(b, e)
        if os.path.isfile(p) and not os.path.islink(p) and os.access(p, os.X_OK) and wrap_file(p, sites):
            print(f"python-fixup: wrapped bin/{e}", file=sys.stderr)
            n += 1
    return 0


def pyc_flags(path):
    with open(path, "rb") as f:
        h = f.read(8)
    return int.from_bytes(h[4:8], "little") if len(h) == 8 else -1


def pyc(out, log=True):
    ob = out.encode()
    for d, _, fs in os.walk(out):
        for f in fs:
            if f.endswith(".py"):
                with open(os.path.join(d, f), "rb") as x:
                    if ob not in x.read():
                        continue
                c = os.path.join(d, "__pycache__")
                for q in os.listdir(c) if os.path.isdir(c) else []:
                    if q.startswith(f[:-3] + ".") and q.endswith(".pyc"):
                        os.remove(os.path.join(c, q))
                        print(f"python-fixup: {f} names $out: ships as source only", file=sys.stderr)
    bad = [os.path.join(d, f) for d, _, fs in os.walk(out) for f in fs if f.endswith(".pyc") and pyc_flags(os.path.join(d, f)) != 3]
    if bad:
        if log:
            print("FATAL: non-checked-hash pyc: " + " ".join(bad[:3]), file=sys.stderr)
        return 1
    return 0


def deps(wheel, sites):
    import importlib.metadata, re, zipfile
    from packaging.metadata import Metadata, parse_email
    from packaging.requirements import Requirement
    with zipfile.ZipFile(wheel) as z:
        m = [n for n in z.namelist() if n.endswith(".dist-info/METADATA")]
        raw, _ = parse_email(z.read(m[0]).decode())
    bad = []
    for r in Metadata.from_raw(raw, validate=False).requires_dist or []:
        if r.marker and not r.marker.evaluate({"extra": ""}):
            continue
        d = next(iter(importlib.metadata.Distribution.discover(name=r.name, path=list(sites))), None)
        if d is None:
            bad.append(f"{re.sub(r'[-_.]+', '-', r.name).lower()} not installed")
        elif r.specifier and not r.specifier.contains(d.version, prereleases=True):
            bad.append(f"{r.name}{r.specifier} not satisfied by version {d.version}")
    for b in bad:
        print(f"  - {b}", file=sys.stderr)
    return 1 if bad else 0


def selftest():
    t = tempfile.mkdtemp()
    s = os.path.join(t, "s")
    with open(s, "w") as f:
        f.write('#!/nix/store/x-python3/bin/python3\n# -*- coding: utf-8 -*-\n"""doc\nmore"""\nfrom __future__ import annotations\n\nimport os\n')
    assert wrap_file(s, ["/a"])
    L = open(s).read().splitlines()
    assert L[0] == "#!/nix/store/x-python3/bin/python3 -s" and L[1] == "# -*- coding: utf-8 -*-" and L[5].startswith("import sys; import site;"), L
    compile(open(s).read(), s, "exec")
    with open(s, "w") as f:
        f.write("#!/bin/sh\necho\n")
    assert not wrap_file(s, ["/a"])
    for flags, ok in ((0, 1), (3, 0)):
        c = os.path.join(t, "__pycache__")
        os.makedirs(c, exist_ok=True)
        with open(os.path.join(c, "m.cpython-313.pyc"), "wb") as f:
            f.write(b"\xf3\r\r\n" + flags.to_bytes(4, "little") + b"h" * 8)
        assert pyc(t, log=False) == ok, flags
    for d, _, fs in os.walk(t, topdown=False):
        for f in fs:
            os.remove(os.path.join(d, f))
        os.rmdir(d)


if __name__ == "__main__":
    selftest()
    a = sys.argv[1:]
    if a == ["--selftest"]:
        print("python-fixup selftest PASS")
        sys.exit(0)
    sys.exit({"deps": lambda: deps(a[1], a[2:]), "wrap": lambda: wrap(a[1], a[2:]), "pyc": lambda: pyc(a[1])}[a[0]]())
