//! org.freedesktop.timedate1 on a private session bus (run under dbus-run-session), over a temp root (etc/default/init,
//! passwd, group, user_attr) and a small zone tree (TZif files, a posix/ copy, a tab/ dir, a non-TZif file). The calls
//! go through a zbus proxy as timedate_zbus::TimeDateProxy makes them (cosmic-settings pages/time/date.rs).
//! Negative controls: a non-administrator's SetTimezone is refused and the file is unchanged; an unknown zone and a
//! path that escapes the tree are refused.
use super::*;
use std::collections::HashMap;
use std::sync::Mutex as StdMutex;

const INIT: &str = "TZ=America/New_York\nLANG=en_US.UTF-8\nLC_ALL=en_US.UTF-8\nUMASK=022\n";
const PASSWD: &str = "root:x:0:0:Super-User:/root:/usr/bin/bash\nalice:x:1000:10:Alice:/home/alice:/usr/bin/bash\n\
plain:x:1001:10:Plain:/home/plain:/usr/bin/bash\nops:x:1002:10:Ops:/home/ops:/usr/bin/bash\n";
const GROUP: &str = "root::0:\nstaff::10:\nsysadmin::14:ops\n";
const USER_ATTR: &str = "#\nroot::::auths=solaris.*;profiles=All;audit_flags=lo\\:no\nalice::::type=normal;profiles=Primary Administrator\n\
plain::::type=normal;profiles=Basic Solaris User,All\n";

/// the caller's uid by its unique bus name; the test sets it before each call
struct Table(Arc<StdMutex<u32>>);
impl Caller for Table {
    fn uid<'a>(&'a self, _c: &'a Connection, _s: &'a str) -> std::pin::Pin<Box<dyn std::future::Future<Output = fdo::Result<u32>> + Send + 'a>> {
        let u = *self.0.lock().unwrap(); Box::pin(async move { Ok(u) })
    }
}

fn tree(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("solnix-timedate-test-{}-{tag}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    for (f, t) in [("etc/default/init", INIT), ("etc/passwd", PASSWD), ("etc/group", GROUP), ("etc/user_attr", USER_ATTR)] {
        let p = d.join(f); std::fs::create_dir_all(p.parent().unwrap()).unwrap(); std::fs::write(p, t).unwrap();
    }
    let z = d.join("zoneinfo");
    for f in ["America/New_York", "America/Argentina/Buenos_Aires", "Europe/Paris", "UTC", "Etc/GMT+5", "posix/Europe/Paris", "right/UTC", "posixrules"] {
        let p = z.join(f); std::fs::create_dir_all(p.parent().unwrap()).unwrap(); std::fs::write(p, b"TZif2\0\0\0").unwrap();
    }
    std::fs::create_dir_all(z.join("tab")).unwrap();
    std::fs::write(z.join("tab/zone_sun.tab"), "AD\t+4230+00131\tEurope/Andorra\t-\n").unwrap();
    std::fs::write(z.join("Europe/README"), "not a zone\n").unwrap();
    d
}

async fn daemon(tag: &str) -> (PathBuf, Connection, String, Arc<StdMutex<u32>>) {
    let d = tree(tag);
    let conn = zbus::connection::Builder::session().unwrap().build().await.expect("a session bus: run under dbus-run-session");
    let uid = Arc::new(StdMutex::new(1000));
    let ctx = Arc::new(Ctx { root: d.clone(), zoneinfo: d.join("zoneinfo"), conn: conn.clone(), be: Box::new(Table(uid.clone())) });
    serve(&ctx).await.unwrap();
    let name = format!("org.solnix.timedatetest.t{}{tag}", std::process::id());
    conn.request_name(name.as_str()).await.unwrap();
    (d, zbus::connection::Builder::session().unwrap().build().await.unwrap(), name, uid)
}

async fn proxy(c: &Connection, dest: &str) -> zbus::Proxy<'static> {
    zbus::proxy::Builder::new(c).destination(dest.to_string()).unwrap().path(PATH).unwrap()
        .interface("org.freedesktop.timedate1").unwrap().cache_properties(zbus::proxy::CacheProperties::No).build().await.unwrap()
}

#[tokio::test(flavor = "current_thread")]
async fn lists_zones_and_reads_tz() {
    let (d, c, n, _) = daemon("list").await;
    let p = proxy(&c, &n).await;
    let z: Vec<String> = p.call("ListTimezones", &()).await.unwrap();
    assert_eq!(z, vec!["America/Argentina/Buenos_Aires", "America/New_York", "Etc/GMT+5", "Europe/Paris", "UTC"],
               "TZif files only, sorted; no posix/, right/, tab/, posixrules or non-zone files");
    assert_eq!(p.get_property::<String>("Timezone").await.unwrap(), "America/New_York");
    assert!(!p.get_property::<bool>("NTP").await.unwrap());
    assert!(!p.get_property::<bool>("CanNTP").await.unwrap());
    // TZ unset: UTC, as illumos libc takes it
    std::fs::write(d.join("etc/default/init"), "LANG=C\n").unwrap();
    assert_eq!(p.get_property::<String>("Timezone").await.unwrap(), "UTC");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test(flavor = "current_thread")]
