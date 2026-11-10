//! Join-path logic without a radio: the daemon on a private session bus (run the tests under dbus-run-session) with a
//! recorder backend. AddAndActivateConnection must write <wifi_dir>/<ssid>.psk 0600 with the passphrase and call the
//! join with that SSID and file; a caller that is neither root nor in the networkmanager group gets AccessDenied and
//! nothing is written or joined (the negative control).
use super::*;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
struct Rec { joins: StdMutex<Vec<(String, String, Option<String>, Option<String>)>>, disconnects: StdMutex<Vec<String>>,
             holds: StdMutex<Vec<(String, bool)>>, uid: StdMutex<u32>, connected: StdMutex<Option<String>> }

struct RecBe(Arc<Rec>);
impl backend::Backend for RecBe {
    fn links(&self) -> backend::Fut<'_, Vec<sys::Link>> {
        Box::pin(async { vec![sys::Link { name: "iwx0".into(), wifi: true, up: true, mac: "E0:D0:45:3D:6F:35".into() }] })
    }
    fn scan<'a>(&'a self, _l: &'a str) -> backend::Fut<'a, Option<Vec<sys::Bss>>> {
        Box::pin(async { Some(vec![
            sys::Bss { essid: "cafe".into(), bssid: "1C:6A:1B:12:16:F3".into(), sec: "wpa".into(), strength: 80, mode: "a".into(), speed_mbps: 54 },
            sys::Bss { essid: "open-net".into(), bssid: "1C:6A:1B:12:16:F4".into(), sec: "none".into(), strength: 60, mode: "g".into(), speed_mbps: 54 }]) })
    }
    fn wifi_status<'a>(&'a self, _l: &'a str) -> backend::Fut<'a, sys::WifiStatus> {
        let c = self.0.connected.lock().unwrap().clone();
        Box::pin(async move { match c { Some(e) => sys::WifiStatus { connected: true, essid: e, bssid: "1C:6A:1B:12:16:F3".into() }, None => sys::WifiStatus::default() } })
    }
    fn addr<'a>(&'a self, _l: &'a str) -> backend::Fut<'a, Option<(String, u32)>> {
        let c = self.0.connected.lock().unwrap().is_some();
        Box::pin(async move { c.then(|| ("192.0.2.10".into(), 24)) })
    }
    fn has_default_route(&self) -> backend::Fut<'_, bool> { Box::pin(async { true }) }
    fn join<'a>(&'a self, link: &'a str, ssid: &'a str, psk_file: Option<&'a str>, _s: u64) -> backend::Fut<'a, bool> {
        // record what the radio would get: the file and its content at join time
        let content = psk_file.and_then(|f| std::fs::read_to_string(f).ok());
        self.0.joins.lock().unwrap().push((link.into(), ssid.into(), psk_file.map(String::from), content.clone()));
        let ok = content.map_or(true, |c| c == "correct-horse\n");   // the AP's passphrase: any other one fails the 4-way
        if ok { *self.0.connected.lock().unwrap() = Some(ssid.to_string()); }
        Box::pin(async move { ok })
    }
    fn disconnect<'a>(&'a self, l: &'a str) -> backend::Fut<'a, bool> {
        self.0.disconnects.lock().unwrap().push(l.into()); *self.0.connected.lock().unwrap() = None; Box::pin(async { true })
    }
    fn set_hold(&self, l: &str, on: bool) { self.0.holds.lock().unwrap().push((l.into(), on)); }
    fn caller_uid<'a>(&'a self, _c: &'a Connection, _s: &'a str) -> backend::Fut<'a, fdo::Result<u32>> {
        let u = *self.0.uid.lock().unwrap(); Box::pin(async move { Ok(u) })
    }
    fn user_in_group(&self, uid: u32, _gid: u32) -> bool { uid == 4242 }   // 4242: a networkmanager member
    fn poll(&self) -> Duration { Duration::from_millis(10) }
}

