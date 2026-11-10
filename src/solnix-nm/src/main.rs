//! solnix-nm: the org.freedesktop.NetworkManager D-Bus subset COSMIC 1.11 calls (through nmrs 3.5), over illumos
//! dladm/ipadm and solnix-netd. What it implements and why: docs/solnix-nm.md. Every object answers Properties.GetAll
//! with every property its interface has, because zbus proxies fetch them all on the first read and one error blanks
//! the applet.
//! MIT. Runs as root under SMF (services.solnix-nm).
mod backend;
mod sys;
#[cfg(test)]
mod tests;

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::sync::Mutex;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zbus::{fdo, interface, message::Header, Connection};

const NM: &str = "/org/freedesktop/NetworkManager";
// NM enums (libnm nm-dbus-interface.h)
const DEV_ETHERNET: u32 = 1;
const DEV_WIFI: u32 = 2;
const DS_UNAVAILABLE: u32 = 20;
const DS_DISCONNECTED: u32 = 30;
const DS_CONFIG: u32 = 50;
const DS_ACTIVATED: u32 = 100;
const DS_FAILED: u32 = 120;
const AC_ACTIVATING: u32 = 1;
const AC_ACTIVATED: u32 = 2;
const AC_DEACTIVATED: u32 = 4;
const NM_STATE_DISCONNECTED: u32 = 20;
const NM_STATE_CONNECTED_GLOBAL: u32 = 70;
const CONN_NONE: u32 = 1;
const CONN_FULL: u32 = 4;
const AP_PRIVACY: u32 = 0x1;
const SEC_PSK_CCMP: u32 = 0x100 | 0x8 | 0x80;   // KEY_MGMT_PSK | PAIR_CCMP | GROUP_CCMP
const REASON_NO_SECRETS: u32 = 7;               // NM_ACTIVE_CONNECTION_STATE_REASON_NO_SECRETS
const REASON_USER: u32 = 2;

type Settings = HashMap<String, HashMap<String, OwnedValue>>;

fn op(s: &str) -> OwnedObjectPath { OwnedObjectPath::try_from(s.to_string()).unwrap() }
fn root() -> OwnedObjectPath { op("/") }
fn ov<'a, T: Into<Value<'a>>>(v: T) -> OwnedValue { OwnedValue::try_from(v.into()).unwrap() }
fn err(m: &str) -> fdo::Error { fdo::Error::Failed(m.into()) }

// ---- the model: what the objects show, rebuilt from the system every refresh -------------------------------------
#[derive(Clone, Default)]
struct Dev { idx: u32, link: sys::Link, state: u32, aps: Vec<u32>, active_ap: u32, addr: Option<(String, u32)>, active: u32 }

#[derive(Clone)]
struct Ap { bss: sys::Bss, last_seen: i32 }

#[derive(Clone)]
struct Active { idx: u32, dev: u32, conn: u32, ap: u32, uuid: String, id: String, state: u32 }

#[derive(Default)]
struct Model {
    devs: Vec<Dev>,
    aps: BTreeMap<u32, Ap>,          // by object index
    ap_key: HashMap<(String, String), u32>, // (link, bssid) -> index, so a BSS keeps its path across scans
    next_ap: u32,
    saved: Vec<sys::Saved>,
    conn_idx: HashMap<String, u32>,  // saved uuid -> Settings/<n>
    next_conn: u32,
    active: Vec<Active>,
    pending: Vec<Active>,            // activations in flight (or just failed): a refresh must not drop them
    next_active: u32,
    wireless_enabled: bool,
    connectivity: u32,
    last_scan: HashMap<String, Instant>,
    boot: Option<Instant>,
}

struct Ctx { m: Mutex<Model>, store: sys::Store, declared: String, conn: Connection, admin_gid: Option<u32>, be: Box<dyn backend::Backend>,
             seen: std::sync::Mutex<Seen> }

impl Model {
    fn conn_path(&mut self, uuid: &str) -> u32 {
        if let Some(&i) = self.conn_idx.get(uuid) { return i; }
        self.next_conn += 1; self.conn_idx.insert(uuid.into(), self.next_conn); self.next_conn
    }
    fn saved_by_idx(&self, i: u32) -> Option<&sys::Saved> {
        self.conn_idx.iter().find(|(_, &v)| v == i).and_then(|(u, _)| self.saved.iter().find(|s| &s.uuid == u))
    }
    fn dev(&self, i: u32) -> Option<&Dev> { self.devs.iter().find(|d| d.idx == i) }
}

/// Rescan the system into the model. `scan`: also run dladm scan-wifi (slow: several seconds).
async fn refresh(ctx: &Ctx, scan: bool) {
    let links = ctx.be.links().await;
    let mut fresh = Vec::new();
    for (n, l) in links.iter().enumerate() {
        let mut d = Dev { idx: n as u32 + 1, link: l.clone(), ..Default::default() };
        d.addr = ctx.be.addr(&l.name).await;
        if l.wifi {
            let w = ctx.be.wifi_status(&l.name).await;
            let bss = if scan { ctx.be.scan(&l.name).await } else { None };
            d.state = if !l.up { DS_UNAVAILABLE } else if w.connected { if d.addr.is_some() { DS_ACTIVATED } else { DS_CONFIG } } else { DS_DISCONNECTED };
            let mut m = ctx.m.lock().await;
            if let Some(list) = bss {
                let now = m.boot.get_or_insert_with(Instant::now).elapsed().as_secs() as i32;
                let mut keep = Vec::new();
                for b in list {
                    let key = (l.name.clone(), b.bssid.clone());
                    let i = match m.ap_key.get(&key) { Some(&i) => i, None => { m.next_ap += 1; let i = m.next_ap; m.ap_key.insert(key, i); i } };
                    m.aps.insert(i, Ap { bss: b, last_seen: now });
                    keep.push(i);
                }
                // the connected BSS stays listed even if this scan missed it
                if w.connected { if let Some(&i) = m.ap_key.get(&(l.name.clone(), w.bssid.clone())) { if !keep.contains(&i) { keep.push(i); } } }
                let gone: Vec<u32> = m.ap_key.iter().filter(|((ln, _), v)| ln == &l.name && !keep.contains(v)).map(|(_, &v)| v).collect();
                for i in &gone { m.aps.remove(i); }
                m.ap_key.retain(|_, v| !gone.contains(v));
                m.last_scan.insert(l.name.clone(), Instant::now());
            }
            d.aps = m.ap_key.iter().filter(|((ln, _), _)| ln == &l.name).map(|(_, &v)| v).collect();
            d.aps.sort();
            if w.connected {
                d.active_ap = m.ap_key.get(&(l.name.clone(), w.bssid.clone())).copied().unwrap_or(0);
            }
            drop(m);
            fresh.push((d, w));
        } else {
            d.state = if !l.up { DS_UNAVAILABLE } else if d.addr.is_some() { DS_ACTIVATED } else { DS_DISCONNECTED };
            fresh.push((d, sys::WifiStatus::default()));
        }
    }
    let route = ctx.be.has_default_route().await;
    let mut m = ctx.m.lock().await;
    m.saved = ctx.store.load(&ctx.declared);
    let saved = m.saved.clone();
    for s in &saved { m.conn_path(&s.uuid); }
    m.conn_idx.retain(|u, _| saved.iter().any(|s| &s.uuid == u));
    // active connections: one per wifi link connected to an SSID we hold a profile for, one per wired link with an address
    let mut act = Vec::new();
    let mut devs = Vec::new();
    for (mut d, w) in fresh {
        d.active = 0;
        let prof = if d.link.wifi && w.connected { saved.iter().find(|s| s.ssid == w.essid.as_bytes()).cloned() } else { None };
        let (uuid, id, conn) = match (&prof, d.link.wifi, d.state) {
            (Some(p), true, _) => (p.uuid.clone(), String::from_utf8_lossy(&p.ssid).into_owned(), m.conn_path(&p.uuid)),
            (None, true, s) if s >= DS_CONFIG => (sys::uuid_from(w.essid.as_bytes()), w.essid.clone(), 0),
            (_, false, DS_ACTIVATED) => (sys::uuid_from(d.link.name.as_bytes()), format!("Wired ({})", d.link.name), 0),
            _ => { devs.push(d); continue; }
        };
        let idx = m.active.iter().find(|a| a.uuid == uuid && a.dev == d.idx).map(|a| a.idx).unwrap_or_else(|| { m.next_active += 1; m.next_active });
        let state = if d.state == DS_ACTIVATED { AC_ACTIVATED } else { AC_ACTIVATING };
        act.push(Active { idx, dev: d.idx, conn, ap: d.active_ap, uuid, id, state });
        d.active = idx;
        devs.push(d);
    }
    for p in m.pending.clone() {
        act.retain(|a| a.dev != p.dev);
        if let Some(d) = devs.iter_mut().find(|d| d.idx == p.dev) { d.active = p.idx; if p.state == AC_ACTIVATING { d.state = DS_CONFIG; } }
        act.push(p);
    }
    m.devs = devs;
    m.active = act;
    m.connectivity = if route { CONN_FULL } else { CONN_NONE };
}

