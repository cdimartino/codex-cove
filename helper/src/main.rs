use codex_cove::broker::{
    AppServerMode, broker_socket, decision_socket, probe_app_server_rpc, probe_direct_stdio,
    run_broker, wait_for_socket,
};
use codex_cove::config::{
    Config, PrivacyMode, find_real_codex, find_real_codex_without_config, home_directory,
};
use codex_cove::doctor;
use codex_cove::hook;
use codex_cove::install;
use codex_cove::ipc::send_event_one_way;
use codex_cove::remote;
use codex_cove::route::{Route, route_codex_args};
use codex_cove::{CoveEvent, EventSource, generate_launch_id, is_truthy};
use serde_json::{Value, json};
use std::collections::BTreeSet;
use std::env;
use std::ffi::{CStr, OsStr};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitCode, Output, Stdio};
use std::time::Duration;

fn main() -> ExitCode {
    match run() {
        Ok(code) => ExitCode::from(code.clamp(0, 255) as u8),
        Err(error) => {
            eprintln!("codex-cove: {error}");
            ExitCode::FAILURE
        }
    }
}

fn run() -> io::Result<i32> {
    let args: Vec<String> = env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("__broker") {
        return run_internal_broker(&args[1..]);
    }
    let executable_argument = env::args_os().next();
    let invoked_as = executable_argument
        .as_deref()
        .and_then(|value| Path::new(value).file_name())
        .and_then(OsStr::to_str)
        .unwrap_or("codex-cove");
    if invoked_as == "codex" {
        return run_codex_shim(&args);
    }
    run_management(&args)
}

fn run_codex_shim(args: &[String]) -> io::Result<i32> {
    let current = env::current_exe()?;
    let bypass = is_truthy(env::var("CODEX_COVE_BYPASS").ok().as_deref());

    if bypass {
        let real_codex = Config::load()
            .ok()
            .and_then(|config| find_real_codex(&config, &current).ok())
            .or_else(|| find_real_codex_without_config(&current).ok())
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::NotFound,
                    "emergency bypass could not find a non-Cove Codex binary on PATH",
                )
            })?;
        return exec_codex(&real_codex, args, None);
    }

    let config = match Config::load() {
        Ok(config) => config,
        Err(error) => {
            let real_codex = find_real_codex_without_config(&current).map_err(|fallback| {
                io::Error::new(
                    fallback.kind(),
                    format!(
                        "Cove configuration is unavailable ({error}) and native Codex fallback failed: {fallback}"
                    ),
                )
            })?;
            eprintln!("codex-cove: configuration unavailable; using native Codex");
            return exec_codex(&real_codex, args, None);
        }
    };
    let real_codex = find_real_codex(&config, &current)?;
    if codex_cove::route::has_explicit_remote(args) {
        return exec_codex(&real_codex, args, None);
    }

    let initial = route_codex_args(args, false, "unix://placeholder");
    if matches!(initial, Route::Direct(_)) {
        return exec_codex(&real_codex, args, None);
    }

    let transport_timeout = Duration::from_millis(config.broker_start_timeout_ms);
    let Some(app_server_mode) =
        select_app_server_mode(&real_codex, transport_timeout, config.max_frame_bytes)
    else {
        trace_broker("selected_mode=native reason=app_server_unavailable");
        eprintln!("codex-cove: app-server unavailable; using native Codex");
        return exec_codex(&real_codex, args, None);
    };
    trace_broker(&format!("selected_mode={}", app_server_mode.as_str()));

    let launch_id = env::var("CODEX_COVE_LAUNCH_ID").unwrap_or_else(|_| generate_launch_id());
    fs::create_dir_all(&config.runtime_directory)?;
    fs::set_permissions(&config.runtime_directory, fs::Permissions::from_mode(0o700))?;
    let socket = broker_socket(&config.runtime_directory, &launch_id);
    let helper = env::current_exe()?;
    let mut broker_command = Command::new(&helper);
    broker_command
        .arg("__broker")
        .arg("--listen")
        .arg(&socket)
        .arg("--launch-id")
        .arg(&launch_id)
        .arg("--real-codex")
        .arg(&real_codex)
        .arg("--mode")
        .arg(app_server_mode.as_str())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .env("CODEX_COVE_BYPASS", "1");
    if trace_broker_enabled() {
        broker_command.stderr(Stdio::inherit());
    } else {
        broker_command.stderr(Stdio::null());
    }
    let broker = broker_command.spawn();
    let Ok(mut broker) = broker else {
        eprintln!("codex-cove: broker unavailable; using native Codex");
        return exec_codex(&real_codex, args, Some(&launch_id));
    };
    if !wait_for_socket(
        &socket,
        Duration::from_millis(config.broker_start_timeout_ms),
    ) {
        let _ = broker.kill();
        let _ = broker.wait();
        eprintln!("codex-cove: broker unavailable; using native Codex");
        return exec_codex(&real_codex, args, Some(&launch_id));
    }

    let uses_remote_marker = should_use_remote_marker(&config);
    register_launch(
        &config,
        &launch_id,
        &decision_socket(&config.runtime_directory, &launch_id),
        uses_remote_marker.then_some(launch_id.as_str()),
    );
    let endpoint = format!("unix://{}", socket.display());
    let routed = match route_codex_args(args, false, &endpoint) {
        Route::CoveRemote(args) => args,
        Route::Direct(args) => args,
    };
    if uses_remote_marker {
        match remote::run_codex_with_osc_marker(&real_codex, &routed, &launch_id) {
            Ok(code) => return Ok(code),
            Err(error) => {
                eprintln!(
                    "codex-cove: terminal marker unavailable ({error}); continuing with native Codex"
                );
            }
        }
    }
    exec_codex(&real_codex, &routed, Some(&launch_id))
}

fn exec_codex(real_codex: &Path, args: &[String], launch_id: Option<&str>) -> io::Result<i32> {
    let mut command = Command::new(real_codex);
    command
        .args(args)
        .env("CODEX_COVE_BYPASS", "1")
        .env_remove("CODEX_COVE_REAL_CODEX")
        .env_remove("CODEX_COVE_TRACE_BROKER");
    if let Some(launch_id) = launch_id {
        command.env("CODEX_COVE_LAUNCH_ID", launch_id);
    }
    let error = command.exec();
    Err(error)
}

fn ensure_daemon(real_codex: &Path, timeout: Duration) -> bool {
    let child = Command::new(real_codex)
        .args(["app-server", "daemon", "start"])
        .env("CODEX_COVE_BYPASS", "1")
        .env_remove("CODEX_COVE_TRACE_BROKER")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    let Ok(mut child) = child else {
        trace_broker("daemon_start=false reason=spawn_failed");
        return false;
    };
    let start = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                trace_broker(&format!("daemon_start_status={status}"));
                return status.success();
            }
            Ok(None) if start.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(25));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                trace_broker("daemon_start=false reason=timeout");
                return false;
            }
            Err(error) => {
                trace_broker(&format!(
                    "daemon_start=false reason=wait_error kind={:?}",
                    error.kind()
                ));
                return false;
            }
        }
    }
}

fn select_app_server_mode(
    real_codex: &Path,
    timeout: Duration,
    max_bytes: usize,
) -> Option<AppServerMode> {
    if ensure_daemon(real_codex, timeout) {
        let proxy = probe_app_server_rpc(real_codex, AppServerMode::Proxy, timeout, max_bytes);
        trace_broker(&format!(
            "readiness mode=proxy available={} detail={}",
            proxy.available, proxy.detail
        ));
        if proxy.available {
            return Some(AppServerMode::Proxy);
        }
        eprintln!(
            "codex-cove: durable app-server unavailable ({})",
            proxy.detail
        );
    }
    let direct_stdio = probe_direct_stdio(real_codex, timeout);
    trace_broker(&format!(
        "direct_stdio_advertised available={} detail={}",
        direct_stdio.available, direct_stdio.detail
    ));
    if direct_stdio.available {
        let direct =
            probe_app_server_rpc(real_codex, AppServerMode::DirectStdio, timeout, max_bytes);
        trace_broker(&format!(
            "readiness mode=direct-stdio available={} detail={}",
            direct.available, direct.detail
        ));
        if direct.available {
            return Some(AppServerMode::DirectStdio);
        }
        eprintln!(
            "codex-cove: direct app-server unavailable ({})",
            direct.detail
        );
    }
    None
}

fn trace_broker_enabled() -> bool {
    is_truthy(env::var("CODEX_COVE_TRACE_BROKER").ok().as_deref())
}

fn trace_broker(message: &str) {
    if trace_broker_enabled() {
        eprintln!("codex-cove-trace: {message}");
    }
}

fn should_use_remote_marker(config: &Config) -> bool {
    if env::var_os("SSH_CONNECTION").is_none() && env::var_os("SSH_TTY").is_none() {
        return false;
    }
    fs::symlink_metadata(&config.event_socket).is_ok_and(|metadata| {
        metadata.file_type().is_socket()
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.permissions().mode() & 0o077 == 0
    })
}

fn register_launch(
    config: &Config,
    launch_id: &str,
    decision_socket: &Path,
    osc_marker: Option<&str>,
) {
    let payload = json!({
        "type": "launch",
        "pid": std::process::id(),
        "parentPid": parent_process_id(),
        "cwd": env::current_dir().ok(),
        "tty": controlling_tty(),
        "termProgram": env::var("TERM_PROGRAM").ok(),
        "termProgramVersion": env::var("TERM_PROGRAM_VERSION").ok(),
        "tmuxPane": env::var("TMUX_PANE").ok(),
        "weztermPane": env::var("WEZTERM_PANE").ok(),
        "decisionSocket": decision_socket,
        "oscMarker": osc_marker,
    });
    let event = CoveEvent::new(
        "launch",
        if env::var_os("CODEX_COVE_HOST_ID").is_some() {
            EventSource::RemoteCli
        } else {
            EventSource::LocalCli
        },
        "pending",
        Some(launch_id.to_owned()),
        payload,
    );
    let _ = send_event_one_way(
        &config.event_socket,
        &event,
        Duration::from_millis(50),
        config.max_frame_bytes,
    );
}

fn parent_process_id() -> u32 {
    // POSIX getppid has no failure mode and returns current parent process ID.
    unsafe { libc::getppid() as u32 }
}

fn controlling_tty() -> Option<String> {
    let environment_tty = env::var("TTY").ok();
    select_controlling_tty(environment_tty.as_deref(), stdin_tty_name)
}

fn select_controlling_tty(
    environment_tty: Option<&str>,
    fallback: impl FnOnce() -> Option<String>,
) -> Option<String> {
    environment_tty
        .and_then(normalize_tty_name)
        .or_else(|| fallback().as_deref().and_then(normalize_tty_name))
}

fn stdin_tty_name() -> Option<String> {
    let mut buffer = vec![0 as libc::c_char; 4_096];
    // SAFETY: `buffer` is writable for its supplied length. `ttyname_r` writes
    // a NUL-terminated string on success and does not retain the pointer.
    let result = unsafe { libc::ttyname_r(libc::STDIN_FILENO, buffer.as_mut_ptr(), buffer.len()) };
    if result != 0 {
        return None;
    }
    // SAFETY: successful `ttyname_r` guarantees NUL termination within the
    // caller-provided buffer.
    let value = unsafe { CStr::from_ptr(buffer.as_ptr()) };
    value.to_str().ok().map(ToOwned::to_owned)
}

fn normalize_tty_name(raw: &str) -> Option<String> {
    let value = raw.trim();
    if value.is_empty() || value.len() > 128 || !value.starts_with("/dev/") {
        return None;
    }
    let suffix = &value["/dev/".len()..];
    let components: Vec<&str> = suffix.split('/').collect();
    if components.is_empty()
        || components.iter().any(|component| {
            component.is_empty()
                || *component == "."
                || *component == ".."
                || !component
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
        })
    {
        return None;
    }
    Some(format!("/dev/{}", components.join("/")))
}

fn run_internal_broker(args: &[String]) -> io::Result<i32> {
    let listen = flag_path(args, "--listen")?;
    let launch_id = flag_value(args, "--launch-id")?;
    let real_codex = flag_path(args, "--real-codex")?;
    let mode = AppServerMode::parse(&flag_value(args, "--mode")?)?;
    let config = Config::load()?;
    run_broker(&listen, &launch_id, &real_codex, &config, mode)
}

