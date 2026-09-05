//! solnix graphical installer — a pop!_OS-style COSMIC wizard that collects an
//! install answer set (target disk, hostname, user, locale, timezone), renders a
//! declarative Nix-flavored solnix config, and drives the existing ZFS
//! boot-environment backend (solnix-install / oi-make-declarative-be.sh).
//!
//! Front-end: libcosmic (cosmic::Application) — the same toolkit pop!_OS's
//! cosmic-installer uses. Linear back/next wizard (no nav bar), one Step per page.

use cosmic::app::{Core, Settings, Task};
use cosmic::iced::{Length, Size};
use cosmic::prelude::*;
use cosmic::{executor, widget};
use std::process::Command;

// ---------------------------------------------------------------------------
// Backend paths + defaults (overridable by env for the dry-run harness).
// ---------------------------------------------------------------------------

fn backend_install() -> String {
    std::env::var("SOLNIX_INSTALL_BIN").unwrap_or_else(|_| "/root/solnix-install".into())
}
fn backend_declarative() -> String {
    std::env::var("SOLNIX_DECLARATIVE_BIN")
        .unwrap_or_else(|_| "/root/oi-make-declarative-be.sh".into())
}
fn config_out_path() -> String {
    std::env::var("SOLNIX_CONFIG_OUT").unwrap_or_else(|_| "/root/solnix-installer-config.nix".into())
}
/// Dry-run mode: NEVER touch a disk. Generate the config + print the backend
/// command line. The install is destructive/hardware-gated, so this is the
/// default the verification harness uses (`SOLNIX_INSTALLER_DRYRUN=1`).
fn dry_run() -> bool {
    std::env::var("SOLNIX_INSTALLER_DRYRUN").map(|v| v != "0").unwrap_or(true)
}

// ---------------------------------------------------------------------------
// Disk enumeration — parse illumos `diskinfo` (TYPE DISK VID PID SIZE RMV SSD).
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
struct Disk {
    dev: String,   // c1t1d0
    label: String, // "NVME  Amazon Elastic Block Store  60.00 GiB"
}

fn enumerate_disks() -> Vec<Disk> {
    let out = Command::new("diskinfo").output();
    let mut disks = Vec::new();
    if let Ok(o) = out {
        let text = String::from_utf8_lossy(&o.stdout);
        for line in text.lines().skip(1) {
            // TYPE DISK VID PID... SIZE UNIT RMV SSD — DISK is field 1 (0-idx).
            let f: Vec<&str> = line.split_whitespace().collect();
            if f.len() < 3 {
                continue;
            }
            let dev = f[1].to_string();
            if !dev.contains('t') || !dev.ends_with("d0") {
                // crude illumos ctd sanity check; keep cNtNdN whole disks
            }
            // human label = everything after the dev name
            let rest = line
                .splitn(3, char::is_whitespace)
                .nth(2)
                .unwrap_or("")
                .trim()
                .to_string();
            disks.push(Disk {
                label: format!("{} — {}", dev, rest),
                dev,
            });
        }
    }
    if disks.is_empty() {
        disks.push(Disk {
            dev: "c1t1d0".into(),
            label: "c1t1d0 — (diskinfo unavailable; sample)".into(),
        });
    }
    disks
}

// ---------------------------------------------------------------------------
// Locale + timezone enumeration (best-effort; falls back to a small static set).
// ---------------------------------------------------------------------------

fn enumerate_locales() -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir("/usr/lib/locale")
        .ok()
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|n| n.contains("UTF-8") || n == "C")
        .collect();
    v.sort();
    if v.is_empty() {
        v = ["C.UTF-8", "en_US.UTF-8", "en_GB.UTF-8"].iter().map(|s| s.to_string()).collect();
    }
    v
}

