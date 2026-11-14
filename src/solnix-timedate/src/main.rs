//! solnix-timedate: org.freedesktop.timedate1 for COSMIC Settings > Time & language, over illumos's zone files and
//! /etc/default/init. cosmic-settings 1.11 (pages/time/date.rs) calls ListTimezones, reads Timezone, NTP and CanNTP, and
//! calls SetTimezone and SetNTP. NixOS answers these with systemd-timedated; illumos has no systemd, so this is the
//! documented departure (docs/solnix-timedate.md). MIT.
//!   ListTimezones: every TZif file under the zoneinfo dir (/usr/share/lib/zoneinfo), by name, sorted (timedated lists
//!     tzdata.zi's zones and links, which illumos does not ship); posix/, right/ and posixrules are left out.
//!   Timezone: TZ from /etc/default/init (illumos init and login read it there), "UTC" when unset.
//!   SetTimezone: root, or an RBAC administrator (solnix-accounts' rule: the Primary Administrator profile, the root role,
//!     or the sysadmin group): rewrites the TZ= line of /etc/default/init (a temp file + rename), then
//!     PropertiesChanged. New logins get it; running processes keep their TZ, as with TZ on illumos.
//!   NTP / CanNTP: false (no time sync service is managed from here); SetNTP, SetTime, SetLocalRTC: NotSupported.
//! Runs as root under SMF (services.solnix-timedate).
#[cfg(test)]
mod tests;

use std::path::{Path, PathBuf};
use std::sync::Arc;
use zbus::object_server::SignalEmitter;
use zbus::{fdo, interface, message::Header, Connection};

pub const PATH: &str = "/org/freedesktop/timedate1";
pub const ADMIN_PROFILE: &str = "Primary Administrator";
pub const ADMIN_GROUP: &str = "sysadmin";

/// Where the files are: `root`/etc/{default/init,passwd,group,user_attr}, `zoneinfo` = the zone tree.
pub struct Ctx { pub root: PathBuf, pub zoneinfo: PathBuf, pub conn: Connection, pub be: Box<dyn Caller> }

/// Who is calling: the bus daemon's answer (the tests answer from a table).
pub trait Caller: Send + Sync {
    fn uid<'a>(&'a self, conn: &'a Connection, sender: &'a str) -> std::pin::Pin<Box<dyn std::future::Future<Output = fdo::Result<u32>> + Send + 'a>>;
}
pub struct BusCaller;
impl Caller for BusCaller {
    fn uid<'a>(&'a self, conn: &'a Connection, sender: &'a str) -> std::pin::Pin<Box<dyn std::future::Future<Output = fdo::Result<u32>> + Send + 'a>> {
        Box::pin(async move {
            let dbus = fdo::DBusProxy::new(conn).await?;
            let name = zbus::names::BusName::try_from(sender).map_err(|e| fdo::Error::Failed(e.to_string()))?;
            dbus.get_connection_unix_user(name).await
        })
    }
}

fn read(p: &Path) -> String { std::fs::read_to_string(p).unwrap_or_default() }

/// A zone name timedated would accept: relative, no "." or ".." component, only the characters tz names use.
pub fn valid_zone(z: &str) -> bool {
    !z.is_empty() && !z.starts_with('/') && z.len() < 256
        && z.split('/').all(|c| !c.is_empty() && c != "." && c != ".." && !c.starts_with('-'))
        && z.chars().all(|c| c.is_ascii_alphanumeric() || "/_-+".contains(c))
}

fn is_tzif(p: &Path) -> bool {
    use std::io::Read;
    let mut b = [0u8; 4];
    std::fs::File::open(p).and_then(|mut f| f.read_exact(&mut b)).is_ok() && &b == b"TZif"
}