fn run_management(args: &[String]) -> io::Result<i32> {
    let Some(command) = args.first().map(String::as_str) else {
        print_help();
        return Ok(0);
    };
    match command {
        "launch" => run_codex_shim(&args[1..]),
        "hook" => {
            hook::run_hook(&Config::load()?)?;
            Ok(0)
        }
        "broker" => run_internal_broker(&args[1..]),
        "remote-relay" => {
            let config = Config::load()?;
            remote::relay(
                &mut io::stdin().lock(),
                &mut io::stdout().lock(),
                config.max_frame_bytes,
            )?;
            Ok(0)
        }
        "remote-relay-server" => {
            let config = Config::load()?;
            remote::run_relay_server(&config)?;
            Ok(0)
        }
        "remote-install" => management_remote_install(args),
        "osc-marker" => {
            let separator = args
                .iter()
                .position(|arg| arg == "--")
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing --"))?;
            let marker = args
                .get(1)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing marker"))?;
            remote::run_with_osc_marker(&args[separator + 1..], marker)
        }
        "doctor" => management_doctor(args),
        "privacy" => management_privacy(args),
        "theme" => management_theme(args),
        "remote" => management_remote(args),
        "install" | "repair" => management_install(args, false),
        "uninstall" => management_install(args, true),
        "--help" | "-h" | "help" => {
            print_help();
            Ok(0)
        }
        "--version" | "-V" => {
            println!("codex-cove {}", env!("CARGO_PKG_VERSION"));
            Ok(0)
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("unknown command {command}"),
        )),
    }
}

fn management_doctor(args: &[String]) -> io::Result<i32> {
    let config = Config::load()?;
    let current = env::current_exe()?;
    let real_codex = find_real_codex(&config, &current).ok();
    let report = doctor::run(&config, real_codex.as_deref());
    if args.iter().any(|arg| arg == "--json") {
        println!(
            "{}",
            serde_json::to_string_pretty(&report)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
        );
    } else {
        for check in &report.checks {
            println!("{:?}\t{}\t{}", check.status, check.name, check.detail);
        }
    }
    Ok(if report.healthy { 0 } else { 1 })
}

fn management_privacy(args: &[String]) -> io::Result<i32> {
    let mode = args
        .get(1)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "usage: privacy auto|on|off"))?;
    let privacy = match mode.as_str() {
        "auto" => PrivacyMode::Auto,
        "on" => PrivacyMode::On,
        "off" => PrivacyMode::Off,
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "privacy mode must be auto, on, or off",
            ));
        }
    };
    let config_path = Config::default_path()?;
    let config = update_privacy_from_path(&config_path, &home_directory()?, privacy)?;
    let event = CoveEvent::new(
        "privacy.changed",
        EventSource::LocalCli,
        "privacy",
        None,
        json!({ "mode": mode }),
    );
    if let Err(error) = send_event_one_way(
        &config.event_socket,
        &event,
        Duration::from_millis(250),
        config.max_frame_bytes,
    ) && fs::symlink_metadata(&config.event_socket).is_ok()
    {
        return Err(io::Error::new(
            error.kind(),
            format!("privacy setting was saved, but the running Cove app was not updated: {error}"),
        ));
    }
    println!("{mode}");
    Ok(0)
}

fn update_privacy_from_path(
    config_path: &Path,
    lock_root: &Path,
    privacy: PrivacyMode,
) -> io::Result<Config> {
    let _mutation_guard = ConfigMutationGuard::acquire(lock_root)?;
    let mut config = Config::load_from(config_path)?;
    config.privacy = privacy;
    config.save_to(config_path)?;
    Ok(config)
}

fn management_theme(args: &[String]) -> io::Result<i32> {
    let operation = args.get(1).map(String::as_str).unwrap_or("");
    let config = Config::load()?;
    match operation {
        "import" => {
            let input = flag_path_at(args, 2)?;
            let bytes = fs::read(&input)?;
            if bytes.len() > config.max_frame_bytes {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "theme too large",
                ));
            }
            let value: Value = serde_json::from_slice(&bytes)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            validate_theme(&value)?;
            let name = value
                .pointer("/palette/name")
                .and_then(Value::as_str)
                .or_else(|| value.get("family").and_then(Value::as_str))
                .unwrap();
            fs::create_dir_all(&config.theme_directory)?;
            fs::set_permissions(&config.theme_directory, fs::Permissions::from_mode(0o700))?;
            let destination = config
                .theme_directory
                .join(format!("{}.json", safe_filename(name)));
            atomic_write_json(&destination, &value)?;
            println!("{}", destination.display());
            Ok(0)
        }
        "export" => {
            let name = args
                .get(2)
                .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing theme name"))?;
            let source = config
                .theme_directory
                .join(format!("{}.json", safe_filename(name)));
            let bytes = fs::read(source)?;
            if let Some(output) = args.get(3) {
                fs::write(output, bytes)?;
            } else {
                io::stdout().write_all(&bytes)?;
            }
            Ok(0)
        }
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "usage: theme import FILE | theme export NAME [FILE]",
        )),
    }
}

const REMOTE_USAGE: &str = "usage: remote add ALIAS | remote deploy ALIAS (--artifact ABSOLUTE_PATH | --plan) | remote doctor ALIAS | remote remove ALIAS [--plan | --forget]";

#[derive(Debug, Clone, PartialEq, Eq)]
enum RemoteManagementAction {
    Add { alias: String },
    Deploy { alias: String, artifact: PathBuf },
    DeployPlan { alias: String },
    Doctor { alias: String },
    Remove { alias: String },
    RemovePlan { alias: String },
    Forget { alias: String },
}

impl RemoteManagementAction {
    fn alias(&self) -> &str {
        match self {
            Self::Add { alias }
            | Self::Deploy { alias, .. }
            | Self::DeployPlan { alias }
            | Self::Doctor { alias }
            | Self::Remove { alias }
            | Self::RemovePlan { alias }
            | Self::Forget { alias } => alias,
        }
    }

    fn requires_configured_alias(&self) -> bool {
        !matches!(self, Self::Add { .. })
    }

    fn mutates_remote_hosts(&self) -> bool {
        matches!(
            self,
            Self::Add { .. } | Self::Remove { .. } | Self::Forget { .. }
        )
    }
}

#[derive(Debug, PartialEq, Eq)]
struct RemoteManagementResult {
    persist_config: bool,
    output: Vec<u8>,
}

fn remote_usage_error() -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, REMOTE_USAGE)
}

struct ConfigMutationGuard {
    _file: File,
}

impl ConfigMutationGuard {
    /// Serialize all helper-owned configuration and integration mutations on a
    /// directory inode that survives staging or removal of the support tree.
    /// Locking HOME itself creates no first-install artifact and prevents a
    /// full uninstall from splitting the advisory lock by recreating support.
    fn acquire(lock_root: &Path) -> io::Result<Self> {
        let file = OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW | libc::O_DIRECTORY)
            .open(lock_root)?;
        let metadata = file.metadata()?;
        if !metadata.is_dir() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!(
                    "config mutation lock root must be a current-user real directory: {}",
                    lock_root.display()
                ),
            ));
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = io::Error::last_os_error();
            if error
                .raw_os_error()
                .is_some_and(|code| code == libc::EWOULDBLOCK || code == libc::EAGAIN)
            {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "another Codex Cove configuration update is in progress",
                ));
            }
            return Err(error);
        }
        Ok(Self { _file: file })
    }
}

impl Drop for ConfigMutationGuard {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self._file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

/// Holds the same persistent advisory lock as the Cove application while a
/// host-list mutation is committed. Requiring Cove to be stopped prevents a
/// removed alias from surviving in the app's in-memory relay set and issuing
/// later SSH reconnect attempts after `--forget` reports success.
struct RemoteHostMutationGuard {
    _file: File,
    runtime_directory: PathBuf,
}

impl RemoteHostMutationGuard {
    fn acquire(support_directory: &Path) -> io::Result<Self> {
        let runtime_directory = support_directory.join("run");
        Self::prepare_owned_directory(support_directory, 0o700)?;
        Self::prepare_owned_directory(&runtime_directory, 0o700)?;

        let lock_path = runtime_directory.join("instance.lock");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
            .open(&lock_path)?;
        let metadata = file.metadata()?;
        if !metadata.is_file()
            || metadata.uid() != unsafe { libc::geteuid() }
            || metadata.nlink() != 1
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("unsafe Codex Cove instance lock at {}", lock_path.display()),
            ));
        }
        if unsafe { libc::fchmod(file.as_raw_fd(), 0o600) } != 0 {
            return Err(io::Error::last_os_error());
        }
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            let error = io::Error::last_os_error();
            if error
                .raw_os_error()
                .is_some_and(|code| code == libc::EWOULDBLOCK || code == libc::EAGAIN)
            {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "Codex Cove is running; quit it before changing remote hosts",
                ));
            }
            return Err(error);
        }
        Ok(Self {
            _file: file,
            runtime_directory,
        })
    }

    fn validate_config_runtime(&self, configured_runtime: &Path) -> io::Result<()> {
        if configured_runtime != self.runtime_directory {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "configured runtime directory does not match the canonical Codex Cove host-mutation lock",
            ));
        }
        Ok(())
    }

    fn prepare_owned_directory(path: &Path, mode: u32) -> io::Result<()> {
        match fs::symlink_metadata(path) {
            Ok(metadata) => {
                if !metadata.is_dir()
                    || metadata.file_type().is_symlink()
                    || metadata.uid() != unsafe { libc::geteuid() }
                {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        format!("unsafe Codex Cove directory at {}", path.display()),
                    ));
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let parent = path.parent().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "directory has no parent")
                })?;
                let parent_metadata = fs::symlink_metadata(parent)?;
                if !parent_metadata.is_dir()
                    || parent_metadata.file_type().is_symlink()
                    || parent_metadata.uid() != unsafe { libc::geteuid() }
                {
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        format!("unsafe parent directory at {}", parent.display()),
                    ));
                }
                fs::create_dir(path)?;
            }
            Err(error) => return Err(error),
        }
        fs::set_permissions(path, fs::Permissions::from_mode(mode))
    }
}

impl Drop for RemoteHostMutationGuard {
    fn drop(&mut self) {
        // Closing the descriptor normally releases flock, but a child spawned
        // concurrently can briefly inherit the same open file description
        // before O_CLOEXEC takes effect. Explicitly unlocking makes release
        // immediate and mirrors the remote relay singleton guard.
        unsafe {
            libc::flock(self._file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

fn parse_remote_management_action(args: &[String]) -> io::Result<RemoteManagementAction> {
    let operation = args.get(1).ok_or_else(remote_usage_error)?;
    let alias = args.get(2).ok_or_else(remote_usage_error)?;
    remote::validate_alias(alias)?;

    let action = match (operation.as_str(), &args[3..]) {
        ("add", []) => RemoteManagementAction::Add {
            alias: alias.clone(),
        },
        ("deploy", [flag]) if flag == "--plan" => RemoteManagementAction::DeployPlan {
            alias: alias.clone(),
        },
        ("deploy", [flag, artifact]) if flag == "--artifact" => RemoteManagementAction::Deploy {
            alias: alias.clone(),
            artifact: PathBuf::from(artifact),
        },
        ("doctor", []) => RemoteManagementAction::Doctor {
            alias: alias.clone(),
        },
        ("remove", []) => RemoteManagementAction::Remove {
            alias: alias.clone(),
        },
        ("remove", [flag]) if flag == "--plan" => RemoteManagementAction::RemovePlan {
            alias: alias.clone(),
        },
        ("remove", [flag]) if flag == "--forget" => RemoteManagementAction::Forget {
            alias: alias.clone(),
        },
        _ => return Err(remote_usage_error()),
    };
    Ok(action)
}

fn execute_remote_management_action(
    action: &RemoteManagementAction,
    config: &mut Config,
    executor: &mut impl remote::CommandExecutor,
) -> io::Result<RemoteManagementResult> {
    let alias = action.alias();
    if action.requires_configured_alias()
        && !config.remote_hosts.iter().any(|host| host.alias == alias)
    {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "remote alias not configured; run remote add first",
        ));
    }

    let result = match action {
        RemoteManagementAction::Add { .. } => {
            remote::add(config, alias)?;
            RemoteManagementResult {
                persist_config: true,
                output: format!("{alias}\n").into_bytes(),
            }
        }
        RemoteManagementAction::Deploy { artifact, .. } => {
            remote::deploy(executor, alias, artifact)?;
            RemoteManagementResult {
                persist_config: false,
                output: format!("deployed {alias}\n").into_bytes(),
            }
        }
        RemoteManagementAction::DeployPlan { .. } => {
            let plan = remote::plan(config, "deploy", alias)?;
            let mut output = serde_json::to_vec_pretty(&plan)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            output.push(b'\n');
            RemoteManagementResult {
                persist_config: false,
                output,
            }
        }
        RemoteManagementAction::Doctor { .. } => {
            let results = remote::execute_specs(executor, &[remote::doctor_spec(alias)?])?;
            RemoteManagementResult {
                persist_config: false,
                output: results[0].stdout.clone(),
            }
        }
        RemoteManagementAction::Remove { .. } => {
            remote::execute_specs(executor, &[remote::remove_spec(alias)?])?;
            remote::remove(config, alias);
            RemoteManagementResult {
                persist_config: true,
                output: format!("removed {alias}\n").into_bytes(),
            }
        }
        RemoteManagementAction::RemovePlan { .. } => {
            let plan = remote::plan(config, "remove", alias)?;
            let mut output = serde_json::to_vec_pretty(&plan)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            output.push(b'\n');
            RemoteManagementResult {
                persist_config: false,
                output,
            }
        }
        RemoteManagementAction::Forget { .. } => {
            remote::remove(config, alias);
            RemoteManagementResult {
                persist_config: true,
                output: format!("forgot {alias}\n").into_bytes(),
            }
        }
    };
    Ok(result)
}

fn execute_remote_management_from_path(
    action: &RemoteManagementAction,
    config_path: &Path,
    lock_root: &Path,
    executor: &mut impl remote::CommandExecutor,
) -> io::Result<RemoteManagementResult> {
    let support_directory = config_path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "config path has no parent"))?;
    let _config_guard = action
        .mutates_remote_hosts()
        .then(|| ConfigMutationGuard::acquire(lock_root))
        .transpose()?;
    let _mutation_guard = action
        .mutates_remote_hosts()
        .then(|| RemoteHostMutationGuard::acquire(support_directory))
        .transpose()?;
    // Load only after the canonical lock is held. Otherwise two concurrent
    // commands can both mutate stale snapshots, allowing a later save to lose
    // an update or even resurrect an alias after `--forget` reported success.
    let mut config = Config::load_from(config_path)?;
    if let Some(guard) = _mutation_guard.as_ref() {
        guard.validate_config_runtime(&config.runtime_directory)?;
    }
    let result = execute_remote_management_action(action, &mut config, executor)?;
    if result.persist_config {
        config.save_to(config_path)?;
    }
    Ok(result)
}

