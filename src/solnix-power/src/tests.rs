//! UPower and PowerProfiles on a private session bus (run under dbus-run-session) with a recorder backend: the kstats
//! are lixi's, power.conf is a string. Reads must match the kstats; a profile change by a seat member writes the cpupm
//! line and applies it once; a plain user's change is refused and nothing is written (the negative control).
use super::*;
use std::sync::Mutex as StdMutex;

const LIXI: &str = "acpi_drv:0:battery BIF0:bif_design_cap\t90090\nacpi_drv:0:battery BIF0:bif_last_cap\t83460\n\
acpi_drv:0:battery BIF0:bif_model\t5B11B79217\nacpi_drv:0:battery BIF0:bif_unit\t0\nacpi_drv:0:battery BIF0:bif_voltage\t15520\n\
acpi_drv:0:battery BST0:bst_rate\t12000\nacpi_drv:0:battery BST0:bst_rem_cap\t62040\nacpi_drv:0:battery BST0:bst_state\t1\n\
acpi_drv:0:battery BST0:bst_voltage\t16227\nacpi_drv:0:power:system power\tbattery\n";
const STOCK: &str = "autopm                  default\ncpupm                   enable\ncpu-threshold           1s\n";

struct Rec { conf: StdMutex<String>, applied: StdMutex<Vec<String>>, uid: StdMutex<u32> }
struct RecBe(Arc<Rec>);
impl Backend for RecBe {
    fn read_power(&self) -> Fut<'_, sys::Power> { Box::pin(async { sys::power_from_kstat(&sys::parse_kstat(LIXI)) }) }
    fn read_conf(&self) -> Option<String> { Some(self.0.conf.lock().unwrap().clone()) }
    fn apply_conf<'a>(&'a self, conf: &'a str) -> Fut<'a, bool> {
        *self.0.conf.lock().unwrap() = conf.to_string(); self.0.applied.lock().unwrap().push(conf.to_string()); Box::pin(async { true })
    }
    fn caller_uid<'a>(&'a self, _c: &'a Connection, _s: &'a str) -> Fut<'a, fdo::Result<u32>> { let u = *self.0.uid.lock().unwrap(); Box::pin(async move { Ok(u) }) }
    fn lid_present(&self) -> bool { true }
    fn user_in_group(&self, uid: u32, gid: u32) -> bool { uid == 4242 && gid == 30082 }   // 4242: in the seat group
}
struct SeatCtx;
impl SeatCtx { fn gid() -> Option<u32> { Some(30082) } }

async fn daemon(tag: &str, uid: u32) -> (Arc<Rec>, Connection, String) {
    let rec = Arc::new(Rec { conf: StdMutex::new(STOCK.into()), applied: StdMutex::new(vec![]), uid: StdMutex::new(uid) });
    let conn = zbus::connection::Builder::session().unwrap().build().await.expect("a session bus: run under dbus-run-session");
    let be = RecBe(rec.clone());
    let power = be.read_power().await;
    let ctx = Arc::new(Ctx { p: Mutex::new(power), profile: Mutex::new("balanced".into()), conn: conn.clone(), be: Box::new(be),
                             console_gid: SeatCtx::gid() });
    serve(&ctx, 1).await.unwrap();
    let name = format!("org.solnix.powertest.t{}{}", std::process::id(), tag);
    conn.request_name(name.as_str()).await.unwrap();
    (rec, zbus::connection::Builder::session().unwrap().build().await.unwrap(), name)
}

async fn get<T: TryFrom<OwnedValue>>(c: &Connection, dest: &str, path: &str, iface: &str, prop: &str) -> T where T::Error: Into<zbus::Error> {
    let p: zbus::Proxy = zbus::proxy::Builder::new(c).destination(dest.to_string()).unwrap().path(path.to_string()).unwrap()
        .interface(iface.to_string()).unwrap().cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap();
    p.get_property::<T>(prop).await.unwrap()
}

