//! The illumos side: parse dladm/ipadm/netstat output into plain structs, and the actions (join, disconnect,
//! saved-network files). Every external command runs with a fixed PATH and a timeout.
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::Duration;
use tokio::process::Command;

pub const PATH: &str = "/usr/lib/inet:/usr/sbin:/usr/bin:/sbin:/bin";

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Link {
    pub name: String,
    pub wifi: bool,
    pub up: bool,
    pub mac: String,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Bss {
    pub essid: String,
    pub bssid: String,
    pub sec: String,      // none | wep | wpa
    pub strength: u8,     // 0..100
    pub mode: String,     // a | b | g | n | ac
    pub speed_mbps: u32,
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct WifiStatus {
    pub connected: bool,
    pub essid: String,
    pub bssid: String,
}

/// Split one `dladm -p` line on unescaped ':' and drop the '\' escapes (dladm escapes ':' and '\' in values).
pub fn split_parsable(line: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut esc = false;
    for c in line.chars() {
        if esc { out.last_mut().unwrap().push(c); esc = false; }
        else if c == '\\' { esc = true; }
        else if c == ':' { out.push(String::new()); }
        else { out.last_mut().unwrap().push(c); }
    }
    out
}

/// dladm prints MAC octets without leading zeros (1c:6a:1b:12:d:7e); NM's HwAddress is upper-case two-digit.
pub fn norm_mac(m: &str) -> String {
    m.split(':').map(|o| format!("{:0>2}", o.to_ascii_uppercase())).collect::<Vec<_>>().join(":")
}

pub fn strength_pct(word: &str) -> u8 {
    match word { "excellent" => 100, "very good" => 80, "good" => 60, "weak" => 35, "very weak" => 15, _ => 0 }
}

pub fn parse_scan(text: &str) -> Vec<Bss> {
    text.lines().filter_map(|l| {
        let f = split_parsable(l);
        if f.len() < 6 { return None; }
        Some(Bss { essid: f[0].clone(), bssid: norm_mac(&f[1]), sec: f[2].clone(), strength: strength_pct(&f[3]),
                   mode: f[4].clone(), speed_mbps: f[5].trim_end_matches("Mb").parse().unwrap_or(0) })
    }).collect()
}

pub fn parse_phys(text: &str) -> Vec<(String, String, String)> {
    text.lines().filter_map(|l| { let f = split_parsable(l); (f.len() >= 3).then(|| (f[0].clone(), f[1].clone(), f[2].clone())) }).collect()
}

pub fn parse_wifi_status(text: &str) -> WifiStatus {
    let f = split_parsable(text.lines().next().unwrap_or(""));
    if f.len() < 3 { return WifiStatus::default(); }
    WifiStatus { connected: f[0] == "connected", essid: f[1].clone(), bssid: if f[2].is_empty() { String::new() } else { norm_mac(&f[2]) } }
}

/// `ipadm show-addr -p -o addrobj,state,addr <link>/`: the first ok IPv4 (address, prefix).
pub fn parse_addr(text: &str) -> Option<(String, u32)> {
    text.lines().find_map(|l| {
        let f = split_parsable(l);
        if f.len() < 3 || f[1] != "ok" || f[2].contains(':') && !f[2].contains('.') { return None; }
        let (a, p) = f[2].split_once('/')?;
        a.contains('.').then(|| (a.to_string(), p.parse().unwrap_or(0)))
    })
}

pub async fn run(args: &[&str], secs: u64) -> Option<String> {
    let mut c = Command::new(args[0]);
    c.args(&args[1..]).env_clear().env("PATH", PATH).env("LC_ALL", "C").kill_on_drop(true);
    let o = tokio::time::timeout(Duration::from_secs(secs), c.output()).await.ok()?.ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).into_owned())
}

pub async fn links() -> Vec<Link> {
    let phys = parse_phys(&run(&["dladm", "show-phys", "-p", "-o", "link,media,state"], 10).await.unwrap_or_default());
    let macs: BTreeMap<String, String> = run(&["dladm", "show-phys", "-m", "-p", "-o", "link,address"], 10).await.unwrap_or_default()
        .lines().filter_map(|l| { let f = split_parsable(l); (f.len() >= 2).then(|| (f[0].clone(), norm_mac(&f[1]))) }).collect();
    phys.into_iter().filter(|(_, m, _)| m == "WiFi" || m == "Ethernet")
        .map(|(n, m, s)| Link { mac: macs.get(&n).cloned().unwrap_or_default(), wifi: m == "WiFi", up: s == "up", name: n }).collect()
}

pub async fn scan(link: &str) -> Option<Vec<Bss>> {
    run(&["dladm", "scan-wifi", "-p", "-o", "essid,bssid,sec,strength,mode,speed", link], 30).await.map(|t| parse_scan(&t))
}

pub async fn wifi_status(link: &str) -> WifiStatus {
    parse_wifi_status(&run(&["dladm", "show-wifi", "-p", "-o", "status,essid,bssid", link], 10).await.unwrap_or_default())
}

