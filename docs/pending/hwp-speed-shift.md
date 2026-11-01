# Intel HWP (Speed Shift) for illumos: scope of a port

Status: scoping only. Nothing here is implemented.

## Why

- illumos drives Intel CPU frequency only through ACPI P-states. speedstep.c reads `_PSS`/`_PCT` and writes
  IA32_PERF_CTL, and `cpupm` picks the state: event mode, the elastic policy in common/os/cpu_pm.c.
- Since Skylake, Intel parts have Hardware P-states (HWP, "Speed Shift"). The OS writes a min/max/desired range
  and an energy-performance preference (EPP), and the CPU chooses the frequency itself, every millisecond.
- Linux (intel_pstate active), Windows and FreeBSD (hwpstate_intel) all use HWP when it is present.
- illumos has no HWP code. The gate's uts/intel/sys/x86_archext.h defines CPUID_INTC_EAX_HWP*, but nothing uses
  them.

The X1 Extreme Gen5 (i9-12900H, Alder Lake-P, family 6 model 0x9a):

- Pop!_OS /proc/cpuinfo: `est hwp hwp_notify hwp_act_window hwp_epp hwp_pkg_req`. intel_pstate runs with EPP
  `balance_performance`, between 400 MHz and 4.9 GHz.
- Its tables have no static `_PSS`. SSDT2 "CpuSsdt" (solnix-bank/evidence/x1e-acpi-N3JET48W/ssdt/SSDT2.dsl,
  lines 344-470) loads the per-CPU tables at run time from `_PDC`/`_OSC` (GCAP):
  - the IST table (`_PSS`/`_PCT`) when the OS's capability bits include 0x09 (PS_MSR | MP);
  - the HWP table (`_CPC`) only when OSYS >= 0x07DF and the platform `_OSC` grants bit 0x40 (CPPC/HWP).
- illumos's cpupm_intel_init sends PS_MSR | MP | ... in `_PDC` when speedstep_supported() is true. That function
  requires family 6 model >= 0xe and CPUID.1:ECX.EST, which Alder Lake passes. So the X1E should get the legacy
  `_PSS` P-states, without HWP. This is not yet confirmed on the machine. The check is
  `kstat -p cpu_info:0:cpu_info0:supported_frequencies_Hz`, which lists more than one value if `_PSS` loaded.
- Without HWP, illumos runs P-states through IA32_PERF_CTL. On HWP-capable parts the firmware may have left HWP
  disabled (IA32_PM_ENABLE = 0), and then PERF_CTL works as on older CPUs. If HWP were ever enabled, PERF_CTL
  writes are ignored.
- Separately, cpupm_intel.c writes IA32_ENERGY_PERF_BIAS (MSR 0x1B0) = `cpupm_iepb_policy` on every CPU. That
  defaults to EPB_MAX_PERF (0), "drive to max performance at any energy cost". Linux's intel_epb sets 6 (normal).
  A one-line /etc/system tunable, `set cpupm_iepb_policy = 7`, would match the balanced setting today. It is not
  set on the media: no measurement on the X1E yet shows it matters.

## The model: FreeBSD sys/x86/cpufreq/hwpstate_intel.c (723 lines)