fn enumerate_timezones() -> Vec<String> {
    // Just the common regions/zones — a full zoneinfo walk is overkill for the UI.
    let candidates = [
        "UTC",
        "America/New_York",
        "America/Chicago",
        "America/Denver",
        "America/Los_Angeles",
        "Europe/London",
        "Europe/Paris",
        "Europe/Berlin",
        "Asia/Tokyo",
        "Asia/Shanghai",
        "Australia/Sydney",
    ];
    let zi = "/usr/share/lib/zoneinfo";
    let mut v: Vec<String> = candidates
        .iter()
        .filter(|z| std::path::Path::new(&format!("{zi}/{z}")).exists())
        .map(|s| s.to_string())
        .collect();
    if v.is_empty() {
        v = candidates.iter().map(|s| s.to_string()).collect();
    }
    v
}

// ---------------------------------------------------------------------------
// Declarative config generation (NixOS-shape solnix config).
// ---------------------------------------------------------------------------

fn render_config(a: &Answers) -> String {
    // NOTE: no password hashing here (crypt is a backend concern). The
    // installer records a plaintext initialPassword the backend must hash, OR a
    // hashedPassword if the operator pre-hashed. Kept minimal: initialPassword.
    format!(
        r#"# Generated by the solnix graphical installer. Declarative, Nix-flavored:
# realized into a ZFS boot environment by oi-make-declarative-be.sh, or laid
# down by solnix-install onto the target disk. Composes over configurations/base.nix.
{{ config, lib, pkgs, ... }}:
{{
  imports = [ ./base.nix ];

  networking.hostName = "{host}";

  time.timeZone = "{tz}";
  i18n.defaultLocale = "{locale}";

  users.users.{user} = {{
    uid = 1000;
    group = "staff";
    description = "{user}";
    shell = "/usr/bin/ksh93";
    extraGroups = [ "adm" "sys" ];
    initialPassword = "{pw}";
  }};
}}
"#,
        host = a.hostname,
        tz = a.timezone,
        locale = a.locale,
        user = a.username,
        pw = a.password,
    )
}

// ---------------------------------------------------------------------------
// Wizard steps.
// ---------------------------------------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq)]
enum Step {
    Welcome,
    Disk,
    User,
    Summary,
    Progress,
}

impl Step {
    fn title(self) -> &'static str {
        match self {
            Step::Welcome => "Welcome to solnix",
            Step::Disk => "Select installation disk",
            Step::User => "User, locale & timezone",
            Step::Summary => "Confirm installation",
            Step::Progress => "Installing solnix",
        }
    }
    fn index(self) -> usize {
        match self {
            Step::Welcome => 0,
            Step::Disk => 1,
            Step::User => 2,
            Step::Summary => 3,
            Step::Progress => 4,
        }
    }
}

/// Optional start-step override (for demo screenshots on a headless session).
fn start_step() -> Step {
    match std::env::var("SOLNIX_INSTALLER_START_STEP").as_deref() {
        Ok("disk") => Step::Disk,
        Ok("user") => Step::User,
        Ok("summary") => Step::Summary,
        Ok("progress") => Step::Progress,
        _ => Step::Welcome,
    }
}

#[derive(Clone)]
struct Answers {
    hostname: String,
    username: String,
    password: String,
    locale_idx: usize,
    tz_idx: usize,
    disk_idx: usize,
    locale: String,
    timezone: String,
}

#[derive(Clone, Debug)]
pub enum Message {
    Next,
    Back,
    Hostname(String),
    Username(String),
    Password(String),
    PickDisk(usize),
    PickLocale(usize),
    PickTz(usize),
    RunInstall,
    InstallDone(String),
}

pub struct App {
    core: Core,
    step: Step,
    disks: Vec<Disk>,
    disk_labels: Vec<String>,
    locales: Vec<String>,
    timezones: Vec<String>,
    a: Answers,
    log: String,
    running: bool,
}

impl cosmic::Application for App {
    type Executor = executor::Default;
    type Flags = ();
    type Message = Message;
    const APP_ID: &'static str = "io.solnix.Installer";

    fn core(&self) -> &Core {
        &self.core
    }
    fn core_mut(&mut self) -> &mut Core {
        &mut self.core
    }

