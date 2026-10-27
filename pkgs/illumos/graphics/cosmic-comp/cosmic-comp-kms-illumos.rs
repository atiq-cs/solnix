/// illumos: keyboard + mouse from /dev/kbd and /dev/mouse (illumos_input.rs), registered
/// the way init_libinput registers libinput. No per-device libinput config exists here.
#[cfg(target_os = "illumos")]
fn init_vuid_input(dh: &DisplayHandle, evlh: &LoopHandle<'static, State>) -> Result<()> {
    evlh.insert_source(illumos_input::VuidSource::new(), move |event, _, state| {
        state.process_input_event(event);
        for output in state.common.shell.read().outputs() {
            state.backend.kms().schedule_render(output);
        }
    })
    .map_err(|err| err.error)
    .context("Failed to initialize illumos input event source")?;
    RelativePointerManagerState::new::<State>(dh);
    Ok(())
}
