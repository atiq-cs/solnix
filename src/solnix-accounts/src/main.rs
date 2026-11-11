//! solnix-accounts: a read-only org.freedesktop.Accounts for COSMIC Settings > Users, over the illumos account files.
//! cosmic-settings 1.11 (pages/system/users/mod.rs reload) reads two properties per listed user through
//! accounts_zbus::UserProxy::from_uid: AccountType (1 shows "Administrator") and IconFile. Without this service both
//! reads fail and the page falls back to "admin iff in group sudo", so on solnix nobody is an administrator.
//! Here AccountType follows illumos RBAC (etc.rs is_admin). Every Set* method and CreateUser/DeleteUser answer
//! org.freedesktop.Accounts.Error.NotSupported: editing accounts from COSMIC is not supported yet. MIT. Runs as root
//! under SMF (it reads /etc/shadow for Locked) and writes nothing.
mod etc;
#[cfg(test)]
mod tests;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;
use zbus::object_server::SignalEmitter;
use zbus::zvariant::{ObjectPath, OwnedObjectPath};
use zbus::{fdo, interface, Connection};

pub const ROOT: &str = "/org/freedesktop/Accounts";
pub fn user_path(uid: u32) -> OwnedObjectPath { OwnedObjectPath::try_from(format!("{ROOT}/User{uid}")).unwrap() }

/// accounts-daemon's own error names, so a client that matches them (cosmic-settings asks polkit only on
/// PermissionDenied, which this service never returns) sees what it expects.
#[derive(Debug, zbus::DBusError)]
#[zbus(prefix = "org.freedesktop.Accounts.Error")]
pub enum Error {
    #[zbus(error)]
    ZBus(zbus::Error),
    Failed(String),
    NotSupported(String),
}
fn read_only<T>() -> Result<T, Error> {
    Err(Error::NotSupported("solnix-accounts is read-only: change accounts in the system configuration (users.users)".into()))
}

pub struct Ctx { pub etc: etc::Etc, pub conn: Connection, known: Mutex<BTreeMap<u32, bool>> }

// ---- org.freedesktop.Accounts ---------------------------------------------------------------------------------------
struct Accounts(Arc<Ctx>);
#[interface(name = "org.freedesktop.Accounts")]
impl Accounts {
    async fn find_user_by_id(&self, id: i64) -> Result<OwnedObjectPath, Error> {
        let uid = u32::try_from(id).ok().filter(|u| self.0.etc.by_uid(*u).is_some())
            .ok_or_else(|| Error::Failed(format!("Failed to look up user with uid {id}.")))?;
        sync(&self.0).await;
        Ok(user_path(uid))
    }
    async fn find_user_by_name(&self, name: &str) -> Result<OwnedObjectPath, Error> {
        let pw = self.0.etc.by_name(name).ok_or_else(|| Error::Failed(format!("Failed to look up user with name {name}.")))?;
        sync(&self.0).await;
        Ok(user_path(pw.uid))
    }
    /// The people's accounts (not system ones), as accounts-daemon lists them.
    async fn list_cached_users(&self) -> Vec<OwnedObjectPath> {
        sync(&self.0).await;
        self.0.known.lock().await.iter().filter(|(_, human)| **human).map(|(u, _)| user_path(*u)).collect()
    }
    async fn create_user(&self, _name: &str, _fullname: &str, _account_type: i32) -> Result<OwnedObjectPath, Error> { read_only() }
    async fn delete_user(&self, _id: i64, _remove_files: bool) -> Result<(), Error> { read_only() }
    #[zbus(signal)] async fn user_added(e: &SignalEmitter<'_>, user: ObjectPath<'_>) -> zbus::Result<()>;
    #[zbus(signal)] async fn user_deleted(e: &SignalEmitter<'_>, user: ObjectPath<'_>) -> zbus::Result<()>;
}

// ---- org.freedesktop.Accounts.User ----------------------------------------------------------------------------------
/// One passwd uid. Every property re-reads the files, so the answer is current.
struct User(Arc<Ctx>, u32);
impl User {
    fn pw(&self) -> fdo::Result<etc::Pw> { self.0.etc.by_uid(self.1).ok_or_else(|| fdo::Error::Failed(format!("no user with uid {}", self.1))) }
}