pub async fn addr(link: &str) -> Option<(String, u32)> {
    parse_addr(&run(&["ipadm", "show-addr", "-p", "-o", "addrobj,state,addr", &format!("{link}/")], 10).await?)
}

pub async fn has_default_route() -> bool {
    run(&["netstat", "-rn", "-f", "inet"], 10).await.is_some_and(|t| t.lines().any(|l| l.starts_with("default")))
}

// ---- saved networks -------------------------------------------------------------------------------------------
// Runtime networks: /etc/wifi/<ssid>.psk (root 0600, first line the passphrase: the file shape
// hardware.wirelessIwx.networks.<ssid>.pskFile uses) plus /var/lib/solnix-nm/networks, one line per network:
// uuid<TAB>ssid-hex<TAB>pskfile ("" for an open network). Declared networks come from SOLNIX_NM_DECLARED
// ("ssid-hex=pskfile ...", set by the module) and are read-only.
pub struct Store { pub dir: PathBuf, pub wifi_dir: PathBuf }

#[derive(Clone, Debug, PartialEq)]
pub struct Saved { pub uuid: String, pub ssid: Vec<u8>, pub psk_file: String, pub declared: bool }

pub fn hex(b: &[u8]) -> String { b.iter().map(|x| format!("{x:02x}")).collect() }
pub fn unhex(s: &str) -> Option<Vec<u8>> {
    (s.len() % 2 == 0).then_some(())?;
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).ok()).collect()
}

/// A stable uuid-shaped id from a seed (declared networks need one that survives restarts).
pub fn uuid_from(seed: &[u8]) -> String {
    let mut h: u128 = 0x6c62272e07bb014262b821756295c58d;
    for &b in seed { h ^= b as u128; h = h.wrapping_mul(0x0000000001000000000000000000013B); }
    let s = format!("{h:032x}");
    format!("{}-{}-4{}-8{}-{}", &s[0..8], &s[8..12], &s[13..16], &s[17..20], &s[20..32])
}

/// A file name for an SSID: printable ASCII kept, anything else hex, so no SSID can name a path outside the dir.
pub fn psk_name(ssid: &[u8]) -> String {
    let ok = !ssid.is_empty() && ssid.iter().all(|c| c.is_ascii_alphanumeric() || b"-_.".contains(c)) && ssid[0] != b'.';
    if ok { format!("{}.psk", String::from_utf8_lossy(ssid)) } else { format!("x{}.psk", hex(ssid)) }
}

impl Store {
    pub fn list_file(&self) -> PathBuf { self.dir.join("networks") }

    pub fn load(&self, declared: &str) -> Vec<Saved> {
        let mut v: Vec<Saved> = declared.split_whitespace().filter_map(|e| {
            let (h, f) = e.split_once('=')?; let ssid = unhex(h)?;
            Some(Saved { uuid: uuid_from(&ssid), ssid, psk_file: f.to_string(), declared: true })
        }).collect();
        for l in std::fs::read_to_string(self.list_file()).unwrap_or_default().lines() {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() != 3 { continue; }
            let Some(ssid) = unhex(f[1]) else { continue };
            if v.iter().any(|s| s.ssid == ssid) { continue; }   // a declared network wins
            v.push(Saved { uuid: f[0].to_string(), ssid, psk_file: f[2].to_string(), declared: false });
        }
        v
    }

    fn write_list(&self, all: &[Saved]) -> std::io::Result<()> {
        std::fs::create_dir_all(&self.dir)?;
        let body: String = all.iter().filter(|s| !s.declared).map(|s| format!("{}\t{}\t{}\n", s.uuid, hex(&s.ssid), s.psk_file)).collect();
        write_private(&self.list_file(), body.as_bytes())
    }

    /// Save (or replace) a runtime network. psk None: open network.
    pub fn save(&self, all: &mut Vec<Saved>, ssid: &[u8], psk: Option<&str>, uuid: &str) -> std::io::Result<Saved> {
        let psk_file = match psk {
            Some(p) => { let f = self.wifi_dir.join(psk_name(ssid)); write_private(&f, format!("{p}\n").as_bytes())?; f.to_string_lossy().into_owned() }
            None => String::new(),
        };
        all.retain(|s| s.declared || s.ssid != ssid);
        let s = Saved { uuid: uuid.to_string(), ssid: ssid.to_vec(), psk_file, declared: false };
        all.push(s.clone());
        self.write_list(all)?;
        Ok(s)
    }

    pub fn delete(&self, all: &mut Vec<Saved>, uuid: &str) -> std::io::Result<bool> {
        let Some(i) = all.iter().position(|s| s.uuid == uuid && !s.declared) else { return Ok(false) };
        let s = all.remove(i);
        if !s.psk_file.is_empty() && Path::new(&s.psk_file).starts_with(&self.wifi_dir) { let _ = std::fs::remove_file(&s.psk_file); }
        self.write_list(all)?;
        Ok(true)
    }
}

/// Write root 0600 through a temp file and rename (a passphrase file is never readable by others, even briefly).
pub fn write_private(p: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::OpenOptionsExt;
    let dir = p.parent().unwrap_or(Path::new("/"));
    std::fs::create_dir_all(dir)?;
    let tmp = dir.join(format!(".{}.tmp", p.file_name().unwrap().to_string_lossy()));
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
    f.write_all(data)?; f.sync_all()?;
    std::fs::rename(&tmp, p)
}