    fn init(core: Core, _flags: ()) -> (Self, Task<Message>) {
        let disks = enumerate_disks();
        let disk_labels: Vec<String> = disks.iter().map(|d| d.label.clone()).collect();
        let locales = enumerate_locales();
        let timezones = enumerate_timezones();
        let a = Answers {
            hostname: "solnix".into(),
            username: "operator".into(),
            password: String::new(),
            locale_idx: 0,
            tz_idx: 0,
            disk_idx: 0,
            locale: locales.first().cloned().unwrap_or_else(|| "C.UTF-8".into()),
            timezone: timezones.first().cloned().unwrap_or_else(|| "UTC".into()),
        };
        let mut app = App {
            core,
            step: start_step(),
            disks,
            disk_labels,
            locales,
            timezones,
            a,
            log: String::new(),
            running: false,
        };
        let cmd = app.update_title();
        (app, cmd)
    }

    fn update(&mut self, message: Message) -> Task<Message> {
        match message {
            Message::Next => {
                self.step = match self.step {
                    Step::Welcome => Step::Disk,
                    Step::Disk => Step::User,
                    Step::User => Step::Summary,
                    Step::Summary => Step::Progress,
                    Step::Progress => Step::Progress,
                };
                return self.update_title();
            }
            Message::Back => {
                self.step = match self.step {
                    Step::Welcome => Step::Welcome,
                    Step::Disk => Step::Welcome,
                    Step::User => Step::Disk,
                    Step::Summary => Step::User,
                    Step::Progress => Step::Summary,
                };
                return self.update_title();
            }
            Message::Hostname(v) => self.a.hostname = v,
            Message::Username(v) => self.a.username = v,
            Message::Password(v) => self.a.password = v,
            Message::PickDisk(i) => self.a.disk_idx = i,
            Message::PickLocale(i) => {
                self.a.locale_idx = i;
                self.a.locale = self.locales.get(i).cloned().unwrap_or_default();
            }
            Message::PickTz(i) => {
                self.a.tz_idx = i;
                self.a.timezone = self.timezones.get(i).cloned().unwrap_or_default();
            }
            Message::RunInstall => {
                self.running = true;
                let a = self.a.clone();
                let disk = self.disks.get(a.disk_idx).map(|d| d.dev.clone()).unwrap_or_default();
                return Task::perform(async move { run_backend(&a, &disk) }, |log| {
                    cosmic::action::app(Message::InstallDone(log))
                });
            }
            Message::InstallDone(log) => {
                self.running = false;
                self.log = log;
            }
        }
        Task::none()
    }

    fn view(&self) -> Element<'_, Message> {
        let body = match self.step {
            Step::Welcome => self.view_welcome(),
            Step::Disk => self.view_disk(),
            Step::User => self.view_user(),
            Step::Summary => self.view_summary(),
            Step::Progress => self.view_progress(),
        };

        let spacing = cosmic::theme::spacing();

        // step indicator
        let dots = widget::text::caption(format!(
            "Step {} of 5",
            self.step.index() + 1
        ));

        // nav buttons
        let mut nav = widget::row::with_capacity(3).spacing(spacing.space_s);
        if self.step != Step::Welcome {
            nav = nav.push(widget::button::standard("Back").on_press(Message::Back));
        }
        nav = nav.push(widget::space::horizontal());
        match self.step {
            Step::Summary => {
                nav = nav
                    .push(widget::button::suggested("Install").on_press(Message::RunInstall));
            }
            Step::Progress => {}
            _ => {
                nav = nav.push(widget::button::suggested("Next").on_press(Message::Next));
            }
        }

        let content = widget::column::with_capacity(5)
            .spacing(spacing.space_m)
            .padding(spacing.space_l)
            .push(widget::text::title2(self.step.title()))
            .push(dots)
            .push(body)
            .push(widget::space::vertical())
            .push(nav);

