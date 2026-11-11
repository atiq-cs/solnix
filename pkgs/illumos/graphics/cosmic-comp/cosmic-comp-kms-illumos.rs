/// illumos: keyboard + mouse from /dev/kbd and /dev/mouse (illumos_input.rs: the keyboard and the TrackPoint),
/// registered the way init_libinput registers libinput. No per-device libinput config exists for these.
#[cfg(target_os = "illumos")]
fn init_vuid_input(dh: &DisplayHandle, session: &LibSeatSession, evlh: &LoopHandle<'static, State>) -> Result<()> {
    evlh.insert_source(illumos_input::VuidSource::new(Some(session.clone())), move |event, _, state| {
        state.process_input_event(event, crate::input::InputBackendId::Normal);
        for output in state.common.shell.read().outputs() {
            state.backend.kms().schedule_render(output);
        }
    })
    .map_err(|err| err.error)
    .context("Failed to initialize illumos input event source")?;
    RelativePointerManagerState::new::<State>(dh);
    Ok(())
}

/// illumos: libinput on its path backend (there is no udevd to enumerate or monitor), with every
/// /dev/input/event* added at start: the evdev minors of solnix's ihid (a precision touchpad), opened through
/// seatd like the DRM node. Properties (ID_INPUT_TOUCHPAD) come from solnix's libudev. No hotplug: a device that
/// appears later needs a compositor restart. ihid puts the touchpad in multitouch mode while this holds it open,
/// and back to mouse mode (consms, the VUID source) when it closes. Without a node this context is empty.
#[cfg(target_os = "illumos")]
fn illumos_libinput_path(session: &LibSeatSession) -> Libinput {
    let mut ctx = Libinput::new_from_path::<LibinputSessionInterface<LibSeatSession>>(session.clone().into());
    let mut nodes: Vec<String> = std::fs::read_dir("/dev/input")
        .map(|d| d.flatten().filter_map(|e| e.file_name().into_string().ok()).filter(|n| n.starts_with("event")).collect())
        .unwrap_or_default();
    nodes.sort();
    for n in nodes {
        let path = format!("/dev/input/{}", n);
        match ctx.path_add_device(&path) {
            Some(_) => tracing::warn!(%path, "illumos: libinput device added"),
            None => tracing::warn!(%path, "illumos: libinput could not add the device"),
        }
    }
    ctx
}
