//! Join-path logic without a radio: the daemon on a private session bus (run the tests under dbus-run-session) with a
//! recorder backend. AddAndActivateConnection must write <wifi_dir>/<ssid>.psk 0600 with the passphrase and call the
//! join with that SSID and file; a caller that is neither root nor in the networkmanager group gets AccessDenied and
//! nothing is written or joined (the negative control).
use super::*;
use std::sync::Mutex as StdMutex;

#[derive(Default)]
struct Rec { joins: StdMutex<Vec<(String, String, Option<String>, Option<String>)>>, disconnects: StdMutex<Vec<String>>,
             holds: StdMutex<Vec<(String, bool)>>, uid: StdMutex<u32>, connected: StdMutex<Option<String>>, strength: StdMutex<u8>,
             hidden: StdMutex<Vec<String>>,   // BSSIDs the scan also returns with an empty ESSID
             wired: bool, wired_on: StdMutex<bool>, wired_calls: StdMutex<Vec<(String, bool)>> }   // a USB NIC usbecm2, its address on

struct RecBe(Arc<Rec>);
impl backend::Backend for RecBe {
    fn links(&self) -> backend::Fut<'_, Vec<sys::Link>> {
        let mut v = vec![sys::Link { name: "iwx0".into(), wifi: true, up: true, mac: "00:00:5E:00:53:10".into(), speed_mbps: 0 }];
        if self.0.wired { v.push(sys::Link { name: "usbecm2".into(), wifi: false, up: true, mac: "00:00:5E:00:53:20".into(), speed_mbps: 100 }); }
        Box::pin(async move { v })
    }
    fn scan<'a>(&'a self, _l: &'a str) -> backend::Fut<'a, Option<Vec<sys::Bss>>> {
        let st = match *self.0.strength.lock().unwrap() { 0 => 80, v => v };
        let hidden = self.0.hidden.lock().unwrap().clone();
        Box::pin(async move { let mut v = vec![
            sys::Bss { essid: "cafe".into(), bssid: "00:00:5E:00:53:F3".into(), sec: "wpa".into(), strength: st, mode: "a".into(), speed_mbps: 54 },
            sys::Bss { essid: "open-net".into(), bssid: "00:00:5E:00:53:F4".into(), sec: "none".into(), strength: 60, mode: "g".into(), speed_mbps: 54 }];
            for b in hidden {   // a hidden BSS: dladm prints an empty ESSID (and the connected one's ESSID too when it hides it)
                v.retain(|x| x.bssid != b);
                v.push(sys::Bss { essid: String::new(), bssid: b, sec: "wpa".into(), strength: 50, mode: "n".into(), speed_mbps: 54 });
            }
            Some(v) })
    }
    fn wifi_status<'a>(&'a self, _l: &'a str) -> backend::Fut<'a, sys::WifiStatus> {
        let c = self.0.connected.lock().unwrap().clone();
        Box::pin(async move { match c { Some(e) => sys::WifiStatus { connected: true, essid: e, bssid: "00:00:5E:00:53:F3".into() }, None => sys::WifiStatus::default() } })
    }
    fn addr<'a>(&'a self, l: &'a str) -> backend::Fut<'a, Option<(String, u32)>> {
        if l == "usbecm2" { let on = *self.0.wired_on.lock().unwrap(); return Box::pin(async move { on.then(|| ("192.0.2.20".into(), 24)) }); }
        let c = self.0.connected.lock().unwrap().is_some();
        Box::pin(async move { c.then(|| ("192.0.2.10".into(), 24)) })
    }
    fn default_routes(&self) -> backend::Fut<'_, Vec<(String, String)>> {
        let w = *self.0.wired_on.lock().unwrap();
        Box::pin(async move { if w { vec![("usbecm2".into(), "192.0.2.1".into())] } else { vec![("iwx0".into(), "192.0.2.254".into())] } })
    }
    fn wired_addrs<'a>(&'a self, l: &'a str, on: bool) -> backend::Fut<'a, bool> {
        self.0.wired_calls.lock().unwrap().push((l.into(), on)); *self.0.wired_on.lock().unwrap() = on; Box::pin(async { true })
    }
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

async fn daemon(tag: &str) -> (Arc<Rec>, Connection, std::path::PathBuf) { let (r, c, d, _) = daemon_ctx(tag).await; (r, c, d) }