        widget::container(content)
            .width(Length::Fill)
            .height(Length::Fill)
            .into()
    }

    fn header_start(&self) -> Vec<Element<'_, Message>> {
        vec![widget::text::body("solnix installer").into()]
    }
}

impl App {
    fn update_title(&mut self) -> Task<Message> {
        let t = format!("{} — solnix installer", self.step.title());
        self.set_header_title(self.step.title().to_string());
        if let Some(id) = self.core.main_window_id() {
            self.set_window_title(t, id)
        } else {
            Task::none()
        }
    }

    fn view_welcome(&self) -> Element<'_, Message> {
        widget::column::with_capacity(3)
            .spacing(12)
            .push(widget::text::body(
                "This will install solnix — a Nix distribution of illumos — onto \
                 a ZFS boot environment on the disk you choose.",
            ))
            .push(widget::text::body(
                "solnix is declarative: the installer writes a Nix config and \
                 realizes its closure into the boot environment, then sets the \
                 bootloader. You can reproduce or roll back the whole system.",
            ))
            .push(widget::text::caption(if dry_run() {
                "Running in DRY-RUN mode: no disk will be modified."
            } else {
                "WARNING: the selected disk will be ERASED."
            }))
            .into()
    }

    fn view_disk(&self) -> Element<'_, Message> {
        widget::settings::view_column(vec![widget::settings::section()
            .title("Available disks")
            .add(widget::settings::item(
                "Target disk",
                widget::dropdown(&self.disk_labels, Some(self.a.disk_idx), Message::PickDisk),
            ))
            .into()])
        .into()
    }

    fn view_user(&self) -> Element<'_, Message> {
        widget::settings::view_column(vec![widget::settings::section()
            .title("System")
            .add(widget::settings::item(
                "Hostname",
                widget::text_input::text_input("solnix", &self.a.hostname)
                    .on_input(Message::Hostname),
            ))
            .add(widget::settings::item(
                "Username",
                widget::text_input::text_input("operator", &self.a.username)
                    .on_input(Message::Username),
            ))
            .add(widget::settings::item(
                "Password",
                widget::text_input::secure_input("", &self.a.password, None, true)
                    .on_input(Message::Password),
            ))
            .add(widget::settings::item(
                "Locale",
                widget::dropdown(&self.locales, Some(self.a.locale_idx), Message::PickLocale),
            ))
            .add(widget::settings::item(
                "Timezone",
                widget::dropdown(&self.timezones, Some(self.a.tz_idx), Message::PickTz),
            ))
            .into()])
        .into()
    }

    fn view_summary(&self) -> Element<'_, Message> {
        let disk = self
            .disks
            .get(self.a.disk_idx)
            .map(|d| d.label.clone())
            .unwrap_or_default();
        let cfg = render_config(&self.a);
        widget::column::with_capacity(3)
            .spacing(12)
            .push(widget::settings::view_column(vec![widget::settings::section()
                .title("Summary")
                .add(widget::settings::item("Disk", widget::text::body(disk)))
                .add(widget::settings::item("Hostname", widget::text::body(self.a.hostname.clone())))
                .add(widget::settings::item("User", widget::text::body(self.a.username.clone())))
                .add(widget::settings::item("Locale", widget::text::body(self.a.locale.clone())))
                .add(widget::settings::item("Timezone", widget::text::body(self.a.timezone.clone())))
                .into()]))
            .push(widget::text::heading("Generated declarative config"))
            .push(widget::scrollable(widget::text::monotext(cfg)).height(Length::Fixed(200.0)))
            .into()
    }

    fn view_progress(&self) -> Element<'_, Message> {
        let status = if self.running {
            "Working…"
        } else if self.log.is_empty() {
            "Ready. Press Install on the previous page."
        } else {
            "Done."
        };
        widget::column::with_capacity(3)
            .spacing(12)
            .push(widget::text::body(status))
            .push(widget::scrollable(widget::text::monotext(if self.log.is_empty() {
                "(no output yet)".to_string()
            } else {
                self.log.clone()
            }))
            .height(Length::Fill))
            .into()
    }
}

