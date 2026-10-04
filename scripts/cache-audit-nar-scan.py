#!/usr/bin/env python3
"""cache-audit-nar-scan.py -- READ-ONLY streaming NAR/ELF scan of solnix cache objects.

For each hash given, GETs nar/<file>.nar.xz from https://cache.solnix.io (URL
taken from the narinfo already saved by cache-audit-narinfo.py), streams it
through an xz decoder and a NAR parser without materialising the NAR, verifies
NarHash/NarSize, and records a listing of every file (regular/executable/
symlink/dir) plus, for every ELF, class/machine/osabi/type/interp/NEEDED/
RUNPATH/RPATH/SONAME. ELF members are spooled to a temp file under
$WORK/tmp (memory-bounded) and parsed with pyelftools.

Output: $WORK/scan/<hash>.json.gz (one per object). Already-present outputs are
skipped, so the run is resumable.

Usage: cache-audit-nar-scan.py WORKDIR HASHES_FILE [JOBS]
Needs python3 with pyelftools.
"""
import gzip, hashlib, json, lzma, os, sys, tempfile, time, urllib.request
from concurrent.futures import ProcessPoolExecutor, as_completed

CACHE = os.environ.get("CACHE", "https://cache.solnix.io")
NIX32 = "0123456789abcdfghijklmnpqrsvwxyz"
SPOOL_MAX = 32 << 20  # ELF members larger than this go to disk, not RAM


def nix32(b):
    n = (len(b) * 8 - 1) // 5 + 1
    out = []
    for i in range(n - 1, -1, -1):
        bp = i * 5; by, j = divmod(bp, 8)
        c = b[by] >> j
        if by + 1 < len(b):
            c |= b[by + 1] << (8 - j)
        out.append(NIX32[c & 0x1f])
    return "".join(out)


class Stream:
    """Byte reader over the decompressed NAR; hashes everything it yields."""

    def __init__(self, resp):
        self.r, self.d = resp, lzma.LZMADecompressor()
        self.buf, self.pos, self.h, self.n = b"", 0, hashlib.sha256(), 0

    def _fill(self, need):
        while len(self.buf) - self.pos < need:
            if self.d.eof:
                raise EOFError("nar truncated")
            raw = self.r.read(1 << 20)
            if not raw and not self.d.needs_input:
                chunk = self.d.decompress(b"", max_length=1 << 22)
            elif not raw:
                raise EOFError("http body truncated")
            else:
                chunk = self.d.decompress(raw)
            self.buf = self.buf[self.pos:] + chunk; self.pos = 0
            while not self.d.needs_input and not self.d.eof:  # drain pending output
                more = self.d.decompress(b"", max_length=1 << 22)
                if not more:
                    break
                self.buf += more

    def read(self, n):
        out = bytearray()
        while n:
            self._fill(1)
            take = min(n, len(self.buf) - self.pos)
            piece = self.buf[self.pos:self.pos + take]
            self.pos += take; n -= take
            self.h.update(piece); self.n += take
            out += piece
        return bytes(out)

    def copy(self, n, sink):
        """Stream n bytes into sink (file-like or None) without holding them."""
        while n:
            self._fill(1)
            take = min(n, len(self.buf) - self.pos)
            piece = self.buf[self.pos:self.pos + take]
            self.pos += take; n -= take
            self.h.update(piece); self.n += take
            if sink is not None:
                sink.write(piece)

    def u64(self):
        return int.from_bytes(self.read(8), "little")

    def pad(self, n):
        if n % 8:
            self.read(8 - n % 8)

    def str(self):
        n = self.u64(); s = self.read(n); self.pad(n); return s

    def expect(self, s):
        got = self.str()
        if got != s:
            raise ValueError(f"nar: expected {s!r} got {got[:40]!r}")