async fn daemon_ctx(tag: &str) -> (Arc<Rec>, Connection, std::path::PathBuf, Arc<Ctx>) { daemon_with(tag, Rec::default()).await }

/// daemon_ctx with the radio's state set before the daemon's first scan (serve runs one)
async fn daemon_with(tag: &str, rec: Rec) -> (Arc<Rec>, Connection, std::path::PathBuf, Arc<Ctx>) {
    let d = std::env::temp_dir().join(format!("solnix-nm-it-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    let rec = Arc::new(rec);
    let conn = zbus::connection::Builder::session().unwrap().build().await.expect("a session bus: run under dbus-run-session");
    let name = format!("org.solnix.nmtest.t{}{}", std::process::id(), tag.replace('-', ""));
    let ctx = Arc::new(Ctx { m: Mutex::new(Model { wireless_enabled: true, ..Default::default() }),
        store: sys::Store { dir: d.join("lib"), wifi_dir: d.join("wifi") }, declared: String::new(), conn: conn.clone(),
        admin_gid: Some(57), be: Box::new(RecBe(rec.clone())), seen: Default::default() });
    serve(&ctx).await.unwrap();
    conn.request_name(name.as_str()).await.unwrap();
    let client = zbus::connection::Builder::session().unwrap().build().await.unwrap();
    std::env::set_var(format!("NMTEST_{tag}"), &name);
    (rec, client, d, ctx)
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

// ---- signal volume: NetworkManager emits PropertiesChanged only for values that changed. nmrs (COSMIC's client) turns
// every AccessPoint Strength change into a NetworkEvent, and the network applet and Settings answer EACH event with a
// full snapshot of calls (lixi BE solnix-51: ~3500 "maximum number of pending replies (128)" dbus refusals for one user
// process during a Wi-Fi reconnect). A refresh that changes nothing must announce nothing.
fn dest_of(tag: &str) -> String { std::env::var(format!("NMTEST_{tag}")).unwrap() }

async fn next_msg(s: &mut zbus::MessageStream) -> Option<zbus::Result<zbus::Message>> {
    std::future::poll_fn(|cx| zbus::export::futures_core::Stream::poll_next(std::pin::Pin::new(&mut *s), cx)).await
}

async fn count_props_changed(client: &Connection, dest: &str, ms: u64) -> Vec<(String, String)> {
    let rule = zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).interface("org.freedesktop.DBus.Properties").unwrap()
        .member("PropertiesChanged").unwrap().build();
    let mut s = zbus::MessageStream::for_match_rule(rule, client, None).await.unwrap();
    let owner = zbus::fdo::DBusProxy::new(client).await.unwrap().get_name_owner(zbus::names::BusName::try_from(dest).unwrap()).await.unwrap();
    let mut got = Vec::new();
    let end = tokio::time::Instant::now() + Duration::from_millis(ms);
    while let Ok(Some(Ok(m))) = tokio::time::timeout_at(end, next_msg(&mut s)).await {
        let h = m.header();
        if h.sender().map(|x| x.as_str()) != Some(owner.as_str()) { continue; }
        let (iface, changed, inval): (String, HashMap<String, OwnedValue>, Vec<String>) = m.body().deserialize().unwrap();
        let path = h.path().map(|p| p.to_string()).unwrap_or_default();
        for k in changed.keys().chain(inval.iter()) { got.push((path.clone(), format!("{iface}.{k}"))); }
    }
    got
}

#[tokio::test(flavor = "current_thread")]
async fn a_refresh_that_changes_nothing_announces_nothing() {
    let (rec, client, d, ctx) = daemon_ctx("quiet").await;
    *rec.connected.lock().unwrap() = Some("cafe".into());
    refresh(&ctx, true).await; publish(&ctx).await;   // settle: connected, APs listed
    let dest2 = dest_of("quiet");
    // three light ticks (the daemon's 5 s refresh, no scan) with nothing changed: no announcement at all
    let c = client.clone(); let t = tokio::spawn(async move { count_props_changed(&c, &dest2, 600).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    for _ in 0..3 { refresh(&ctx, false).await; publish(&ctx).await; }
    let q = t.await.unwrap();
    assert!(q.is_empty(), "{} PropertiesChanged on unchanged ticks: {:?}", q.len(), &q[..q.len().min(8)]);
    // a scan tick that finds the same APs at the same strengths: only the device's LastScan, once
    let (c, dd) = (client.clone(), dest_of("quiet")); let t = tokio::spawn(async move { count_props_changed(&c, &dd, 600).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    refresh(&ctx, true).await; publish(&ctx).await;
    let o = t.await.unwrap();
    assert_eq!(o, vec![("/org/freedesktop/NetworkManager/Devices/1".to_string(), "org.freedesktop.NetworkManager.Device.Wireless.LastScan".to_string())],
               "an unchanged scan announces LastScan alone");
    // one AP's strength changes: that property is announced once, beside the scan's LastScan; then quiet again
    *rec.strength.lock().unwrap() = 40;
    let (c, dd) = (client.clone(), dest_of("quiet")); let t = tokio::spawn(async move { count_props_changed(&c, &dd, 600).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    refresh(&ctx, true).await; publish(&ctx).await;
    refresh(&ctx, false).await; publish(&ctx).await;
    let o = t.await.unwrap();
    let strength: Vec<_> = o.iter().filter(|(_, p)| p.ends_with("AccessPoint.Strength")).collect();
    assert_eq!(strength.len(), 1, "one Strength change -> one announcement: {o:?}");
    assert_eq!(strength[0].0, "/org/freedesktop/NetworkManager/AccessPoint/1", "{o:?}");
    assert!(o.iter().all(|(_, p)| p.ends_with("AccessPoint.Strength") || p.ends_with("Wireless.LastScan")), "and nothing else: {o:?}");
    // a disconnect still announces what changed (the negative control for over-suppression)
    *rec.connected.lock().unwrap() = None;
    let (c, dd) = (client.clone(), dest_of("quiet")); let t = tokio::spawn(async move { count_props_changed(&c, &dd, 600).await });
    tokio::time::sleep(Duration::from_millis(100)).await;
    refresh(&ctx, false).await; publish(&ctx).await;
    let o: Vec<String> = t.await.unwrap().into_iter().map(|(_, p)| p).collect();
    for want in ["org.freedesktop.NetworkManager.ActiveConnections", "org.freedesktop.NetworkManager.PrimaryConnection",
                 "org.freedesktop.NetworkManager.State", "org.freedesktop.NetworkManager.Device.State",
                 "org.freedesktop.NetworkManager.Device.ActiveConnection", "org.freedesktop.NetworkManager.Device.Ip4Config",
                 "org.freedesktop.NetworkManager.Device.Wireless.ActiveAccessPoint"] {
        assert!(o.iter().any(|p| p == want), "a disconnect must announce {want}: {o:?}");
    }
    let _ = std::fs::remove_dir_all(&d);
}

// A BSS with an empty ESSID (a hidden network: 7 of 16 in one scan on a laptop) is not listed: NetworkManager lists only
// the networks it can name, and COSMIC drew each as "<Hidden Network>". The AP we are connected to stays listed, hidden
// or not, so ActiveAccessPoint always names a listed object. NEG: drop the filter in refresh() and the first assert fails.
#[tokio::test(flavor = "current_thread")]
async fn hidden_bsses_are_not_listed_unless_connected() {
    let (rec, client, d, ctx) = daemon_ctx("hidden").await;
    *rec.hidden.lock().unwrap() = vec!["00:00:5E:00:53:A1".into(), "00:00:5E:00:53:A2".into()];
    refresh(&ctx, true).await; publish(&ctx).await;
    let dest = dest_of("hidden");
    let dev: zbus::Proxy = zbus::proxy::Builder::new(&client).destination(dest.clone()).unwrap().path(format!("{NM}/Devices/1")).unwrap()
        .interface("org.freedesktop.NetworkManager.Device.Wireless").unwrap()
        .cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap();
    let ssids = |paths: Vec<OwnedObjectPath>| { let (c, d) = (client.clone(), dest.clone()); async move {
        let mut v = Vec::new();
        for p in paths {
            let ap: zbus::Proxy = zbus::proxy::Builder::new(&c).destination(d.clone()).unwrap().path(p).unwrap()
                .interface("org.freedesktop.NetworkManager.AccessPoint").unwrap()
                .cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap();
            v.push(String::from_utf8(ap.get_property::<Vec<u8>>("Ssid").await.unwrap()).unwrap());
        }
        v.sort(); v } };
    let prop: Vec<OwnedObjectPath> = dev.get_property("AccessPoints").await.unwrap();
    assert_eq!(ssids(prop).await, vec!["cafe", "open-net"], "the AccessPoints property lists no hidden BSS");
    let all: Vec<OwnedObjectPath> = dev.call("GetAllAccessPoints", &()).await.unwrap();
    assert_eq!(ssids(all).await, vec!["cafe", "open-net"], "neither does GetAllAccessPoints");
    let _ = std::fs::remove_dir_all(&d);
    // a daemon that starts connected to "cafe", whose BSS ...F3 hides its ESSID in every scan: listed, named "cafe", active
    let rec = Rec { connected: StdMutex::new(Some("cafe".into())),
                    hidden: StdMutex::new(vec!["00:00:5E:00:53:F3".into(), "00:00:5E:00:53:A1".into()]), ..Default::default() };
    let (_rec, client, d, ctx) = daemon_with("hidden2", rec).await;
    refresh(&ctx, true).await; publish(&ctx).await;
    let dest = dest_of("hidden2");
    let dev: zbus::Proxy = zbus::proxy::Builder::new(&client).destination(dest.clone()).unwrap().path(format!("{NM}/Devices/1")).unwrap()
        .interface("org.freedesktop.NetworkManager.Device.Wireless").unwrap()
        .cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap();
    let prop: Vec<OwnedObjectPath> = dev.get_property("AccessPoints").await.unwrap();
    let active: OwnedObjectPath = dev.get_property("ActiveAccessPoint").await.unwrap();
    assert!(prop.contains(&active), "the active AP {active:?} is listed: {prop:?}");
    assert_eq!(prop.len(), 2, "the connected hidden BSS and open-net, not the other hidden one: {prop:?}");
    let ap: zbus::Proxy = zbus::proxy::Builder::new(&client).destination(dest.clone()).unwrap().path(active.clone()).unwrap()
        .interface("org.freedesktop.NetworkManager.AccessPoint").unwrap()
        .cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap();
    assert_eq!(ap.get_property::<Vec<u8>>("Ssid").await.unwrap(), b"cafe".to_vec(), "the connected hidden AP is named by its association");
    let _ = std::fs::remove_dir_all(&d);
}

async fn px(c: &Connection, dest: &str, path: &str, iface: &str) -> zbus::Proxy<'static> {
    zbus::proxy::Builder::new(c).destination(dest.to_string()).unwrap().path(path.to_string()).unwrap()
        .interface(iface.to_string()).unwrap().cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap()
}

/// COSMIC Settings' Wired page lists a device's saved 802-3-ethernet profiles (nmrs list_saved_connections, matched by
/// type and interface-name) and shows nothing without one; its Disconnect and Connect go through DeactivateConnection
/// and ActivateConnection. solnix-nm had no wired profile, and refused to disconnect a wired link.
#[tokio::test(flavor = "current_thread")]
async fn a_wired_link_has_a_profile_details_and_disconnects() {
    let rec = Rec { wired: true, wired_on: StdMutex::new(true), ..Default::default() };
    let (rec, client, d, ctx) = daemon_with("wired", rec).await;
    refresh(&ctx, false).await; publish(&ctx).await;
    let dest = dest_of("wired");
    let set = px(&client, &dest, &format!("{NM}/Settings"), "org.freedesktop.NetworkManager.Settings").await;
    let list: Vec<OwnedObjectPath> = set.call("ListConnections", &()).await.unwrap();
    let mut prof = None;
    for p in &list {
        let c = px(&client, &dest, p.as_str(), "org.freedesktop.NetworkManager.Settings.Connection").await;
        let s: Settings = c.call("GetSettings", &()).await.unwrap();
        if settings_str(&s, "connection", "type").as_deref() == Some("802-3-ethernet") {
            assert_eq!(settings_str(&s, "connection", "interface-name").as_deref(), Some("usbecm2"));
            assert_eq!(settings_str(&s, "connection", "id").as_deref(), Some("Wired (usbecm2)"));
            assert!(settings_str(&s, "connection", "uuid").is_some_and(|u| !u.is_empty()));
            prof = Some(p.clone());
        }
    }
    let prof = prof.expect("ListConnections has an 802-3-ethernet profile for usbecm2");
    let dev = px(&client, &dest, &format!("{NM}/Devices/2"), "org.freedesktop.NetworkManager.Device").await;
    assert_eq!(dev.get_property::<Vec<OwnedObjectPath>>("AvailableConnections").await.unwrap(), vec![prof.clone()], "the device offers its profile");
    let ac: OwnedObjectPath = dev.get_property("ActiveConnection").await.unwrap();
    assert_ne!(ac.as_str(), "/", "the leased link is active");
    let a = px(&client, &dest, ac.as_str(), "org.freedesktop.NetworkManager.Connection.Active").await;
    assert_eq!(a.get_property::<OwnedObjectPath>("Connection").await.unwrap(), prof, "the active connection names its profile");
    assert_eq!(a.get_property::<String>("Type").await.unwrap(), "802-3-ethernet");
    let w = px(&client, &dest, &format!("{NM}/Devices/2"), "org.freedesktop.NetworkManager.Device.Wired").await;
    assert_eq!(w.get_property::<u32>("Speed").await.unwrap(), 100, "the link's measured speed, not a constant");
    assert_eq!(w.get_property::<String>("HwAddress").await.unwrap(), "00:00:5E:00:53:20");
    let ip4: OwnedObjectPath = dev.get_property("Ip4Config").await.unwrap();
    let ip = px(&client, &dest, ip4.as_str(), "org.freedesktop.NetworkManager.IP4Config").await;
    let ad: Vec<HashMap<String, OwnedValue>> = ip.get_property("AddressData").await.unwrap();
    assert_eq!(String::try_from(ad[0]["address"].try_clone().unwrap()).unwrap(), "192.0.2.20");
    assert_eq!(u32::try_from(ad[0]["prefix"].try_clone().unwrap()).unwrap(), 24);
    assert_eq!(ip.get_property::<String>("Gateway").await.unwrap(), "192.0.2.1", "the link's default route");
    let _: Vec<HashMap<String, OwnedValue>> = ip.get_property("NameserverData").await.unwrap();
    // its settings are the system's: neither deleted nor rewritten over D-Bus
    *rec.uid.lock().unwrap() = 0;
    let c = px(&client, &dest, prof.as_str(), "org.freedesktop.NetworkManager.Settings.Connection").await;
    let r: zbus::Result<()> = c.call("Delete", &()).await; assert!(r.is_err(), "a wired profile is not deletable");
    // a non-member may not disconnect it
    *rec.uid.lock().unwrap() = 1000;
    let r: zbus::Result<()> = dev.call("Disconnect", &()).await; assert!(r.is_err(), "non-admin refused");
    assert!(rec.wired_calls.lock().unwrap().is_empty(), "nothing done for a refused caller");
    // Disconnect (Settings' "Disconnect": DeactivateConnection on its active connection) as a networkmanager member
    *rec.uid.lock().unwrap() = 4242;
    let root = px(&client, &dest, NM, "org.freedesktop.NetworkManager").await;
    let r: zbus::Result<()> = root.call("DeactivateConnection", &(ac.clone(),)).await; r.expect("a wired link disconnects");
    assert_eq!(rec.wired_calls.lock().unwrap().clone(), vec![("usbecm2".to_string(), false)], "its addresses went down");
    assert!(rec.holds.lock().unwrap().contains(&("usbecm2".to_string(), true)), "solnix-netd holds it (no DHCP, no default)");
    assert_eq!(dev.get_property::<OwnedObjectPath>("ActiveConnection").await.unwrap().as_str(), "/", "no longer active");
    assert_eq!(dev.get_property::<Vec<OwnedObjectPath>>("AvailableConnections").await.unwrap(), vec![prof.clone()], "still offered, to connect again");
    // Connect (ActivateConnection of the profile on the device)
    let _: OwnedObjectPath = root.call("ActivateConnection", &(prof.clone(), op(&format!("{NM}/Devices/2")), op("/"))).await.expect("connects");
    assert_eq!(rec.wired_calls.lock().unwrap().last().cloned(), Some(("usbecm2".to_string(), true)));
    assert_eq!(rec.holds.lock().unwrap().last().cloned(), Some(("usbecm2".to_string(), false)), "hold released: netd may DHCP it");
    assert_ne!(dev.get_property::<OwnedObjectPath>("ActiveConnection").await.unwrap().as_str(), "/", "active again");
    let _ = std::fs::remove_dir_all(&d);
}