fn management_remote(args: &[String]) -> io::Result<i32> {
    let action = parse_remote_management_action(args)?;
    let config_path = Config::default_path()?;
    let result = execute_remote_management_from_path(
        &action,
        &config_path,
        &home_directory()?,
        &mut remote::SystemExecutor,
    )?;
    io::stdout().write_all(&result.output)?;
    Ok(0)
}

fn management_remote_install(args: &[String]) -> io::Result<i32> {
    let expected = flag_value(args, "--expected-sha256")?;
    let current = env::current_exe()?;
    if install::sha256_file(&current)? != expected {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "remote artifact checksum mismatch",
        ));
    }
    let layout = install::InstallLayout::current()?;
    let _config_guard = ConfigMutationGuard::acquire(&layout.home)?;
    let config = Config::for_home(&layout.home);
    let real_codex = find_real_codex(&config, &current)?;
    install::apply_install(&current, None, &real_codex, &layout, None)?;
    if !run_bounded(
        Command::new(&real_codex)
            .args(["app-server", "daemon", "bootstrap"])
            .env("CODEX_COVE_BYPASS", "1"),
        Duration::from_secs(10),
    ) {
        eprintln!("codex-cove: remote daemon bootstrap incomplete; checking direct stdio fallback");
    }
    report_app_server_mode(&real_codex, Duration::from_secs(10), config.max_frame_bytes);
    println!("remote integration installed; review hooks with /hooks");
    Ok(0)
}

fn management_install(args: &[String], uninstall: bool) -> io::Result<i32> {
    let layout = install::InstallLayout::current()?;
    let keep_settings = args.iter().any(|arg| arg == "--keep-settings");
    let keep_app = args.iter().any(|arg| arg == "--keep-app");
    if keep_app && !uninstall {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "--keep-app is valid only with uninstall",
        ));
    }
    if args.iter().any(|arg| arg == "--plan") {
        let plan = if uninstall {
            install::uninstall_plan_for_layout_with_options(&layout, keep_settings, keep_app)?
        } else {
            let config = Config::load()?;
            install::install_plan_for_layout(&env::current_exe()?, &config, &layout)?
        };
        println!(
            "{}",
            serde_json::to_string_pretty(&plan)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
        );
        return Ok(if plan.blocked { 2 } else { 0 });
    }

    // Hold the same stable mutation lock used by privacy and remote-host
    // writers from the first mutable load through editor/app cleanup and the
    // final integration mutation. The lock root is outside the support tree,
    // so full uninstall cannot create a second lock inode mid-transaction.
    let _config_guard = ConfigMutationGuard::acquire(&layout.home)?;

    if uninstall {
        let mut editor_cleanup = SystemEditorExtensionCleaner;
        execute_local_uninstall(
            &layout,
            keep_settings,
            keep_app,
            &mut editor_cleanup,
            unregister_login_item,
            sync_login_item,
        )?;
        if keep_app {
            println!("Codex Cove integration removed; app retained for external package manager");
        } else {
            println!("Codex Cove integration removed");
        }
        return Ok(0);
    }

    let current = env::current_exe()?;
    let app_path = args
        .iter()
        .position(|arg| arg == "--app-path")
        .and_then(|index| args.get(index + 1))
        .map(PathBuf::from)
        .or_else(|| infer_app_path(&current))
        .or_else(|| {
            install::read_manifest(&layout)
                .ok()
                .and_then(|manifest| manifest.app_path)
        })
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                "cannot infer installed app; pass --app-path",
            )
        })?;
    if !app_path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "--app-path must be absolute",
        ));
    }
    let mut config = Config::load()?;
    let real_codex = find_real_codex(&config, &current)?;
    config.real_codex = Some(real_codex.clone());
    let bundled_vsix = args
        .iter()
        .position(|arg| arg == "--editor-vsix")
        .and_then(|index| args.get(index + 1))
        .map(PathBuf::from)
        .or_else(|| {
            let candidate = app_path.join("Contents/Resources/extension/codex-cove.vsix");
            candidate.exists().then_some(candidate)
        });
    const EXTENSION_ID: &str = "codex-cove-local.cove-extension";
    let prior_manifest = match install::read_manifest(&layout) {
        Ok(manifest) => Some(manifest),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => {
            return Err(io::Error::new(
                error.kind(),
                format!(
                    "cannot safely preserve editor cleanup obligations from the existing install manifest: {error}"
                ),
            ));
        }
    };
    if let Some(previous_id) = prior_manifest
        .as_ref()
        .and_then(|manifest| manifest.editor_extension_id.as_deref())
        && previous_id != EXTENSION_ID
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!(
                "existing manifest records unexpected editor extension {previous_id}; refusing to discard its cleanup obligation"
            ),
        ));
    }
    let previous_targets = prior_manifest
        .as_ref()
        .filter(|manifest| manifest.editor_extension_id.as_deref() == Some(EXTENSION_ID))
        .map(install::InstallManifest::editor_cleanup_targets)
        .transpose()?
        .unwrap_or_default();
    let extension_id =
        (bundled_vsix.is_some() || !previous_targets.is_empty()).then_some(EXTENSION_ID);
    let mut manifest = install::apply_install(
        &current,
        Some(&app_path),
        &real_codex,
        &layout,
        extension_id,
    )?;
    let mut extension_warnings = Vec::new();
    if let Some(vsix) = bundled_vsix {
        let mut commands = SystemEditorExtensionCommands::default();
        let report =
            install_editor_extension(&mut commands, &vsix, EXTENSION_ID, &previous_targets);
        match install::record_editor_extension_installation(
            &layout,
            Some(EXTENSION_ID),
            &report.cleanup_targets,
        ) {
            Ok(updated) => manifest = updated,
            Err(error) => extension_warnings.push(format!(
                "could not write precise editor targets ({error}); conservative legacy cleanup obligations remain recorded"
            )),
        }
        extension_warnings.extend(report.failures);
    } else if extension_id.is_some() {
        match install::record_editor_extension_installation(
            &layout,
            Some(EXTENSION_ID),
            &previous_targets,
        ) {
            Ok(updated) => manifest = updated,
            Err(error) => extension_warnings.push(format!(
                "could not preserve precise prior editor targets ({error}); conservative legacy cleanup obligations remain recorded"
            )),
        }
    }
    if !run_bounded(
        Command::new(&real_codex)
            .args(["app-server", "daemon", "bootstrap"])
            .env("CODEX_COVE_BYPASS", "1"),
        Duration::from_secs(10),
    ) {
        eprintln!("codex-cove: daemon bootstrap incomplete; checking direct stdio fallback");
    }
    report_app_server_mode(&real_codex, Duration::from_secs(10), config.max_frame_bytes);
    println!(
        "{}",
        serde_json::to_string_pretty(&manifest)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
    );
    if !extension_warnings.is_empty() {
        eprintln!(
            "codex-cove: editor extension installation incomplete: {}; successful or unverified editor targets remain recorded in the install manifest for safe cleanup and retry",
            extension_warnings.join("; ")
        );
    }
    Ok(0)
}

fn report_app_server_mode(real_codex: &Path, timeout: Duration, max_bytes: usize) {
    match select_app_server_mode(real_codex, timeout, max_bytes) {
        Some(AppServerMode::Proxy) => {}
        Some(AppServerMode::DirectStdio) => {
            eprintln!(
                "codex-cove: durable daemon unavailable; direct app-server stdio fallback is ready"
            );
        }
        None => {
            eprintln!("codex-cove: app-server unavailable; native Codex remains available");
        }
    }
}

fn infer_app_path(executable: &Path) -> Option<PathBuf> {
    executable
        .ancestors()
        .find(|ancestor| {
            ancestor
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.ends_with(".app"))
        })
        .map(Path::to_path_buf)
}

#[derive(Debug, Default, PartialEq, Eq)]
struct EditorExtensionInstallReport {
    cleanup_targets: Vec<String>,
    failures: Vec<String>,
}

trait EditorExtensionCommands {
    fn is_available(&mut self, editor: &str) -> bool;
    fn query_extension(&mut self, editor: &str, extension_id: &str) -> io::Result<bool>;
    fn install_extension(&mut self, editor: &str, vsix: &Path) -> io::Result<()>;
    fn uninstall_extension(&mut self, editor: &str, extension_id: &str) -> io::Result<()>;
}

const EDITOR_EXTENSION_COMMAND_TIMEOUT: Duration = Duration::from_secs(30);
const EDITOR_EXTENSION_COMMAND_POLL_INTERVAL: Duration = Duration::from_millis(25);

struct SystemEditorExtensionCommands {
    timeout: Duration,
}

impl Default for SystemEditorExtensionCommands {
    fn default() -> Self {
        Self {
            timeout: EDITOR_EXTENSION_COMMAND_TIMEOUT,
        }
    }
}

impl SystemEditorExtensionCommands {
    fn path(editor: &str) -> io::Result<PathBuf> {
        find_on_path(editor).ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("{editor} CLI is unavailable"),
            )
        })
    }

    #[cfg(test)]
    fn with_timeout(timeout: Duration) -> Self {
        Self { timeout }
    }
}

impl EditorExtensionCommands for SystemEditorExtensionCommands {
    fn is_available(&mut self, editor: &str) -> bool {
        find_on_path(editor).is_some()
    }

    fn query_extension(&mut self, editor: &str, extension_id: &str) -> io::Result<bool> {
        let operation = format!("{editor} extension query");
        let mut command = Command::new(Self::path(editor)?);
        command.arg("--list-extensions");
        let output = run_editor_command_output(&mut command, &operation, self.timeout)?;
        if !output.status.success() {
            return Err(editor_command_exit_error(&operation, &output));
        }
        Ok(output
            .stdout
            .split(|byte| *byte == b'\n')
            .any(|line| line.strip_suffix(b"\r").unwrap_or(line) == extension_id.as_bytes()))
    }

    fn install_extension(&mut self, editor: &str, vsix: &Path) -> io::Result<()> {
        let operation = format!("{editor} extension install");
        let mut command = Command::new(Self::path(editor)?);
        command
            .args(["--install-extension"])
            .arg(vsix)
            .arg("--force");
        run_editor_command_status(&mut command, &operation, self.timeout)
    }

    fn uninstall_extension(&mut self, editor: &str, extension_id: &str) -> io::Result<()> {
        let operation = format!("{editor} extension uninstall");
        let mut command = Command::new(Self::path(editor)?);
        command.args(["--uninstall-extension", extension_id]);
        run_editor_command_status(&mut command, &operation, self.timeout)
    }
}

