#!/usr/bin/env python3
"""builder-watchdog.py -- a read-only, no-LLM watchdog for the solnix queue builders (durable1, 2026-11-11).

  builder-watchdog.py --hosts <hosts.tsv> --out <dir> [--now <epoch>]   one run: <dir>/STATUS.md, ALERT lines to <dir>/ALERTS.log
  builder-watchdog.py --selftest                                         fixtures, with negative controls

hosts.tsv: "<name>\t<command prefix>" per builder; the prefix gets ONE argument, the remote shell command (e.g. an ssh line
with its pinned known_hosts). The remote command only reads: svcs, the SMF log (world-readable on illumos). It never fixes
anything. Per builder: service state, the age of its last progress (a `published` line or a `complete ... -> 200`), the last
plan's counts, the last tick's held/decline counts, and the log's last line (a silent log is a wedged loop). Also: served
narinfos for the last rows of the served recipes.tsv (and the change since the last run), and infra's inbox vs our outbox.
ALERT (appended, then repeated every 6 h while it holds): a builder online with BUILD/EVAL jobs and no progress in 6 h; a
builder in maintenance/offline/degraded; an online builder whose log has been silent 3 h; infra silent 12 h after our last
message. A disabled builder is deliberate (dixi/dixa await their tier), shown, never alerted.
"""
import concurrent.futures, json, os, re, subprocess, sys, time, urllib.request, shlex

CACHE = "https://cache.solnix.io"
RECIPES = CACHE + "/registry/recipes.tsv"
LOG = "/var/svc/log/site-solnix-builder:default.log"
INBOX = "/tmp/to-solnix-builder-team"   # infra -> us
OUTBOX = "/tmp/to-solnix-infra-team"    # us -> infra
STALL_H, SILENT_H, INFRA_H, REPEAT_H, LAST_ROWS = 6, 3, 12, 6, 100
# The remote side: state, now, every progress/plan line (the log can outgrow a tail), the last tick (from its last plan: line)
REMOTE = ("svcs -H -o state site/solnix-builder 2>&1 | head -1; date -u +%Y-%m-%dT%H:%M:%SZ; L=" + LOG + "; grep ' builder: ' $L | head -1 | cut -c1-20; "
          "echo @@P; egrep 'builder: [^ ]+: published /nix/store/|builder: complete [^ ]+ -> 200|builder: plan:' $L | tail -400; "
          "echo @@T; n=$(grep -n 'builder: plan:' $L | tail -1 | cut -d: -f1); tail -n +${n:-1} $L | tail -2000; echo @@E")
TS = re.compile(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ) builder: ")
PROG = re.compile(r"builder: (?:[^ ]+: published /nix/store/|complete [^ ]+ -> 200)")

