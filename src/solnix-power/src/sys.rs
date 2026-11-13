//! The illumos side of solnix-power: acpi_drv's kstats (battery and AC), the lid, and /etc/power.conf's cpupm line.
//! Every command runs with a cleared environment, a fixed PATH and a timeout.
use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;
use tokio::process::Command;

pub const PATH: &str = "/usr/sbin:/usr/bin:/sbin:/bin";

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Battery {
    pub present: bool,
    pub design: f64,      // Wh
    pub full: f64,        // Wh (bif_last_cap)
    pub now: f64,         // Wh (bst_rem_cap)
    pub rate: f64,        // W
    pub voltage: f64,     // V
    pub charging: bool,
    pub discharging: bool,
    pub model: String,
    pub serial: String,
    pub vendor: String,
    pub tech: u32,        // UPower BatteryTechnology
}

#[derive(Clone, Debug, PartialEq, Default)]
pub struct Power { pub on_ac: bool, pub batteries: Vec<Battery> }

/// `kstat -p acpi_drv:0` lines: `acpi_drv:0:<name>:<stat>\t<value>`; <name> and <stat> may hold spaces.
pub fn parse_kstat(text: &str) -> BTreeMap<(String, String), String> {
    text.lines().filter_map(|l| {
        let (k, v) = l.split_once('\t')?;
        let mut f = k.splitn(4, ':');
        let (_m, _i, n, s) = (f.next()?, f.next()?, f.next()?, f.next()?);
        Some(((n.to_string(), s.to_string()), v.trim().to_string()))
    }).collect()
}

/// acpi_drv units: bif_unit 0 = mWh / mW, 1 = mAh / mA (times the design voltage in mV to get mWh).
pub fn power_from_kstat(k: &BTreeMap<(String, String), String>) -> Power {
    let g = |n: &str, s: &str| k.get(&(n.to_string(), s.to_string())).cloned();
    let num = |n: &str, s: &str| g(n, s).and_then(|v| v.parse::<f64>().ok()).filter(|v| *v >= 0.0 && *v < 4.0e9);
    let mut bats = Vec::new();
    for i in 0..4 {
        let (bif, bst) = (format!("battery BIF{i}"), format!("battery BST{i}"));
        if g(&bif, "bif_last_cap").is_none() { continue; }
        let mv = num(&bif, "bif_voltage").unwrap_or(0.0);
        let scale = if g(&bif, "bif_unit").as_deref() == Some("1") { mv / 1.0e6 } else { 1.0e-3 };   // -> Wh / W
        let state = g(&bst, "bst_state").and_then(|v| v.parse::<u32>().ok()).unwrap_or(0);
        let tech = match g(&bif, "bif_type").unwrap_or_default().to_ascii_lowercase().as_str() {
            t if t.starts_with("lip") || t.contains("poly") => 2, t if t.starts_with("li") => 1, _ => 0 };
        bats.push(Battery {
            present: true,
            design: num(&bif, "bif_design_cap").unwrap_or(0.0) * scale,
            full: num(&bif, "bif_last_cap").unwrap_or(0.0) * scale,
            now: num(&bst, "bst_rem_cap").unwrap_or(0.0) * scale,
            rate: num(&bst, "bst_rate").unwrap_or(0.0) * scale,
            voltage: num(&bst, "bst_voltage").unwrap_or(0.0) / 1000.0,
            discharging: state & 1 != 0,
            charging: state & 2 != 0,
            model: g(&bif, "bif_model").unwrap_or_default().trim().to_string(),
            serial: g(&bif, "bif_serial").unwrap_or_default().trim().to_string(),
            vendor: g(&bif, "bif_oem_info").unwrap_or_default().trim().to_string(),
            tech,
        });
    }
    Power { on_ac: g("power", "system power").as_deref() != Some("battery"), batteries: bats }
}