async fn admin_sets_the_zone_others_are_refused() {
    let (d, c, n, uid) = daemon("set").await;
    let p = proxy(&c, &n).await;
    let init = d.join("etc/default/init");
    // NEG: plain (no administration profile) is refused, the file is untouched
    *uid.lock().unwrap() = 1001;
    let r: zbus::Result<()> = p.call("SetTimezone", &("Europe/Paris", false)).await;
    assert!(matches!(&r, Err(zbus::Error::MethodError(e, _, _)) if e.as_str() == "org.freedesktop.timedate1.AccessDenied"), "{r:?}");
    assert_eq!(std::fs::read_to_string(&init).unwrap(), INIT);
    // alice (Primary Administrator): TZ= rewritten, the other lines kept, PropertiesChanged announces it
    *uid.lock().unwrap() = 1000;
    let rule = zbus::MatchRule::builder().msg_type(zbus::message::Type::Signal).interface("org.freedesktop.DBus.Properties").unwrap()
        .member("PropertiesChanged").unwrap().path(PATH).unwrap().build();
    let mut ch = zbus::MessageStream::for_match_rule(rule, &c, None).await.unwrap();
    let r: zbus::Result<()> = p.call("SetTimezone", &("Europe/Paris", false)).await;
    assert!(r.is_ok(), "{r:?}");
    assert_eq!(std::fs::read_to_string(&init).unwrap(), INIT.replace("TZ=America/New_York", "TZ=Europe/Paris"));
    let next = std::future::poll_fn(|cx| zbus::export::futures_core::Stream::poll_next(std::pin::Pin::new(&mut ch), cx));
    let m = tokio::time::timeout(std::time::Duration::from_secs(3), next).await.ok().flatten().expect("a PropertiesChanged").unwrap();
    let (iface, changed, _inv): (String, HashMap<String, zbus::zvariant::OwnedValue>, Vec<String>) = m.body().deserialize().unwrap();
    assert_eq!(iface, "org.freedesktop.timedate1");
    assert_eq!(changed.get("Timezone").and_then(|v| String::try_from(v.clone()).ok()).as_deref(), Some("Europe/Paris"), "{changed:?}");
    assert_eq!(p.get_property::<String>("Timezone").await.unwrap(), "Europe/Paris");
    // ops (group sysadmin) and root may too
    for (u, z) in [(1002, "UTC"), (0, "America/Argentina/Buenos_Aires")] {
        *uid.lock().unwrap() = u;
        let r: zbus::Result<()> = p.call("SetTimezone", &(z, false)).await;
        assert!(r.is_ok(), "uid {u}: {r:?}");
        assert_eq!(current(&d), z);
    }
    // NEG: unknown, non-TZif and escaping names are refused, the file keeps the last good zone
    *uid.lock().unwrap() = 0;
    for bad in ["Mars/Olympus", "Europe/README", "../etc/passwd", "/etc/passwd", "posix/../../etc/passwd", ""] {
        let r: zbus::Result<()> = p.call("SetTimezone", &(bad, false)).await;
        assert!(matches!(&r, Err(zbus::Error::MethodError(e, _, _)) if e.as_str() == "org.freedesktop.timedate1.InvalidTimezone"), "{bad:?}: {r:?}");
    }
    assert_eq!(current(&d), "America/Argentina/Buenos_Aires");
    // the other setters keep systemd's member names and answer NotSupported
    let r: zbus::Result<()> = p.call("SetNTP", &(true, false)).await;
    assert!(matches!(&r, Err(zbus::Error::MethodError(e, _, _)) if e.as_str() == "org.freedesktop.timedate1.NotSupported"), "{r:?}");
    let r: zbus::Result<()> = p.call("SetLocalRTC", &(true, false, false)).await;
    assert!(matches!(&r, Err(zbus::Error::MethodError(e, _, _)) if e.as_str() == "org.freedesktop.timedate1.NotSupported"), "{r:?}");
    let r: zbus::Result<()> = p.call("SetTime", &(0i64, true, false)).await;
    assert!(matches!(&r, Err(zbus::Error::MethodError(e, _, _)) if e.as_str() == "org.freedesktop.timedate1.NotSupported"), "{r:?}");
    let _ = std::fs::remove_dir_all(&d);
}

#[test]
fn file_edits() {
    assert_eq!(with_zone(INIT, "UTC"), INIT.replace("America/New_York", "UTC"));
    assert_eq!(with_zone("LANG=C\n", "UTC"), "LANG=C\nTZ=UTC\n");
    assert_eq!(with_zone("TZ=A\nX=1\nTZ=B\n", "UTC"), "TZ=UTC\nX=1\nTZ=B\n");
    let d = tree("edits");
    std::fs::write(d.join("etc/default/init"), "TZ=:US/Eastern\n").unwrap();
    assert_eq!(current(&d), "US/Eastern");
    let m: HashMap<&str, bool> = [("America/New_York", true), ("Etc/GMT-14", true), ("..", false), ("a/./b", false), ("a//b", false), ("-x", false)].into();
    for (z, ok) in m { assert_eq!(valid_zone(z), ok, "{z}"); }
    let _ = std::fs::remove_dir_all(&d);
}