def raw_dynamic(f):
    """Minimal PT_DYNAMIC reader (no section headers). Returns dict of
    interp/needed/runpath/rpath/soname, or None if there is no PT_DYNAMIC."""
    import struct
    f.seek(0); h = f.read(64)
    c64, le = h[4] == 2, h[5] == 1
    E = "<" if le else ">"
    if c64:
        phoff, = struct.unpack(E + "Q", h[32:40]); phentsize, phnum = struct.unpack(E + "HH", h[54:58])
    else:
        phoff, = struct.unpack(E + "I", h[28:32]); phentsize, phnum = struct.unpack(E + "HH", h[42:46])
    loads, dyn, interp = [], None, None
    for i in range(phnum):
        f.seek(phoff + i * phentsize); p = f.read(phentsize)
        if c64:
            pt, _, off, va, _, fsz = struct.unpack(E + "IIQQQQ", p[:40])
        else:
            pt, off, va, _, fsz = struct.unpack(E + "IIIII", p[:20])
        if pt == 1: loads.append((va, off, fsz))
        elif pt == 2: dyn = (off, fsz)
        elif pt == 3:
            f.seek(off); interp = f.read(fsz).rstrip(b"\0").decode("utf-8", "replace")
    if dyn is None:
        return None
    f.seek(dyn[0]); raw = f.read(dyn[1]); fmt, sz = (E + "qQ", 16) if c64 else (E + "iI", 8)
    ents = [struct.unpack(fmt, raw[i:i + sz]) for i in range(0, len(raw) - sz + 1, sz)]
    strtab = next((v for t, v in ents if t == 5), None)
    stroff = next((off + strtab - va for va, off, fsz in loads if va <= (strtab or -1) < va + fsz), None)
    def s(v):
        f.seek(stroff + v); b = f.read(4096); return b.split(b"\0", 1)[0].decode("utf-8", "replace")
    out = {"interp": interp, "needed": [], "runpath": None, "rpath": None, "soname": None}
    for t, v in ents:
        if t == 0: break
        if stroff is None: continue
        if t == 1: out["needed"].append(s(v))
        elif t == 29: out["runpath"] = s(v)
        elif t == 15: out["rpath"] = s(v)
        elif t == 14: out["soname"] = s(v)
    return out


def elf_info(f):
    try:
        return _elf_info(f)
    except Exception as ex:
        from elftools.elf.elffile import ELFFile
        f.seek(0); e = ELFFile(f)  # header-only parse still works
        info = {"class": e.elfclass, "machine": e.header["e_machine"], "osabi": e.header["e_ident"]["EI_OSABI"],
                "type": e.header["e_type"], "dyn": False, "interp": None, "needed": [], "runpath": None,
                "rpath": None, "soname": None, "parser": "raw-phdr", "pyelftools_error": str(ex)[:120]}
        d = raw_dynamic(f)
        if d:
            info.update(d); info["dyn"] = True
        return info


def _elf_info(f):
    from elftools.elf.elffile import ELFFile
    from elftools.elf.dynamic import DynamicSection
    f.seek(0)
    e = ELFFile(f)
    info = {"class": e.elfclass, "machine": e.header["e_machine"], "osabi": e.header["e_ident"]["EI_OSABI"],
            "type": e.header["e_type"], "interp": None, "needed": [], "runpath": None, "rpath": None,
            "soname": None, "dyn": False}
    for seg in e.iter_segments():
        if seg.header.p_type == "PT_INTERP":
            try:
                info["interp"] = seg.get_interp_name()
            except Exception:
                info["interp"] = "?"
    sec = e.get_section_by_name(".dynamic")
    if sec is None or sec.header["sh_type"] == "SHT_NOBITS" or not isinstance(sec, DynamicSection):
        return info  # static, relocatable, or a separate-debuginfo file
    info["dyn"] = True
    for t in sec.iter_tags():
        k = t.entry.d_tag
        if k == "DT_NEEDED":
            info["needed"].append(t.needed)
        elif k == "DT_RUNPATH":
            info["runpath"] = t.runpath
        elif k == "DT_RPATH":
            info["rpath"] = t.rpath
        elif k == "DT_SONAME":
            info["soname"] = t.soname
    return info