// ---- actions ----------------------------------------------------------------------------------------------------
/// Join: wpa-pmk (in-kernel WPA2 4-way, ESSID-only, the solnix-wifi-join mechanism) or an open connect-wifi, then wait
/// up to `secs` for `connected` on that ESSID. solnix-netd's DHCP picks the link up from there.
pub async fn join(link: &str, ssid: &str, psk_file: Option<&str>, secs: u64) -> bool {
    let _ = run(&["dladm", "disconnect-wifi", link], 10).await;
    let ok = match psk_file {
        Some(f) => run(&["wpa-pmk", "-f", f, ssid, link], 30).await.is_some(),
        None => run(&["dladm", "connect-wifi", "-e", ssid, link], 30).await.is_some(),
    };
    if !ok { return false; }
    for _ in 0..secs / 2 {
        let w = wifi_status(link).await;
        if w.connected && w.essid == ssid { return true; }
        tokio::time::sleep(Duration::from_secs(2)).await;
    }
    false
}

pub async fn disconnect(link: &str) -> bool { run(&["dladm", "disconnect-wifi", link], 10).await.is_some() }

/// solnix-netd rejoins a disconnected wifi link within seconds; a hold file tells it not to (wifi_keep honours it).
pub fn hold_path(link: &str) -> PathBuf { PathBuf::from(format!("/var/run/solnix-nm/{link}.down")) }
pub fn set_hold(link: &str, on: bool) {
    let p = hold_path(link);
    if on { let _ = std::fs::create_dir_all(p.parent().unwrap()); let _ = std::fs::write(&p, b""); } else { let _ = std::fs::remove_file(&p); }
}

#[cfg(test)]
mod tests {
    use super::*;
    // real lines from a solnix laptop (2026-11-10, dladm scan-wifi -p as root)
    #[test]
    fn scan_lines() {
        let t = "sedgwick:c\\:ea\\:14\\:36\\:14\\:22:wpa:good:g:54Mb\n:12\\:ea\\:14\\:36\\:14\\:22:wpa:good:g:54Mb\nsedgwick:1c\\:6a\\:1b\\:12\\:16\\:f3:wpa:very good:a:54Mb\n";
        let b = parse_scan(t);
        assert_eq!(b.len(), 3);
        assert_eq!(b[0].essid, "sedgwick"); assert_eq!(b[0].bssid, "0C:EA:14:36:14:22"); assert_eq!(b[0].strength, 60);
        assert_eq!(b[1].essid, ""); assert_eq!(b[2].strength, 80); assert_eq!(b[2].speed_mbps, 54);
    }
    #[test]
    fn status_and_addr() {
        let w = parse_wifi_status("connected:sedgwick:1c\\:6a\\:1b\\:12\\:16\\:f3\n");
        assert!(w.connected); assert_eq!(w.essid, "sedgwick"); assert_eq!(w.bssid, "1C:6A:1B:12:16:F3");
        assert!(!parse_wifi_status("disconnected::\n").connected);
        assert_eq!(parse_addr("iwx0/dhcp:ok:192.168.1.192/24\n"), Some(("192.168.1.192".into(), 24)));
        assert_eq!(parse_addr("usbecm1/dhcp:disabled:?\n"), None);
    }
    #[test]
    fn names_and_store() {
        assert_eq!(psk_name(b"sedgwick"), "sedgwick.psk");
        assert_eq!(psk_name(b"../etc/x"), "x2e2e2f6574632f78.psk");   // never a path
        assert_eq!(psk_name(b".hidden"), "x2e68696464656e.psk");
        assert_eq!(unhex(&hex(b"caf\xc3\xa9")), Some(b"caf\xc3\xa9".to_vec()));
        assert_eq!(uuid_from(b"sedgwick"), uuid_from(b"sedgwick")); assert_ne!(uuid_from(b"a"), uuid_from(b"b"));
        let d = std::env::temp_dir().join(format!("solnix-nm-test-{}", std::process::id()));
        let st = Store { dir: d.join("lib"), wifi_dir: d.join("wifi") };
        let mut all = st.load(&format!("{}=/etc/wifi/sedgwick.psk", hex(b"sedgwick")));
        assert_eq!(all.len(), 1); assert!(all[0].declared);
        let s = st.save(&mut all, b"cafe", Some("hunter22"), "u-1").unwrap();
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&s.psk_file).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::read_to_string(&s.psk_file).unwrap(), "hunter22\n");
        assert_eq!(st.load(&format!("{}=/etc/wifi/sedgwick.psk", hex(b"sedgwick"))).len(), 2);
        assert!(!st.delete(&mut all, &uuid_from(b"sedgwick")).unwrap());   // declared: refused
        assert!(st.delete(&mut all, "u-1").unwrap());
        assert!(!Path::new(&s.psk_file).exists());
        let _ = std::fs::remove_dir_all(&d);
    }
}
