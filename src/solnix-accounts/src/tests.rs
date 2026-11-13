//! org.freedesktop.Accounts on a private session bus (run under dbus-run-session) over a copy of /etc in a temp dir:
//! the files are a solnix desktop's lines plus test users. The reads go through a zbus proxy built the way accounts_zbus's
//! UserProxy::from_uid builds it (the path, the interface, the default lazy property cache that asks GetAll first).
//! The negative control rewrites user_attr without the profile and the same object must answer 0.
use super::*;
use zbus::proxy::CacheProperties;

const PASSWD: &str = "root:x:0:0:Super-User:/root:/usr/bin/bash\n\
alice:x:1000:10:Alice Liddell:/HOME/alice:/usr/bin/bash\n\
plain:x:1001:10:Plain User, Room 4,555:/HOME/plain:/usr/bin/bash\n\
ops:x:1002:10:Doe, Jane:/HOME/ops:/usr/bin/bash\n\
roler:x:1003:10::/HOME/roler:/usr/bin/bash\n\
nixbld1:x:30001:30000:Nix build user 1:/var/empty:/bin/false\n\
cosmic-greeter:x:30080:30080:COSMIC login greeter user:/var/lib/cosmic-greeter:/usr/bin/false\n";
const GROUP: &str = "root::0:\nstaff::10:\nsysadmin::14:ops\nseat::30082:cosmic-greeter,alice\n";
const SHADOW: &str = "root:$5$x:::::::\nalice:$5$y:::::::\nplain:*LK*$5$z:::::::\nops:NP:::::::\n";
// a solnix desktop's /etc/user_attr (comments, the stock lines, root's escaped colon, the desktop user's line as alice's) and the test users
const USER_ATTR: &str = "#\n# /etc/user_attr\n#\nadm::::profiles=Log Management\n\
netadm::::type=role;project=default;profiles=Network Autoconf Admin,Network Management,Service Management\n\
root::::auths=solaris.*,solaris.grant;profiles=All;audit_flags=lo\\:no;lock_after_retries=no;min_label=admin_low;clearance=admin_high\n\
alice::::type=normal;profiles=Primary Administrator\n\
plain::::type=normal;profiles=Basic Solaris User,All\n\
roler::::type=normal;roles=root\n";
const LOGIN_DEFS: &str = "UID_MIN 1000\nUID_MAX 29999\n";

fn etc_dir(tag: &str) -> std::path::PathBuf {
    let d = std::env::temp_dir().join(format!("solnix-accounts-test-{}-{tag}", std::process::id()));
    std::fs::create_dir_all(d.join("etc")).unwrap();
    for (f, t) in [("passwd", PASSWD), ("group", GROUP), ("shadow", SHADOW), ("user_attr", USER_ATTR), ("login.defs", LOGIN_DEFS)] {
        std::fs::write(d.join("etc").join(f), t).unwrap();
    }
    let homes = PASSWD.replace("/HOME/", &format!("{}/home/", d.display()));
    std::fs::write(d.join("etc/passwd"), homes).unwrap();
    for u in ["alice", "plain", "ops", "roler"] { std::fs::create_dir_all(d.join("home").join(u)).unwrap(); }
    d
}

async fn daemon(tag: &str) -> (std::path::PathBuf, Connection, String) {
    let d = etc_dir(tag);
    let conn = zbus::connection::Builder::session().unwrap().build().await.expect("a session bus: run under dbus-run-session");
    serve(etc::Etc { root: d.clone() }, conn.clone()).await.unwrap();
    let name = format!("org.solnix.accountstest.t{}{tag}", std::process::id());
    conn.request_name(name.as_str()).await.unwrap();
    (d, zbus::connection::Builder::session().unwrap().build().await.unwrap(), name)
}

