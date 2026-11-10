//! solnix-power: org.freedesktop.UPower (battery, AC, display device) and org.freedesktop.UPower.PowerProfiles for
//! COSMIC 1.11 (Settings > Power, the battery applet, cosmic-settings-daemon, cosmic-idle), over illumos acpi_drv
//! kstats and /etc/power.conf. What COSMIC reads and why: docs/solnix-power.md. Read-only until a client sets
//! ActiveProfile, which only root or a member of the seat group may do (may_change). MIT. Runs as root under SMF.
mod sys;
#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, OwnedObjectPath, OwnedValue, Value};
use zbus::{fdo, interface, message::Header, Connection};

const UP: &str = "/org/freedesktop/UPower";
const DISPLAY: &str = "/org/freedesktop/UPower/devices/DisplayDevice";
const AC: &str = "/org/freedesktop/UPower/devices/line_power_AC";
const PP: &str = "/org/freedesktop/UPower/PowerProfiles";

fn op(s: &str) -> OwnedObjectPath { OwnedObjectPath::try_from(s.to_string()).unwrap() }
fn bat_path(i: usize) -> String { format!("{UP}/devices/battery_BAT{i}") }
fn ov<'a, T: Into<Value<'a>>>(v: T) -> OwnedValue { OwnedValue::try_from(v.into()).unwrap() }

pub type Fut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

/// The seam to the system; tests swap in a recorder.
pub trait Backend: Send + Sync {
    fn read_power(&self) -> Fut<'_, sys::Power>;
    fn read_conf(&self) -> Option<String>;
    /// Write power.conf and apply it (pmconfig). Only called for an allowed caller's profile change.
    fn apply_conf<'a>(&'a self, conf: &'a str) -> Fut<'a, bool>;
    fn caller_uid<'a>(&'a self, conn: &'a Connection, sender: &'a str) -> Fut<'a, fdo::Result<u32>>;
    fn lid_present(&self) -> bool;
    fn user_in_group(&self, uid: u32, gid: u32) -> bool;
}

pub struct Real { pub conf: std::path::PathBuf }
impl Backend for Real {
    fn read_power(&self) -> Fut<'_, sys::Power> { Box::pin(sys::read_power()) }
    fn read_conf(&self) -> Option<String> { std::fs::read_to_string(&self.conf).ok() }
    fn apply_conf<'a>(&'a self, conf: &'a str) -> Fut<'a, bool> {
        Box::pin(async move {
            // same file, same owner and mode: write beside it, keep its permissions, rename over it
            let tmp = self.conf.with_extension("conf.solnix-power");
            let mode = std::fs::metadata(&self.conf).map(|m| { use std::os::unix::fs::PermissionsExt; m.permissions().mode() }).unwrap_or(0o644);
            if std::fs::write(&tmp, conf).is_err() { return false; }
            { use std::os::unix::fs::PermissionsExt; let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(mode)); }
            if std::fs::rename(&tmp, &self.conf).is_err() { let _ = std::fs::remove_file(&tmp); return false; }
            sys::run(&["pmconfig"], 30).await.is_some()
        })
    }
    fn caller_uid<'a>(&'a self, conn: &'a Connection, sender: &'a str) -> Fut<'a, fdo::Result<u32>> {
        Box::pin(async move {
            let dbus = fdo::DBusProxy::new(conn).await.map_err(|e| fdo::Error::Failed(e.to_string()))?;
            dbus.get_connection_unix_user(zbus::names::BusName::try_from(sender).map_err(|e| fdo::Error::Failed(e.to_string()))?).await
        })
    }
    fn lid_present(&self) -> bool { sys::lid_present() }
    fn user_in_group(&self, uid: u32, gid: u32) -> bool { user_in_group(uid, gid) }
}

struct Ctx { p: Mutex<sys::Power>, profile: Mutex<String>, conn: Connection, be: Box<dyn Backend>, console_gid: Option<u32> }