// ---- who may change things: root, or a member of the networkmanager group (NixOS's NM convention) ---------------
async fn may_change(ctx: &Ctx, hdr: &Header<'_>) -> fdo::Result<()> {
    let sender = hdr.sender().ok_or_else(|| err("no sender"))?.to_string();
    let uid = ctx.be.caller_uid(&ctx.conn, &sender).await?;
    if uid == 0 { return Ok(()); }
    if let Some(g) = ctx.admin_gid {
        if ctx.be.user_in_group(uid, g) { return Ok(()); }
    }
    Err(fdo::Error::AccessDenied("solnix-nm: root or the networkmanager group only".into()))
}

pub(crate) fn user_in_group(uid: u32, gid: u32) -> bool {
    let pw = std::fs::read_to_string("/etc/passwd").unwrap_or_default();
    let Some(name) = pw.lines().map(|l| l.split(':').collect::<Vec<_>>()).find(|f| f.len() > 3 && f[2] == uid.to_string()).map(|f| f[0].to_string()) else { return false };
    let primary = pw.lines().map(|l| l.split(':').collect::<Vec<_>>()).any(|f| f.len() > 3 && f[0] == name && f[3] == gid.to_string());
    primary || std::fs::read_to_string("/etc/group").unwrap_or_default().lines().any(|l| {
        let f: Vec<&str> = l.split(':').collect();
        f.len() > 3 && f[2] == gid.to_string() && f[3].split(',').any(|m| m == name)
    })
}

fn group_gid(name: &str) -> Option<u32> {
    std::fs::read_to_string("/etc/group").ok()?.lines().find_map(|l| { let f: Vec<&str> = l.split(':').collect(); (f.len() > 2 && f[0] == name).then(|| f[2].parse().ok()).flatten() })
}

// ---- objects -----------------------------------------------------------------------------------------------------
struct Root(Arc<Ctx>);

fn settings_ssid(s: &Settings) -> Option<Vec<u8>> {
    let w = s.get("802-11-wireless")?.get("ssid")?;
    <Vec<u8>>::try_from(w.try_clone().ok()?).ok()
}
fn settings_str(s: &Settings, sec: &str, key: &str) -> Option<String> {
    String::try_from(s.get(sec)?.get(key)?.try_clone().ok()?).ok()
}

impl Root {
    /// Activate on a wifi device: save the profile (psk given) or use the saved one, join, publish the result.
    async fn activate(&self, ssid: Vec<u8>, psk: Option<String>, uuid: Option<String>, dev: u32) -> fdo::Result<(OwnedObjectPath, OwnedObjectPath)> {
        let ctx = &self.0;
        let (link, saved) = {
            let m = ctx.m.lock().await;
            let d = m.dev(dev).filter(|d| d.link.wifi).ok_or_else(|| err("not a wifi device"))?;
            (d.link.name.clone(), m.saved.iter().find(|s| s.ssid == ssid).cloned())
        };
        let ssid_s = String::from_utf8(ssid.clone()).map_err(|_| err("SSID is not UTF-8 (wpa-pmk takes text)"))?;
        let open = psk.is_none() && saved.as_ref().map_or(true, |s| s.psk_file.is_empty());
        let prof = {
            let mut m = ctx.m.lock().await;
            let mut all = m.saved.clone();
            let p = match (&psk, saved) {
                (Some(p), Some(s)) if s.declared => { let _ = p; s }   // declared: its file is the system's, never rewritten
                (Some(p), s) => {
                    if p.len() < 8 || p.len() > 63 { return Err(fdo::Error::InvalidArgs("a WPA passphrase is 8 to 63 characters".into())); }
                    let u = uuid.or(s.map(|s| s.uuid)).unwrap_or_else(|| sys::uuid_from(format!("{}{:?}", ssid_s, Instant::now()).as_bytes()));
                    ctx.store.save(&mut all, &ssid, Some(p), &u).map_err(|e| err(&e.to_string()))?
                }
                (None, Some(s)) => s,
                (None, None) if open => { let u = uuid.unwrap_or_else(|| sys::uuid_from(ssid_s.as_bytes())); ctx.store.save(&mut all, &ssid, None, &u).map_err(|e| err(&e.to_string()))? }
                (None, None) => return Err(err("no saved secret for this network")),
            };
            m.saved = all;
            p
        };
        let (cidx, aidx) = {
            let mut m = ctx.m.lock().await;
            let c = m.conn_path(&prof.uuid);
            m.next_active += 1; let a = m.next_active;
            let ap = m.devs.iter().find(|d| d.idx == dev).and_then(|d| d.aps.iter().copied().find(|i| m.aps.get(i).is_some_and(|x| x.bss.essid.as_bytes() == ssid.as_slice()))).unwrap_or(0);
            let p = Active { idx: a, dev, conn: c, ap, uuid: prof.uuid.clone(), id: ssid_s.clone(), state: AC_ACTIVATING };
            m.pending.retain(|x| x.dev != dev); m.pending.push(p.clone());
            m.active.retain(|x| x.dev != dev); m.active.push(p);
            if let Some(d) = m.devs.iter_mut().find(|d| d.idx == dev) { d.state = DS_CONFIG; d.active = a; }
            (c, a)
        };
        publish(ctx).await;
        let ctx2 = ctx.clone();
        let psk_file = (!prof.psk_file.is_empty()).then(|| prof.psk_file.clone());
        tokio::spawn(async move {
            // nmrs waits 30 s for Activated: 20 s to associate, then up to 8 s for solnix-netd's DHCP lease
            ctx2.be.set_hold(&link, true);   // solnix-netd must not rejoin its own network meanwhile
            let ok = ctx2.be.join(&link, &ssid_s, psk_file.as_deref(), 20).await;
            ctx2.be.set_hold(&link, false);  // associated: netd keeps it; failed: netd falls back to the declared networks
            if ok { for _ in 0..4 { if ctx2.be.addr(&link).await.is_some() { break; } tokio::time::sleep(ctx2.be.poll()).await; } }
            let (state, reason) = if ok { (AC_ACTIVATED, 0) } else { (AC_DEACTIVATED, REASON_NO_SECRETS) };
            {
                let mut m = ctx2.m.lock().await;
                if ok { m.pending.retain(|x| x.idx != aidx); }
                else { for x in m.pending.iter_mut().filter(|x| x.idx == aidx) { x.state = AC_DEACTIVATED; } }
            }
            refresh(&ctx2, false).await;
            if ok {   // the computed entry for this link reuses aidx (same uuid, same device); make sure it reads activated
                let mut m = ctx2.m.lock().await;
                for x in m.active.iter_mut().filter(|x| x.idx == aidx) { x.state = AC_ACTIVATED; }
            } else {
                let mut m = ctx2.m.lock().await;
                if let Some(d) = m.devs.iter_mut().find(|d| d.idx == dev) { d.state = DS_FAILED; }
            }
            publish(&ctx2).await;
            if let Ok(e) = SignalEmitter::new(&ctx2.conn, format!("{NM}/ActiveConnection/{aidx}")) { let _ = ActiveObj::ac_state_changed(&e, state, reason).await; }
            if let Ok(e) = SignalEmitter::new(&ctx2.conn, format!("{NM}/Devices/{dev}")) {
                let _ = DevObj::dev_state_changed(&e, if ok { DS_ACTIVATED } else { DS_FAILED }, DS_CONFIG, if ok { 0 } else { 7 }).await;
            }
            if !ok {   // readers see Deactivated for a few seconds, then the object goes
                tokio::time::sleep(Duration::from_secs(5)).await;
                ctx2.m.lock().await.pending.retain(|x| x.idx != aidx);
                refresh(&ctx2, false).await; publish(&ctx2).await;
            }
        });
        Ok((op(&format!("{NM}/Settings/{cidx}")), op(&format!("{NM}/ActiveConnection/{aidx}"))))
    }
}

