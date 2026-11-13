#!/usr/bin/env python3
# desktop-entry-check.py <entry.desktop> <bindir> <icon-theme-dir>: the parts of desktop-file-validate (desktop-file-utils, which
# NixOS's makeDesktopItem runs in its checkPhase) a launcher depends on, for a host without desktop-file-utils, plus what that
# validator cannot see: Exec's program resolves (absolute, or a name in <bindir>), and Icon resolves in <icon-theme-dir>
# (<size>x<size>/apps/<icon>.png whose PNG header is that size, or scalable/apps/<icon>.svg). Exit 1 with a reason per problem.
# Spec: https://specifications.freedesktop.org/desktop-entry-spec/1.5 (key list: "Recognized desktop entry keys").
import os, re, struct, sys

KEYS = {"Type", "Version", "Name", "GenericName", "NoDisplay", "Comment", "Icon", "Hidden", "OnlyShowIn", "NotShowIn",
        "DBusActivatable", "TryExec", "Exec", "Path", "Terminal", "Actions", "MimeType", "Categories", "Implements",
        "Keywords", "StartupNotify", "StartupWMClass", "URL", "PrefersNonDefaultGPU", "SingleMainWindow"}
BOOL = {"NoDisplay", "Hidden", "DBusActivatable", "Terminal", "StartupNotify", "PrefersNonDefaultGPU", "SingleMainWindow"}
LOCALE = {"Name", "GenericName", "Comment", "Icon", "Keywords"}
CODES = set("fFuUick%")


def parse(path, errs):
    groups, order, cur = {}, [], None
    for n, raw in enumerate(open(path, encoding="utf-8").read().split("\n"), 1):
        line = raw.rstrip("\r")
        if not line or line.startswith("#"):
            continue
        m = re.fullmatch(r"\[([^\[\]]+)\]", line)
        if m:
            cur = m.group(1)
            if cur in groups:
                errs.append(f"line {n}: group [{cur}] twice")
            groups[cur] = {}; order.append(cur); continue
        if cur is None:
            errs.append(f"line {n}: a key before the first group"); continue
        m = re.fullmatch(r"([A-Za-z0-9-]+)(\[[A-Za-z_@.0-9-]+\])?\s*=\s*(.*)", line)
        if not m:
            errs.append(f"line {n}: not a key=value line: {line!r}"); continue
        k = m.group(1) + (m.group(2) or "")
        if k in groups[cur]:
            errs.append(f"line {n}: key {k} twice in [{cur}]")
        groups[cur][k] = m.group(3)
    return groups, order


def check_exec(where, v, bindir, errs):
    toks = re.findall(r'"(?:[^"\\]|\\.)*"|\S+', v)
    if not toks:
        errs.append(f"{where}: Exec is empty"); return
    prog = toks[0].strip('"')
    if "=" in prog:   # launchers (libcosmic spawn_desktop_exec) refuse an env-assignment first word
        errs.append(f"{where}: Exec starts with an assignment {prog!r}")
    elif os.path.isabs(prog):
        if not os.access(prog, os.X_OK):
            errs.append(f"{where}: Exec program {prog} is not an executable file")
    elif not os.access(os.path.join(bindir, prog), os.X_OK):
        errs.append(f"{where}: Exec program {prog!r} is not in {bindir}")
    files = 0
    for c in re.findall(r"%(.)", v):
        if c not in CODES:
            errs.append(f"{where}: Exec has an unknown field code %{c}")
        files += c in "fFuU"
    if files > 1:
        errs.append(f"{where}: Exec has more than one of %f %F %u %U")


def png_size(p):
    with open(p, "rb") as f:
        h = f.read(24)
    if h[:8] != b"\x89PNG\r\n\x1a\n" or h[12:16] != b"IHDR":
        return None
    return struct.unpack(">II", h[16:24])


def check_icon(icon, theme, errs):
    if os.path.isabs(icon):
        if not os.path.isfile(icon):
            errs.append(f"Icon {icon} does not exist")
        return
    if "/" in icon or icon.endswith((".png", ".svg", ".xpm")):
        errs.append(f"Icon {icon!r}: a theme icon name has no path and no extension"); return
    found = os.path.isfile(os.path.join(theme, "scalable", "apps", icon + ".svg"))
    for d in sorted(os.listdir(theme)) if os.path.isdir(theme) else []:
        m = re.fullmatch(r"(\d+)x(\d+)", d)
        p = os.path.join(theme, d, "apps", icon + ".png")
        if m and os.path.isfile(p):
            s = png_size(p)
            if s != (int(m.group(1)), int(m.group(2))):
                errs.append(f"{p}: PNG size {s} is not its directory's {d}")
            found = True
    if not found:
        errs.append(f"Icon {icon!r} is in no <size>x<size>/apps or scalable/apps of {theme}")


def check(path, bindir, theme):
    errs = []
    groups, order = parse(path, errs)
    if not order or order[0] != "Desktop Entry":
        return errs + ["the first group is not [Desktop Entry]"]
    e = groups["Desktop Entry"]
    for k, v in e.items():
        base = k.split("[")[0]
        if base.startswith("X-"):
            continue
        if base not in KEYS:
            errs.append(f"unknown key {k}")
        elif "[" in k and base not in LOCALE:
            errs.append(f"key {base} is not localizable ({k})")
        if base in BOOL and v not in ("true", "false"):
            errs.append(f"{k}={v!r} is not a boolean")
    for k in ("Type", "Name"):
        if k not in e:
            errs.append(f"[Desktop Entry] has no {k}")
    if e.get("Type") == "Application":
        if "Exec" not in e and e.get("DBusActivatable") != "true":
            errs.append("an Application with no Exec")
    elif "Type" in e and e["Type"] not in ("Link", "Directory"):
        errs.append(f"unknown Type {e['Type']!r}")
    if "Version" in e and e["Version"] not in ("1.0", "1.1", "1.2", "1.3", "1.4", "1.5"):
        errs.append(f"unknown Version {e['Version']!r}")
    if "Exec" in e:
        check_exec("[Desktop Entry]", e["Exec"], bindir, errs)
    if "Icon" in e:
        check_icon(e["Icon"], theme, errs)
    for t in [x for x in e.get("MimeType", "").split(";") if x]:
        if not re.fullmatch(r"[a-z0-9.+-]+/[A-Za-z0-9.+_-]+", t):
            errs.append(f"MimeType {t!r} is not type/subtype")
    acts = [a for a in e.get("Actions", "").split(";") if a]
    for a in acts:
        g = groups.get(f"Desktop Action {a}")
        if g is None:
            errs.append(f"action {a} has no [Desktop Action {a}] group"); continue
        if "Name" not in g:
            errs.append(f"[Desktop Action {a}] has no Name")
        if "Exec" in g:
            check_exec(f"[Desktop Action {a}]", g["Exec"], bindir, errs)
    for g in order[1:]:
        if g.startswith("Desktop Action ") and g[len("Desktop Action "):] not in acts:
            errs.append(f"[{g}] is not listed in Actions")
        elif not g.startswith(("Desktop Action ", "X-")):
            errs.append(f"unknown group [{g}]")
    return errs


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: desktop-entry-check.py <entry.desktop> <bindir> <icon-theme-dir>")
    errs = check(*sys.argv[1:])
    for x in errs:
        print(f"{sys.argv[1]}: {x}", file=sys.stderr)
    sys.exit(1 if errs else 0)