def ts(s):
    return int(time.mktime(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ")) - time.timezone) if s else None

def parse(text, now):
    """One builder's remote output -> its status dict (pure: the selftest drives it)."""
    lines = text.splitlines()
    st = {"state": lines[0].strip() if lines else "unreachable", "progress": None, "plan": "", "jobs": 0, "held": 0,
          "decline": 0, "last": None, "first": None, "ok": "@@E" in lines}
    if not st["ok"]: st["state"] = "unreachable"; return st
    # the log's first timestamp sits between the date line and @@P (absent when the log is empty, or the remote grep failed)
    hd = lines[2:lines.index("@@P")] if "@@P" in lines else []
    st["first"] = ts(hd[0][:20]) if hd and TS.match(hd[0][:20] + " builder: ") else None
    sec = None
    for l in lines[2:]:
        if l in ("@@P", "@@T", "@@E"): sec = l; continue
        m = TS.match(l)
        if not m: continue
        t = ts(m.group(1)); st["last"] = max(st["last"] or 0, t)
        if sec == "@@P" and PROG.search(l): st["progress"] = max(st["progress"] or 0, t)
        if sec == "@@P" and "builder: plan:" in l:
            st["plan"] = l.split("plan:", 1)[1].strip()
            c = dict((k, int(v)) for v, k in re.findall(r"(\d+) ([A-Z][A-Z-]+)", st["plan"]))
            st["jobs"] = c.get("BUILD", 0) + c.get("EVAL", 0)
        if sec == "@@T":
            st["held"] += bool(re.search(r"builder: held ", l)); st["decline"] += bool(re.search(r"builder: decline ", l))
    return st

def alerts(name, st, now):
    """[(key, text)] for one builder."""
    a, h = [], lambda t: (now - t) / 3600
    if st["state"] in ("maintenance", "offline", "degraded", "unreachable"):
        a.append((f"{name}:state", f"{name}: site/solnix-builder is {st['state']}"))
    if st["state"] == "online":
        if st["last"] and h(st["last"]) > SILENT_H:
            a.append((f"{name}:silent", f"{name}: online but its log has been silent {h(st['last']):.1f} h (a wedged loop?)"))
        since = st["progress"] or st["first"]   # no progress line in the log: count from the log's first line
        if st["jobs"] > 0 and since and h(since) > STALL_H:
            what = f"last progress {h(st['progress']):.1f} h ago" if st["progress"] else f"no progress in its log ({h(since):.1f} h)"
            a.append((f"{name}:stall", f"{name}: {what} while its plan has {st['jobs']} BUILD/EVAL jobs ({st['plan']}); "
                                       f"last tick: {st['held']} held, {st['decline']} declined"))
    return a

def stamp(name, path):
    m = re.match(r"(\d{8}T\d{6})", name)
    return int(time.mktime(time.strptime(m.group(1), "%Y%m%dT%H%M%S")) - time.timezone) if m else int(os.path.getmtime(path))

def newest(d):
    """(epoch, name) of the newest message in d (files or row folders; not handled/, not the sops file)."""
    best = (0, "-")
    try: names = os.listdir(d)
    except OSError: return best
    for n in names:
        if n in ("handled",) or n.endswith(".sops.yaml") or n.startswith("."): continue
        best = max(best, (stamp(n, os.path.join(d, n)), n))
    return best

def infra(now, inbox=INBOX, outbox=OUTBOX):
    i, o = newest(inbox), newest(outbox)
    a = []
    if o[0] > i[0] and (now - o[0]) / 3600 > INFRA_H:
        a.append(("infra:silent", f"infra: no reply for {(now - o[0]) / 3600:.1f} h since our {o[1]} (their newest: {i[1]})"))
    return i, o, a

UA = {"User-Agent": "solnix-builder-watchdog/1 (curl-compatible)"}   # cache.solnix.io answers 403 to Python-urllib's UA (measured)
def get(url, method="GET"): return urllib.request.urlopen(urllib.request.Request(url, method=method, headers=UA), timeout=60)
def head(url):
    try:
        with get(url, "HEAD") as r: return r.status
    except Exception as e: return getattr(e, "code", 0)

def cache():
    """(served, total, rows): narinfos served for the out and debug columns of the last LAST_ROWS rows of recipes.tsv."""
    with get(RECIPES) as r: rows = r.read().decode().splitlines()[1:]
    outs = [p for l in rows[-LAST_ROWS:] for p in (l.split("\t") + ["", ""])[8:10] if p.startswith("/nix/store/")]
    with concurrent.futures.ThreadPoolExecutor(16) as ex:
        codes = list(ex.map(lambda p: head(f"{CACHE}/{p[11:43]}.narinfo"), outs))
    return sum(c == 200 for c in codes), len(outs), len(rows)

def age(t, now): return "-" if not t else f"{(now - t) / 3600:.1f} h"

def run(hosts, out, now):
    os.makedirs(out, exist_ok=True)
    sp, stt = os.path.join(out, "state.json"), {}
    try: stt = json.load(open(sp))
    except (OSError, ValueError): pass
    rows, al = [], []
    for l in open(hosts):
        if not l.strip() or l.startswith("#"): continue
        name, cmd = l.rstrip("\n").split("\t", 1)
        try: txt = subprocess.run(shlex.split(cmd) + [REMOTE], capture_output=True, text=True, timeout=90).stdout
        except subprocess.TimeoutExpired: txt = ""
        st = parse(txt, now)
        # a restarted or rotated log forgets older progress: keep the newest seen across runs (state.json)
        lp = stt.setdefault("progress", {}); st["progress"] = max(st["progress"] or 0, lp.get(name, 0)) or None
        if st["progress"]: lp[name] = st["progress"]
        al += alerts(name, st, now)
        rows.append(f"| {name} | {st['state']} | {age(st['progress'], now)} | {st['plan'] or '-'} | {st['held']} | {st['decline']} | {age(st['last'], now)} |")
    try:
        s, t, n = cache(); prev = stt.get("cache", [s, t, n])
        cl = f"{s}/{t} served (out+debug of the last {LAST_ROWS} rows; was {prev[0]}/{prev[1]}); recipes.tsv {n} rows (was {prev[2]})"
        stt["cache"] = [s, t, n]
    except Exception as e: cl = f"unavailable ({e})"; al.append(("cache:down", f"cache: recipes.tsv or narinfos unreachable: {e}"))
    i, o, a = infra(now); al += a
    # an alert is appended when it starts, and again every REPEAT_H while it holds; cleared keys are forgotten
    seen, new = stt.get("alerts", {}), {}
    with open(os.path.join(out, "ALERTS.log"), "a") as f:
        for k, txt in al:
            t0 = seen.get(k, 0); new[k] = t0
            if now - t0 >= REPEAT_H * 3600: f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(now))} ALERT {txt}\n"); new[k] = now
    stt["alerts"] = new
    md = [f"# solnix builders, {time.strftime('%Y-%m-%dT%H:%MZ', time.gmtime(now))} (builder-watchdog.py, read-only)", "",
          "| builder | service | last progress | last plan | held | declined (last tick) | log last line |",
          "|---|---|---|---|---|---|---|", *rows, "",
          f"- cache: {cl}", f"- infra inbox newest: {i[1]} ({age(i[0], now)}); our outbox newest: {o[1]} ({age(o[0], now)})", "",
          "## Active alerts", *([f"- {t}" for _, t in al] or ["- none"])]
    open(sp + ".new", "w").write(json.dumps(stt)); os.replace(sp + ".new", sp)
    open(os.path.join(out, "STATUS.md.new"), "w").write("\n".join(md) + "\n"); os.replace(os.path.join(out, "STATUS.md.new"), os.path.join(out, "STATUS.md"))
    return al