def scan(work, h):
    outp = f"{work}/scan/{h}.json.gz"
    if os.path.exists(outp):
        return h, "cached"
    ni = open(f"{work}/meta/narinfo/{h}.narinfo").read()
    kv = dict(l.split(": ", 1) for l in ni.splitlines() if ": " in l)
    url = f"{CACHE}/{kv['URL']}"
    res = {"hash": h, "storepath": kv.get("StorePath"), "files": {}, "elf": {}, "error": None}
    t0 = time.time()
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "solnix-cache-audit/1"})
        with urllib.request.urlopen(req, timeout=120) as r:
            s = Stream(r)
            s.expect(b"nix-archive-1")
            walk(s, "", res, work)
        res["nar_size_actual"] = s.n
        res["nar_hash_actual"] = "sha256:" + nix32(s.h.digest())
        res["nar_hash_ok"] = res["nar_hash_actual"] == kv.get("NarHash") and str(s.n) == kv.get("NarSize")
    except Exception as ex:
        res["error"] = f"{type(ex).__name__}: {ex}"[:300]
    res["secs"] = round(time.time() - t0, 1)
    tmp = outp + ".part"
    with gzip.open(tmp, "wt") as fo:
        json.dump(res, fo)
    os.replace(tmp, outp)
    return h, res["error"] or "ok"


def walk(s, path, res, work):
    s.expect(b"(")
    s.expect(b"type")
    t = s.str()
    if t == b"regular":
        tag = s.str(); ex = False
        if tag == b"executable":
            ex = True; s.expect(b""); tag = s.str()
        if tag != b"contents":
            raise ValueError("nar: no contents")
        n = s.u64()
        head = s.read(min(n, 4))
        res["files"][path or "/"] = ["x" if ex else "f", n]
        if head == b"\x7fELF":
            with tempfile.SpooledTemporaryFile(SPOOL_MAX, dir=f"{work}/tmp") as sp:
                sp.write(head); s.copy(n - len(head), sp)
                try:
                    res["elf"][path or "/"] = elf_info(sp)
                except Exception as e:
                    res["elf"][path or "/"] = {"error": f"{type(e).__name__}: {e}"[:200]}
        elif head[:2] == b"#!":
            rest = s.read(min(n - len(head), 252))
            line = (head + rest).split(b"\n", 1)[0][2:].strip()
            res.setdefault("shebang", {})[path or "/"] = line.decode("utf-8", "replace")
            s.copy(n - len(head) - len(rest), None)
        else:
            s.copy(n - len(head), None)
        s.pad(n)
        s.expect(b")")
    elif t == b"symlink":
        s.expect(b"target")
        res["files"][path or "/"] = ["l", s.str().decode("utf-8", "replace")]
        s.expect(b")")
    elif t == b"directory":
        res["files"][path or "/"] = ["d"]
        while True:
            tag = s.str()
            if tag == b")":
                break
            if tag != b"entry":
                raise ValueError(f"nar: bad dir tag {tag!r}")
            s.expect(b"("); s.expect(b"name")
            name = s.str().decode("utf-8", "replace")
            s.expect(b"node")
            walk(s, f"{path}/{name}", res, work)
            s.expect(b")")
    else:
        raise ValueError(f"nar: bad type {t!r}")


def main():
    work, hf = sys.argv[1], sys.argv[2]
    jobs = int(sys.argv[3]) if len(sys.argv) > 3 else 6
    os.makedirs(f"{work}/scan", exist_ok=True); os.makedirs(f"{work}/tmp", exist_ok=True)
    hs = [l.strip() for l in open(hf) if len(l.strip()) == 32]
    todo = [h for h in hs if not os.path.exists(f"{work}/scan/{h}.json.gz")]
    print(f"{len(hs)} requested, {len(todo)} to scan", file=sys.stderr, flush=True)
    t0 = time.time(); done = 0
    with ProcessPoolExecutor(jobs) as ex:
        futs = [ex.submit(scan, work, h) for h in todo]
        for f in as_completed(futs):
            done += 1
            try:
                h, st = f.result()
            except Exception as e:  # a worker died (e.g. OOM); rerun resumes it
                h, st = "?", f"worker-died {e}"
            if st != "ok" or done % 50 == 0:
                print(f"[{done}/{len(todo)} {time.time()-t0:.0f}s] {h} {st}", file=sys.stderr, flush=True)
    print("SCAN-DONE", file=sys.stderr)


if __name__ == "__main__":
    main()