#[tokio::test(flavor = "current_thread")]
async fn reads_match_the_kstats() {
    let (_rec, c, d) = daemon("read", 1000).await;
    let up = zbus::Proxy::new(&c, d.clone(), UP, "org.freedesktop.UPower").await.unwrap();
    let disp: OwnedObjectPath = up.call("GetDisplayDevice", &()).await.unwrap();
    assert_eq!(disp.as_str(), DISPLAY);
    let devs: Vec<OwnedObjectPath> = up.call("EnumerateDevices", &()).await.unwrap();
    assert_eq!(devs.iter().map(|p| p.as_str().to_string()).collect::<Vec<_>>(), vec![AC.to_string(), bat_path(0)]);
    assert!(get::<bool>(&c, &d, UP, "org.freedesktop.UPower", "OnBattery").await);
    let pct: f64 = get(&c, &d, DISPLAY, "org.freedesktop.UPower.Device", "Percentage").await;
    assert!((pct - 74.33).abs() < 0.01, "{pct}");
    assert_eq!(get::<u32>(&c, &d, DISPLAY, "org.freedesktop.UPower.Device", "Type").await, 2);
    assert_eq!(get::<u32>(&c, &d, DISPLAY, "org.freedesktop.UPower.Device", "State").await, 2);
    assert_eq!(get::<i64>(&c, &d, DISPLAY, "org.freedesktop.UPower.Device", "TimeToEmpty").await, (62.04 / 12.0 * 3600.0) as i64);
    assert!(get::<bool>(&c, &d, DISPLAY, "org.freedesktop.UPower.Device", "IsPresent").await);
    assert!(!get::<bool>(&c, &d, AC, "org.freedesktop.UPower.Device", "Online").await);
    assert_eq!(get::<String>(&c, &d, DISPLAY, "org.freedesktop.UPower.Device", "IconName").await, "battery-level-70-symbolic");
    // every object answers GetAll (zbus's cache asks for it on the first read)
    for (p, i) in [(UP, "org.freedesktop.UPower"), (DISPLAY, "org.freedesktop.UPower.Device"), (AC, "org.freedesktop.UPower.Device"),
                   (bat_path(0).as_str(), "org.freedesktop.UPower.Device"), (PP, "org.freedesktop.UPower.PowerProfiles")] {
        let pr = fdo::PropertiesProxy::builder(&c).destination(d.clone()).unwrap().path(p.to_string()).unwrap().build().await.unwrap();
        let all = pr.get_all(zbus::names::InterfaceName::try_from(i).unwrap()).await.expect(p);
        assert!(all.len() >= 3, "{p} {i}: {} props", all.len());
    }
    assert_eq!(get::<String>(&c, &d, PP, "org.freedesktop.UPower.PowerProfiles", "ActiveProfile").await, "balanced");
}

#[tokio::test(flavor = "current_thread")]
async fn seat_member_sets_power_saver() {
    let (rec, c, d) = daemon("set", 4242).await;   // a seat member, not root
    let p = zbus::Proxy::new(&c, d.clone(), PP, "org.freedesktop.UPower.PowerProfiles").await.unwrap();
    p.set_property("ActiveProfile", "power-saver").await.expect("a seat member may set");
    let applied = rec.applied.lock().unwrap().clone();
    assert_eq!(applied.len(), 1, "applied once");
    assert_eq!(sys::profile_of(&applied[0]), "power-saver");
    assert!(applied[0].contains("cpu-threshold           1s") && applied[0].contains("autopm"), "other lines kept");
    assert_eq!(get::<String>(&c, &d, PP, "org.freedesktop.UPower.PowerProfiles", "ActiveProfile").await, "power-saver");
    // the same profile again applies nothing
    p.set_property("ActiveProfile", "power-saver").await.unwrap();
    assert_eq!(rec.applied.lock().unwrap().len(), 1);
    // an unknown profile is refused
    assert!(p.set_property("ActiveProfile", "turbo").await.is_err());
    assert_eq!(rec.applied.lock().unwrap().len(), 1);
}

#[tokio::test(flavor = "current_thread")]
async fn plain_user_is_refused_and_nothing_is_written() {
    let (rec, c, d) = daemon("deny", 1000).await;
    let p = zbus::Proxy::new(&c, d.clone(), PP, "org.freedesktop.UPower.PowerProfiles").await.unwrap();
    let e = p.set_property("ActiveProfile", "performance").await.expect_err("must be refused");
    assert!(e.to_string().contains("AccessDenied"), "{e}");
    assert!(rec.applied.lock().unwrap().is_empty(), "nothing applied");
    assert_eq!(*rec.conf.lock().unwrap(), STOCK, "power.conf unchanged");
}