fn dev_idx(p: &ObjectPath<'_>) -> Option<u32> { p.as_str().strip_prefix(&format!("{NM}/Devices/"))?.parse().ok() }
fn idx_of(p: &ObjectPath<'_>, kind: &str) -> Option<u32> { p.as_str().strip_prefix(&format!("{NM}/{kind}/"))?.parse().ok() }

#[interface(name = "org.freedesktop.NetworkManager")]
impl Root {
    async fn get_devices(&self) -> Vec<OwnedObjectPath> { self.0.m.lock().await.devs.iter().map(|d| op(&format!("{NM}/Devices/{}", d.idx))).collect() }
    async fn get_all_devices(&self) -> Vec<OwnedObjectPath> { self.get_devices().await }

    async fn add_and_activate_connection(&self, #[zbus(header)] hdr: Header<'_>, connection: Settings, device: ObjectPath<'_>,
                                         _specific_object: ObjectPath<'_>) -> fdo::Result<(OwnedObjectPath, OwnedObjectPath)> {
        may_change(&self.0, &hdr).await?;
        let ssid = settings_ssid(&connection).ok_or_else(|| fdo::Error::InvalidArgs("no 802-11-wireless.ssid".into()))?;
        let km = settings_str(&connection, "802-11-wireless-security", "key-mgmt");
        let psk = settings_str(&connection, "802-11-wireless-security", "psk").filter(|p| !p.is_empty());
        match km.as_deref() {
            None | Some("none") if psk.is_none() => {}
            Some("wpa-psk") => {}
            Some(k) => return Err(fdo::Error::NotSupported(format!("solnix-nm: key-mgmt {k} (WPA2-PSK and open networks only)"))),
            None => {}
        }
        let uuid = settings_str(&connection, "connection", "uuid");
        let dev = dev_idx(&device).or(self.0.m.lock().await.devs.iter().find(|d| d.link.wifi).map(|d| d.idx)).ok_or_else(|| err("no wifi device"))?;
        self.activate(ssid, psk, uuid, dev).await
    }

    async fn activate_connection(&self, #[zbus(header)] hdr: Header<'_>, connection: ObjectPath<'_>, device: ObjectPath<'_>,
                                 _specific_object: ObjectPath<'_>) -> fdo::Result<OwnedObjectPath> {
        may_change(&self.0, &hdr).await?;
        let ci = idx_of(&connection, "Settings").ok_or_else(|| fdo::Error::UnknownObject("not a connection".into()))?;
        let s = self.0.m.lock().await.saved_by_idx(ci).cloned().ok_or_else(|| fdo::Error::UnknownObject("no such connection".into()))?;
        let dev = dev_idx(&device).or(self.0.m.lock().await.devs.iter().find(|d| d.link.wifi).map(|d| d.idx)).ok_or_else(|| err("no wifi device"))?;
        Ok(self.activate(s.ssid, None, Some(s.uuid), dev).await?.1)
    }

    async fn deactivate_connection(&self, #[zbus(header)] hdr: Header<'_>, active_connection: ObjectPath<'_>) -> fdo::Result<()> {
        may_change(&self.0, &hdr).await?;
        let ai = idx_of(&active_connection, "ActiveConnection").ok_or_else(|| fdo::Error::UnknownObject("no such active connection".into()))?;
        let dev = { let m = self.0.m.lock().await; m.active.iter().find(|a| a.idx == ai).map(|a| a.dev) }.ok_or_else(|| fdo::Error::UnknownObject("no such active connection".into()))?;
        down_device(&self.0, dev).await
    }

    async fn check_connectivity(&self) -> u32 { refresh(&self.0, false).await; self.0.m.lock().await.connectivity }

    #[zbus(property)] async fn wireless_enabled(&self) -> bool { self.0.m.lock().await.wireless_enabled }
    #[zbus(property)]
    async fn set_wireless_enabled(&self, #[zbus(header)] hdr: Option<Header<'_>>, on: bool) -> fdo::Result<()> {
        may_change(&self.0, hdr.as_ref().ok_or_else(|| err("no header"))?).await?;
        let links: Vec<String> = { let mut m = self.0.m.lock().await; m.wireless_enabled = on; m.devs.iter().filter(|d| d.link.wifi).map(|d| d.link.name.clone()).collect() };
        for l in links { self.0.be.set_hold(&l, !on); if !on { self.0.be.disconnect(&l).await; } }
        let c = self.0.clone(); tokio::spawn(async move { refresh(&c, false).await; publish(&c).await; });
        Ok(())
    }
    #[zbus(property)] async fn wireless_hardware_enabled(&self) -> bool { true }
    #[zbus(property)] async fn wwan_enabled(&self) -> bool { false }
    #[zbus(property)] async fn set_wwan_enabled(&self, _on: bool) -> fdo::Result<()> { Ok(()) }
    #[zbus(property)] async fn wwan_hardware_enabled(&self) -> bool { false }
    #[zbus(property)] async fn wimax_enabled(&self) -> bool { false }
    #[zbus(property)] async fn wimax_hardware_enabled(&self) -> bool { false }
    #[zbus(property)] async fn networking_enabled(&self) -> bool { true }
    #[zbus(property)] async fn active_connections(&self) -> Vec<OwnedObjectPath> { self.0.m.lock().await.active.iter().map(|a| op(&format!("{NM}/ActiveConnection/{}", a.idx))).collect() }
    #[zbus(property)] async fn primary_connection(&self) -> OwnedObjectPath {
        let m = self.0.m.lock().await;
        m.active.iter().find(|a| a.state == AC_ACTIVATED).map(|a| op(&format!("{NM}/ActiveConnection/{}", a.idx))).unwrap_or_else(root)
    }
    #[zbus(property)] async fn primary_connection_type(&self) -> String {
        let m = self.0.m.lock().await;
        m.active.iter().find(|a| a.state == AC_ACTIVATED).and_then(|a| m.dev(a.dev)).map(|d| if d.link.wifi { "802-11-wireless" } else { "802-3-ethernet" }).unwrap_or("").into()
    }
    #[zbus(property)] async fn activating_connection(&self) -> OwnedObjectPath {
        let m = self.0.m.lock().await;
        m.active.iter().find(|a| a.state == AC_ACTIVATING).map(|a| op(&format!("{NM}/ActiveConnection/{}", a.idx))).unwrap_or_else(root)
    }
    #[zbus(property)] async fn state(&self) -> u32 { if self.0.m.lock().await.active.iter().any(|a| a.state == AC_ACTIVATED) { NM_STATE_CONNECTED_GLOBAL } else { NM_STATE_DISCONNECTED } }
    #[zbus(property)] async fn connectivity(&self) -> u32 { self.0.m.lock().await.connectivity }
    #[zbus(property)] async fn connectivity_check_available(&self) -> bool { false }
    #[zbus(property)] async fn connectivity_check_enabled(&self) -> bool { false }
    #[zbus(property)] async fn connectivity_check_uri(&self) -> String { String::new() }
    #[zbus(property)] async fn startup(&self) -> bool { false }
    #[zbus(property)] async fn version(&self) -> String { "1.52.0-solnix-nm".into() }
    #[zbus(property)] async fn capabilities(&self) -> Vec<u32> { vec![] }
    #[zbus(property)] async fn metered(&self) -> u32 { 4 }   // NM_METERED_GUESS_NO
    #[zbus(property)] async fn global_dns_configuration(&self) -> HashMap<String, OwnedValue> { HashMap::new() }
    #[zbus(property)] async fn set_global_dns_configuration(&self, _v: HashMap<String, OwnedValue>) -> fdo::Result<()> {
        Err(fdo::Error::NotSupported("solnix-nm: DNS comes from the DHCP lease or networking.nameservers".into()))
    }
    #[zbus(property)] async fn all_devices(&self) -> Vec<OwnedObjectPath> { self.get_devices().await }
    #[zbus(property)] async fn devices(&self) -> Vec<OwnedObjectPath> { self.get_devices().await }
    #[zbus(property)] async fn checkpoints(&self) -> Vec<OwnedObjectPath> { vec![] }

    #[zbus(signal)] async fn device_added(e: &SignalEmitter<'_>, device: ObjectPath<'_>) -> zbus::Result<()>;
    #[zbus(signal)] async fn device_removed(e: &SignalEmitter<'_>, device: ObjectPath<'_>) -> zbus::Result<()>;
    #[zbus(signal, name = "StateChanged")] async fn nm_state_changed(e: &SignalEmitter<'_>, state: u32) -> zbus::Result<()>;
}