/// A profile change: root, or a member of the seat group. power-profiles-daemon's polkit rule allows any user in an
/// active local session (allow_active); on solnix the desktop user is in `seat` (services.seatd), the closest fact.
async fn may_change(ctx: &Ctx, hdr: &Header<'_>) -> fdo::Result<()> {
    let sender = hdr.sender().ok_or_else(|| fdo::Error::Failed("no sender".into()))?.to_string();
    let uid = ctx.be.caller_uid(&ctx.conn, &sender).await?;
    if uid == 0 || ctx.console_gid.is_some_and(|g| ctx.be.user_in_group(uid, g)) { return Ok(()); }
    Err(fdo::Error::AccessDenied("solnix-power: root or the seat group only".into()))
}

pub(crate) fn user_in_group(uid: u32, gid: u32) -> bool {
    let pw = std::fs::read_to_string("/etc/passwd").unwrap_or_default();
    let rows: Vec<Vec<&str>> = pw.lines().map(|l| l.split(':').collect()).collect();
    let Some(name) = rows.iter().find(|f| f.len() > 3 && f[2] == uid.to_string()).map(|f| f[0].to_string()) else { return false };
    rows.iter().any(|f| f.len() > 3 && f[0] == name && f[3] == gid.to_string())
        || std::fs::read_to_string("/etc/group").unwrap_or_default().lines().any(|l| {
            let f: Vec<&str> = l.split(':').collect(); f.len() > 3 && f[2] == gid.to_string() && f[3].split(',').any(|m| m == name) })
}

fn group_gid(name: &str) -> Option<u32> {
    std::fs::read_to_string("/etc/group").ok()?.lines().find_map(|l| { let f: Vec<&str> = l.split(':').collect(); (f.len() > 2 && f[0] == name).then(|| f[2].parse().ok()).flatten() })
}

// ---- org.freedesktop.UPower ---------------------------------------------------------------------------------------
struct Root(Arc<Ctx>);
#[interface(name = "org.freedesktop.UPower")]
impl Root {
    async fn enumerate_devices(&self) -> Vec<OwnedObjectPath> {
        let n = self.0.p.lock().await.batteries.len();
        let mut v = vec![op(AC)]; v.extend((0..n).map(|i| op(&bat_path(i)))); v
    }
    async fn get_display_device(&self) -> OwnedObjectPath { op(DISPLAY) }
    async fn get_critical_action(&self) -> String { "PowerOff".into() }
    #[zbus(property)] async fn daemon_version(&self) -> String { "1.90.0-solnix-power".into() }
    #[zbus(property)] async fn on_battery(&self) -> bool { let p = self.0.p.lock().await; !p.on_ac && !p.batteries.is_empty() }
    #[zbus(property)] async fn lid_is_closed(&self) -> bool { false }
    #[zbus(property)] async fn lid_is_present(&self) -> bool { self.0.be.lid_present() }
    #[zbus(signal)] async fn device_added(e: &SignalEmitter<'_>, device: ObjectPath<'_>) -> zbus::Result<()>;
    #[zbus(signal)] async fn device_removed(e: &SignalEmitter<'_>, device: ObjectPath<'_>) -> zbus::Result<()>;
}

/// One UPower device: a battery (Some(index)), the composite display device (None, display = true) or line power.
#[derive(Clone, Copy)]
enum Kind { Bat(usize), Display, Line }
struct Dev(Arc<Ctx>, Kind);

impl Dev {
    /// The battery this object shows (the display device: the sum of all batteries, as UPower composes it).
    async fn bat(&self) -> Option<(sys::Battery, bool)> {
        let p = self.0.p.lock().await;
        match self.1 {
            Kind::Bat(i) => p.batteries.get(i).cloned().map(|b| (b, p.on_ac)),
            Kind::Display if !p.batteries.is_empty() => {
                let mut s = sys::Battery { present: true, ..Default::default() };
                for b in &p.batteries { s.design += b.design; s.full += b.full; s.now += b.now; s.rate += b.rate; s.charging |= b.charging; s.discharging |= b.discharging; }
                s.voltage = p.batteries[0].voltage;
                Some((s, p.on_ac))
            }
            _ => None,
        }
    }
    async fn d(&self) -> (f64, u32, i64, i64) { match self.bat().await { Some((b, ac)) => sys::derive(&b, ac), None => (0.0, 0, 0, 0) } }
}

