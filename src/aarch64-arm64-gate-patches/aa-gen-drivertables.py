#!/usr/bin/python3.9
# pkg-STYLE driver tables: every proto driver binary gets a major (like
# add_drv at pkg-install time), and aliases come from the gate pkg manifests
# (authoritative) + the metal DT-synth compatibles. Combines the completeness
# of aa-fix-ntm with the CORRECT pkg-manifest aliases.
import os, re, glob

GATE = "/aarch64/arm64-gate/illumos-gate"
MANDIR = GATE + "/usr/src/pkg/manifests"
PROTO = "/build/proto/root_aarch64"
OUT = "/build/drivertables"
os.makedirs(OUT, exist_ok=True)

# 1. manifest aliases: name -> set(aliases)
drivers = {}
for mf in glob.glob(MANDIR + "/*.p5m"):
    txt = open(mf, encoding="utf-8", errors="replace").read()
    txt = re.sub(r"\\\n", " ", txt)
    for line in txt.splitlines():
        line = line.strip()
        if not line.startswith("driver "):
            continue
        if "$(i386_ONLY)" in line or "$(sparc_ONLY)" in line:
            continue
        m = re.search(r"\bname=(\S+)", line)
        if not m:
            continue
        name = m.group(1)
        aliases = set(re.findall(r'\balias=((?:"[^"]*")|(?:\S+))', line))
        aliases = {a.strip('"') for a in aliases}
        drivers.setdefault(name, set()).update(aliases)

# 2. EVERY driver binary present in the proto (completeness: no missing major)
proto_drv = set()
for d in ["kernel/drv/aarch64", "platform/armv8/kernel/drv/aarch64"]:
    p = os.path.join(PROTO, d)
    if os.path.isdir(p):
        for f in os.listdir(p):
            if not f.endswith(".conf"):
                proto_drv.add(f)

# essential pseudo/nexus that may be built into unix/genunix (no drv binary)
essential = {"rootnex", "options", "pseudo", "clone", "scsi_vhci", "mm", "wc",
    "cn", "zcons", "dump", "zfs", "lofi", "ramdisk", "sad", "log", "sy", "ptc",
    "ptm", "pts", "physmem", "cpuid", "kmdb", "dtrace", "fbt", "sdt", "systrace",
    "profile", "lockstat", "fasttrap", "iwscn", "vni", "bl"}

all_drv = proto_drv | essential | set(drivers)

# 3. assign majors: static first, then stable alpha order
static = {"md": 85, "devinfo": 88, "asy": 106, "did": 239}
ntm = dict(static)
used = set(static.values())
nextm = [0]

def alloc():
    while nextm[0] in used:
        nextm[0] += 1
    v = nextm[0]
    used.add(v)
    nextm[0] += 1
    return v

for n in sorted(all_drv):
    if n not in ntm:
        ntm[n] = alloc()

# 4. metal/DT-synth compatibles (from dboot_synth_fdt FDT, not manifests)
metal_aliases = {
    "ecam": ["pci-host-ecam-generic", "pci-host-generic"],
    "npe": ["pciex_root_complex"],
    "pcieb": ["pciexclass,060400"],
    "ns16550a": ["arm,pl011", "arm,sbsa-uart", "ns16550a", "snps,dw-apb-uart"],
    "gicthree": ["arm,gic-v3"],
    "gictwo": ["arm,cortex-a15-gic", "arm,gic-400"],
    "arm_gtmr": ["arm,armv8-timer", "arm,armv7-timer"],
    "simple-bus": ["simple-bus"],
    "efifb": ["simple-framebuffer"],
}
for n, al in metal_aliases.items():
    if n in ntm:
        drivers.setdefault(n, set()).update(al)

# 5. write name_to_major (sorted by major)
with open(OUT + "/name_to_major", "w") as f:
    for n in sorted(ntm, key=lambda k: ntm[k]):
        f.write("%s %d\n" % (n, ntm[n]))

# 6. write driver_aliases (only drivers with a major)
with open(OUT + "/driver_aliases", "w") as f:
    for n in sorted(drivers):
        if n not in ntm:
            continue
        for a in sorted(drivers[n]):
            if not a:
                continue
            f.write('%s "%s"\n' % (n, a))

print("name_to_major entries:", len(ntm))
print("proto driver binaries:", len(proto_drv))
for k in ["rootnex", "scsi_vhci", "zcons", "ena", "nvme", "npe", "blkdev",
          "pcieb", "arm_gtmr", "ns16550a", "simple-bus", "options", "clone"]:
    print("  %-12s major=%s aliases=%s" % (k, ntm.get(k),
          sorted(drivers.get(k, []))[:4]))