/// accounts_zbus::UserProxy::from_uid's proxy: path User<uid>, the User interface, the lazy cache (GetAll first).
async fn user(c: &Connection, dest: &str, uid: u32) -> zbus::Proxy<'static> {
    zbus::proxy::Builder::new(c).destination(dest.to_string()).unwrap().path(format!("{ROOT}/User{uid}")).unwrap()
        .interface("org.freedesktop.Accounts.User").unwrap().cache_properties(CacheProperties::Lazily).build().await.unwrap()
}
async fn account_type(c: &Connection, d: &str, uid: u32) -> i32 { user(c, d, uid).await.get_property::<i32>("AccountType").await.unwrap() }

#[tokio::test(flavor = "current_thread")]
async fn admin_follows_rbac() {
    let (_d, c, d) = daemon("rbac").await;
    assert_eq!(account_type(&c, &d, 1000).await, 1, "alice: Primary Administrator (the desktop user's real line)");
    assert_eq!(account_type(&c, &d, 1001).await, 0, "plain: Basic Solaris User and All are not administration");
    assert_eq!(account_type(&c, &d, 1002).await, 1, "ops: in sysadmin");
    assert_eq!(account_type(&c, &d, 1003).await, 1, "roler: may assume the root role");
    assert_eq!(account_type(&c, &d, 0).await, 1, "root");
    assert_eq!(account_type(&c, &d, 30001).await, 0, "nixbld1");
}

#[tokio::test(flavor = "current_thread")]
async fn removing_the_profile_makes_a_standard_user() {
    let (dir, c, d) = daemon("negctl").await;
    assert_eq!(account_type(&c, &d, 1000).await, 1);
    std::fs::write(dir.join("etc/user_attr"), USER_ATTR.replace("alice::::type=normal;profiles=Primary Administrator", "alice::::type=normal")).unwrap();
    // a fresh proxy (cosmic-settings makes one per page load) reads the file as it is now
    assert_eq!(account_type(&c, &d, 1000).await, 0, "negative control: no profile, not an administrator");
    std::fs::write(dir.join("etc/user_attr"), USER_ATTR.replace("profiles=Primary Administrator", "profiles=Basic Solaris User,Primary Administrator")).unwrap();
    assert_eq!(account_type(&c, &d, 1000).await, 1, "the profile among others");
}

#[tokio::test(flavor = "current_thread")]
async fn the_page_reads_and_getall() {
    let (dir, c, d) = daemon("reads").await;
    let g = user(&c, &d, 1000).await;
    assert_eq!(g.get_property::<String>("UserName").await.unwrap(), "alice");
    assert_eq!(g.get_property::<String>("RealName").await.unwrap(), "Alice Liddell");
    assert_eq!(g.get_property::<u64>("Uid").await.unwrap(), 1000);
    assert_eq!(g.get_property::<String>("HomeDirectory").await.unwrap(), dir.join("home/alice").display().to_string());
    assert_eq!(g.get_property::<String>("Shell").await.unwrap(), "/usr/bin/bash");
    assert!(!g.get_property::<bool>("Locked").await.unwrap());
    assert!(!g.get_property::<bool>("SystemAccount").await.unwrap());
    // no ~/.face: IconFile fails (cosmic-settings shows its default icon), and GetAll still answers
    assert!(g.get_property::<String>("IconFile").await.is_err());
    let props = fdo::PropertiesProxy::builder(&c).destination(d.clone()).unwrap().path(format!("{ROOT}/User1000")).unwrap().build().await.unwrap();
    let all = props.get_all(zbus::names::InterfaceName::try_from("org.freedesktop.Accounts.User").unwrap()).await.expect("GetAll");
    assert!(all.contains_key("AccountType") && !all.contains_key("IconFile"), "{:?}", all.keys());
    std::fs::write(dir.join("home/alice/.face"), b"png").unwrap();
    assert_eq!(user(&c, &d, 1000).await.get_property::<String>("IconFile").await.unwrap(), dir.join("home/alice/.face").display().to_string());
    // RealName: up to the first comma, but "Last, First" whole (accounts-daemon)
    assert_eq!(user(&c, &d, 1001).await.get_property::<String>("RealName").await.unwrap(), "Plain User");
    assert_eq!(user(&c, &d, 1002).await.get_property::<String>("RealName").await.unwrap(), "Doe, Jane");
    assert!(user(&c, &d, 1001).await.get_property::<bool>("Locked").await.unwrap(), "plain: *LK*");
    assert!(user(&c, &d, 30080).await.get_property::<bool>("SystemAccount").await.unwrap());
}