fn run_editor_command_output(
    command: &mut Command,
    operation: &str,
    timeout: Duration,
) -> io::Result<Output> {
    let mut stdout = tempfile::tempfile().map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("{operation} could not prepare stdout capture: {error}"),
        )
    })?;
    let mut stderr = tempfile::tempfile().map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("{operation} could not prepare stderr capture: {error}"),
        )
    })?;
    let child_stdout = stdout.try_clone().map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("{operation} could not attach stdout capture: {error}"),
        )
    })?;
    let child_stderr = stderr.try_clone().map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("{operation} could not attach stderr capture: {error}"),
        )
    })?;
    command
        .stdout(Stdio::from(child_stdout))
        .stderr(Stdio::from(child_stderr));
    command.process_group(0);
    let mut child = command.spawn().map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("{operation} could not start: {error}"),
        )
    })?;
    let started = std::time::Instant::now();

    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                terminate_remaining_process_group(child.id()).map_err(|error| {
                    io::Error::new(
                        error.kind(),
                        format!("{operation} exited but descendant cleanup failed: {error}"),
                    )
                })?;
                return Ok(Output {
                    status,
                    stdout: read_editor_command_capture(&mut stdout, operation, "stdout")?,
                    stderr: read_editor_command_capture(&mut stderr, operation, "stderr")?,
                });
            }
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(EDITOR_EXTENSION_COMMAND_POLL_INTERVAL);
            }
            Ok(None) => {
                let cleanup = kill_process_group_and_reap(&mut child);
                let stdout = read_editor_command_capture(&mut stdout, operation, "stdout");
                let stderr = read_editor_command_capture(&mut stderr, operation, "stderr");
                let diagnostic = editor_command_capture_diagnostic(
                    stdout.as_deref().unwrap_or_default(),
                    stderr.as_deref().unwrap_or_default(),
                );
                let capture_error = stdout
                    .err()
                    .or_else(|| stderr.err())
                    .map(|error| format!("; capture error: {error}"))
                    .unwrap_or_default();
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!(
                        "{operation} timed out after {timeout:?}; {cleanup}{diagnostic}{capture_error}"
                    ),
                ));
            }
            Err(error) => {
                let cleanup = kill_process_group_and_reap(&mut child);
                return Err(io::Error::new(
                    error.kind(),
                    format!("{operation} wait failed: {error}; {cleanup}"),
                ));
            }
        }
    }
}

fn run_editor_command_status(
    command: &mut Command,
    operation: &str,
    timeout: Duration,
) -> io::Result<()> {
    let output = run_editor_command_output(command, operation, timeout)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(editor_command_exit_error(operation, &output))
    }
}

fn read_editor_command_capture(
    capture: &mut File,
    operation: &str,
    stream: &str,
) -> io::Result<Vec<u8>> {
    capture.seek(SeekFrom::Start(0)).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("{operation} could not rewind captured {stream}: {error}"),
        )
    })?;
    let mut bytes = Vec::new();
    capture.read_to_end(&mut bytes).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("{operation} could not read captured {stream}: {error}"),
        )
    })?;
    Ok(bytes)
}

fn terminate_process_group(pid: u32) -> io::Result<()> {
    let process_group = libc::pid_t::try_from(pid).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("child PID {pid} cannot identify a process group"),
        )
    })?;
    if process_group <= 0 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("child PID {pid} cannot identify a process group"),
        ));
    }
    if unsafe { libc::kill(-process_group, libc::SIGKILL) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn terminate_remaining_process_group(pid: u32) -> io::Result<()> {
    match terminate_process_group(pid) {
        Ok(()) => Ok(()),
        Err(error) if error.raw_os_error() == Some(libc::ESRCH) => Ok(()),
        Err(error) => Err(error),
    }
}

fn kill_process_group_and_reap(child: &mut Child) -> String {
    let pid = child.id();
    let group_kill_result = terminate_process_group(pid);
    let direct_kill_result = if group_kill_result.is_err() {
        Some(child.kill())
    } else {
        None
    };
    let wait_result = child.wait();
    match (group_kill_result, direct_kill_result, wait_result) {
        (Ok(()), _, Ok(status)) => {
            format!("process {pid} group killed and reaped ({status})")
        }
        (Err(group_error), Some(Ok(())), Ok(status)) => format!(
            "process {pid} group kill failed ({group_error}); direct process killed and reaped ({status})"
        ),
        (Err(group_error), Some(Err(kill_error)), Ok(status)) => format!(
            "process {pid} group kill failed ({group_error}) and direct kill failed ({kill_error}), then reaped ({status})"
        ),
        (Ok(()), _, Err(wait_error)) => {
            format!("process {pid} group killed but could not be reaped ({wait_error})")
        }
        (Err(group_error), Some(Ok(())), Err(wait_error)) => format!(
            "process {pid} group kill failed ({group_error}); direct process killed but could not be reaped ({wait_error})"
        ),
        (Err(group_error), Some(Err(kill_error)), Err(wait_error)) => format!(
            "process {pid} group kill failed ({group_error}), direct kill failed ({kill_error}), and wait failed ({wait_error})"
        ),
        (Err(group_error), None, status) => format!(
            "process {pid} group kill failed ({group_error}); unexpected cleanup state ({status:?})"
        ),
    }
}

fn editor_command_exit_error(operation: &str, output: &Output) -> io::Error {
    io::Error::other(format!(
        "{operation} exited {}{}",
        output.status,
        editor_command_capture_diagnostic(&output.stdout, &output.stderr)
    ))
}

fn editor_command_capture_diagnostic(stdout: &[u8], stderr: &[u8]) -> String {
    let preferred = if stderr.iter().any(|byte| !byte.is_ascii_whitespace()) {
        stderr
    } else {
        stdout
    };
    let detail = String::from_utf8_lossy(preferred)
        .trim()
        .chars()
        .take(512)
        .collect::<String>();
    if detail.is_empty() {
        String::new()
    } else {
        format!(": {detail}")
    }
}

fn install_editor_extension<C: EditorExtensionCommands>(
    commands: &mut C,
    vsix: &Path,
    extension_id: &str,
    previous_targets: &[String],
) -> EditorExtensionInstallReport {
    let previous = previous_targets.iter().cloned().collect::<BTreeSet<_>>();
    let mut cleanup = BTreeSet::new();
    let mut failures = Vec::new();
    for editor in install::SUPPORTED_EDITOR_TARGETS {
        if !commands.is_available(editor) {
            if previous.contains(*editor) {
                cleanup.insert((*editor).to_owned());
                let detail =
                    format!("{editor} CLI unavailable; its prior cleanup obligation was retained");
                eprintln!("codex-cove: editor extension {detail}");
                failures.push(detail);
            } else {
                eprintln!(
                    "codex-cove: editor extension skipped for {editor}: CLI unavailable (no cleanup obligation recorded)"
                );
            }
            continue;
        }

        let install_result = commands.install_extension(editor, vsix);
        let verification = commands.query_extension(editor, extension_id);
        match (install_result, verification) {
            (Ok(()), Ok(true)) => {
                cleanup.insert((*editor).to_owned());
                eprintln!("codex-cove: editor extension installed and verified in {editor}");
            }
            (Ok(()), Ok(false)) => {
                let detail = format!(
                    "{editor} reported a successful install, but {extension_id} was not present during verification"
                );
                eprintln!("codex-cove: {detail}");
                failures.push(detail);
            }
            (Ok(()), Err(error)) => {
                cleanup.insert((*editor).to_owned());
                let detail = format!(
                    "{editor} install succeeded but verification failed ({error}); cleanup obligation recorded conservatively"
                );
                eprintln!("codex-cove: {detail}");
                failures.push(detail);
            }
            (Err(error), Ok(true)) => {
                cleanup.insert((*editor).to_owned());
                let detail = format!(
                    "{editor} install command failed ({error}), but {extension_id} is present; cleanup obligation recorded"
                );
                eprintln!("codex-cove: {detail}");
                failures.push(detail);
            }
            (Err(error), Ok(false)) => {
                let detail = format!(
                    "{editor} install failed ({error}); verification confirms {extension_id} is absent"
                );
                eprintln!("codex-cove: {detail}");
                failures.push(detail);
            }
            (Err(install_error), Err(query_error)) => {
                cleanup.insert((*editor).to_owned());
                let detail = format!(
                    "{editor} install failed ({install_error}) and state could not be verified ({query_error}); cleanup obligation recorded conservatively"
                );
                eprintln!("codex-cove: {detail}");
                failures.push(detail);
            }
        }
    }
    EditorExtensionInstallReport {
        cleanup_targets: cleanup.into_iter().collect(),
        failures,
    }
}

trait EditorExtensionCleaner {
    fn uninstall_extension(
        &mut self,
        extension_id: &str,
        targets: &[String],
        restore_targets: &mut Vec<String>,
    ) -> io::Result<()>;
    fn restore_extension(
        &mut self,
        extension_id: &str,
        targets: &[String],
        vsix_path: &Path,
    ) -> io::Result<()>;
}

struct SystemEditorExtensionCleaner;

impl EditorExtensionCleaner for SystemEditorExtensionCleaner {
    fn uninstall_extension(
        &mut self,
        extension_id: &str,
        targets: &[String],
        restore_targets: &mut Vec<String>,
    ) -> io::Result<()> {
        let mut commands = SystemEditorExtensionCommands::default();
        cleanup_editor_extension(&mut commands, extension_id, targets, restore_targets)
    }

    fn restore_extension(
        &mut self,
        extension_id: &str,
        targets: &[String],
        vsix_path: &Path,
    ) -> io::Result<()> {
        let mut commands = SystemEditorExtensionCommands::default();
        restore_editor_extension(&mut commands, extension_id, targets, vsix_path)
    }
}

fn cleanup_editor_extension<C: EditorExtensionCommands>(
    commands: &mut C,
    extension_id: &str,
    targets: &[String],
    restore_targets: &mut Vec<String>,
) -> io::Result<()> {
    let mut failures = Vec::new();
    for editor in targets {
        if !commands.is_available(editor) {
            failures.push(format!(
                "recorded editor {editor} is unreachable because its CLI is unavailable"
            ));
            continue;
        }
        match commands.query_extension(editor, extension_id) {
            Ok(false) => {
                eprintln!(
                    "codex-cove: {extension_id} is already absent from recorded editor {editor}; cleanup verified"
                );
            }
            Err(error) => {
                failures.push(format!("{editor} extension query failed: {error}"));
            }
            Ok(true) => {
                // The target was present before this attempt. Record it before
                // invoking the editor because even a failing command may have
                // removed it and therefore require compensation.
                restore_targets.push(editor.clone());
                match commands.uninstall_extension(editor, extension_id) {
                    Err(error) => {
                        failures.push(format!("{editor} extension uninstall failed: {error}"))
                    }
                    Ok(()) => match commands.query_extension(editor, extension_id) {
                        Ok(false) => eprintln!(
                            "codex-cove: removed and verified editor extension {extension_id} from {editor}"
                        ),
                        Ok(true) => failures.push(format!(
                            "{editor} still reports {extension_id} after uninstall"
                        )),
                        Err(error) => failures.push(format!(
                            "{editor} post-uninstall verification failed: {error}"
                        )),
                    },
                }
            }
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "editor extension cleanup failed ({}); preserving the local helper and manifest so cleanup can be retried",
            failures.join("; ")
        )))
    }
}

fn restore_editor_extension<C: EditorExtensionCommands>(
    commands: &mut C,
    extension_id: &str,
    targets: &[String],
    vsix: &Path,
) -> io::Result<()> {
    let metadata = fs::symlink_metadata(vsix).map_err(|error| {
        io::Error::new(
            error.kind(),
            format!("bundled editor extension is unavailable for compensation: {error}"),
        )
    })?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bundled editor extension is unsafe for compensation",
        ));
    }
    let expected_vsix_sha256 = install::sha256_file(vsix)?;

    let mut failures = Vec::new();
    for editor in targets {
        if !commands.is_available(editor) {
            failures.push(format!("recorded editor {editor} is unreachable"));
            continue;
        }
        if install::sha256_file(vsix)? != expected_vsix_sha256 {
            failures.push("compensation VSIX changed before editor installation".to_owned());
            break;
        }
        match commands.install_extension(editor, vsix) {
            Err(error) => failures.push(format!("{editor} restore failed: {error}")),
            Ok(()) => match commands.query_extension(editor, extension_id) {
                Ok(true) => eprintln!(
                    "codex-cove: restored and verified editor extension {extension_id} in {editor}"
                ),
                Ok(false) => failures.push(format!(
                    "{editor} did not report {extension_id} after compensation"
                )),
                Err(error) => failures.push(format!(
                    "{editor} compensation verification failed: {error}"
                )),
            },
        }
        if install::sha256_file(vsix)? != expected_vsix_sha256 {
            failures.push("compensation VSIX changed during editor installation".to_owned());
            break;
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "editor extension compensation failed ({})",
            failures.join("; ")
        )))
    }
}