/// Every zone under `dir`, by name, sorted. timedated lists the zones and links of tzdata.zi; illumos ships no
/// tzdata.zi, so take every TZif file in the tree, leaving out posix/ and right/ (copies of the same zones) and posixrules.
pub fn zones(dir: &Path) -> Vec<String> {
    fn walk(base: &Path, d: &Path, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(d) else { return };
        for e in rd.flatten() {
            let p = e.path();
            let Ok(rel) = p.strip_prefix(base) else { continue };
            let rel = rel.to_string_lossy().to_string();
            if p.is_dir() {
                if rel != "posix" && rel != "right" { walk(base, &p, out); }
            } else if rel != "posixrules" && valid_zone(&rel) && is_tzif(&p) {
                out.push(rel);
            }
        }
    }
    let mut v = Vec::new();
    walk(dir, dir, &mut v);
    v.sort();
    v
}

/// TZ from <root>/etc/default/init ("UTC" when unset or empty), with illumos's ":" prefix dropped.
pub fn current(root: &Path) -> String {
    read(&root.join("etc/default/init")).lines()
        .find_map(|l| l.strip_prefix("TZ=").map(|v| v.trim().trim_start_matches(':').trim_matches('"').to_string()))
        .filter(|v| !v.is_empty()).unwrap_or_else(|| "UTC".into())
}

/// The file with its TZ= line set to `zone` (appended if absent); every other line kept as it is.
pub fn with_zone(text: &str, zone: &str) -> String {
    let mut seen = false;
    let mut out: Vec<String> = text.lines().map(|l| if l.starts_with("TZ=") && !seen { seen = true; format!("TZ={zone}") } else { l.to_string() }).collect();
    if !seen { out.push(format!("TZ={zone}")); }
    out.join("\n") + "\n"
}

/// root, or an RBAC administrator by solnix-accounts' rule (Primary Administrator, the root role, or group sysadmin).
pub fn is_admin(root: &Path, uid: u32) -> bool {
    if uid == 0 { return true; }
    let pw = read(&root.join("etc/passwd"));
    let Some((name, gid)) = pw.lines().map(|l| l.split(':').collect::<Vec<_>>()).find(|f| f.len() > 3 && f[2] == uid.to_string()).map(|f| (f[0].to_string(), f[3].to_string())) else { return false };
    let ua = read(&root.join("etc/user_attr"));
    let attr = ua.lines().filter(|l| !l.starts_with('#')).find(|l| l.split(':').next() == Some(name.as_str())).map(|l| l.splitn(5, ':').nth(4).unwrap_or("").to_string()).unwrap_or_default();
    let kv = |k: &str| attr.split(';').find_map(|p| p.strip_prefix(&format!("{k}=")).map(|v| v.split(',').map(str::to_string).collect::<Vec<_>>())).unwrap_or_default();
    if kv("profiles").iter().any(|p| p == ADMIN_PROFILE) || kv("roles").iter().any(|r| r == "root") { return true; }
    read(&root.join("etc/group")).lines().any(|l| {
        let f: Vec<&str> = l.split(':').collect();
        f.len() > 3 && f[0] == ADMIN_GROUP && (f[2] == gid || f[3].split(',').any(|m| m == name))
    })
}

#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.timedate1")]
pub enum Error {
    #[zbus(error)]
    ZBus(zbus::Error),
    /// systemd-timedated's name for an unknown zone
    InvalidTimezone(String),
    NotSupported(String),
    AccessDenied(String),
    Failed(String),
}

pub struct Timedate(pub Arc<Ctx>);