async fn down_device(ctx: &Arc<Ctx>, dev: u32) -> fdo::Result<()> {
    let (link, wifi) = { let m = ctx.m.lock().await; let d = m.dev(dev).ok_or_else(|| fdo::Error::UnknownObject("no such device".into()))?; (d.link.name.clone(), d.link.wifi) };
    if !wifi { return Err(fdo::Error::NotSupported("solnix-nm: wired links are solnix-netd's (networking.interfaces)".into())); }
    ctx.be.set_hold(&link, true);
    ctx.be.disconnect(&link).await;
    let aidx = { let m = ctx.m.lock().await; m.active.iter().find(|a| a.dev == dev).map(|a| a.idx) };
    refresh(ctx, false).await;
    if let Some(a) = aidx {
        if let Ok(e) = SignalEmitter::new(&ctx.conn, op(&format!("{NM}/ActiveConnection/{a}"))) { let _ = ActiveObj::ac_state_changed(&e, AC_DEACTIVATED, REASON_USER).await; }
    }
    if let Ok(e) = SignalEmitter::new(&ctx.conn, op(&format!("{NM}/Devices/{dev}"))) { let _ = DevObj::dev_state_changed(&e, DS_DISCONNECTED, DS_ACTIVATED, 39).await; }
    publish(ctx).await;
    Ok(())
}

struct DevObj(Arc<Ctx>, u32);
impl DevObj { async fn d(&self) -> Dev { self.0.m.lock().await.dev(self.1).cloned().unwrap_or_default() } }

#[interface(name = "org.freedesktop.NetworkManager.Device")]
impl DevObj {
    async fn disconnect(&self, #[zbus(header)] hdr: Header<'_>) -> fdo::Result<()> {
        may_change(&self.0, &hdr).await?;
        if self.d().await.active == 0 { return Err(fdo::Error::Failed("org.freedesktop.NetworkManager.Device.NotActive".into())); }
        down_device(&self.0, self.1).await
    }
    async fn delete(&self) -> fdo::Result<()> { Err(fdo::Error::NotSupported("solnix-nm: hardware device".into())) }
    #[zbus(property)] async fn udi(&self) -> String { format!("/devices/{}", self.d().await.link.name) }
    #[zbus(property)] async fn path(&self) -> String { String::new() }
    #[zbus(property)] async fn interface(&self) -> String { self.d().await.link.name }
    #[zbus(property)] async fn ip_interface(&self) -> String { self.d().await.link.name }
    #[zbus(property)] async fn driver(&self) -> String { self.d().await.link.name.trim_end_matches(|c: char| c.is_ascii_digit()).to_string() }
    #[zbus(property)] async fn driver_version(&self) -> String { String::new() }
    #[zbus(property)] async fn firmware_version(&self) -> String { String::new() }
    #[zbus(property)] async fn capabilities(&self) -> u32 { 1 }
    #[zbus(property)] async fn state(&self) -> u32 { self.d().await.state }
    #[zbus(property)] async fn state_reason(&self) -> (u32, u32) { (self.d().await.state, 0) }
    #[zbus(property)] async fn active_connection(&self) -> OwnedObjectPath { let a = self.d().await.active; if a == 0 { root() } else { op(&format!("{NM}/ActiveConnection/{a}")) } }
    #[zbus(property)] async fn ip4_config(&self) -> OwnedObjectPath { if self.d().await.addr.is_some() { op(&format!("{NM}/IP4Config/{}", self.1)) } else { root() } }
    #[zbus(property)] async fn dhcp4_config(&self) -> OwnedObjectPath { root() }
    #[zbus(property)] async fn ip6_config(&self) -> OwnedObjectPath { root() }
    #[zbus(property)] async fn dhcp6_config(&self) -> OwnedObjectPath { root() }
    #[zbus(property)] async fn managed(&self) -> bool { true }
    #[zbus(property)] async fn set_managed(&self, _v: bool) -> fdo::Result<()> { Ok(()) }
    #[zbus(property)] async fn autoconnect(&self) -> bool { true }
    #[zbus(property)] async fn set_autoconnect(&self, _v: bool) -> fdo::Result<()> { Ok(()) }
    #[zbus(property)] async fn firmware_missing(&self) -> bool { false }
    #[zbus(property)] async fn nm_plugin_missing(&self) -> bool { false }
    #[zbus(property)] async fn device_type(&self) -> u32 { if self.d().await.link.wifi { DEV_WIFI } else { DEV_ETHERNET } }
    #[zbus(property)] async fn available_connections(&self) -> Vec<OwnedObjectPath> {
        let m = self.0.m.lock().await;
        if !m.dev(self.1).is_some_and(|d| d.link.wifi) { return vec![]; }
        m.saved.iter().filter_map(|s| m.conn_idx.get(&s.uuid)).map(|i| op(&format!("{NM}/Settings/{i}"))).collect()
    }
    #[zbus(property)] async fn physical_port_id(&self) -> String { String::new() }
    #[zbus(property)] async fn mtu(&self) -> u32 { 1500 }
    #[zbus(property)] async fn metered(&self) -> u32 { 4 }
    #[zbus(property)] async fn real(&self) -> bool { true }
    #[zbus(property)] async fn ip4_connectivity(&self) -> u32 { if self.d().await.addr.is_some() { self.0.m.lock().await.connectivity } else { CONN_NONE } }
    #[zbus(property)] async fn ip6_connectivity(&self) -> u32 { CONN_NONE }
    #[zbus(property)] async fn interface_flags(&self) -> u32 { if self.d().await.link.up { 0x1 } else { 0 } }
    #[zbus(property)] async fn hw_address(&self) -> String { self.d().await.link.mac }
    #[zbus(property)] async fn ports(&self) -> Vec<OwnedObjectPath> { vec![] }
    #[zbus(signal, name = "StateChanged")] async fn dev_state_changed(e: &SignalEmitter<'_>, new_state: u32, old_state: u32, reason: u32) -> zbus::Result<()>;
}