/// UPower's numbers for one battery: (percentage, state, time_to_empty s, time_to_full s).
/// state: 1 charging, 2 discharging, 4 fully charged, 5 pending charge (on AC, not charging, not full).
pub fn derive(b: &Battery, on_ac: bool) -> (f64, u32, i64, i64) {
    let pct = if b.full > 0.0 { (b.now / b.full * 100.0).clamp(0.0, 100.0) } else { 0.0 };
    let state = if b.charging { 1 } else if b.discharging || !on_ac { 2 } else if pct >= 99.0 { 4 } else { 5 };
    let tte = if state == 2 && b.rate > 0.0 { (b.now / b.rate * 3600.0) as i64 } else { 0 };
    let ttf = if state == 1 && b.rate > 0.0 { ((b.full - b.now).max(0.0) / b.rate * 3600.0) as i64 } else { 0 };
    (pct, state, tte, ttf)
}

/// UPower's BatteryLevel is None (1) for batteries that report a percentage; WarningLevel from the percentage.
pub fn warning_level(pct: f64, discharging: bool) -> u32 { if !discharging { 1 } else if pct <= 2.0 { 5 } else if pct <= 5.0 { 4 } else if pct <= 10.0 { 3 } else { 1 } }

/// UPower's icon names (up_daemon_get_icon_name style, the -symbolic set COSMIC ships).
pub fn icon(pct: f64, state: u32) -> String {
    let lvl = ((pct / 10.0).round() as u32 * 10).min(100);
    let suffix = match state { 1 | 5 => "-charging", 4 => "-charged", _ => "" };
    if state == 4 { "battery-level-100-charged-symbolic".into() } else { format!("battery-level-{lvl}{suffix}-symbolic") }
}

pub async fn run(args: &[&str], secs: u64) -> Option<String> {
    let mut c = Command::new(args[0]);
    c.args(&args[1..]).env_clear().env("PATH", PATH).env("LC_ALL", "C").kill_on_drop(true);
    let o = tokio::time::timeout(Duration::from_secs(secs), c.output()).await.ok()?.ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).into_owned())
}

pub async fn read_power() -> Power {
    power_from_kstat(&parse_kstat(&run(&["kstat", "-p", "acpi_drv:0"], 10).await.unwrap_or_default()))
}

/// The lid: acpi_drv's lid minor answers ACPI_DRV_IOC_LID_STATUS. Not read in v1 (no ioctl binding): lid present
/// iff the node exists, closed never reported.
pub fn lid_present() -> bool { Path::new("/devices/pseudo/acpi_drv@0:lid").exists() }

// ---- power profiles over /etc/power.conf --------------------------------------------------------------------------
// performance: `cpupm disable` (full clock); balanced: `cpupm enable` (the stock event mode); power-saver:
// `cpupm enable poll-mode` with `cpu-threshold 1s` (the stock threshold; poll-mode lowers clocks on a timer rather
// than on events). pmconfig(8) applies the file.
pub const PROFILES: [&str; 3] = ["power-saver", "balanced", "performance"];

pub fn profile_of(conf: &str) -> &'static str {
    let line = conf.lines().map(str::trim).find(|l| l.starts_with("cpupm") && !l.starts_with("cpupm_"));
    let w: Vec<&str> = line.map(|l| l.split_whitespace().collect()).unwrap_or_default();
    match (w.get(1).copied(), w.get(2).copied()) {
        (Some("disable"), _) => "performance",
        (Some("enable"), Some("poll-mode")) => "power-saver",
        _ => "balanced",
    }
}