#[interface(name = "org.freedesktop.timedate1")]
impl Timedate {
    async fn list_timezones(&self) -> Vec<String> { zones(&self.0.zoneinfo) }
    async fn set_timezone(&self, #[zbus(header)] hdr: Header<'_>, #[zbus(signal_emitter)] e: SignalEmitter<'_>, timezone: &str, _interactive: bool) -> Result<(), Error> {
        let sender = hdr.sender().ok_or_else(|| Error::Failed("no sender".into()))?.to_string();
        let uid = self.0.be.uid(&self.0.conn, &sender).await.map_err(|e| Error::Failed(e.to_string()))?;
        if !is_admin(&self.0.root, uid) { return Err(Error::AccessDenied("solnix-timedate: root or an administrator (RBAC) only".into())); }
        if !valid_zone(timezone) || !is_tzif(&self.0.zoneinfo.join(timezone)) { return Err(Error::InvalidTimezone(format!("Invalid or not installed time zone '{timezone}'"))); }
        if current(&self.0.root) == timezone { return Ok(()); }
        let f = self.0.root.join("etc/default/init");
        let tmp = f.with_extension("timedate");
        std::fs::write(&tmp, with_zone(&read(&f), timezone)).and_then(|_| {
            if let Ok(m) = std::fs::metadata(&f) { std::fs::set_permissions(&tmp, m.permissions())?; }
            std::fs::rename(&tmp, &f)
        }).map_err(|e| Error::Failed(format!("{}: {e}", f.display())))?;
        let _ = self.timezone_changed(&e).await;
        Ok(())
    }
    #[zbus(name = "SetNTP")]
    async fn set_ntp(&self, _use_ntp: bool, _interactive: bool) -> Result<(), Error> { Err(Error::NotSupported("solnix-timedate: no NTP service is managed here".into())) }
    async fn set_time(&self, _usec_utc: i64, _relative: bool, _interactive: bool) -> Result<(), Error> { Err(Error::NotSupported("solnix-timedate: set the clock with date(1)".into())) }
    #[zbus(name = "SetLocalRTC")]
    async fn set_local_rtc(&self, _local_rtc: bool, _fix_system: bool, _interactive: bool) -> Result<(), Error> { Err(Error::NotSupported("solnix-timedate: the RTC mode is the boot configuration's".into())) }
    #[zbus(property)] async fn timezone(&self) -> String { current(&self.0.root) }
    #[zbus(property, name = "LocalRTC")] async fn local_rtc(&self) -> bool { false }
    #[zbus(property(emits_changed_signal = "false"), name = "CanNTP")] async fn can_ntp(&self) -> bool { false }
    #[zbus(property, name = "NTP")] async fn ntp(&self) -> bool { false }
    #[zbus(property(emits_changed_signal = "false"), name = "NTPSynchronized")] async fn ntp_synchronized(&self) -> bool { false }
    #[zbus(property(emits_changed_signal = "false"), name = "TimeUSec")] async fn time_usec(&self) -> u64 {
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_micros() as u64).unwrap_or(0)
    }
    #[zbus(property(emits_changed_signal = "false"), name = "RTCTimeUSec")] async fn rtc_time_usec(&self) -> u64 { self.time_usec().await }
}

pub async fn serve(ctx: &Arc<Ctx>) -> zbus::Result<()> {
    ctx.conn.object_server().at(PATH, Timedate(ctx.clone())).await?;
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let conn = if session { zbus::connection::Builder::session()? } else { zbus::connection::Builder::system()? }.build().await?;
    // SOLNIX_TIMEDATE_ROOT / SOLNIX_ZONEINFO: read a copy instead of / and /usr/share/lib/zoneinfo (the checks)
    let root: PathBuf = std::env::var("SOLNIX_TIMEDATE_ROOT").unwrap_or("/".into()).into();
    let zoneinfo: PathBuf = std::env::var("SOLNIX_ZONEINFO").unwrap_or("/usr/share/lib/zoneinfo".into()).into();
    let ctx = Arc::new(Ctx { root, zoneinfo, conn: conn.clone(), be: Box::new(BusCaller) });
    serve(&ctx).await?;
    conn.request_name("org.freedesktop.timedate1").await?;
    eprintln!("solnix-timedate: on the bus as org.freedesktop.timedate1 ({} zones, TZ {})", zones(&ctx.zoneinfo).len(), current(&ctx.root));
    std::future::pending::<()>().await;
    Ok(())
}