struct WifiObj(Arc<Ctx>, u32);
#[interface(name = "org.freedesktop.NetworkManager.Device.Wireless")]
impl WifiObj {
    async fn request_scan(&self, _options: HashMap<String, OwnedValue>) -> fdo::Result<()> {
        let c = self.0.clone();
        tokio::spawn(async move { refresh(&c, true).await; publish(&c).await; });
        Ok(())
    }
    async fn get_access_points(&self) -> Vec<OwnedObjectPath> { self.access_points().await }
    async fn get_all_access_points(&self) -> Vec<OwnedObjectPath> { self.access_points().await }
    #[zbus(property)] async fn hw_address(&self) -> String { self.0.m.lock().await.dev(self.1).map(|d| d.link.mac.clone()).unwrap_or_default() }
    #[zbus(property)] async fn perm_hw_address(&self) -> String { self.hw_address().await }
    #[zbus(property)] async fn mode(&self) -> u32 { 2 }   // NM_802_11_MODE_INFRA
    #[zbus(property)] async fn bitrate(&self) -> u32 {
        let m = self.0.m.lock().await;
        m.dev(self.1).and_then(|d| m.aps.get(&d.active_ap)).map(|a| a.bss.speed_mbps * 1000).unwrap_or(0)
    }
    #[zbus(property)] async fn access_points(&self) -> Vec<OwnedObjectPath> {
        self.0.m.lock().await.dev(self.1).map(|d| d.aps.iter().map(|i| op(&format!("{NM}/AccessPoint/{i}"))).collect()).unwrap_or_default()
    }
    #[zbus(property)] async fn active_access_point(&self) -> OwnedObjectPath {
        let a = self.0.m.lock().await.dev(self.1).map(|d| d.active_ap).unwrap_or(0);
        if a == 0 { root() } else { op(&format!("{NM}/AccessPoint/{a}")) }
    }
    #[zbus(property)] async fn wireless_capabilities(&self) -> u32 { 0x1 | 0x2 | 0x4 | 0x8 | 0x10 | 0x20 | 0x200 | 0x400 }   // ciphers, WPA, RSN, 2.4+5 GHz
    #[zbus(property)] async fn last_scan(&self) -> i64 {
        let m = self.0.m.lock().await;
        let link = m.dev(self.1).map(|d| d.link.name.clone()).unwrap_or_default();
        match (m.last_scan.get(&link), m.boot) { (Some(t), Some(b)) => (t.duration_since(b).as_millis() as i64).max(1), _ => -1 }
    }
    #[zbus(signal)] async fn access_point_added(e: &SignalEmitter<'_>, access_point: ObjectPath<'_>) -> zbus::Result<()>;
    #[zbus(signal)] async fn access_point_removed(e: &SignalEmitter<'_>, access_point: ObjectPath<'_>) -> zbus::Result<()>;
}

struct WiredObj(Arc<Ctx>, u32);
#[interface(name = "org.freedesktop.NetworkManager.Device.Wired")]
impl WiredObj {
    #[zbus(property)] async fn hw_address(&self) -> String { self.0.m.lock().await.dev(self.1).map(|d| d.link.mac.clone()).unwrap_or_default() }
    #[zbus(property)] async fn perm_hw_address(&self) -> String { self.hw_address().await }
    #[zbus(property)] async fn speed(&self) -> u32 { 1000 }
    #[zbus(property)] async fn s390_subchannels(&self) -> Vec<String> { vec![] }
    #[zbus(property)] async fn carrier(&self) -> bool { self.0.m.lock().await.dev(self.1).is_some_and(|d| d.link.up) }
}

struct ApObj(Arc<Ctx>, u32);
impl ApObj { async fn a(&self) -> Option<Ap> { self.0.m.lock().await.aps.get(&self.1).cloned() } }
#[interface(name = "org.freedesktop.NetworkManager.AccessPoint")]
impl ApObj {
    #[zbus(property)] async fn flags(&self) -> u32 { self.a().await.map_or(0, |a| if a.bss.sec == "none" { 0 } else { AP_PRIVACY }) }
    #[zbus(property)] async fn wpa_flags(&self) -> u32 { 0 }
    #[zbus(property)] async fn rsn_flags(&self) -> u32 { self.a().await.map_or(0, |a| if a.bss.sec == "wpa" { SEC_PSK_CCMP } else { 0 }) }
    #[zbus(property)] async fn ssid(&self) -> Vec<u8> { self.a().await.map(|a| a.bss.essid.into_bytes()).unwrap_or_default() }
    #[zbus(property)] async fn frequency(&self) -> u32 { self.a().await.map_or(0, |a| if a.bss.mode.contains('a') { 5180 } else { 2437 }) }
    #[zbus(property)] async fn hw_address(&self) -> String { self.a().await.map(|a| a.bss.bssid).unwrap_or_default() }
    #[zbus(property)] async fn mode(&self) -> u32 { 2 }
    #[zbus(property)] async fn max_bitrate(&self) -> u32 { self.a().await.map_or(0, |a| a.bss.speed_mbps * 1000) }
    #[zbus(property)] async fn bandwidth(&self) -> u32 { 20 }
    #[zbus(property)] async fn strength(&self) -> u8 { self.a().await.map_or(0, |a| a.bss.strength) }
    #[zbus(property)] async fn last_seen(&self) -> i32 { self.a().await.map_or(-1, |a| a.last_seen) }
}

