// browser-test.mjs URL -- tryit1: load the demo page in headless Chromium (CDP over node's WebSocket), type
// into the page's own xterm.js terminal as a visitor would (CDP Input events), and check what infra checks:
// login: within 20 s, log in as root, uname -a, ls /, a pipeline, Backspace edits, ^C on sleep 30, no
// trace/FAIL/WARN lines, no JS console errors. Env CDP=ws://... (the browser's page target).
const url = process.argv[2];
const ws = new WebSocket(process.env.CDP);
let id = 0; const pend = new Map(); const errors = [];
ws.onmessage = (e) => { const m = JSON.parse(e.data);
  if (m.id && pend.has(m.id)) { pend.get(m.id)(m); pend.delete(m.id); }
  if (m.method === "Runtime.exceptionThrown") errors.push(JSON.stringify(m.params.exceptionDetails).slice(0, 300));
  if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error") errors.push(JSON.stringify(m.params.args).slice(0, 300));
  if (m.method === "Log.entryAdded" && m.params.entry.level === "error" && !/favicon\.ico/.test(m.params.entry.url || "")) errors.push((m.params.entry.url || "") + " " + m.params.entry.text.slice(0, 200)); };
const send = (method, params = {}) => new Promise((r) => { const i = ++id; pend.set(i, r); ws.send(JSON.stringify({ id: i, method, params })); });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const screen = async () => (await send("Runtime.evaluate", { expression:
  "(()=>{const b=term.buffer.active;let s=[];for(let i=0;i<b.length;i++)s.push(b.getLine(i).translateToString(true));return s.join('\\n')})()",
  returnByValue: true })).result.result.value || "";
async function until(re, ms, from = 0) { const end = Date.now() + ms;
  while (Date.now() < end) { const s = (await screen()).slice(from); if (re.test(s)) return s; await sleep(100); } return null; }
const key = (k, code, kc, text) => send("Input.dispatchKeyEvent", { type: "keyDown", key: k, code, windowsVirtualKeyCode: kc, text })
  .then(() => send("Input.dispatchKeyEvent", { type: "keyUp", key: k, code, windowsVirtualKeyCode: kc }));
async function type(s) { for (const c of s) {
  if (c === "\r") await key("Enter", "Enter", 13, "\r");
  else if (c === "\x7f") await key("Backspace", "Backspace", 8, "\x7f");
  else if (c === "\x03") await send("Input.dispatchKeyEvent", { type: "keyDown", key: "c", code: "KeyC", windowsVirtualKeyCode: 67, modifiers: 2 })
    .then(() => send("Input.dispatchKeyEvent", { type: "keyUp", key: "c", code: "KeyC", windowsVirtualKeyCode: 67, modifiers: 2 }));
  else { const up = /[A-Z]/.test(c), sym = !/[a-z0-9 ]/i.test(c);
    await send("Input.dispatchKeyEvent", { type: "keyDown", key: c, text: c, unmodifiedText: c,
      code: /[a-z]/i.test(c) ? "Key" + c.toUpperCase() : /[0-9]/.test(c) ? "Digit" + c : c === " " ? "Space" : "",
      windowsVirtualKeyCode: /[a-z]/i.test(c) ? c.toUpperCase().charCodeAt(0) : /[0-9 ]/.test(c) ? c.charCodeAt(0) : 0,
      modifiers: up ? 8 : 0 });
    await send("Input.dispatchKeyEvent", { type: "keyUp", key: c, modifiers: up ? 8 : 0 }); void sym; }
  await sleep(30); } }
const res = []; const check = (n, ok, info = "") => { res.push(ok); console.log(`CHECK ${ok ? "PASS" : "FAIL"} ${n} ${info}`); };
ws.onopen = async () => {
  await send("Runtime.enable"); await send("Log.enable"); await send("Page.enable");
  const t0 = Date.now(); await send("Page.navigate", { url });
  let s = await until(/solnix-riscv login: *$/m, 60000);
  check("login-prompt<20s", s !== null && Date.now() - t0 < 20000, `${((Date.now() - t0) / 1000).toFixed(1)}s`);
  await send("Runtime.evaluate", { expression: "term.focus(); window.__sent=[]; term.onData(d => window.__sent.push(Array.from(d).map(c => c.charCodeAt(0))))" });
  const cmd = async (n, line, re, ms = 20000) => { const from = (await screen()).length; await type(line);
    const r = await until(re, ms, Math.max(0, from - 2)); check(n, r !== null, r === null ? JSON.stringify((await screen()).slice(-200)) : ""); };
  await cmd("login-root", "root\r", /# *$/m);
  if (process.env.DIAG) { console.log("SENT " + JSON.stringify((await send("Runtime.evaluate", { expression: "JSON.stringify(window.__sent)", returnByValue: true })).result.result.value)); process.exit(2); }
  await cmd("uname", "uname -a\r", /SunOS solnix 5\.11[^\n]*riscv64\n# *$/);
  await cmd("ls-root", "ls /\r", /bin[\s\S]*etc[\s\S]*sbin[\s\S]*\n# *$/);
  await cmd("pipeline", "grep an /etc/words | sort | uniq -c | sort -rn | head -1\r", /\n\s+2 banana\n# *$/);
  await cmd("backspace", "echo abX\x7fc\r", /\nabc\n# *$/);
  const from = (await screen()).length; await type("sleep 30\r"); await sleep(2000); const t1 = Date.now(); await type("\x03");
  const r = await until(/\^C[\s\S]*# *$/, 10000, from - 2);
  check("ctrl-c-sleep30", r !== null && Date.now() - t1 < 5000, `${((Date.now() - t1) / 1000).toFixed(1)}s`);
  await cmd("after-ctrl-c", "echo X$((6*7))X\r", /\nX42X\n# *$/);
  const all = await screen();
  const bad = all.split("\n").filter((l) => /\[(fork|exec|elf|exit)\]|\[ld\.so|FAIL|WARN/.test(l));
  check("quiet-console", bad.length === 0, JSON.stringify(bad.slice(0, 3)));
  check("no-js-errors", errors.length === 0, JSON.stringify(errors.slice(0, 3)));
  console.log("TRANSCRIPT-BEGIN\n" + all.replace(/\n+$/, "") + "\nTRANSCRIPT-END");
  console.log(`SUMMARY ${res.filter(Boolean).length}/${res.length}`); process.exit(res.every(Boolean) ? 0 : 1);
};
