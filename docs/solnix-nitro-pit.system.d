* solnix: the AWS Nitro emulated i8254 PIT is unreliable on 16-vCPU cold boot;
* the legacy PIT calibration (tsc_pit_also -> tsc_calibrate_pit -> freq_tsc_pit)
* intermittently wedges startup_tsc() before device probe (~11%/boot). The TSC
* freq comes from the VMware/hypervisor CPUID leaf and the APIC calibrates off the
* TSC, so the PIT path is pure legacy diagnostics. pit_is_broken=1 makes both
* tsc_calibrate_pit() and apic_calibrate_pit() short-circuit before any PIT I/O.
set pit_is_broken = 1