struct ActiveObj(Arc<Ctx>, u32);
impl ActiveObj { async fn a(&self) -> Option<Active> { self.0.m.lock().await.active.iter().find(|a| a.idx == self.1).cloned() } }
#[interface(name = "org.freedesktop.NetworkManager.Connection.Active")]
impl ActiveObj {
    #[zbus(property)] async fn connection(&self) -> OwnedObjectPath { match self.a().await { Some(a) if a.conn != 0 => op(&format!("{NM}/Settings/{}", a.conn)), _ => root() } }
    #[zbus(property)] async fn specific_object(&self) -> OwnedObjectPath { match self.a().await { Some(a) if a.ap != 0 => op(&format!("{NM}/AccessPoint/{}", a.ap)), _ => root() } }
    #[zbus(property)] async fn id(&self) -> String { self.a().await.map(|a| a.id).unwrap_or_default() }
    #[zbus(property)] async fn uuid(&self) -> String { self.a().await.map(|a| a.uuid).unwrap_or_default() }
    #[zbus(property, name = "Type")] async fn type_(&self) -> String {
        let m = self.0.m.lock().await;
        m.active.iter().find(|a| a.idx == self.1).and_then(|a| m.dev(a.dev)).map(|d| if d.link.wifi { "802-11-wireless" } else { "802-3-ethernet" }).unwrap_or("802-11-wireless").into()
    }
    #[zbus(property)] async fn devices(&self) -> Vec<OwnedObjectPath> { self.a().await.map(|a| vec![op(&format!("{NM}/Devices/{}", a.dev))]).unwrap_or_default() }
    #[zbus(property)] async fn state(&self) -> u32 { self.a().await.map_or(AC_DEACTIVATED, |a| a.state) }
    #[zbus(property)] async fn state_flags(&self) -> u32 { 0 }
    #[zbus(property)] async fn default(&self) -> bool { self.a().await.is_some_and(|a| a.state == AC_ACTIVATED) }
    #[zbus(property)] async fn ip4_config(&self) -> OwnedObjectPath {
        let m = self.0.m.lock().await;
        match m.active.iter().find(|a| a.idx == self.1).and_then(|a| m.dev(a.dev)) { Some(d) if d.addr.is_some() => op(&format!("{NM}/IP4Config/{}", d.idx)), _ => root() }
    }
    #[zbus(property)] async fn dhcp4_config(&self) -> OwnedObjectPath { root() }
    #[zbus(property)] async fn default6(&self) -> bool { false }
    #[zbus(property)] async fn ip6_config(&self) -> OwnedObjectPath { root() }
    #[zbus(property)] async fn dhcp6_config(&self) -> OwnedObjectPath { root() }
    #[zbus(property)] async fn vpn(&self) -> bool { false }
    #[zbus(property)] async fn controller(&self) -> OwnedObjectPath { root() }
    #[zbus(property)] async fn master(&self) -> OwnedObjectPath { root() }
    #[zbus(signal, name = "StateChanged")] async fn ac_state_changed(e: &SignalEmitter<'_>, state: u32, reason: u32) -> zbus::Result<()>;
}

struct Ip4Obj(Arc<Ctx>, u32);
#[interface(name = "org.freedesktop.NetworkManager.IP4Config")]
impl Ip4Obj {
    #[zbus(property)] async fn address_data(&self) -> Vec<HashMap<String, OwnedValue>> {
        let a = self.0.m.lock().await.dev(self.1).and_then(|d| d.addr.clone());
        a.map(|(ad, p)| vec![HashMap::from([("address".to_string(), ov(ad)), ("prefix".to_string(), ov(p))])]).unwrap_or_default()
    }
    #[zbus(property)] async fn gateway(&self) -> String { String::new() }
    #[zbus(property)] async fn route_data(&self) -> Vec<HashMap<String, OwnedValue>> { vec![] }
    #[zbus(property)] async fn nameserver_data(&self) -> Vec<HashMap<String, OwnedValue>> {
        std::fs::read_to_string("/etc/resolv.conf").unwrap_or_default().lines().filter_map(|l| l.strip_prefix("nameserver ")).map(|a| HashMap::from([("address".to_string(), ov(a.trim().to_string()))])).collect()
    }
    #[zbus(property)] async fn domains(&self) -> Vec<String> { vec![] }
    #[zbus(property)] async fn searches(&self) -> Vec<String> { vec![] }
    #[zbus(property)] async fn dns_options(&self) -> Vec<String> { vec![] }
    #[zbus(property)] async fn dns_priority(&self) -> i32 { 0 }
    #[zbus(property)] async fn wins_server_data(&self) -> Vec<String> { vec![] }
}

struct SettingsObj(Arc<Ctx>);
#[interface(name = "org.freedesktop.NetworkManager.Settings")]
impl SettingsObj {
    async fn list_connections(&self) -> Vec<OwnedObjectPath> { self.connections().await }
    async fn get_connection_by_uuid(&self, uuid: &str) -> fdo::Result<OwnedObjectPath> {
        self.0.m.lock().await.conn_idx.get(uuid).map(|i| op(&format!("{NM}/Settings/{i}"))).ok_or_else(|| fdo::Error::Failed("org.freedesktop.NetworkManager.Settings.InvalidConnection".into()))
    }
    async fn add_connection(&self, #[zbus(header)] hdr: Header<'_>, connection: Settings) -> fdo::Result<OwnedObjectPath> {
        may_change(&self.0, &hdr).await?;
        let ssid = settings_ssid(&connection).ok_or_else(|| fdo::Error::NotSupported("solnix-nm: wifi profiles only".into()))?;
        let psk = settings_str(&connection, "802-11-wireless-security", "psk").filter(|p| !p.is_empty());
        if let Some(p) = &psk { if p.len() < 8 || p.len() > 63 { return Err(fdo::Error::InvalidArgs("a WPA passphrase is 8 to 63 characters".into())); } }
        let uuid = settings_str(&connection, "connection", "uuid").unwrap_or_else(|| sys::uuid_from(&ssid));
        let mut m = self.0.m.lock().await;
        let mut all = m.saved.clone();
        if all.iter().any(|s| s.declared && s.ssid == ssid) { return Err(err("declared in the system configuration (hardware.wirelessIwx.networks)")); }
        let s = self.0.store.save(&mut all, &ssid, psk.as_deref(), &uuid).map_err(|e| err(&e.to_string()))?;
        m.saved = all;
        let i = m.conn_path(&s.uuid);
        drop(m);
        publish(&self.0).await;
        Ok(op(&format!("{NM}/Settings/{i}")))
    }
    async fn add_connection_unsaved(&self, #[zbus(header)] hdr: Header<'_>, connection: Settings) -> fdo::Result<OwnedObjectPath> { self.add_connection(hdr, connection).await }
    async fn reload_connections(&self) -> bool { refresh(&self.0, false).await; publish(&self.0).await; true }
    #[zbus(property)] async fn connections(&self) -> Vec<OwnedObjectPath> {
        let m = self.0.m.lock().await;
        let mut v: Vec<u32> = m.saved.iter().filter_map(|s| m.conn_idx.get(&s.uuid).copied()).collect(); v.sort();
        v.into_iter().map(|i| op(&format!("{NM}/Settings/{i}"))).collect()
    }
    #[zbus(property)] async fn hostname(&self) -> String { std::fs::read_to_string("/etc/nodename").unwrap_or_default().trim().into() }
    #[zbus(property)] async fn can_modify(&self) -> bool { true }
    #[zbus(signal)] async fn new_connection(e: &SignalEmitter<'_>, connection: ObjectPath<'_>) -> zbus::Result<()>;
    #[zbus(signal)] async fn connection_removed(e: &SignalEmitter<'_>, connection: ObjectPath<'_>) -> zbus::Result<()>;
}