#[interface(name = "org.freedesktop.Accounts.User")]
impl User {
    #[zbus(property)] async fn user_name(&self) -> fdo::Result<String> { Ok(self.pw()?.name) }
    /// The GECOS name up to the first comma, unless it reads "Last, First" (accounts-daemon's rule).
    #[zbus(property)] async fn real_name(&self) -> fdo::Result<String> {
        let g = self.pw()?.gecos;
        Ok(match g.split_once(',') { Some((a, b)) if !(b.starts_with(' ') && !b.contains(',')) => a.to_string(), _ => g })
    }
    #[zbus(property)] async fn uid(&self) -> fdo::Result<u64> { Ok(self.pw()?.uid.into()) }
    /// 1 = administrator, 0 = standard (etc.rs is_admin).
    #[zbus(property)] async fn account_type(&self) -> fdo::Result<i32> { Ok(self.0.etc.is_admin(&self.pw()?) as i32) }
    /// ~/.face when it exists (accounts-daemon's default icon); otherwise an error, which cosmic-settings shows as its
    /// default icon. GetAll leaves the property out then.
    #[zbus(property)] async fn icon_file(&self) -> fdo::Result<String> {
        let face = std::path::Path::new(&self.pw()?.home).join(".face");
        if face.is_file() { Ok(face.to_string_lossy().into_owned()) } else { Err(fdo::Error::Failed("no icon".into())) }
    }
    #[zbus(property)] async fn locked(&self) -> fdo::Result<bool> { Ok(self.0.etc.locked(&self.pw()?.name)) }
    #[zbus(property)] async fn home_directory(&self) -> fdo::Result<String> { Ok(self.pw()?.home) }
    #[zbus(property)] async fn shell(&self) -> fdo::Result<String> { Ok(self.pw()?.shell) }
    #[zbus(property)] async fn system_account(&self) -> fdo::Result<bool> { Ok(!self.0.etc.is_human(&self.pw()?)) }
    #[zbus(property)] async fn local_account(&self) -> bool { true }

    // what cosmic-settings calls to edit (users/mod.rs, time/region.rs): not supported yet
    async fn set_account_type(&self, _account_type: i32) -> Result<(), Error> { read_only() }
    async fn set_password(&self, _password: &str, _hint: &str) -> Result<(), Error> { read_only() }
    async fn set_real_name(&self, _name: &str) -> Result<(), Error> { read_only() }
    async fn set_user_name(&self, _name: &str) -> Result<(), Error> { read_only() }
    async fn set_icon_file(&self, _filename: &str) -> Result<(), Error> { read_only() }
    async fn set_language(&self, _language: &str) -> Result<(), Error> { read_only() }
}

/// One object per passwd uid (the first entry for a uid, as getpwuid). New and removed uids are announced with
/// UserAdded/UserDeleted, for people's accounts only, as accounts-daemon does.
pub async fn sync(ctx: &Arc<Ctx>) {
    let now: BTreeMap<u32, bool> = ctx.etc.passwd().into_iter().rev().map(|p| (p.uid, ctx.etc.is_human(&p))).collect();
    let mut known = ctx.known.lock().await;
    let os = ctx.conn.object_server();
    let Ok(e) = SignalEmitter::new(&ctx.conn, ROOT) else { return };
    for (&uid, &human) in &now {
        if known.contains_key(&uid) { continue; }
        if os.at(user_path(uid).as_str(), User(ctx.clone(), uid)).await.is_ok() && human { let _ = Accounts::user_added(&e, user_path(uid).into_inner()).await; }
    }
    for (&uid, &human) in known.iter().filter(|(u, _)| !now.contains_key(u)) {
        let _ = os.remove::<User, _>(user_path(uid).as_str()).await;
        if human { let _ = Accounts::user_deleted(&e, user_path(uid).into_inner()).await; }
    }
    *known = now;
}

pub async fn serve(etc: etc::Etc, conn: Connection) -> zbus::Result<Arc<Ctx>> {
    let ctx = Arc::new(Ctx { etc, conn: conn.clone(), known: Mutex::new(BTreeMap::new()) });
    conn.object_server().at(ROOT, Accounts(ctx.clone())).await?;
    sync(&ctx).await;
    Ok(ctx)
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let session = std::env::args().any(|a| a == "--session");
    let conn = if session { zbus::connection::Builder::session()? } else { zbus::connection::Builder::system()? }.build().await?;
    // SOLNIX_ACCOUNTS_ROOT: read <dir>/etc/... instead of /etc (the checks run it over a copy)
    let root = std::env::var("SOLNIX_ACCOUNTS_ROOT").unwrap_or("/".into());
    let ctx = serve(etc::Etc { root: root.into() }, conn.clone()).await?;
    conn.request_name("org.freedesktop.Accounts").await?;
    eprintln!("solnix-accounts: on the bus as org.freedesktop.Accounts ({} users)", ctx.known.lock().await.len());
    loop { tokio::time::sleep(Duration::from_secs(10)).await; sync(&ctx).await; }
}