async fn daemon(tag: &str) -> (Arc<Rec>, Connection, std::path::PathBuf) {
    let d = std::env::temp_dir().join(format!("solnix-nm-it-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    let rec = Arc::new(Rec::default());
    let conn = zbus::connection::Builder::session().unwrap().build().await.expect("a session bus: run under dbus-run-session");
    let name = format!("org.solnix.nmtest.t{}{}", std::process::id(), tag.replace('-', ""));
    let ctx = Arc::new(Ctx { m: Mutex::new(Model { wireless_enabled: true, ..Default::default() }),
        store: sys::Store { dir: d.join("lib"), wifi_dir: d.join("wifi") }, declared: String::new(), conn: conn.clone(),
        admin_gid: Some(57), be: Box::new(RecBe(rec.clone())), seen: Default::default() });
    serve(&ctx).await.unwrap();
    conn.request_name(name.as_str()).await.unwrap();
    let client = zbus::connection::Builder::session().unwrap().build().await.unwrap();
    std::env::set_var(format!("NMTEST_{tag}"), &name);
    (rec, client, d)
}

fn wifi_settings(ssid: &str, psk: Option<&str>) -> Settings {
    let mut s: Settings = HashMap::new();
    s.insert("connection".into(), HashMap::from([("id".into(), ov(ssid.to_string())), ("type".into(), ov("802-11-wireless")),
                                                  ("uuid".into(), ov("6b1a8e2c-0000-4000-8000-000000000001"))]));
    s.insert("802-11-wireless".into(), HashMap::from([("ssid".into(), ov(ssid.as_bytes().to_vec())), ("mode".into(), ov("infrastructure"))]));
    if let Some(p) = psk {
        s.insert("802-11-wireless-security".into(), HashMap::from([("key-mgmt".into(), ov("wpa-psk")), ("psk".into(), ov(p.to_string()))]));
    }
    s
}

async fn add_activate(client: &Connection, dest: &str, s: Settings) -> zbus::Result<(OwnedObjectPath, OwnedObjectPath)> {
    let p = zbus::Proxy::new(client, dest.to_string(), NM, "org.freedesktop.NetworkManager").await?;
    p.call("AddAndActivateConnection", &(s, op(&format!("{NM}/Devices/1")), op("/"))).await
}

async fn active_state(client: &Connection, dest: &str, path: &OwnedObjectPath) -> u32 {
    let p: zbus::Proxy = zbus::proxy::Builder::new(client).destination(dest.to_string()).unwrap().path(path.clone()).unwrap()
        .interface("org.freedesktop.NetworkManager.Connection.Active").unwrap()
        .cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap();
    p.get_property::<u32>("State").await.unwrap_or(AC_DEACTIVATED)
}

async fn wait_state(client: &Connection, dest: &str, path: &OwnedObjectPath, want: u32) -> bool {
    for _ in 0..200 { if active_state(client, dest, path).await == want { return true; } tokio::time::sleep(Duration::from_millis(25)).await; }
    false
}

#[tokio::test(flavor = "current_thread")]
async fn join_writes_psk_0600_and_joins_that_ssid() {
    let (rec, client, d) = daemon("join").await;
    let dest = std::env::var("NMTEST_join").unwrap();
    *rec.uid.lock().unwrap() = 1000 + 3242;   // 4242: a networkmanager member, not root
    let (conn_path, active) = add_activate(&client, &dest, wifi_settings("cafe", Some("correct-horse"))).await.expect("AddAndActivate");
    assert!(wait_state(&client, &dest, &active, AC_ACTIVATED).await, "never Activated");
    let j = rec.joins.lock().unwrap().clone();
    assert_eq!(j.len(), 1, "one join");
    let f = d.join("wifi").join("cafe.psk");
    assert_eq!(j[0].0, "iwx0"); assert_eq!(j[0].1, "cafe");
    assert_eq!(j[0].2.as_deref(), Some(f.to_str().unwrap()), "joined with the saved file");
    assert_eq!(j[0].3.as_deref(), Some("correct-horse\n"), "the file held the passphrase when the join ran");
    use std::os::unix::fs::PermissionsExt;
    assert_eq!(std::fs::metadata(&f).unwrap().permissions().mode() & 0o777, 0o600, "psk file mode");
    // netd held off during the join, released after
    assert_eq!(rec.holds.lock().unwrap().clone(), vec![("iwx0".to_string(), true), ("iwx0".to_string(), false)]);
    // the profile is listed, and GetSettings never returns the secret
    let c = zbus::Proxy::new(&client, dest.clone(), conn_path.clone(), "org.freedesktop.NetworkManager.Settings.Connection").await.unwrap();
    let s: Settings = c.call("GetSettings", &()).await.unwrap();
    assert!(s.get("802-11-wireless-security").is_some_and(|m| !m.contains_key("psk")), "no psk in GetSettings");
    let list = std::fs::read_to_string(d.join("lib").join("networks")).unwrap();
    assert!(list.contains(&sys::hex(b"cafe")) && !list.contains("correct-horse"), "the list file names the network, never the passphrase");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test(flavor = "current_thread")]
async fn wrong_passphrase_deactivates() {
    let (rec, client, d) = daemon("wrong").await;
    let dest = std::env::var("NMTEST_wrong").unwrap();
    *rec.uid.lock().unwrap() = 0;
    let (_c, active) = add_activate(&client, &dest, wifi_settings("cafe", Some("wrong-horse"))).await.unwrap();
    assert!(wait_state(&client, &dest, &active, AC_DEACTIVATED).await, "a failed 4-way must end Deactivated");
    assert_eq!(rec.joins.lock().unwrap().len(), 1);
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test(flavor = "current_thread")]
async fn non_admin_is_refused_and_nothing_is_written() {
    let (rec, client, d) = daemon("deny").await;
    let dest = std::env::var("NMTEST_deny").unwrap();
    *rec.uid.lock().unwrap() = 1000;   // a plain user
    let e = add_activate(&client, &dest, wifi_settings("cafe", Some("correct-horse"))).await.expect_err("must be refused");
    assert!(e.to_string().contains("AccessDenied"), "{e}");
    assert!(rec.joins.lock().unwrap().is_empty(), "no join");
    assert!(!d.join("wifi").exists() || std::fs::read_dir(d.join("wifi")).unwrap().next().is_none(), "no psk file");
    assert!(!d.join("lib").join("networks").exists(), "no list file");
    // the radio setter is guarded too
    let p = zbus::Proxy::new(&client, dest.clone(), NM, "org.freedesktop.NetworkManager").await.unwrap();
    let r = p.set_property("WirelessEnabled", false).await;
    assert!(r.is_err(), "WirelessEnabled=false from a plain user must fail");
    assert!(rec.disconnects.lock().unwrap().is_empty(), "no disconnect");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test(flavor = "current_thread")]
async fn short_passphrase_rejected_before_any_write() {
    let (rec, client, d) = daemon("short").await;
    let dest = std::env::var("NMTEST_short").unwrap();
    *rec.uid.lock().unwrap() = 0;
    let e = add_activate(&client, &dest, wifi_settings("cafe", Some("short"))).await.expect_err("7 chars");
    assert!(e.to_string().contains("InvalidArgs"), "{e}");
    assert!(rec.joins.lock().unwrap().is_empty());
    assert!(!d.join("wifi").join("cafe.psk").exists());
    let _ = std::fs::remove_dir_all(&d);
}