struct ConnObj(Arc<Ctx>, u32);
#[interface(name = "org.freedesktop.NetworkManager.Settings.Connection")]
impl ConnObj {
    /// NM never returns secrets from GetSettings (GetSecrets does, to agents); neither does this.
    async fn get_settings(&self) -> fdo::Result<Settings> {
        let m = self.0.m.lock().await;
        let s = m.saved_by_idx(self.1).ok_or_else(|| fdo::Error::UnknownObject("no such connection".into()))?;
        let id = String::from_utf8_lossy(&s.ssid).into_owned();
        let mut out: Settings = HashMap::new();
        out.insert("connection".into(), HashMap::from([("id".into(), ov(id)), ("uuid".into(), ov(s.uuid.clone())),
            ("type".into(), ov("802-11-wireless")), ("autoconnect".into(), ov(true))]));
        out.insert("802-11-wireless".into(), HashMap::from([("ssid".into(), ov(s.ssid.clone())), ("mode".into(), ov("infrastructure"))]));
        if !s.psk_file.is_empty() {
            out.insert("802-11-wireless-security".into(), HashMap::from([("key-mgmt".into(), ov("wpa-psk"))]));
        }
        out.insert("ipv4".into(), HashMap::from([("method".into(), ov("auto"))]));
        Ok(out)
    }
    async fn get_secrets(&self, _setting_name: &str) -> fdo::Result<Settings> { Err(fdo::Error::AccessDenied("solnix-nm: secrets stay in /etc/wifi".into())) }
    async fn update(&self, #[zbus(header)] hdr: Header<'_>, properties: Settings) -> fdo::Result<()> {
        may_change(&self.0, &hdr).await?;
        let psk = settings_str(&properties, "802-11-wireless-security", "psk").filter(|p| !p.is_empty());
        let mut m = self.0.m.lock().await;
        let s = m.saved_by_idx(self.1).cloned().ok_or_else(|| fdo::Error::UnknownObject("no such connection".into()))?;
        if s.declared { return Err(err("declared in the system configuration (hardware.wirelessIwx.networks)")); }
        if let Some(p) = psk {
            if p.len() < 8 || p.len() > 63 { return Err(fdo::Error::InvalidArgs("a WPA passphrase is 8 to 63 characters".into())); }
            let mut all = m.saved.clone();
            self.0.store.save(&mut all, &s.ssid, Some(&p), &s.uuid).map_err(|e| err(&e.to_string()))?;
            m.saved = all;
        }
        Ok(())
    }
    async fn update_unsaved(&self, #[zbus(header)] hdr: Header<'_>, properties: Settings) -> fdo::Result<()> { self.update(hdr, properties).await }
    async fn delete(&self, #[zbus(header)] hdr: Header<'_>) -> fdo::Result<()> {
        may_change(&self.0, &hdr).await?;
        let mut m = self.0.m.lock().await;
        let s = m.saved_by_idx(self.1).cloned().ok_or_else(|| fdo::Error::UnknownObject("no such connection".into()))?;
        if s.declared { return Err(err("declared in the system configuration (hardware.wirelessIwx.networks): remove it there")); }
        let mut all = m.saved.clone();
        self.0.store.delete(&mut all, &s.uuid).map_err(|e| err(&e.to_string()))?;
        m.saved = all;
        drop(m);
        let path = op(&format!("{NM}/Settings/{}", self.1));
        if let Ok(e) = SignalEmitter::new(&self.0.conn, path.clone()) { let _ = ConnObj::removed(&e).await; }
        if let Ok(e) = SignalEmitter::new(&self.0.conn, op(&format!("{NM}/Settings"))) { let _ = SettingsObj::connection_removed(&e, path.as_ref()).await; }
        let c = self.0.clone(); tokio::spawn(async move { refresh(&c, false).await; publish(&c).await; });
        Ok(())
    }
    async fn save(&self) -> fdo::Result<()> { Ok(()) }
    #[zbus(property)] async fn unsaved(&self) -> bool { false }
    #[zbus(property)] async fn flags(&self) -> u32 { 0 }
    #[zbus(property)] async fn filename(&self) -> String { self.0.m.lock().await.saved_by_idx(self.1).map(|s| s.psk_file.clone()).unwrap_or_default() }
    #[zbus(signal)] async fn updated(e: &SignalEmitter<'_>) -> zbus::Result<()>;
    #[zbus(signal)] async fn removed(e: &SignalEmitter<'_>) -> zbus::Result<()>;
}

/// COSMIC registers a secret agent; solnix-nm takes the PSK inline (AddAndActivateConnection) and never asks an agent.
struct AgentMgr;
#[interface(name = "org.freedesktop.NetworkManager.AgentManager")]
impl AgentMgr {
    async fn register(&self, _identifier: &str) {}
    async fn register_with_capabilities(&self, _identifier: &str, _capabilities: u32) {}
    async fn unregister(&self) {}
}

// ---- publish: make the object tree match the model, and announce what changed -------------------------------------
#[derive(Default, PartialEq, Clone)]
struct Seen { devs: Vec<(u32, bool, u32)>, aps: Vec<(u32, u32)>, active: Vec<(u32, u32)>, conns: Vec<u32>, ips: Vec<u32>, wifi_on: bool, connectivity: u32 }

async fn publish(ctx: &Arc<Ctx>) {
    let last = &ctx.seen;
    let now = {
        let m = ctx.m.lock().await;
        Seen {
            devs: m.devs.iter().map(|d| (d.idx, d.link.wifi, d.state)).collect(),
            aps: m.devs.iter().flat_map(|d| d.aps.iter().map(move |a| (*a, d.idx))).collect(),
            active: m.active.iter().map(|a| (a.idx, a.state)).collect(),
            conns: m.conn_idx.values().copied().collect(),
            ips: m.devs.iter().filter(|d| d.addr.is_some()).map(|d| d.idx).collect(),
            wifi_on: m.wireless_enabled, connectivity: m.connectivity,
        }
    };
    let before = last.lock().unwrap().clone();
    let os = ctx.conn.object_server();
    for &(i, wifi, _) in &now.devs {
        if before.devs.iter().any(|d| d.0 == i) { continue; }
        let p = format!("{NM}/Devices/{i}");
        let _ = os.at(p.clone(), DevObj(ctx.clone(), i)).await;
        if wifi { let _ = os.at(p.clone(), WifiObj(ctx.clone(), i)).await; } else { let _ = os.at(p.clone(), WiredObj(ctx.clone(), i)).await; }
        if let Ok(e) = SignalEmitter::new(&ctx.conn, NM) { let _ = Root::device_added(&e, ObjectPath::try_from(p.as_str()).unwrap()).await; }
    }
    for &(i, wifi, _) in &before.devs {
        if now.devs.iter().any(|d| d.0 == i) { continue; }
        let p = format!("{NM}/Devices/{i}");
        let _ = os.remove::<DevObj, _>(p.as_str()).await;
        if wifi { let _ = os.remove::<WifiObj, _>(p.as_str()).await; } else { let _ = os.remove::<WiredObj, _>(p.as_str()).await; }
        if let Ok(e) = SignalEmitter::new(&ctx.conn, NM) { let _ = Root::device_removed(&e, ObjectPath::try_from(p.as_str()).unwrap()).await; }
    }
    for &(a, d) in &now.aps {
        if before.aps.iter().any(|x| x.0 == a) { continue; }
        let p = format!("{NM}/AccessPoint/{a}");
        let _ = os.at(p.clone(), ApObj(ctx.clone(), a)).await;
        if let Ok(e) = SignalEmitter::new(&ctx.conn, format!("{NM}/Devices/{d}")) { let _ = WifiObj::access_point_added(&e, ObjectPath::try_from(p.as_str()).unwrap()).await; }
    }
    for &(a, d) in &before.aps {
        if now.aps.iter().any(|x| x.0 == a) { continue; }
        let p = format!("{NM}/AccessPoint/{a}");
        if let Ok(e) = SignalEmitter::new(&ctx.conn, format!("{NM}/Devices/{d}")) { let _ = WifiObj::access_point_removed(&e, ObjectPath::try_from(p.as_str()).unwrap()).await; }
        let _ = os.remove::<ApObj, _>(p.as_str()).await;
    }
    for &(a, _) in &now.active { if !before.active.iter().any(|x| x.0 == a) { let _ = os.at(format!("{NM}/ActiveConnection/{a}"), ActiveObj(ctx.clone(), a)).await; } }
    for &(a, _) in &before.active { if !now.active.iter().any(|x| x.0 == a) { let _ = os.remove::<ActiveObj, _>(format!("{NM}/ActiveConnection/{a}")).await; } }
    for &i in &now.ips { if !before.ips.contains(&i) { let _ = os.at(format!("{NM}/IP4Config/{i}"), Ip4Obj(ctx.clone(), i)).await; } }
    for &i in &before.ips { if !now.ips.contains(&i) { let _ = os.remove::<Ip4Obj, _>(format!("{NM}/IP4Config/{i}")).await; } }
    for &c in &now.conns {
        if before.conns.contains(&c) { continue; }
        let p = format!("{NM}/Settings/{c}");
        let _ = os.at(p.clone(), ConnObj(ctx.clone(), c)).await;
        if let Ok(e) = SignalEmitter::new(&ctx.conn, format!("{NM}/Settings")) { let _ = SettingsObj::new_connection(&e, ObjectPath::try_from(p.as_str()).unwrap()).await; }
    }
    for &c in &before.conns { if !now.conns.contains(&c) { let _ = os.remove::<ConnObj, _>(format!("{NM}/Settings/{c}")).await; } }
    // property changes: invalidate (zbus clients refetch), so no value can be stale
    if before != now {
        if let Ok(r) = os.interface::<_, Root>(NM).await {
            let e = r.signal_emitter();
            let _ = r.get().await.active_connections_changed(e).await;
            let _ = r.get().await.primary_connection_changed(e).await;
            let _ = r.get().await.wireless_enabled_changed(e).await;
            let _ = r.get().await.connectivity_changed(e).await;
            let _ = r.get().await.state_changed(e).await;
        }
        for &(i, wifi, s) in &now.devs {
            let p = format!("{NM}/Devices/{i}");
            if let Ok(r) = os.interface::<_, DevObj>(p.as_str()).await {
                let old = before.devs.iter().find(|d| d.0 == i).map(|d| d.2);
                if old.is_some_and(|o| o != s) { let _ = DevObj::dev_state_changed(r.signal_emitter(), s, old.unwrap(), 0).await; }
                let _ = r.get().await.state_changed(r.signal_emitter()).await;
                let _ = r.get().await.active_connection_changed(r.signal_emitter()).await;
                let _ = r.get().await.ip4_config_changed(r.signal_emitter()).await;
            }
            if wifi { if let Ok(r) = os.interface::<_, WifiObj>(p.as_str()).await {
                let _ = r.get().await.access_points_changed(r.signal_emitter()).await;
                let _ = r.get().await.active_access_point_changed(r.signal_emitter()).await;
                let _ = r.get().await.last_scan_changed(r.signal_emitter()).await;
            } }
        }
        if let Ok(r) = os.interface::<_, SettingsObj>(format!("{NM}/Settings")).await { let _ = r.get().await.connections_changed(r.signal_emitter()).await; }
    }
    // AP strength and active-connection state can change without the sets changing
    for &(a, _) in &now.aps { if let Ok(r) = os.interface::<_, ApObj>(format!("{NM}/AccessPoint/{a}")).await { let _ = r.get().await.strength_changed(r.signal_emitter()).await; } }
    for &(a, s) in &now.active {
        if let Ok(r) = os.interface::<_, ActiveObj>(format!("{NM}/ActiveConnection/{a}")).await {
            if before.active.iter().find(|x| x.0 == a).is_some_and(|x| x.1 != s) { let _ = ActiveObj::ac_state_changed(r.signal_emitter(), s, 0).await; }
            let _ = r.get().await.state_changed(r.signal_emitter()).await;
        }
    }
    *last.lock().unwrap() = now;
}

/// Put the object tree on ctx's connection (main, and the tests on their own bus).
async fn serve(ctx: &Arc<Ctx>) -> zbus::Result<()> {
    refresh(ctx, true).await;
    let os = ctx.conn.object_server();
    os.at(NM, Root(ctx.clone())).await?;
    os.at(format!("{NM}/Settings"), SettingsObj(ctx.clone())).await?;
    os.at(format!("{NM}/AgentManager"), AgentMgr).await?;
    publish(ctx).await;
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();
    let bus = if args.iter().any(|a| a == "--session") { zbus::connection::Builder::session()? } else { zbus::connection::Builder::system()? };
    let conn = bus.build().await?;
    let ctx = Arc::new(Ctx {
        m: Mutex::new(Model { wireless_enabled: true, ..Default::default() }),
        store: sys::Store { dir: std::env::var("SOLNIX_NM_STATE").unwrap_or("/var/lib/solnix-nm".into()).into(),
                            wifi_dir: std::env::var("SOLNIX_NM_WIFI_DIR").unwrap_or("/etc/wifi".into()).into() },
        declared: std::env::var("SOLNIX_NM_DECLARED").unwrap_or_default(),
        admin_gid: group_gid("networkmanager"),
        conn: conn.clone(),
        be: Box::new(backend::Real),
        seen: Default::default(),
    });
    serve(&ctx).await?;
    conn.request_name("org.freedesktop.NetworkManager").await?;
    eprintln!("solnix-nm: on the bus as org.freedesktop.NetworkManager");
    // a light refresh every 5 s (status, addresses, routes), a scan every 60 s while the radio is on
    let mut tick = 0u32;
    loop {
        tokio::time::sleep(Duration::from_secs(5)).await;
        tick += 1;
        let scan = tick % 12 == 0 && ctx.m.lock().await.wireless_enabled;
        refresh(&ctx, scan).await;
        publish(&ctx).await;
    }
}