| Piece | FreeBSD | illumos home |
|---|---|---|
| Detection | CPUID.06H:EAX bit 7 (HWP); bits 8/9/10/11 = notification, activity window, EPP, package request | cpuid.c already reads leaf 6 for EST/turbo; add X86FSET_HWP |
| Enable | `wrmsr IA32_PM_ENABLE (0x770) = 1`, package-scoped; only the first write counts, and it cannot be undone without a reset | a new `hwp_init` called from cpupm_intel_init in place of speedstep when HWP is present |
| Capabilities | `IA32_HWP_CAPABILITIES (0x771)`: highest [7:0], guaranteed [15:8], most efficient [23:16], lowest [31:24] | per-CPU, read once at init |
| Request | `IA32_HWP_REQUEST (0x774)`: min [7:0] = lowest, max [15:8] = highest, desired [23:16] = 0 (autonomous), EPP [31:24], activity window [41:32] = 0 (hardware chooses), package-control bit 42 | written per CPU on each CPU (FreeBSD: smp_rendezvous_cpu; illumos: xc_call, or cpu_call to the target CPU) |
| Package request | `IA32_HWP_REQUEST_PKG (0x772)` when CPUID bit 11. FreeBSD turns it OFF on hybrid parts (pc_small_core), because the package frequency then follows whichever core wrote last. Alder Lake is hybrid: per-CPU requests only | same rule |
| EPP | sysctl `dev.hwpstate_intel.N.epp`, 0-100 mapped to 0-255. Falls back to EPB (0x1B0, 4 bits) when there is no EPP | a cpupm tunable, or a kstat-writable knob; power.conf has no keyword for it |
| Status | `IA32_HWP_STATUS (0x777)`, notification `IA32_HWP_INTERRUPT (0x773)` | not needed for a first cut |
| Suspend/resume | re-write PM_ENABLE + REQUEST on resume | cpupm's resume path (cpupm_mach.c); illumos S3 on this laptop is unproven anyway |

FreeBSD's attach (`set_autonomous_hwp_cb`) does exactly this:

1. PM_ENABLE = 1.
2. Read CAPABILITIES and REQUEST.
3. Clear desired and the activity window.
4. min = lowest, max = highest.
5. Write REQUEST, plus REQUEST_PKG when package control is allowed.

The frequency driver then reports one `cf_setting`. FreeBSD's cpufreq framework stops managing that CPU, and
the hardware takes over.

## What an illumos port touches

1. **cpuid.c / x86_archext.h**: X86FSET_HWP, X86FSET_HWP_EPP, X86FSET_HWP_PKG from leaf 6 EAX. About 20 lines.
2. **New `uts/i86pc/os/cpupm/hwp.c`**, a `cpupm_state_ops_t` like speedstep_ops. `cpus_init` enables HWP and writes
   the autonomous request. `cpus_change` is a no-op, or writes the min/max window, so cpupm's "max performance"
   and "min power" requests become window edges. `cpus_stop` cannot disable HWP, so it widens the window back to
   lowest..highest. About 250 lines, modelled on speedstep.c.
3. **cpupm_intel.c**: prefer hwp_ops over speedstep_ops when X86FSET_HWP is set. Advertise `_OSC` bit 0x40
   (CPPC) so the firmware loads its HWP table, which matters only for `_CPC` consumers. Keep the `_PDC` P-state
   bits so the IST/`_PSS` tables still load for the `cpu_info` kstat. About 30 lines.
4. **EPP knob**: `cpupm_hwp_epp` (/etc/system), default 128 (balance_performance, Linux's default on this
   machine). Later, a power.conf keyword in cmd/power (conf.c + handlers.c), which is a userland change.
5. **kstat**: `cpu_info` current_clock_Hz is computed from the P-state cpupm last set. Under HWP it must come from
   APERF/MPERF deltas (MSR 0xE8/0xE7), as Linux's scaling_cur_freq does. Otherwise the reported clock is a
   constant lie. About 40 lines in cpuid.c / cpupm_mach.c.
6. **Hybrid**: per-CPU requests only. P-cores and E-cores report different HIGHEST values, so max must come from
   each CPU's own CAPABILITIES.

Effort: about 400 lines of kernel C. Test on two machines:

- the X1E itself, comparing APERF/MPERF under load against the 0x770/0x774 MSR values;
- an EC2 metal Intel instance (m5zn.metal exposes HWP: CPUID leaf 6 bit 7), with a negative control that has
  `cpupm_hwp_enable = 0`, i.e. today's speedstep path, and shows the window stuck.

Upstreaming to illumos-gate would need an RTI and a man page change (cpupm in power.conf(5)).

## Not decided here

- Whether to leave the firmware's HWP enable state alone when the BIOS already enabled it. FreeBSD writes
  PM_ENABLE unconditionally.
- Whether illumos's elastic policy should drive the HWP window at all, or HWP should run fully autonomous with
  cpupm only for C-states.