/// power.conf with its cpupm line set for `profile`; every other line kept as it is.
pub fn set_profile(conf: &str, profile: &str) -> Option<String> {
    let line = match profile { "performance" => "cpupm                   disable", "balanced" => "cpupm                   enable",
                               "power-saver" => "cpupm                   enable poll-mode", _ => return None };
    let mut seen = false;
    let mut out: Vec<String> = conf.lines().map(|l| {
        let t = l.trim_start();
        if t.starts_with("cpupm") && !t.starts_with("cpupm_") && !t.starts_with('#') { seen = true; line.to_string() } else { l.to_string() }
    }).collect();
    if !seen { out.push(line.to_string()); }
    Some(out.join("\n") + "\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    // `kstat -p acpi_drv:0` on a ThinkPad X1 Extreme Gen 5, 2026-11-10 (on AC, idle)
    const LIXI: &str = "acpi_drv:0:battery BIF0:bif_design_cap\t90090\nacpi_drv:0:battery BIF0:bif_last_cap\t83460\n\
acpi_drv:0:battery BIF0:bif_model\t5B11B79217\nacpi_drv:0:battery BIF0:bif_oem_info\tSMP\nacpi_drv:0:battery BIF0:bif_serial\t 1868\n\
acpi_drv:0:battery BIF0:bif_type\tLiP\nacpi_drv:0:battery BIF0:bif_unit\t0\nacpi_drv:0:battery BIF0:bif_voltage\t15520\n\
acpi_drv:0:battery BST0:bst_rate\t0\nacpi_drv:0:battery BST0:bst_rem_cap\t62040\nacpi_drv:0:battery BST0:bst_state\t0\n\
acpi_drv:0:battery BST0:bst_voltage\t16227\nacpi_drv:0:power:supported_battery_count\t1\nacpi_drv:0:power:system power\tAC\n";
    #[test]
    fn lixi_kstats() {
        let p = power_from_kstat(&parse_kstat(LIXI));
        assert!(p.on_ac); assert_eq!(p.batteries.len(), 1);
        let b = &p.batteries[0];
        assert!((b.full - 83.46).abs() < 1e-9 && (b.now - 62.04).abs() < 1e-9 && (b.design - 90.09).abs() < 1e-9);
        assert_eq!(b.model, "5B11B79217"); assert_eq!(b.serial, "1868"); assert_eq!(b.tech, 2);
        let (pct, st, tte, ttf) = derive(b, p.on_ac);
        assert!((pct - 74.33).abs() < 0.01, "{pct}"); assert_eq!(st, 5); assert_eq!((tte, ttf), (0, 0));
        assert_eq!(icon(pct, st), "battery-level-70-charging-symbolic");
    }
    #[test]
    fn discharging_and_units() {
        let t = LIXI.replace("bst_state\t0", "bst_state\t1").replace("bst_rate\t0", "bst_rate\t12000").replace("system power\tAC", "system power\tbattery");
        let p = power_from_kstat(&parse_kstat(&t));
        assert!(!p.on_ac);
        let (_, st, tte, _) = derive(&p.batteries[0], p.on_ac);
        assert_eq!(st, 2); assert_eq!(tte, (62.04 / 12.0 * 3600.0) as i64);
        // mAh unit: capacity times the design voltage
        let a = LIXI.replace("bif_unit\t0", "bif_unit\t1");
        let b = &power_from_kstat(&parse_kstat(&a)).batteries[0];
        assert!((b.full - 83460.0 * 15.52 / 1000.0).abs() < 1e-6);
        // no battery: none listed, AC assumed
        let p = power_from_kstat(&parse_kstat("acpi_drv:0:power:system power\tAC\n"));
        assert!(p.batteries.is_empty() && p.on_ac);
    }
    #[test]
    fn profiles() {
        let stock = "device-dependency-property removable-media /dev/fb\nautopm                  default\ncpupm                   enable\ncpu-threshold           1s\n";
        assert_eq!(profile_of(stock), "balanced");
        let ps = set_profile(stock, "power-saver").unwrap();
        assert_eq!(profile_of(&ps), "power-saver"); assert!(ps.contains("cpu-threshold           1s") && ps.contains("autopm"));
        assert_eq!(ps.lines().count(), stock.lines().count());
        assert_eq!(profile_of(&set_profile(stock, "performance").unwrap()), "performance");
        assert_eq!(set_profile(&set_profile(stock, "performance").unwrap(), "balanced").unwrap(), stock);
        assert!(set_profile(stock, "turbo").is_none());
        assert_eq!(profile_of(&set_profile("autopm default\n", "performance").unwrap()), "performance");   // no cpupm line: appended
    }
}
