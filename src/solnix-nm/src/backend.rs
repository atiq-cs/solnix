//! The seam between the D-Bus objects and the system: `Real` runs dladm/ipadm (sys.rs); the tests swap in a recorder
//! that never touches a radio.
use std::future::Future;
use std::pin::Pin;
use std::time::Duration;
use zbus::{fdo, Connection};

use crate::sys;

pub type Fut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;

pub trait Backend: Send + Sync {
    fn links(&self) -> Fut<'_, Vec<sys::Link>>;
    fn scan<'a>(&'a self, link: &'a str) -> Fut<'a, Option<Vec<sys::Bss>>>;
    fn wifi_status<'a>(&'a self, link: &'a str) -> Fut<'a, sys::WifiStatus>;
    fn addr<'a>(&'a self, link: &'a str) -> Fut<'a, Option<(String, u32)>>;
    fn has_default_route(&self) -> Fut<'_, bool>;
    /// Join `ssid` on `link` with the passphrase in `psk_file` (None: open); true once associated.
    fn join<'a>(&'a self, link: &'a str, ssid: &'a str, psk_file: Option<&'a str>, secs: u64) -> Fut<'a, bool>;
    fn disconnect<'a>(&'a self, link: &'a str) -> Fut<'a, bool>;
    fn set_hold(&self, link: &str, on: bool);
    /// The uid behind a bus name (org.freedesktop.DBus.GetConnectionUnixUser).
    fn caller_uid<'a>(&'a self, conn: &'a Connection, sender: &'a str) -> Fut<'a, fdo::Result<u32>>;
    fn user_in_group(&self, uid: u32, gid: u32) -> bool;
    /// How long to wait between DHCP polls after a join.
    fn poll(&self) -> Duration { Duration::from_secs(2) }
}

pub struct Real;

impl Backend for Real {
    fn links(&self) -> Fut<'_, Vec<sys::Link>> { Box::pin(sys::links()) }
    fn scan<'a>(&'a self, link: &'a str) -> Fut<'a, Option<Vec<sys::Bss>>> { Box::pin(sys::scan(link)) }
    fn wifi_status<'a>(&'a self, link: &'a str) -> Fut<'a, sys::WifiStatus> { Box::pin(sys::wifi_status(link)) }
    fn addr<'a>(&'a self, link: &'a str) -> Fut<'a, Option<(String, u32)>> { Box::pin(sys::addr(link)) }
    fn has_default_route(&self) -> Fut<'_, bool> { Box::pin(sys::has_default_route()) }
    fn join<'a>(&'a self, link: &'a str, ssid: &'a str, psk_file: Option<&'a str>, secs: u64) -> Fut<'a, bool> {
        Box::pin(sys::join(link, ssid, psk_file, secs))
    }
    fn disconnect<'a>(&'a self, link: &'a str) -> Fut<'a, bool> { Box::pin(sys::disconnect(link)) }
    fn set_hold(&self, link: &str, on: bool) { sys::set_hold(link, on) }
    fn caller_uid<'a>(&'a self, conn: &'a Connection, sender: &'a str) -> Fut<'a, fdo::Result<u32>> {
        Box::pin(async move {
            let dbus = fdo::DBusProxy::new(conn).await.map_err(|e| fdo::Error::Failed(e.to_string()))?;
            let name = zbus::names::BusName::try_from(sender).map_err(|e| fdo::Error::Failed(e.to_string()))?;
            dbus.get_connection_unix_user(name).await
        })
    }
    fn user_in_group(&self, uid: u32, gid: u32) -> bool { crate::user_in_group(uid, gid) }
}
