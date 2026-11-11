//! The account files solnix-accounts answers from: /etc/passwd, group, shadow, user_attr(5) and login.defs, read fresh
//! on every call (no cache), so a change made by an activation or by usermod shows on the next read.
use std::path::PathBuf;

/// RBAC's root-equivalent profile (prof_attr: `Primary Administrator`, exec_attr `*` with uid=0): pfexec runs anything.
pub const ADMIN_PROFILE: &str = "Primary Administrator";
/// The illumos administrators' group (gid 14), the nearest thing to wheel.
pub const ADMIN_GROUP: &str = "sysadmin";

#[derive(Clone, Debug, PartialEq)]
pub struct Pw { pub name: String, pub uid: u32, pub gid: u32, pub gecos: String, pub home: String, pub shell: String }

/// `root` is "/" on a system; the tests and the lixi check point it at a copy.
pub struct Etc { pub root: PathBuf }

impl Etc {
    fn read(&self, rel: &str) -> String { std::fs::read_to_string(self.root.join(rel)).unwrap_or_default() }

    pub fn passwd(&self) -> Vec<Pw> {
        self.read("etc/passwd").lines().filter_map(|l| {
            let f: Vec<&str> = l.split(':').collect();
            if f.len() < 7 { return None; }
            Some(Pw { name: f[0].into(), uid: f[2].parse().ok()?, gid: f[3].parse().ok()?, gecos: f[4].into(), home: f[5].into(), shell: f[6].into() })
        }).collect()
    }
    /// The first entry, as getpwuid(3C) returns it.
    pub fn by_uid(&self, uid: u32) -> Option<Pw> { self.passwd().into_iter().find(|p| p.uid == uid) }
    pub fn by_name(&self, name: &str) -> Option<Pw> { self.passwd().into_iter().find(|p| p.name == name) }

    /// AccountType 1: root, a user with the Primary Administrator profile or the root role in user_attr, or a member of
    /// sysadmin. accounts-daemon's rule is uid 0 or a member of its admin group (NixOS: wheel); illumos grants
    /// administration through RBAC, which `pfexec` and solnix's sudo honour.
    /// shortcut: profiles nested in prof_attr and policy.conf's PROFS_GRANTED are not followed; follow them if a site
    /// grants Primary Administrator that way.
    pub fn is_admin(&self, pw: &Pw) -> bool {
        pw.uid == 0
            || self.user_attr(&pw.name).iter().any(|(k, v)| (k == "profiles" && v.iter().any(|p| p == ADMIN_PROFILE)) || (k == "roles" && v.iter().any(|r| r == "root")))
            || self.in_group(pw, ADMIN_GROUP)
    }

    fn in_group(&self, pw: &Pw, group: &str) -> bool {
        self.read("etc/group").lines().any(|l| {
            let f: Vec<&str> = l.split(':').collect();
            f.len() > 3 && f[0] == group && (f[2].parse::<u32>().ok() == Some(pw.gid) || f[3].split(',').any(|m| m == pw.name))
        })
    }

    /// The user's user_attr(5) attributes (key, values), from the first line that names the user, as getusernam(3SECDB).
    pub fn user_attr(&self, name: &str) -> Vec<(String, Vec<String>)> {
        let text = self.read("etc/user_attr");
        let Some(attr) = text.lines().filter(|l| !l.starts_with('#')).map(|l| split_esc(l, ':'))
            .find(|f| f.len() > 4 && unesc(f[0]) == name).map(|f| f[4..].join(":")) else { return vec![] };
        split_esc(&attr, ';').into_iter().filter_map(|kv| {
            let (k, v) = kv.split_once('=')?;
            Some((unesc(k), split_esc(v, ',').into_iter().map(unesc).collect()))
        }).collect()
    }

    /// passwd -l writes *LK* in front of the hash (shadow(5)).
    pub fn locked(&self, name: &str) -> bool {
        self.read("etc/shadow").lines().filter_map(|l| l.split_once(':')).any(|(n, rest)| n == name && rest.starts_with("*LK*"))
    }

    /// A person's account, not a system one: a uid in login.defs' UID_MIN..UID_MAX (cosmic-settings' own defaults,
    /// 1000..60000, when the file has none) and a login shell (accounts-daemon's user-classify: not false or nologin).
    pub fn is_human(&self, pw: &Pw) -> bool {
        let (mut lo, mut hi) = (1000, 60000);
        for l in self.read("etc/login.defs").lines() {
            let mut w = l.split_whitespace();
            match (w.next(), w.next().and_then(|v| v.parse().ok())) {
                (Some("UID_MIN"), Some(v)) => lo = v,
                (Some("UID_MAX"), Some(v)) => hi = v,
                _ => {}
            }
        }
        let sh = pw.shell.rsplit('/').next().unwrap_or("");
        (lo..=hi).contains(&pw.uid) && sh != "false" && sh != "nologin"
    }
}

/// Split on `sep` where it is not escaped with a backslash (user_attr's `\:`, `\;`, `\,`); escapes are kept.
fn split_esc(s: &str, sep: char) -> Vec<&str> {
    let (mut out, mut start, mut esc) = (vec![], 0, false);
    for (i, c) in s.char_indices() {
        if esc { esc = false } else if c == '\\' { esc = true } else if c == sep { out.push(&s[start..i]); start = i + 1; }
    }
    out.push(&s[start..]);
    out
}

fn unesc(s: &str) -> String {
    let (mut o, mut esc) = (String::new(), false);
    for c in s.chars() { if !esc && c == '\\' { esc = true } else { o.push(c); esc = false } }
    o
}

#[cfg(test)]
mod t {
    use super::*;
    #[test]
    fn user_attr_escapes() {
        // root's line on lixi: an escaped colon inside audit_flags must not end the field
        let l = r"root::::auths=solaris.*,solaris.grant;profiles=All;audit_flags=lo\:no;lock_after_retries=no";
        let f = split_esc(l, ':');
        assert_eq!(f.len(), 5, "{f:?}");
        let a: Vec<(String, Vec<String>)> = split_esc(f[4], ';').into_iter().filter_map(|kv| { let (k, v) = kv.split_once('=')?;
            Some((unesc(k), split_esc(v, ',').into_iter().map(unesc).collect())) }).collect();
        assert_eq!(a[0], ("auths".into(), vec!["solaris.*".into(), "solaris.grant".into()]));
        assert_eq!(a[2], ("audit_flags".into(), vec!["lo:no".into()]));
    }
}