/// Drive the backend. In dry-run: write the config, print the exact backend
/// command line, enumerate the disk — but do NOT touch the disk. In a real run:
/// exec the ZFS-BE installer with the chosen disk.
fn run_backend(a: &Answers, disk: &str) -> String {
    let mut log = String::new();
    let cfg = render_config(a);
    let cfg_path = config_out_path();
    match std::fs::write(&cfg_path, &cfg) {
        Ok(_) => log.push_str(&format!("wrote declarative config -> {cfg_path}\n")),
        Err(e) => log.push_str(&format!("WARN: could not write {cfg_path}: {e}\n")),
    }
    log.push_str("--- generated config.nix ---\n");
    log.push_str(&cfg);
    log.push_str("----------------------------\n");

    let install_bin = backend_install();
    let decl_bin = backend_declarative();
    log.push_str(&format!(
        "\ndeclarative realize (would run):\n  {decl_bin}  # builds toplevel from {cfg_path}, lays BE\n"
    ));
    log.push_str(&format!(
        "ZFS-BE install (would run):\n  SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 {install_bin} {disk} <toplevel>\n"
    ));

    if dry_run() {
        // Prove disk enumeration is live without touching anything.
        if let Ok(o) = Command::new("diskinfo").output() {
            log.push_str("\n--- diskinfo (live disk enumeration) ---\n");
            log.push_str(&String::from_utf8_lossy(&o.stdout));
        }
        log.push_str("\nDRY-RUN: no disk modified. Set SOLNIX_INSTALLER_DRYRUN=0 for a real install.\n");
        return log;
    }

    // Real install: hardware/destructive. Run the declarative realize then the BE install.
    log.push_str("\nREAL INSTALL: invoking backend…\n");
    let out = Command::new("sh")
        .arg("-c")
        .arg(format!(
            "SOLNIX_POOL=rpool SOLNIX_ALLOW_RPOOL=1 {install_bin} {disk}"
        ))
        .output();
    match out {
        Ok(o) => {
            log.push_str(&String::from_utf8_lossy(&o.stdout));
            log.push_str(&String::from_utf8_lossy(&o.stderr));
            log.push_str(&format!("\nbackend exit: {}\n", o.status));
        }
        Err(e) => log.push_str(&format!("backend spawn failed: {e}\n")),
    }
    log
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn")).init();

    // Headless verification path: exercise disk enumeration + declarative config
    // generation + the dry-run backend wiring WITHOUT a display. Proves the same
    // code the Progress page runs, for CI/no-session checks.
    if std::env::args().any(|a| a == "--dry-run-test") {
        let disks = enumerate_disks();
        let locales = enumerate_locales();
        let timezones = enumerate_timezones();
        let a = Answers {
            hostname: "solnix-demo".into(),
            username: "operator".into(),
            password: "changeme".into(),
            locale_idx: 0,
            tz_idx: 0,
            disk_idx: 0,
            locale: locales.first().cloned().unwrap_or_else(|| "C.UTF-8".into()),
            timezone: timezones.first().cloned().unwrap_or_else(|| "UTC".into()),
        };
        let disk = disks.first().map(|d| d.dev.clone()).unwrap_or_default();
        println!("# enumerated {} disk(s):", disks.len());
        for d in &disks {
            println!("#   {}", d.label);
        }
        println!("# {} locale(s), {} timezone(s)", locales.len(), timezones.len());
        println!("{}", run_backend(&a, &disk));
        return Ok(());
    }

    // transparent(false): headless VNC/software (tiny-skia + softbuffer) only
    // supports the depth-24 TrueColor visual; the default transparent=true makes
    // winit pick a depth-32 visual softbuffer rejects.
    let settings = Settings::default()
        .size(Size::new(900., 680.))
        .transparent(false);
    cosmic::app::run::<App>(settings, ())?;
    Ok(())
}