#[tokio::test(flavor = "current_thread")]
async fn find_and_list() {
    let (dir, c, d) = daemon("find").await;
    let a = zbus::Proxy::new(&c, d.clone(), ROOT, "org.freedesktop.Accounts").await.unwrap();
    let p: OwnedObjectPath = a.call("FindUserByName", &("alice",)).await.unwrap();
    assert_eq!(p.as_str(), format!("{ROOT}/User1000"));
    let p: OwnedObjectPath = a.call("FindUserById", &(1001i64,)).await.unwrap();
    assert_eq!(p.as_str(), format!("{ROOT}/User1001"));
    assert!(a.call::<_, _, OwnedObjectPath>("FindUserByName", &("nobody-here",)).await.is_err());
    assert!(a.call::<_, _, OwnedObjectPath>("FindUserById", &(-1i64,)).await.is_err());
    let l: Vec<OwnedObjectPath> = a.call("ListCachedUsers", &()).await.unwrap();
    assert_eq!(l.iter().map(|p| p.as_str().to_string()).collect::<Vec<_>>(),
               [1000, 1001, 1002, 1003].map(|u| format!("{ROOT}/User{u}")), "people only, not root, nixbld or the greeter");
    // a user added to passwd is found (and gets an object) without a restart
    let mut pw = std::fs::read_to_string(dir.join("etc/passwd")).unwrap(); pw.push_str("newbie:x:1004:10:New:/nonexistent:/usr/bin/bash\n");
    std::fs::write(dir.join("etc/passwd"), pw).unwrap();
    let p: OwnedObjectPath = a.call("FindUserByName", &("newbie",)).await.unwrap();
    assert_eq!(account_type(&c, &d, 1004).await, 0, "{p}");
}

#[tokio::test(flavor = "current_thread")]
async fn edits_are_not_supported_and_change_nothing() {
    let (dir, c, d) = daemon("ro").await;
    let before: Vec<String> = ["passwd", "group", "shadow", "user_attr"].iter().map(|f| std::fs::read_to_string(dir.join("etc").join(f)).unwrap()).collect();
    let g = user(&c, &d, 1001).await;
    let a = zbus::Proxy::new(&c, d.clone(), ROOT, "org.freedesktop.Accounts").await.unwrap();
    let errs = [
        g.call::<_, _, ()>("SetAccountType", &(1i32,)).await.unwrap_err(),
        g.call::<_, _, ()>("SetPassword", &("$5$hash", "")).await.unwrap_err(),
        g.call::<_, _, ()>("SetRealName", &("X",)).await.unwrap_err(),
        g.call::<_, _, ()>("SetUserName", &("x",)).await.unwrap_err(),
        g.call::<_, _, ()>("SetIconFile", &("/tmp/x.png",)).await.unwrap_err(),
        g.call::<_, _, ()>("SetLanguage", &("de_DE",)).await.unwrap_err(),
        a.call::<_, _, OwnedObjectPath>("CreateUser", &("x", "X", 1i32)).await.unwrap_err(),
        a.call::<_, _, ()>("DeleteUser", &(1001i64, false)).await.unwrap_err(),
    ];
    for e in errs {
        // NotSupported, never PermissionDenied: on PermissionDenied cosmic-settings would ask polkit and retry
        assert!(matches!(&e, zbus::Error::MethodError(n, _, _) if n.as_str() == "org.freedesktop.Accounts.Error.NotSupported"), "{e}");
    }
    let after: Vec<String> = ["passwd", "group", "shadow", "user_attr"].iter().map(|f| std::fs::read_to_string(dir.join("etc").join(f)).unwrap()).collect();
    assert_eq!(before, after);
    assert_eq!(account_type(&c, &d, 1001).await, 0);
}