#[interface(name = "org.freedesktop.UPower.Device")]
impl Dev {
    async fn refresh(&self) { let p = self.0.be.read_power().await; *self.0.p.lock().await = p; }
    async fn get_history(&self, _t: &str, _ts: u32, _res: u32) -> Vec<(u32, f64, u32)> { vec![] }
    async fn get_statistics(&self, _t: &str) -> Vec<(f64, f64)> { vec![] }
    async fn enable_charge_threshold(&self, _on: bool) -> fdo::Result<()> { Err(fdo::Error::NotSupported("solnix-power: no charge thresholds".into())) }
    #[zbus(property)] async fn native_path(&self) -> String { match self.1 { Kind::Bat(i) => format!("acpi_drv:0:battery BIF{i}"), Kind::Line => "acpi_drv:0:power".into(), Kind::Display => String::new() } }
    #[zbus(property)] async fn vendor(&self) -> String { self.bat().await.map(|b| b.0.vendor).unwrap_or_default() }
    #[zbus(property)] async fn model(&self) -> String { self.bat().await.map(|b| b.0.model).unwrap_or_default() }
    #[zbus(property)] async fn serial(&self) -> String { self.bat().await.map(|b| b.0.serial).unwrap_or_default() }
    #[zbus(property)] async fn update_time(&self) -> u64 { std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0) }
    #[zbus(property, name = "Type")] async fn type_(&self) -> u32 {
        match self.1 { Kind::Line => 1, Kind::Bat(_) => 2, Kind::Display => if self.bat().await.is_some() { 2 } else { 0 } }
    }
    #[zbus(property)] async fn power_supply(&self) -> bool { true }
    #[zbus(property)] async fn has_history(&self) -> bool { false }
    #[zbus(property)] async fn has_statistics(&self) -> bool { false }
    #[zbus(property)] async fn online(&self) -> bool { matches!(self.1, Kind::Line) && self.0.p.lock().await.on_ac }
    #[zbus(property)] async fn energy(&self) -> f64 { self.bat().await.map_or(0.0, |b| b.0.now) }
    #[zbus(property)] async fn energy_empty(&self) -> f64 { 0.0 }
    #[zbus(property)] async fn energy_full(&self) -> f64 { self.bat().await.map_or(0.0, |b| b.0.full) }
    #[zbus(property)] async fn energy_full_design(&self) -> f64 { self.bat().await.map_or(0.0, |b| b.0.design) }
    #[zbus(property)] async fn energy_rate(&self) -> f64 { self.bat().await.map_or(0.0, |b| b.0.rate) }
    #[zbus(property)] async fn voltage(&self) -> f64 { self.bat().await.map_or(0.0, |b| b.0.voltage) }
    #[zbus(property)] async fn charge_cycles(&self) -> i32 { -1 }
    #[zbus(property)] async fn luminosity(&self) -> f64 { 0.0 }
    #[zbus(property)] async fn time_to_empty(&self) -> i64 { self.d().await.2 }
    #[zbus(property)] async fn time_to_full(&self) -> i64 { self.d().await.3 }
    #[zbus(property)] async fn percentage(&self) -> f64 { self.d().await.0 }
    #[zbus(property)] async fn temperature(&self) -> f64 { 0.0 }
    #[zbus(property)] async fn is_present(&self) -> bool { self.bat().await.is_some_and(|b| b.0.present) }
    #[zbus(property)] async fn state(&self) -> u32 { self.d().await.1 }
    #[zbus(property)] async fn is_rechargeable(&self) -> bool { self.bat().await.is_some() }
    #[zbus(property)] async fn capacity(&self) -> f64 { self.bat().await.map_or(0.0, |b| if b.0.design > 0.0 { (b.0.full / b.0.design * 100.0).min(100.0) } else { 0.0 }) }
    #[zbus(property)] async fn technology(&self) -> u32 { self.bat().await.map_or(0, |b| b.0.tech) }
    #[zbus(property)] async fn warning_level(&self) -> u32 { let (p, s, _, _) = self.d().await; if self.bat().await.is_none() { 1 } else { sys::warning_level(p, s == 2) } }
    #[zbus(property)] async fn battery_level(&self) -> u32 { 1 }
    #[zbus(property)] async fn icon_name(&self) -> String {
        match self.1 { Kind::Line => "ac-adapter-symbolic".into(), _ => match self.bat().await { None => String::new(), Some(_) => { let (p, s, _, _) = self.d().await; sys::icon(p, s) } } }
    }
    #[zbus(property)] async fn charge_start_threshold(&self) -> u32 { 0 }
    #[zbus(property)] async fn charge_end_threshold(&self) -> u32 { 100 }
    #[zbus(property)] async fn charge_threshold_enabled(&self) -> bool { false }
    #[zbus(property)] async fn charge_threshold_supported(&self) -> bool { false }
    #[zbus(property)] async fn charge_threshold_settings_supported(&self) -> u32 { 0 }
    #[zbus(property)] async fn voltage_min_design(&self) -> f64 { 0.0 }
    #[zbus(property)] async fn voltage_max_design(&self) -> f64 { 0.0 }
    #[zbus(property)] async fn capacity_level(&self) -> String { String::new() }
}

