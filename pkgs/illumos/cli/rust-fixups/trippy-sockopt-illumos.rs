
// socket2 0.5 has no set_tos/set_tclass_v6/set_reuse_port for illumos; illumos has IP_TOS and IPV6_TCLASS
// (setsockopt, int) but no SO_REUSEPORT, so that one is a no-op here.
#[cfg(target_os = "illumos")]
#[allow(unsafe_code)]
mod sockopt_illumos {
    use nix::libc;
    use std::os::fd::AsRawFd;
    fn set(s: &socket2::Socket, level: libc::c_int, name: libc::c_int, v: u32) -> std::io::Result<()> {
        let v = v as libc::c_int;
        let n = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
        let r = unsafe { libc::setsockopt(s.as_raw_fd(), level, name, (&v as *const libc::c_int).cast(), n) };
        if r == 0 { Ok(()) } else { Err(std::io::Error::last_os_error()) }
    }
    pub trait SockExt {
        fn set_tos(&self, v: u32) -> std::io::Result<()>;
        fn set_tclass_v6(&self, v: u32) -> std::io::Result<()>;
        fn set_reuse_port(&self, r: bool) -> std::io::Result<()>;
    }
    impl SockExt for socket2::Socket {
        fn set_tos(&self, v: u32) -> std::io::Result<()> { set(self, libc::IPPROTO_IP, libc::IP_TOS, v) }
        fn set_tclass_v6(&self, v: u32) -> std::io::Result<()> { set(self, libc::IPPROTO_IPV6, libc::IPV6_TCLASS, v) }
        fn set_reuse_port(&self, _r: bool) -> std::io::Result<()> { Ok(()) }
    }
}
