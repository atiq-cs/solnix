#!/usr/bin/env python3
# pam-sys05-illumos.py <pam-sys-0.5.6 dir> <pam_appl.h>: pam-sys 0.5 hardcodes Linux-PAM numbers
# (no bindgen). illumos libpam differs (measured, gate pam_appl.h): PAM_ESTABLISH_CRED is 0x1
# (pam-sys sends 0x2 = illumos DELETE_CRED), AUTH_ERR is 9 (pam-sys decodes 9 as AUTHINFO_UNAVAIL),
# SILENT is 0x80000000. Each value is read from the illumos header, so the table cannot drift.
# Codes illumos lacks get 100+ (above PAM_TOTAL_ERRNUM, never returned). GUARDED.
import sys, os, re
d, hdr = sys.argv[1], sys.argv[2]
H = {m.group(1): int(m.group(2), 0) for m in
     re.finditer(r"#define\s+PAM_([A-Z_]+)\s+(0x[0-9a-fA-F]+|\d+)", open(hdr).read())}
p = os.path.join(d, "src/types.rs"); s = open(p).read()
VAR = re.compile(r"(?m)^(\s+)([A-Z_]+) = (0x[0-9a-fA-F]+|\d+),")

def fix(enum, fmt, spare):
    global s
    a = s.index("pub enum %s {" % enum); b = s.index("\n}\n", a)
    def sub(m):
        k = m.group(2)
        if k == "NONE": return m.group(0)
        v = H.get(k)
        if v is None: v = spare.pop(0); return "%s%s = %s, // not in illumos libpam" % (m.group(1), k, fmt(v))
        return "%s%s = %s," % (m.group(1), k, fmt(v))
    s = s[:a] + VAR.sub(sub, s[a:b]) + s[b:]
    return VAR.findall(s[a:s.index("\n}\n", a)])

codes = fix("PamReturnCode", str, list(range(100, 110)))
# PamFlag stays a Linux-valued enum (illumos reuses values across APIs: ESTABLISH_CRED ==
# DISALLOW_NULL_AUTHTOK == 0x1, so an enum cannot hold them); the FFI cast maps it instead.
fl = re.findall(r"(?m)^\s+([A-Z_]+) = 0x[0-9a-fA-F]+,", s[s.index("pub enum PamFlag {"):s.index("\n}\n", s.index("pub enum PamFlag {"))])
arms = "".join("            PamFlag::%s => %su32,\n" % (k, hex(H[k]) if k in H else "0") for k in fl)
s = s.replace("impl Display for PamFlag {", "impl PamFlag {\n    /// The illumos <security/pam_appl.h> value of this flag.\n"
              "    pub fn illumos(self) -> i32 {\n        (match self {\n" + arms + "        }) as i32   // illumos int; PAM_SILENT is the sign bit\n    }\n}\n\nimpl Display for PamFlag {", 1)
w = os.path.join(d, "src/wrapped.rs"); t = open(w).read()
if t.count("flags as c_int") != 6: sys.exit("FATAL: pam-sys wrapped.rs: flags as c_int x%d (want 6)" % t.count("flags as c_int"))
open(w, "w").write(t.replace("flags as c_int", "flags.illumos() as c_int"))
# From<i32>: decode through the enum's own (now illumos) values, not the Linux literal table.
a = s.index("impl From<i32> for PamReturnCode {"); b = s.index("\n}\n", a) + 3
arms = "".join("            x if x == PamReturnCode::%s as i32 => PamReturnCode::%s,\n" % (c[1], c[1]) for c in codes)
s = s[:a] + ("impl From<i32> for PamReturnCode {\n    fn from(status: i32) -> PamReturnCode {\n        match status {\n"
             + arms + "            _ => PamReturnCode::SYSTEM_ERR,\n        }\n    }\n}\n") + s[b:]
open(p, "w").write(s)
for k, v in (("PamFlag::ESTABLISH_CRED =>", "0x1u32,"), ("PamFlag::DELETE_CRED =>", "0x2u32,"), ("PamFlag::SILENT =>", "0x80000000u32,"),
             ("AUTH_ERR =", "9,"), ("SUCCESS =", "0,")):
    if not re.search(r"(?m)^\s+%s %s" % (re.escape(k), v), s): sys.exit("FATAL: pam-sys self-check: %s %s" % (k, v))
print("pam-sys 0.5 illumos values: %d return codes, %d flags from %s" % (len(codes), len(fl), hdr), file=sys.stderr)