// ---- org.freedesktop.UPower.PowerProfiles ---------------------------------------------------------------------------
struct Profiles(Arc<Ctx>);
#[interface(name = "org.freedesktop.UPower.PowerProfiles")]
impl Profiles {
    #[zbus(property)] async fn active_profile(&self) -> String { self.0.profile.lock().await.clone() }
    #[zbus(property)]
    async fn set_active_profile(&self, #[zbus(header)] hdr: Option<Header<'_>>, profile: String) -> fdo::Result<()> {
        may_change(&self.0, hdr.as_ref().ok_or_else(|| fdo::Error::Failed("no header".into()))?).await?;
        if !sys::PROFILES.contains(&profile.as_str()) { return Err(fdo::Error::InvalidArgs(format!("no profile {profile}"))); }
        let conf = self.0.be.read_conf().ok_or_else(|| fdo::Error::Failed("cannot read /etc/power.conf".into()))?;
        if sys::profile_of(&conf) == profile { *self.0.profile.lock().await = profile; return Ok(()); }
        let new = sys::set_profile(&conf, &profile).ok_or_else(|| fdo::Error::InvalidArgs(profile.clone()))?;
        if !self.0.be.apply_conf(&new).await { return Err(fdo::Error::Failed("pmconfig failed (power.conf kept the new line; see svcs -x power)".into())); }
        *self.0.profile.lock().await = profile;
        Ok(())
    }
    #[zbus(property)] async fn performance_inhibited(&self) -> String { String::new() }
    #[zbus(property)] async fn performance_degraded(&self) -> String { String::new() }
    #[zbus(property)] async fn profiles(&self) -> Vec<HashMap<String, OwnedValue>> {
        sys::PROFILES.iter().map(|p| HashMap::from([("Profile".to_string(), ov(p.to_string())), ("Driver".to_string(), ov("cpupm")),
            ("CpuDriver".to_string(), ov("cpupm")), ("PlatformDriver".to_string(), ov("placeholder"))])).collect()
    }
    #[zbus(property)] async fn actions(&self) -> Vec<String> { vec![] }
    #[zbus(property)] async fn actions_info(&self) -> Vec<HashMap<String, OwnedValue>> { vec![] }
    #[zbus(property)] async fn active_profile_holds(&self) -> Vec<HashMap<String, OwnedValue>> { vec![] }
    #[zbus(property)] async fn version(&self) -> String { "0.30-solnix-power".into() }
    #[zbus(property)] async fn battery_aware(&self) -> bool { false }
    async fn hold_profile(&self, _profile: &str, _reason: &str, _application_id: &str) -> fdo::Result<u32> {
        Err(fdo::Error::NotSupported("solnix-power: profile holds are not supported".into()))
    }
    async fn release_profile(&self, _cookie: u32) -> fdo::Result<()> { Err(fdo::Error::NotSupported("solnix-power: no holds".into())) }
    #[zbus(signal)] async fn profile_released(e: &SignalEmitter<'_>, cookie: u32) -> zbus::Result<()>;
}