fn execute_local_uninstall<C, F, S>(
    layout: &install::InstallLayout,
    keep_settings: bool,
    keep_app: bool,
    editor_cleanup: &mut C,
    mut unregister: F,
    mut sync: S,
) -> io::Result<()>
where
    C: EditorExtensionCleaner,
    F: FnMut(&Path) -> io::Result<()>,
    S: FnMut(&Path) -> io::Result<()>,
{
    if keep_app {
        let mut external_cleanup_started = false;
        let mut progress = LocalUninstallExternalCleanupProgress::default();
        let result = install::apply_uninstall_with_options_before_commit(
            layout,
            keep_settings,
            true,
            |preflight| {
                external_cleanup_started = true;
                run_local_uninstall_external_cleanup(
                    preflight,
                    editor_cleanup,
                    &mut unregister,
                    &mut progress,
                )
            },
        );
        let error = match result {
            Ok(()) => return Ok(()),
            Err(error) => error,
        };
        if !external_cleanup_started || fs::symlink_metadata(&layout.manifest_path).is_err() {
            return Err(error);
        }
        return compensate_preserved_local_uninstall(
            error,
            layout,
            &progress,
            editor_cleanup,
            &mut sync,
        );
    }

    // All local artifact checks complete before either external cleanup or the
    // transactional filesystem mutation begins.
    let preflight = install::preflight_uninstall(layout)?;
    let mut progress = LocalUninstallExternalCleanupProgress::default();
    if let Err(error) = run_local_uninstall_external_cleanup(
        &preflight,
        editor_cleanup,
        &mut unregister,
        &mut progress,
    ) {
        return compensate_preserved_local_uninstall(
            error,
            layout,
            &progress,
            editor_cleanup,
            &mut sync,
        );
    }
    match install::apply_uninstall_with_options(layout, keep_settings, false) {
        Ok(()) => Ok(()),
        Err(error) if fs::symlink_metadata(&layout.manifest_path).is_ok() => {
            compensate_preserved_local_uninstall(
                error,
                layout,
                &progress,
                editor_cleanup,
                &mut sync,
            )
        }
        Err(error) => Err(error),
    }
}

#[derive(Default)]
struct LocalUninstallExternalCleanupProgress {
    editor_restore_targets: Vec<String>,
    login_item_attempted: bool,
}

impl LocalUninstallExternalCleanupProgress {
    fn changed_external_state(&self) -> bool {
        !self.editor_restore_targets.is_empty() || self.login_item_attempted
    }
}

fn compensate_preserved_local_uninstall<C, S>(
    error: io::Error,
    layout: &install::InstallLayout,
    progress: &LocalUninstallExternalCleanupProgress,
    editor_cleanup: &mut C,
    sync: &mut S,
) -> io::Result<()>
where
    C: EditorExtensionCleaner,
    S: FnMut(&Path) -> io::Result<()>,
{
    if !progress.changed_external_state() {
        return Err(error);
    }
    let restored_preflight = match install::preflight_uninstall(layout) {
        Ok(preflight) => preflight,
        Err(validation_error) => {
            let kind = error.kind();
            return Err(io::Error::new(
                kind,
                format!(
                    "{error}; external cleanup compensation was skipped because the preserved installation did not pass validation: {validation_error}"
                ),
            ));
        }
    };
    let compensation = compensate_local_uninstall_external_cleanup(
        &restored_preflight,
        progress,
        editor_cleanup,
        sync,
    );
    let kind = error.kind();
    match compensation {
        Ok(()) => Err(io::Error::new(
            kind,
            format!("{error}; external cleanup was compensated and the installation was preserved"),
        )),
        Err(compensation_error) => Err(io::Error::new(
            kind,
            format!("{error}; external cleanup compensation was incomplete: {compensation_error}"),
        )),
    }
}

fn compensate_local_uninstall_external_cleanup<C, S>(
    preflight: &install::UninstallPreflight,
    progress: &LocalUninstallExternalCleanupProgress,
    editor_cleanup: &mut C,
    sync: &mut S,
) -> io::Result<()>
where
    C: EditorExtensionCleaner,
    S: FnMut(&Path) -> io::Result<()>,
{
    let mut failures = Vec::new();
    if !progress.editor_restore_targets.is_empty() {
        match (
            preflight.manifest().editor_extension_id.as_deref(),
            preflight.removable_app(),
        ) {
            (Some(extension_id), Some(_)) => {
                match snapshot_verified_compensation_vsix(preflight) {
                    Ok(snapshot) => {
                        if let Err(error) = editor_cleanup.restore_extension(
                            extension_id,
                            &progress.editor_restore_targets,
                            snapshot.path(),
                        ) {
                            failures.push(error.to_string());
                        }
                    }
                    Err(error) => failures.push(format!(
                        "editor extension compensation input failed validation: {error}"
                    )),
                }
                if let Err(error) = preflight.validate_removable_app() {
                    failures.push(format!(
                        "installed app changed during editor extension compensation: {error}"
                    ));
                }
            }
            _ => failures.push(
                "editor extension compensation lacks a validated app or extension identifier"
                    .to_owned(),
            ),
        }
    }
    if progress.login_item_attempted {
        match preflight.removable_app() {
            Some(app_path) => {
                match preflight.validate_removable_app() {
                    Ok(()) => {
                        if let Err(error) = sync(app_path) {
                            failures.push(format!(
                                "launch-at-login compensation failed: {error}"
                            ));
                        }
                    }
                    Err(error) => failures.push(format!(
                        "launch-at-login compensation skipped because the installed app changed: {error}"
                    )),
                }
            }
            None => failures
                .push("launch-at-login compensation lacks a validated installed app".to_owned()),
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(io::Error::other(failures.join("; ")))
    }
}

fn snapshot_verified_compensation_vsix(
    preflight: &install::UninstallPreflight,
) -> io::Result<tempfile::NamedTempFile> {
    preflight.validate_removable_app()?;
    let app_path = preflight.removable_app().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "installed app is unavailable for editor extension compensation",
        )
    })?;
    let source_path = app_path.join("Contents/Resources/extension/codex-cove.vsix");
    let source_metadata = fs::symlink_metadata(&source_path)?;
    if !source_metadata.is_file()
        || source_metadata.file_type().is_symlink()
        || source_metadata.uid() != unsafe { libc::geteuid() }
        || source_metadata.nlink() != 1
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "bundled editor extension is not a safe current-user file",
        ));
    }
    let mut source = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(&source_path)?;
    if !same_file_snapshot(&source_metadata, &source.metadata()?) {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "bundled editor extension changed while opening",
        ));
    }
    let source_sha256 = install::sha256_file(&source_path)?;

    let mut snapshot = tempfile::Builder::new()
        .prefix("codex-cove-extension-compensation-")
        .suffix(".vsix")
        .tempfile()?;
    io::copy(&mut source, &mut snapshot)?;
    snapshot.as_file_mut().flush()?;
    snapshot.as_file().sync_all()?;
    fs::set_permissions(snapshot.path(), fs::Permissions::from_mode(0o400))?;
    if !same_file_snapshot(&source_metadata, &source.metadata()?) {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "bundled editor extension changed while snapshotting",
        ));
    }
    if install::sha256_file(&source_path)? != source_sha256
        || install::sha256_file(snapshot.path())? != source_sha256
    {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "bundled editor extension contents changed while snapshotting",
        ));
    }
    preflight.validate_removable_app()?;
    Ok(snapshot)
}

fn same_file_snapshot(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    left.dev() == right.dev()
        && left.ino() == right.ino()
        && left.uid() == right.uid()
        && left.nlink() == right.nlink()
        && left.len() == right.len()
        && left.mode() == right.mode()
        && left.mtime() == right.mtime()
        && left.mtime_nsec() == right.mtime_nsec()
        && left.ctime() == right.ctime()
        && left.ctime_nsec() == right.ctime_nsec()
}

fn run_local_uninstall_external_cleanup<C, F>(
    preflight: &install::UninstallPreflight,
    editor_cleanup: &mut C,
    unregister: &mut F,
    progress: &mut LocalUninstallExternalCleanupProgress,
) -> io::Result<()>
where
    C: EditorExtensionCleaner,
    F: FnMut(&Path) -> io::Result<()>,
{
    if let Some(extension_id) = preflight.manifest().editor_extension_id.as_deref() {
        let targets = preflight.manifest().editor_cleanup_targets()?;
        editor_cleanup
            .uninstall_extension(
                extension_id,
                &targets,
                &mut progress.editor_restore_targets,
            )
            .map_err(|error| {
                io::Error::new(
                    error.kind(),
                    format!(
                        "editor extension cleanup failed: {error}; preserving the local helper and manifest so cleanup can be retried"
                    ),
                )
            })?;
    }
    if let Some(app_path) = preflight.removable_app() {
        // Editor cleanup can be slow. Revalidate the exact app immediately
        // before asking it to mutate launch-at-login registration.
        preflight.validate_removable_app()?;
        progress.login_item_attempted = true;
        unregister(app_path)?;
    }
    Ok(())
}

fn unregister_login_item(app_path: &Path) -> io::Result<()> {
    run_login_item_maintenance(app_path, "--unregister-login-item-and-quit", "cleanup")
}

fn sync_login_item(app_path: &Path) -> io::Result<()> {
    run_login_item_maintenance(app_path, "--sync-login-item-and-quit", "sync")
}

fn run_login_item_maintenance(app_path: &Path, argument: &str, operation: &str) -> io::Result<()> {
    let executable = app_path.join("Contents/MacOS/CodexCove");
    if !codex_cove::config::is_executable(&executable) {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "installed app cannot run its launch-at-login cleanup",
        ));
    }
    let mut command = Command::new(executable);
    command.arg(argument);
    if run_bounded(&mut command, Duration::from_secs(5)) {
        Ok(())
    } else {
        Err(io::Error::other(format!(
            "launch-at-login {operation} did not complete; preserving installation"
        )))
    }
}

fn find_on_path(executable: &str) -> Option<PathBuf> {
    env::var_os("PATH")
        .into_iter()
        .flat_map(|path| env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join(executable))
        .find(|candidate| codex_cove::config::is_executable(candidate))
}

fn run_bounded(command: &mut Command, timeout: Duration) -> bool {
    command.process_group(0);
    let Ok(mut child) = command.stdout(Stdio::null()).stderr(Stdio::null()).spawn() else {
        return false;
    };
    let started = std::time::Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let cleanup_succeeded = terminate_remaining_process_group(child.id()).is_ok();
                return status.success() && cleanup_succeeded;
            }
            Ok(None) if started.elapsed() < timeout => {
                std::thread::sleep(Duration::from_millis(25))
            }
            Ok(None) => {
                let _ = kill_process_group_and_reap(&mut child);
                return false;
            }
            Err(_) => {
                let _ = kill_process_group_and_reap(&mut child);
                return false;
            }
        }
    }
}

fn validate_theme(value: &Value) -> io::Result<()> {
    if value.get("schemaVersion").and_then(Value::as_u64) != Some(1)
        || !matches!(
            value.get("family").and_then(Value::as_str),
            Some("nativeGlass" | "retroTerminal" | "minimalOLED")
        )
        || !value.get("palette").is_some_and(Value::is_object)
        || !value.get("typography").is_some_and(Value::is_object)
        || value
            .pointer("/palette/name")
            .and_then(Value::as_str)
            .is_none()
        || !matches!(
            value.get("blur").and_then(Value::as_str),
            Some("off" | "thin" | "regular" | "thick")
        )
        || !opacity_is_valid(value.get("collapsedOpacity"))
        || !opacity_is_valid(value.get("expandedOpacity"))
        || !value.get("animation").is_some_and(Value::is_object)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "theme does not match theme-definition.v1",
        ));
    }
    Ok(())
}

fn opacity_is_valid(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_f64)
        .is_some_and(|value| (0.35..=1.0).contains(&value))
}

fn safe_filename(value: &str) -> String {
    let result: String = value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_'))
        .take(80)
        .collect();
    if result.is_empty() {
        "theme".to_owned()
    } else {
        result
    }
}

fn atomic_write_json(path: &Path, value: &Value) -> io::Result<()> {
    let temporary = path.with_extension(format!("tmp.{}", std::process::id()));
    let bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    fs::write(&temporary, bytes)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    fs::rename(temporary, path)
}

fn flag_value(args: &[String], flag: &str) -> io::Result<String> {
    let index = args
        .iter()
        .position(|arg| arg == flag)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("missing {flag}")))?;
    args.get(index + 1)
        .cloned()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("missing {flag} value")))
}

fn flag_path(args: &[String], flag: &str) -> io::Result<PathBuf> {
    Ok(PathBuf::from(flag_value(args, flag)?))
}

fn flag_path_at(args: &[String], index: usize) -> io::Result<PathBuf> {
    args.get(index)
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing path"))
}