def selftest():
    import tempfile
    now = ts("2026-11-11T12:00:00Z"); bad = 0
    def fx(state, plan, prog, tick, first="2026-11-11T00:00:00Z", last=None):
        p = [f"{plan[0]} builder: plan:  {plan[1]}"] if plan else []
        p += [f"{t} builder: x: published /nix/store/aaa-x" for t in prog]
        t = [f"{tick} builder: plan:  {plan[1] if plan else ''}", f"{tick} builder: held a: newest b refused here (c)",
             f"{tick} builder: decline d: e", f"{tick} builder: decline f: g"] + ([f"{last} builder: not idle"] if last else [])
        return "\n".join([state, "2026-11-11T12:00:00Z", first, "@@P", *p, "@@T", *t, "@@E"])
    def chk(desc, cond):
        nonlocal bad; bad += not cond; print(("ok  " if cond else "BAD ") + desc)
    s = parse(fx("online", ("2026-11-11T11:43:00Z", "7 BUILD 3 EVAL 524 NO-RECIPE"), ["2026-11-11T09:00:00Z"], "2026-11-11T11:43:00Z"), now)
    chk("parse: plan counts BUILD+EVAL, last tick held/decline", s["jobs"] == 10 and s["held"] == 1 and s["decline"] == 2)
    chk("recent progress (3 h), jobs: no alert", alerts("h", s, now) == [])
    s = parse(fx("online", ("2026-11-11T11:43:00Z", "7 BUILD 3 EVAL"), ["2026-11-11T05:00:00Z"], "2026-11-11T11:43:00Z"), now)
    chk("NEG progress 7 h ago with jobs: stall ALERT", [k for k, _ in alerts("h", s, now)] == ["h:stall"])
    s = parse(fx("online", ("2026-11-11T11:43:00Z", "524 NO-RECIPE"), [], "2026-11-11T11:43:00Z"), now)
    chk("no progress, no BUILD/EVAL jobs: no alert (nothing to do is not a stall)", alerts("h", s, now) == [])
    s = parse(fx("online", ("2026-11-11T11:43:00Z", "2 BUILD"), [], "2026-11-11T11:43:00Z", first="2026-11-11T09:00:00Z"), now)
    chk("no progress line, log only 3 h old: no alert yet", alerts("h", s, now) == [])
    s = parse(fx("online", ("2026-11-11T11:43:00Z", "2 BUILD"), [], "2026-11-11T11:43:00Z"), now)
    chk("NEG no progress line in a 12 h log, with jobs: stall ALERT", [k for k, _ in alerts("h", s, now)] == ["h:stall"])
    s = parse(fx("online", ("2026-11-11T07:00:00Z", "1 BUILD"), ["2026-11-11T07:00:00Z"], "2026-11-11T07:00:00Z"), now)
    chk("NEG log silent 5 h: silent ALERT", "h:silent" in [k for k, _ in alerts("h", s, now)])
    s = parse(fx("disabled", None, [], "2026-11-10T23:00:00Z"), now)
    chk("disabled: shown, no alert", s["state"] == "disabled" and alerts("h", s, now) == [])
    chk("NEG maintenance: state ALERT", [k for k, _ in alerts("h", parse(fx("maintenance", None, [], "2026-11-11T11:00:00Z"), now), now)] == ["h:state"])
    s = parse(fx("online", ("2026-11-11T11:43:00Z", "2 BUILD"), ["2026-11-11T10:00:00Z"], "2026-11-11T11:43:00Z").replace("2026-11-11T00:00:00Z\n@@P", "@@P"), now)
    chk("no first-line timestamp (an empty log head): plan and progress still parse", s["jobs"] == 2 and s["progress"] == ts("2026-11-11T10:00:00Z") and s["first"] is None)
    chk("NEG truncated output (no @@E): unreachable ALERT", parse("online\n2026", now)["state"] == "unreachable")
    s = parse(fx("online", ("2026-11-11T11:43:00Z", "1 BUILD"), ["2026-11-11T11:00:00Z"], "2026-11-11T11:43:00Z")
              .replace("x: published /nix/store/aaa-x", "x: /nix/store/aaa-x-debug is not published yet: the job is claimed once every listed out is")
              .replace("@@T", "2026-11-11T11:01:00Z builder: held y: its reference published /nix/store/bbb elsewhere\n@@T"), now)
    chk("'is not published yet' and a non-pname 'published /nix/store' are not progress", s["progress"] is None)
    d = tempfile.mkdtemp(); ib, ob = os.path.join(d, "in"), os.path.join(d, "out"); os.makedirs(ib + "/handled"); os.makedirs(ob)
    open(ob + "/20261110T200000-ask.md", "w").close(); open(ib + "/20261110T190000-reply.md", "w").close()
    open(ib + "/handled/20261111T110000-old.md", "w").close()
    chk("NEG our message 16 h old, infra's newest older (handled/ ignored): infra ALERT", [k for k, _ in infra(now, ib, ob)[2]] == ["infra:silent"])
    os.mkdir(ib + "/20261111T020000-rows-reply")
    chk("infra replied after it (a row folder): no alert", infra(now, ib, ob)[2] == [])
    # run(): ALERT appended once, repeated only after REPEAT_H (a fake host whose command prints the fixture)
    fxs = fx("online", ("2026-11-11T11:43:00Z", "2 BUILD"), [], "2026-11-11T11:43:00Z")
    open(d + "/fx", "w").write(fxs); open(d + "/hosts.tsv", "w").write(f"fake\tsh -c 'cat {d}/fx' --\n")
    global cache, INBOX, OUTBOX; cache = lambda: (5, 10, 100); INBOX, OUTBOX = ib, ob
    run(d + "/hosts.tsv", d + "/w", now); run(d + "/hosts.tsv", d + "/w", now + 1800)
    n1 = open(d + "/w/ALERTS.log").read().count("ALERT fake: no progress"); run(d + "/hosts.tsv", d + "/w", now + REPEAT_H * 3600)
    n2 = open(d + "/w/ALERTS.log").read().count("ALERT fake: no progress")
    st = open(d + "/w/STATUS.md").read()
    open(d + "/fx", "w").write(fx("online", ("2026-11-11T11:43:00Z", "2 BUILD"), ["2026-11-11T11:00:00Z"], "2026-11-11T11:43:00Z"))
    run(d + "/hosts.tsv", d + "/w2", now); open(d + "/fx", "w").write(fxs)   # progress at 11:00, then a log without it
    a2 = run(d + "/hosts.tsv", d + "/w2", now + 3 * 3600); a3 = run(d + "/hosts.tsv", d + "/w2", now + 6 * 3600)
    chk("a restarted log keeps the last progress seen (state.json): no alert at +3 h, stall ALERT at +6 h",
        not [k for k, _ in a2 if k == "fake:stall"] and [k for k, _ in a3 if k == "fake:stall"] == ["fake:stall"])
    chk("run: ALERT appended once in 30 min, again after 6 h; STATUS.md has the row", (n1, n2) == (1, 2) and "| fake | online |" in st and "2 BUILD" in st)
    print("RESULT:", "PASS" if bad == 0 else f"FAIL ({bad})"); return 1 if bad else 0

if __name__ == "__main__":
    a = sys.argv[1:]
    if a == ["--selftest"]: sys.exit(selftest())
    if len(a) >= 4 and a[0] == "--hosts" and a[2] == "--out":
        run(a[1], a[3], int(a[5]) if a[4:5] == ["--now"] else int(time.time())); sys.exit(0)
    print(__doc__); sys.exit(2)