async fn serve(ctx: &Arc<Ctx>, n_bat: usize) -> zbus::Result<()> {
    let os = ctx.conn.object_server();
    os.at(UP, Root(ctx.clone())).await?;
    os.at(DISPLAY, Dev(ctx.clone(), Kind::Display)).await?;
    os.at(AC, Dev(ctx.clone(), Kind::Line)).await?;
    for i in 0..n_bat { os.at(bat_path(i), Dev(ctx.clone(), Kind::Bat(i))).await?; }
    os.at(PP, Profiles(ctx.clone())).await?;
    Ok(())
}

/// Re-read the kstats; announce what COSMIC watches (OnBattery, the devices' Percentage/State/TimeToEmpty/Online).
async fn poll(ctx: &Arc<Ctx>) {
    let new = ctx.be.read_power().await;
    let old = std::mem::replace(&mut *ctx.p.lock().await, new.clone());
    let conf_profile = ctx.be.read_conf().map(|c| sys::profile_of(&c).to_string());
    if let Some(p) = conf_profile { let mut cur = ctx.profile.lock().await; if *cur != p { *cur = p; drop(cur);
        if let Ok(r) = ctx.conn.object_server().interface::<_, Profiles>(PP).await { let _ = r.get().await.active_profile_changed(r.signal_emitter()).await; } } }
    if old == new { return; }
    let os = ctx.conn.object_server();
    if old.on_ac != new.on_ac { if let Ok(r) = os.interface::<_, Root>(UP).await { let _ = r.get().await.on_battery_changed(r.signal_emitter()).await; } }
    let mut paths = vec![DISPLAY.to_string(), AC.to_string()];
    paths.extend((0..new.batteries.len()).map(bat_path));
    for p in paths {
        if let Ok(r) = os.interface::<_, Dev>(p.as_str()).await {
            let e = r.signal_emitter(); let d = r.get().await;
            let _ = d.percentage_changed(e).await; let _ = d.state_changed(e).await; let _ = d.time_to_empty_changed(e).await;
            let _ = d.time_to_full_changed(e).await; let _ = d.online_changed(e).await; let _ = d.icon_name_changed(e).await;
            let _ = d.energy_changed(e).await; let _ = d.energy_rate_changed(e).await; let _ = d.warning_level_changed(e).await;
        }
    }
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let conn = if session { zbus::connection::Builder::session()? } else { zbus::connection::Builder::system()? }.build().await?;
    let be = Real { conf: std::env::var("SOLNIX_POWER_CONF").unwrap_or("/etc/power.conf".into()).into() };
    let power = be.read_power().await;
    let profile = be.read_conf().map(|c| sys::profile_of(&c).to_string()).unwrap_or("balanced".into());
    let n = power.batteries.len();
    let ctx = Arc::new(Ctx { p: Mutex::new(power), profile: Mutex::new(profile), conn: conn.clone(), be: Box::new(be),
                             console_gid: group_gid(&std::env::var("SOLNIX_POWER_GROUP").unwrap_or("seat".into())) });
    serve(&ctx, n).await?;
    conn.request_name("org.freedesktop.UPower").await?;
    conn.request_name("org.freedesktop.UPower.PowerProfiles").await?;
    eprintln!("solnix-power: on the bus as org.freedesktop.UPower and org.freedesktop.UPower.PowerProfiles ({n} batteries)");
    loop { tokio::time::sleep(Duration::from_secs(10)).await; poll(&ctx).await; }
}