fn print_help() {
    println!(
        "Codex Cove helper\n\
         usage: codex-cove <launch|doctor|privacy|theme|remote|install|uninstall|hook>\n\
         launch [CODEX_ARGS...] starts an explicitly Cove-routed Codex session\n\
         install --app-path PATH applies user-local integration; --plan previews\n\
         uninstall [--keep-settings] [--keep-app] removes integration; --keep-app leaves the verified bundle for an external package manager"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::mpsc;
    use std::thread;
    use tempfile::tempdir;

    #[derive(Default)]
    struct RecordingRemoteExecutor {
        seen: Vec<remote::CommandSpec>,
        fail: bool,
    }

    impl remote::CommandExecutor for RecordingRemoteExecutor {
        fn run(&mut self, spec: &remote::CommandSpec) -> io::Result<remote::CommandResult> {
            self.seen.push(spec.clone());
            Ok(remote::CommandResult {
                success: !self.fail,
                stdout: b"doctor-output\n".to_vec(),
                stderr: if self.fail {
                    b"fixture failure".to_vec()
                } else {
                    Vec::new()
                },
            })
        }
    }

    struct BlockingRemoteExecutor {
        entered: mpsc::Sender<()>,
        release: mpsc::Receiver<()>,
    }

    impl remote::CommandExecutor for BlockingRemoteExecutor {
        fn run(&mut self, _spec: &remote::CommandSpec) -> io::Result<remote::CommandResult> {
            self.entered
                .send(())
                .map_err(|_| io::Error::other("test coordinator closed"))?;
            self.release
                .recv()
                .map_err(|_| io::Error::other("test release channel closed"))?;
            Ok(remote::CommandResult {
                success: true,
                stdout: Vec::new(),
                stderr: Vec::new(),
            })
        }
    }

    #[derive(Default)]
    struct FailingEditorExtensionCleaner {
        calls: Vec<(String, Vec<String>)>,
        restore_calls: Vec<(String, Vec<String>, bool)>,
    }

    impl EditorExtensionCleaner for FailingEditorExtensionCleaner {
        fn uninstall_extension(
            &mut self,
            extension_id: &str,
            targets: &[String],
            _restore_targets: &mut Vec<String>,
        ) -> io::Result<()> {
            self.calls.push((extension_id.to_owned(), targets.to_vec()));
            Err(io::Error::other("mock editor refused cleanup"))
        }

        fn restore_extension(
            &mut self,
            extension_id: &str,
            targets: &[String],
            vsix_path: &Path,
        ) -> io::Result<()> {
            self.restore_calls.push((
                extension_id.to_owned(),
                targets.to_vec(),
                vsix_path.is_file(),
            ));
            Ok(())
        }
    }

    #[derive(Default)]
    struct RecordingEditorExtensionCleaner {
        uninstall_calls: Vec<(String, Vec<String>)>,
        restore_calls: Vec<(String, Vec<String>, bool)>,
        mutate_app_on_restore: Option<PathBuf>,
    }

    impl EditorExtensionCleaner for RecordingEditorExtensionCleaner {
        fn uninstall_extension(
            &mut self,
            extension_id: &str,
            targets: &[String],
            restore_targets: &mut Vec<String>,
        ) -> io::Result<()> {
            self.uninstall_calls
                .push((extension_id.to_owned(), targets.to_vec()));
            // Simulate code being installed and cursor already being absent.
            restore_targets.push("code".to_owned());
            Ok(())
        }

        fn restore_extension(
            &mut self,
            extension_id: &str,
            targets: &[String],
            vsix_path: &Path,
        ) -> io::Result<()> {
            self.restore_calls.push((
                extension_id.to_owned(),
                targets.to_vec(),
                vsix_path.is_file(),
            ));
            if let Some(app_path) = self.mutate_app_on_restore.as_ref() {
                fs::write(
                    app_path.join("Contents/changed-during-editor-compensation"),
                    b"changed",
                )?;
            }
            Ok(())
        }
    }

    #[derive(Default)]
    struct FakeEditorExtensionCommands {
        available: BTreeSet<String>,
        installed: BTreeSet<String>,
        install_failures: BTreeSet<String>,
        query_failures: BTreeSet<String>,
        uninstall_failures: BTreeSet<String>,
    }

    impl EditorExtensionCommands for FakeEditorExtensionCommands {
        fn is_available(&mut self, editor: &str) -> bool {
            self.available.contains(editor)
        }

        fn query_extension(&mut self, editor: &str, _extension_id: &str) -> io::Result<bool> {
            if self.query_failures.contains(editor) {
                Err(io::Error::other("mock query failure"))
            } else {
                Ok(self.installed.contains(editor))
            }
        }

        fn install_extension(&mut self, editor: &str, _vsix: &Path) -> io::Result<()> {
            if self.install_failures.contains(editor) {
                Err(io::Error::other("mock install failure"))
            } else {
                self.installed.insert(editor.to_owned());
                Ok(())
            }
        }

        fn uninstall_extension(&mut self, editor: &str, _extension_id: &str) -> io::Result<()> {
            if self.uninstall_failures.contains(editor) {
                Err(io::Error::other("mock uninstall failure"))
            } else {
                self.installed.remove(editor);
                Ok(())
            }
        }
    }

    fn owned_args(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    fn fake_codex(body: &str) -> (tempfile::TempDir, PathBuf) {
        let temp = tempdir().unwrap();
        let path = temp.path().join("codex");
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        (temp, path)
    }

    fn fake_editor_cli(body: &str) -> (tempfile::TempDir, PathBuf) {
        let temp = tempdir().unwrap();
        let path = temp.path().join("editor-cli");
        fs::write(&path, format!("#!/bin/sh\n{body}\n")).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
        (temp, path)
    }

    fn fake_installed_app(root: &Path) -> PathBuf {
        let app = root.join("Codex Cove.app");
        let contents = app.join("Contents");
        let executable = contents.join("MacOS/CodexCove");
        let extension = contents.join("Resources/extension/codex-cove.vsix");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::create_dir_all(extension.parent().unwrap()).unwrap();
        fs::write(
            contents.join("Info.plist"),
            b"<plist><string>local.chris.codexcove</string></plist>",
        )
        .unwrap();
        fs::write(&executable, b"#!/bin/sh\nexit 0\n").unwrap();
        fs::write(&extension, b"fixture editor extension").unwrap();
        fs::set_permissions(&executable, fs::Permissions::from_mode(0o755)).unwrap();
        app
    }

    fn assert_timed_out_editor_was_reaped(timeout_error: &str) {
        let pid = timeout_error
            .split("; process ")
            .nth(1)
            .expect("timeout error must report the child process")
            .split_whitespace()
            .next()
            .expect("timeout error must include the child PID")
            .trim()
            .parse::<libc::pid_t>()
            .unwrap();
        assert_process_is_gone(pid);
    }

    fn assert_process_is_gone(pid: libc::pid_t) {
        for _ in 0..100 {
            if unsafe { libc::kill(pid, 0) } == -1
                && io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
            {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        panic!("process {pid} remained after bounded command cleanup");
    }

    fn test_transport_timeout() -> Duration {
        Duration::from_secs(5)
    }

    #[test]
    fn prefers_durable_daemon_transport() {
        let (_temp, codex) = fake_codex(
            "if [ \"$1 $2 $3\" = \"app-server daemon start\" ]; then exit 0; fi\n\
             if [ \"$1 $2\" = \"app-server proxy\" ]; then \
               IFS= read -r initialize || exit 20; \
               printf '%s\\n' '{\"id\":\"cove-probe-initialize\",\"result\":{\"platformFamily\":\"unix\"}}'; \
               IFS= read -r initialized || exit 21; \
               IFS= read -r config || exit 22; \
               printf '%s\\n' '{\"id\":\"cove-probe-config\",\"result\":{\"requirements\":null}}'; \
               exit 0; \
             fi\n\
             exit 1",
        );
        assert_eq!(
            select_app_server_mode(
                &codex,
                test_transport_timeout(),
                codex_cove::DEFAULT_MAX_FRAME_BYTES
            ),
            Some(AppServerMode::Proxy)
        );
    }

    #[test]
    fn selects_direct_stdio_when_daemon_is_unavailable() {
        let (_temp, codex) = fake_codex(
            "if [ \"$1 $2 $3\" = \"app-server daemon start\" ]; then exit 1; fi\n\
             if [ \"$1 $2\" = \"app-server --help\" ]; then printf '%s\\n' '--stdio stdio://'; exit 0; fi\n\
             if [ \"$1 $2\" = \"app-server --stdio\" ]; then \
               IFS= read -r initialize || exit 20; \
               printf '%s\\n' '{\"id\":\"cove-probe-initialize\",\"result\":{\"platformFamily\":\"unix\"}}'; \
               IFS= read -r initialized || exit 21; \
               IFS= read -r config || exit 22; \
               printf '%s\\n' '{\"id\":\"cove-probe-config\",\"result\":{\"requirements\":null}}'; \
               exit 0; \
             fi\n\
             exit 1",
        );
        assert_eq!(
            select_app_server_mode(
                &codex,
                test_transport_timeout(),
                codex_cove::DEFAULT_MAX_FRAME_BYTES
            ),
            Some(AppServerMode::DirectStdio)
        );
    }

    #[test]
    fn declines_broker_when_neither_transport_is_available() {
        let (_temp, codex) = fake_codex("exit 1");
        assert_eq!(
            select_app_server_mode(
                &codex,
                test_transport_timeout(),
                codex_cove::DEFAULT_MAX_FRAME_BYTES
            ),
            None
        );
    }

    #[test]
    fn declines_direct_stdio_when_readiness_request_fails() {
        let (_temp, codex) = fake_codex(
            "if [ \"$1 $2 $3\" = \"app-server daemon start\" ]; then exit 1; fi\n\
             if [ \"$1 $2\" = \"app-server --help\" ]; then printf '%s\\n' '--stdio stdio://'; exit 0; fi\n\
             if [ \"$1 $2\" = \"app-server --stdio\" ]; then exit 1; fi\n\
             exit 1",
        );
        assert_eq!(
            select_app_server_mode(
                &codex,
                test_transport_timeout(),
                codex_cove::DEFAULT_MAX_FRAME_BYTES
            ),
            None
        );
    }

    #[test]
    fn captures_and_safely_normalizes_the_controlling_tty() {
        assert_eq!(
            select_controlling_tty(Some(" /dev/ttys004\n"), || {
                Some("/dev/ttys999".to_owned())
            }),
            Some("/dev/ttys004".to_owned())
        );
        assert_eq!(
            select_controlling_tty(None, || Some("/dev/pts/7".to_owned())),
            Some("/dev/pts/7".to_owned())
        );
        assert_eq!(
            select_controlling_tty(Some("/dev/../private/data"), || None),
            None
        );
    }

    #[test]
    fn parses_remote_forget_and_rejects_extra_or_conflicting_flags() {
        assert_eq!(
            parse_remote_management_action(&owned_args(&[
                "remote",
                "remove",
                "selected-host",
                "--forget",
            ]))
            .unwrap(),
            RemoteManagementAction::Forget {
                alias: "selected-host".to_owned(),
            }
        );

        for invalid in [
            &["remote", "remove", "selected-host", "--forget", "--plan"][..],
            &["remote", "remove", "selected-host", "--unknown"][..],
            &[
                "remote",
                "deploy",
                "selected-host",
                "--plan",
                "--artifact",
                "/tmp/helper",
            ][..],
            &["remote", "add", "selected-host", "--forget"][..],
            &["remote", "doctor", "selected-host", "extra"][..],
        ] {
            let error = parse_remote_management_action(&owned_args(invalid)).unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidInput);
            assert_eq!(error.to_string(), REMOTE_USAGE);
        }
    }

    #[test]
    fn parses_every_supported_remote_management_form() {
        let cases = [
            (
                &["remote", "add", "selected-host"][..],
                RemoteManagementAction::Add {
                    alias: "selected-host".to_owned(),
                },
            ),
            (
                &[
                    "remote",
                    "deploy",
                    "selected-host",
                    "--artifact",
                    "/tmp/helper",
                ][..],
                RemoteManagementAction::Deploy {
                    alias: "selected-host".to_owned(),
                    artifact: PathBuf::from("/tmp/helper"),
                },
            ),
            (
                &["remote", "deploy", "selected-host", "--plan"][..],
                RemoteManagementAction::DeployPlan {
                    alias: "selected-host".to_owned(),
                },
            ),
            (
                &["remote", "doctor", "selected-host"][..],
                RemoteManagementAction::Doctor {
                    alias: "selected-host".to_owned(),
                },
            ),
            (
                &["remote", "remove", "selected-host"][..],
                RemoteManagementAction::Remove {
                    alias: "selected-host".to_owned(),
                },
            ),
            (
                &["remote", "remove", "selected-host", "--plan"][..],
                RemoteManagementAction::RemovePlan {
                    alias: "selected-host".to_owned(),
                },
            ),
            (
                &["remote", "remove", "selected-host", "--forget"][..],
                RemoteManagementAction::Forget {
                    alias: "selected-host".to_owned(),
                },
            ),
        ];

        for (arguments, expected) in cases {
            assert_eq!(
                parse_remote_management_action(&owned_args(arguments)).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn remote_host_mutation_guard_excludes_a_running_cove_instance() {
        let temp = tempdir().unwrap();
        let support = temp.path().join("Codex Cove");
        fs::create_dir(&support).unwrap();
        let first = RemoteHostMutationGuard::acquire(&support).unwrap();

        let error = match RemoteHostMutationGuard::acquire(&support) {
            Ok(_) => panic!("a second instance lock must not be acquired"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(error.to_string().contains("quit"));

        drop(first);
        RemoteHostMutationGuard::acquire(&support).unwrap();
    }

    #[test]
    fn config_mutation_lock_survives_support_tree_staging_and_recreation() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        fs::create_dir_all(&layout.support).unwrap();
        let held = ConfigMutationGuard::acquire(&layout.home).unwrap();

        let staged_support = temp.path().join("staged-support");
        fs::rename(&layout.support, &staged_support).unwrap();
        fs::create_dir_all(&layout.support).unwrap();

        let error = match ConfigMutationGuard::acquire(&layout.home) {
            Ok(_) => panic!("support replacement must not split the config mutation lock"),
            Err(error) => error,
        };
        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);

        drop(held);
        ConfigMutationGuard::acquire(&layout.home).unwrap();
    }

    #[test]
    fn held_cove_lock_blocks_forget_before_executor_or_config_mutation() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        remote::add(&mut config, "selected-host").unwrap();
        let support = config.runtime_directory.parent().unwrap().to_path_buf();
        fs::create_dir_all(&support).unwrap();
        let config_path = support.join("helper-config.json");
        config.save_to(&config_path).unwrap();
        let _app_lock = RemoteHostMutationGuard::acquire(&support).unwrap();
        let mut executor = RecordingRemoteExecutor::default();
        let action = RemoteManagementAction::Forget {
            alias: "selected-host".to_owned(),
        };

        let error =
            execute_remote_management_from_path(&action, &config_path, temp.path(), &mut executor)
                .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::WouldBlock);
        assert!(executor.seen.is_empty());
        let persisted = Config::load_from(&config_path).unwrap();
        assert_eq!(persisted.remote_hosts.len(), 1);
        assert_eq!(persisted.remote_hosts[0].alias, "selected-host");
    }

    #[test]
    fn host_mutation_lock_precedes_config_load_and_config_errors_do_not_contact_ssh() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        fs::create_dir_all(&layout.support).unwrap();
        fs::set_permissions(&layout.support, fs::Permissions::from_mode(0o700)).unwrap();
        let malformed = b"{malformed-config\n";
        fs::write(&layout.config_path, malformed).unwrap();
        fs::set_permissions(&layout.config_path, fs::Permissions::from_mode(0o600)).unwrap();
        let held = RemoteHostMutationGuard::acquire(&layout.support).unwrap();
        let action = RemoteManagementAction::Remove {
            alias: "selected-host".to_owned(),
        };
        let mut executor = RecordingRemoteExecutor::default();

        let locked_error = execute_remote_management_from_path(
            &action,
            &layout.config_path,
            &layout.home,
            &mut executor,
        )
        .unwrap_err();
        assert_eq!(locked_error.kind(), io::ErrorKind::WouldBlock);
        assert!(executor.seen.is_empty());
        assert_eq!(fs::read(&layout.config_path).unwrap(), malformed);

        drop(held);
        let config_error = execute_remote_management_from_path(
            &action,
            &layout.config_path,
            &layout.home,
            &mut executor,
        )
        .unwrap_err();
        assert_eq!(config_error.kind(), io::ErrorKind::InvalidData);
        assert!(executor.seen.is_empty());
        assert_eq!(fs::read(&layout.config_path).unwrap(), malformed);
    }

    #[test]
    fn concurrent_host_mutations_cannot_reintroduce_a_removed_alias() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let mut config = Config::for_home(temp.path());
        remote::add(&mut config, "old-host").unwrap();
        config.save_to(&layout.config_path).unwrap();

        let config_path = layout.config_path.clone();
        let lock_root = layout.home.clone();
        let (entered_sender, entered_receiver) = mpsc::channel();
        let (release_sender, release_receiver) = mpsc::channel();
        let remover = thread::spawn(move || {
            let action = RemoteManagementAction::Remove {
                alias: "old-host".to_owned(),
            };
            let mut executor = BlockingRemoteExecutor {
                entered: entered_sender,
                release: release_receiver,
            };
            execute_remote_management_from_path(&action, &config_path, &lock_root, &mut executor)
        });

        entered_receiver.recv().unwrap();
        let add = RemoteManagementAction::Add {
            alias: "new-host".to_owned(),
        };
        let mut executor = RecordingRemoteExecutor::default();
        let concurrent_error = execute_remote_management_from_path(
            &add,
            &layout.config_path,
            &layout.home,
            &mut executor,
        )
        .unwrap_err();
        assert_eq!(concurrent_error.kind(), io::ErrorKind::WouldBlock);
        assert!(executor.seen.is_empty());

        release_sender.send(()).unwrap();
        remover.join().unwrap().unwrap();
        execute_remote_management_from_path(&add, &layout.config_path, &layout.home, &mut executor)
            .unwrap();

        let persisted = Config::load_from(&layout.config_path).unwrap();
        assert_eq!(persisted.remote_hosts.len(), 1);
        assert_eq!(persisted.remote_hosts[0].alias, "new-host");
    }

    #[test]
    fn concurrent_privacy_update_cannot_reintroduce_a_removed_alias() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let mut config = Config::for_home(temp.path());
        remote::add(&mut config, "old-host").unwrap();
        config.save_to(&layout.config_path).unwrap();

        let config_path = layout.config_path.clone();
        let lock_root = layout.home.clone();
        let (entered_sender, entered_receiver) = mpsc::channel();
        let (release_sender, release_receiver) = mpsc::channel();
        let remover = thread::spawn(move || {
            let action = RemoteManagementAction::Remove {
                alias: "old-host".to_owned(),
            };
            let mut executor = BlockingRemoteExecutor {
                entered: entered_sender,
                release: release_receiver,
            };
            execute_remote_management_from_path(&action, &config_path, &lock_root, &mut executor)
        });

        entered_receiver.recv().unwrap();
        let concurrent_error =
            update_privacy_from_path(&layout.config_path, &layout.home, PrivacyMode::On)
                .unwrap_err();
        assert_eq!(concurrent_error.kind(), io::ErrorKind::WouldBlock);

        release_sender.send(()).unwrap();
        remover.join().unwrap().unwrap();
        update_privacy_from_path(&layout.config_path, &layout.home, PrivacyMode::On).unwrap();

        let persisted = Config::load_from(&layout.config_path).unwrap();
        assert!(persisted.remote_hosts.is_empty());
        assert_eq!(persisted.privacy, PrivacyMode::On);
    }

    #[test]
    fn custom_runtime_cannot_move_or_bypass_the_canonical_host_mutation_lock() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let mut config = Config::for_home(temp.path());
        remote::add(&mut config, "selected-host").unwrap();
        config.runtime_directory = layout.support.join("custom-run");
        config.event_socket = config.runtime_directory.join("events.sock");
        config.save_to(&layout.config_path).unwrap();
        let before = fs::read(&layout.config_path).unwrap();
        let action = RemoteManagementAction::Forget {
            alias: "selected-host".to_owned(),
        };
        let mut executor = RecordingRemoteExecutor::default();

        let error = execute_remote_management_from_path(
            &action,
            &layout.config_path,
            &layout.home,
            &mut executor,
        )
        .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("canonical"));
        assert!(executor.seen.is_empty(), "--forget must never invoke SSH");
        assert_eq!(fs::read(&layout.config_path).unwrap(), before);
    }

    #[test]
    fn remote_forget_removes_only_local_configuration_without_an_executor_call() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        remote::add(&mut config, "selected-host").unwrap();
        let mut executor = RecordingRemoteExecutor::default();
        let action = RemoteManagementAction::Forget {
            alias: "selected-host".to_owned(),
        };

        let result = execute_remote_management_action(&action, &mut config, &mut executor).unwrap();

        assert!(executor.seen.is_empty(), "--forget must never invoke SSH");
        assert!(config.remote_hosts.is_empty());
        assert!(result.persist_config);
        assert_eq!(result.output, b"forgot selected-host\n");

        let saved = temp.path().join("helper-config.json");
        config.save_to(&saved).unwrap();
        assert!(Config::load_from(&saved).unwrap().remote_hosts.is_empty());
    }

    #[test]
    fn normal_remote_remove_invokes_ssh_before_removing_local_configuration() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        remote::add(&mut config, "selected-host").unwrap();
        let mut executor = RecordingRemoteExecutor::default();
        let action = RemoteManagementAction::Remove {
            alias: "selected-host".to_owned(),
        };

        let result = execute_remote_management_action(&action, &mut config, &mut executor).unwrap();

        assert_eq!(executor.seen.len(), 1);
        assert_eq!(executor.seen[0].program, OsStr::new("ssh"));
        assert!(config.remote_hosts.is_empty());
        assert!(result.persist_config);
        assert_eq!(result.output, b"removed selected-host\n");
    }

    #[test]
    fn failed_normal_remote_remove_preserves_local_configuration() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        remote::add(&mut config, "selected-host").unwrap();
        let mut executor = RecordingRemoteExecutor {
            fail: true,
            ..Default::default()
        };
        let action = RemoteManagementAction::Remove {
            alias: "selected-host".to_owned(),
        };

        let error =
            execute_remote_management_action(&action, &mut config, &mut executor).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::Other);
        assert_eq!(executor.seen.len(), 1);
        assert_eq!(config.remote_hosts.len(), 1);
        assert_eq!(config.remote_hosts[0].alias, "selected-host");
    }

    #[test]
    fn editor_cleanup_failure_is_explicit_and_preserves_uninstall_retry_state() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        fs::write(&source, b"helper").unwrap();
        fs::write(&real, b"codex").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        install::apply_install(
            &source,
            None,
            &real,
            &layout,
            Some("codex-cove-local.cove-extension"),
        )
        .unwrap();
        let hooks_before = fs::read(&layout.hooks_path).unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let mut cleaner = FailingEditorExtensionCleaner::default();
        let mut unregister_called = false;

        let error = execute_local_uninstall(
            &layout,
            false,
            false,
            &mut cleaner,
            |_| {
                unregister_called = true;
                Ok(())
            },
            |_| Ok(()),
        )
        .unwrap_err();

        assert_eq!(
            cleaner.calls,
            [(
                "codex-cove-local.cove-extension".to_owned(),
                vec!["code".to_owned(), "cursor".to_owned()]
            )]
        );
        assert!(!unregister_called);
        assert!(
            error
                .to_string()
                .contains("editor extension cleanup failed")
        );
        assert!(error.to_string().contains("cleanup can be retried"));
        assert_eq!(fs::read(&layout.hooks_path).unwrap(), hooks_before);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert!(fs::symlink_metadata(&layout.codex_shim).is_err());
        assert_eq!(
            fs::read_link(&layout.management_link).unwrap(),
            layout.managed_binary
        );
    }

    #[test]
    fn keep_app_validation_failure_skips_external_cleanup_callbacks() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_installed_app(temp.path());
        fs::write(&source, b"helper").unwrap();
        fs::write(&real, b"codex").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        install::apply_install(
            &source,
            Some(&app),
            &real,
            &layout,
            Some("codex-cove-local.cove-extension"),
        )
        .unwrap();
        fs::write(app.join("Contents/unexpected-change"), b"changed").unwrap();
        let mut cleaner = FailingEditorExtensionCleaner::default();
        let mut unregister_called = false;

        let error = execute_local_uninstall(
            &layout,
            true,
            true,
            &mut cleaner,
            |_| {
                unregister_called = true;
                Ok(())
            },
            |_| Ok(()),
        )
        .unwrap_err();

        let detail = error.to_string();
        assert!(
            detail.contains("installed app bundle checksum changed"),
            "{detail}"
        );
        assert!(
            cleaner.calls.is_empty(),
            "editor cleanup must not run before retained-app validation"
        );
        assert!(
            !unregister_called,
            "login-item cleanup must not run before retained-app validation"
        );
        assert!(layout.managed_binary.exists());
        assert!(layout.manifest_path.exists());
        assert!(app.exists());
    }

    #[test]
    fn keep_app_failure_restores_only_editor_targets_present_before_cleanup() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_installed_app(temp.path());
        fs::write(&source, b"helper").unwrap();
        fs::write(&real, b"codex").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        install::apply_install(
            &source,
            Some(&app),
            &real,
            &layout,
            Some("codex-cove-local.cove-extension"),
        )
        .unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let mut cleaner = RecordingEditorExtensionCleaner::default();
        let mut sync_calls = Vec::new();

        let error = execute_local_uninstall(
            &layout,
            true,
            true,
            &mut cleaner,
            |_| Err(io::Error::other("mock login-item cleanup failure")),
            |path| {
                sync_calls.push(path.to_path_buf());
                Ok(())
            },
        )
        .unwrap_err();

        assert_eq!(
            cleaner.uninstall_calls,
            [(
                "codex-cove-local.cove-extension".to_owned(),
                vec!["code".to_owned(), "cursor".to_owned()]
            )]
        );
        assert_eq!(
            cleaner.restore_calls,
            [(
                "codex-cove-local.cove-extension".to_owned(),
                vec!["code".to_owned()],
                true
            )],
            "an editor target that was already absent must remain absent"
        );
        assert_eq!(sync_calls.as_slice(), std::slice::from_ref(&app));
        assert!(
            error
                .to_string()
                .contains("external cleanup was compensated")
        );
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert!(app.exists());
    }

    #[test]
    fn compensation_revalidates_app_after_editor_restore_before_login_sync() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_installed_app(temp.path());
        fs::write(&source, b"helper").unwrap();
        fs::write(&real, b"codex").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        install::apply_install(
            &source,
            Some(&app),
            &real,
            &layout,
            Some("codex-cove-local.cove-extension"),
        )
        .unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let mut cleaner = RecordingEditorExtensionCleaner {
            mutate_app_on_restore: Some(app.clone()),
            ..Default::default()
        };
        let mut sync_called = false;

        let error = execute_local_uninstall(
            &layout,
            true,
            true,
            &mut cleaner,
            |_| Err(io::Error::other("mock login-item cleanup failure")),
            |_| {
                sync_called = true;
                Ok(())
            },
        )
        .unwrap_err();

        let detail = error.to_string();
        assert!(
            detail.contains("external cleanup compensation was incomplete"),
            "{detail}"
        );
        assert!(
            detail.contains("installed app changed during editor extension compensation"),
            "{detail}"
        );
        assert!(
            detail.contains("launch-at-login compensation skipped"),
            "{detail}"
        );
        assert!(
            !sync_called,
            "a changed app must never run during compensation"
        );
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert!(app.exists());
    }

    #[test]
    fn keep_app_detects_app_mutation_during_external_cleanup_before_commit() {
        let temp = tempdir().unwrap();
        let layout = install::InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_installed_app(temp.path());
        fs::write(&source, b"helper").unwrap();
        fs::write(&real, b"codex").unwrap();
        fs::set_permissions(&source, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        install::apply_install(&source, Some(&app), &real, &layout, None).unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let mut cleaner = RecordingEditorExtensionCleaner::default();
        let app_for_mutation = app.clone();
        let mut sync_called = false;

        let error = execute_local_uninstall(
            &layout,
            true,
            true,
            &mut cleaner,
            move |_| {
                fs::write(
                    app_for_mutation.join("Contents/unexpected-change"),
                    b"changed during cleanup",
                )?;
                Ok(())
            },
            |_| {
                sync_called = true;
                Ok(())
            },
        )
        .unwrap_err();

        let detail = error.to_string();
        assert!(
            detail.contains("installed app bundle checksum changed"),
            "{detail}"
        );
        assert!(
            detail.contains("compensation was skipped"),
            "an unvalidated replacement must never be executed for compensation: {detail}"
        );
        assert!(!sync_called);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert!(app.exists());
    }

    #[test]
    fn editor_install_records_only_verified_targets_for_a_new_install() {
        let mut commands = FakeEditorExtensionCommands {
            available: ["code".to_owned()].into_iter().collect(),
            ..Default::default()
        };

        let report = install_editor_extension(
            &mut commands,
            Path::new("/tmp/codex-cove.vsix"),
            "codex-cove-local.cove-extension",
            &[],
        );

        assert_eq!(report.cleanup_targets, ["code".to_owned()]);
        assert!(report.failures.is_empty());
        assert!(commands.installed.contains("code"));
    }

    #[test]
    fn system_editor_query_preserves_stdout_and_reports_exit_details() {
        let (_temp, editor) = fake_editor_cli(
            r#"
if [ "$1" = "--list-extensions" ]; then
    printf 'other.extension\r\ncodex-cove-local.cove-extension\r\n'
    exit 0
fi
printf 'unexpected query arguments\n' >&2
exit 64
"#,
        );
        let editor = editor.to_string_lossy();
        let mut commands = SystemEditorExtensionCommands::with_timeout(Duration::from_secs(5));

        assert!(
            commands
                .query_extension(&editor, "codex-cove-local.cove-extension")
                .unwrap()
        );

        let (_temp, failing_editor) =
            fake_editor_cli("printf 'fixture query failure detail\\n' >&2\nexit 23");
        let failing_editor = failing_editor.to_string_lossy();
        let error = commands
            .query_extension(&failing_editor, "codex-cove-local.cove-extension")
            .unwrap_err();
        assert!(error.to_string().contains("exit status: 23"));
        assert!(error.to_string().contains("fixture query failure detail"));
    }

    #[test]
    fn system_editor_query_timeout_kills_and_reaps_child() {
        let (_temp, editor) = fake_editor_cli(
            r#"
printf 'fixture query entered busy loop\n' >&2
while :; do :; done
"#,
        );
        let editor = editor.to_string_lossy();
        let mut commands = SystemEditorExtensionCommands::with_timeout(Duration::from_millis(500));

        let error = commands
            .query_extension(&editor, "codex-cove-local.cove-extension")
            .unwrap_err();
        let detail = error.to_string();

        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(detail.contains("extension query timed out"), "{detail}");
        assert!(detail.contains("killed and reaped"), "{detail}");
        assert_timed_out_editor_was_reaped(&detail);
    }

    #[test]
    fn system_editor_timeout_kills_the_wrapper_process_group() {
        let temp = tempdir().unwrap();
        let editor = temp.path().join("editor-cli");
        fs::write(
            &editor,
            "#!/bin/sh\nsleep 30 &\ndescendant=$!\nprintf 'descendant:%s\\n' \"$descendant\" >&2\nwait \"$descendant\"\n",
        )
        .unwrap();
        fs::set_permissions(&editor, fs::Permissions::from_mode(0o755)).unwrap();
        let editor = editor.to_string_lossy();
        let mut commands = SystemEditorExtensionCommands::with_timeout(Duration::from_secs(5));

        let error = commands
            .query_extension(&editor, "codex-cove-local.cove-extension")
            .unwrap_err();
        let detail = error.to_string();

        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        let descendant_pid = detail
            .split("descendant:")
            .nth(1)
            .unwrap_or_else(|| panic!("timeout diagnostic omitted descendant PID: {detail}"))
            .split_whitespace()
            .next()
            .unwrap()
            .trim()
            .parse::<libc::pid_t>()
            .unwrap();
        assert_process_is_gone(descendant_pid);
    }

    #[test]
    fn bounded_failure_cleans_up_lingering_descendants() {
        let temp = tempdir().unwrap();
        let command_path = temp.path().join("bounded-command");
        let descendant_pid_path = temp.path().join("descendant.pid");
        fs::write(
            &command_path,
            format!(
                "#!/bin/sh\nsleep 5 &\nprintf '%s\\n' \"$!\" > '{}'\nexit 7\n",
                descendant_pid_path.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&command_path, fs::Permissions::from_mode(0o755)).unwrap();
        let mut command = Command::new(&command_path);

        assert!(!run_bounded(&mut command, Duration::from_secs(2)));
        let descendant_pid = fs::read_to_string(&descendant_pid_path)
            .unwrap()
            .trim()
            .parse::<libc::pid_t>()
            .unwrap();
        assert_process_is_gone(descendant_pid);
    }

    #[test]
    fn system_editor_status_paths_succeed_and_report_exit_details() {
        let (_temp, editor) = fake_editor_cli(
            r#"
case "$1" in
    --install-extension|--uninstall-extension) exit 0 ;;
esac
printf 'unexpected status arguments\n' >&2
exit 64
"#,
        );
        let editor = editor.to_string_lossy();
        let mut commands = SystemEditorExtensionCommands::with_timeout(Duration::from_secs(5));

        commands
            .install_extension(&editor, Path::new("/tmp/codex-cove.vsix"))
            .unwrap();
        commands
            .uninstall_extension(&editor, "codex-cove-local.cove-extension")
            .unwrap();

        let (_temp, failing_editor) =
            fake_editor_cli("printf 'fixture install failure detail\\n' >&2\nexit 29");
        let failing_editor = failing_editor.to_string_lossy();
        let error = commands
            .install_extension(&failing_editor, Path::new("/tmp/codex-cove.vsix"))
            .unwrap_err();
        assert!(error.to_string().contains("exit status: 29"));
        assert!(error.to_string().contains("fixture install failure detail"));
    }

    #[test]
    fn system_editor_status_timeout_kills_and_reaps_child() {
        let (_temp, editor) = fake_editor_cli(
            r#"
printf 'fixture uninstall entered busy loop\n' >&2
while :; do :; done
"#,
        );
        let editor = editor.to_string_lossy();
        let mut commands = SystemEditorExtensionCommands::with_timeout(Duration::from_millis(500));

        let error = commands
            .uninstall_extension(&editor, "codex-cove-local.cove-extension")
            .unwrap_err();
        let detail = error.to_string();

        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(detail.contains("extension uninstall timed out"), "{detail}");
        assert!(detail.contains("killed and reaped"), "{detail}");
        assert_timed_out_editor_was_reaped(&detail);
    }

    #[test]
    fn editor_install_retains_an_unreachable_prior_obligation() {
        let mut commands = FakeEditorExtensionCommands {
            available: ["code".to_owned()].into_iter().collect(),
            ..Default::default()
        };

        let report = install_editor_extension(
            &mut commands,
            Path::new("/tmp/codex-cove.vsix"),
            "codex-cove-local.cove-extension",
            &["cursor".to_owned()],
        );

        assert_eq!(
            report.cleanup_targets,
            ["code".to_owned(), "cursor".to_owned()]
        );
        assert!(
            report
                .failures
                .iter()
                .any(|failure| failure.contains("prior cleanup obligation was retained"))
        );
    }

    #[test]
    fn editor_cleanup_rejects_an_unreachable_recorded_target_after_cleaning_reachable_peers() {
        let mut commands = FakeEditorExtensionCommands {
            available: ["code".to_owned()].into_iter().collect(),
            installed: ["code".to_owned(), "cursor".to_owned()]
                .into_iter()
                .collect(),
            ..Default::default()
        };

        let mut restore_targets = Vec::new();
        let error = cleanup_editor_extension(
            &mut commands,
            "codex-cove-local.cove-extension",
            &["code".to_owned(), "cursor".to_owned()],
            &mut restore_targets,
        )
        .unwrap_err();

        assert_eq!(restore_targets, ["code".to_owned()]);
        assert!(!commands.installed.contains("code"));
        assert!(commands.installed.contains("cursor"));
        assert!(
            error
                .to_string()
                .contains("recorded editor cursor is unreachable")
        );
        assert!(error.to_string().contains("cleanup can be retried"));
    }

    #[test]
    fn editor_cleanup_requires_zero_available_legacy_targets_but_not_unrecorded_peers() {
        let mut no_editors = FakeEditorExtensionCommands::default();
        let mut restore_targets = Vec::new();
        let error = cleanup_editor_extension(
            &mut no_editors,
            "codex-cove-local.cove-extension",
            &["code".to_owned(), "cursor".to_owned()],
            &mut restore_targets,
        )
        .unwrap_err();
        assert!(restore_targets.is_empty());
        assert!(
            error
                .to_string()
                .contains("recorded editor code is unreachable")
        );
        assert!(
            error
                .to_string()
                .contains("recorded editor cursor is unreachable")
        );

        let mut code_only = FakeEditorExtensionCommands {
            available: ["code".to_owned()].into_iter().collect(),
            installed: ["code".to_owned()].into_iter().collect(),
            ..Default::default()
        };
        let mut restore_targets = Vec::new();
        cleanup_editor_extension(
            &mut code_only,
            "codex-cove-local.cove-extension",
            &["code".to_owned()],
            &mut restore_targets,
        )
        .unwrap();
        assert_eq!(restore_targets, ["code".to_owned()]);
        assert!(code_only.installed.is_empty());
    }
}
