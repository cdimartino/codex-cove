use crate::config::{Config, REMOTE_HELPER_PATH, RemoteHost};
use crate::install::sha256_file;
use crate::ipc::{bind_private_listener, read_length_frame, read_limited_line, write_length_frame};
use crate::{CoveEvent, DEFAULT_MAX_FRAME_BYTES};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs::{self, File, OpenOptions};
use std::io::{self, BufReader, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{self, Receiver, Sender, TryRecvError};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemotePlan {
    pub alias: String,
    pub operation: String,
    pub command: Vec<String>,
    pub mutates_remote: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandSpec {
    pub program: OsString,
    pub args: Vec<OsString>,
}

pub trait CommandExecutor {
    fn run(&mut self, spec: &CommandSpec) -> io::Result<CommandResult>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CommandResult {
    pub success: bool,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

pub struct SystemExecutor;

impl CommandExecutor for SystemExecutor {
    fn run(&mut self, spec: &CommandSpec) -> io::Result<CommandResult> {
        let output = Command::new(&spec.program)
            .args(&spec.args)
            .stdin(Stdio::null())
            .output()?;
        Ok(CommandResult {
            success: output.status.success(),
            stdout: output.stdout,
            stderr: output.stderr,
        })
    }
}

pub fn add(config: &mut Config, alias: &str) -> io::Result<()> {
    validate_alias(alias)?;
    if config.remote_hosts.iter().any(|host| host.alias == alias) {
        return Ok(());
    }
    config.remote_hosts.push(RemoteHost {
        alias: alias.to_owned(),
        helper_path: REMOTE_HELPER_PATH.to_owned(),
        enabled: true,
    });
    Ok(())
}

pub fn remove(config: &mut Config, alias: &str) -> bool {
    let previous = config.remote_hosts.len();
    config.remote_hosts.retain(|host| host.alias != alias);
    config.remote_hosts.len() != previous
}

pub fn plan(config: &Config, operation: &str, alias: &str) -> io::Result<RemotePlan> {
    validate_alias(alias)?;
    let host = config
        .remote_hosts
        .iter()
        .find(|host| host.alias == alias)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "remote alias not configured"))?;
    let command = match operation {
        "doctor" => vec![
            "ssh".to_owned(),
            "-o".to_owned(),
            "BatchMode=yes".to_owned(),
            alias.to_owned(),
            format!("{} doctor --json", host.helper_path),
        ],
        "deploy" => vec![
            "ssh".to_owned(),
            "-T".to_owned(),
            alias.to_owned(),
            "sh -s -- codex-cove-deploy".to_owned(),
        ],
        "remove" => vec![
            "ssh".to_owned(),
            "-T".to_owned(),
            alias.to_owned(),
            format!("{} uninstall --remote --plan", host.helper_path),
        ],
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "unsupported remote operation",
            ));
        }
    };
    Ok(RemotePlan {
        alias: alias.to_owned(),
        operation: operation.to_owned(),
        command,
        mutates_remote: operation != "doctor",
    })
}

pub fn deploy_specs(alias: &str, artifact: &Path, checksum: &str) -> io::Result<Vec<CommandSpec>> {
    validate_alias(alias)?;
    if !artifact.is_absolute() || !artifact.is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "remote artifact must be an existing absolute file",
        ));
    }
    if checksum.len() != 64 || !checksum.chars().all(|ch| ch.is_ascii_hexdigit()) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "artifact checksum must be SHA-256 hex",
        ));
    }
    let version = format!("{}-{}", env!("CARGO_PKG_VERSION"), &checksum[..12]);
    let directory = format!("~/.local/share/codex-cove/{version}");
    let upload = format!("{directory}/codex-cove.upload");
    let installed = format!("{directory}/codex-cove");
    let destination = format!("{alias}:{upload}");
    let prepare = format!("mkdir -p {directory} && chmod 700 {directory}");
    let activate = format!(
        "chmod 700 {upload} && {upload} remote-install --expected-sha256 {checksum} && mv {upload} {installed} && ln -sfn {version} ~/.local/share/codex-cove/current"
    );
    Ok(vec![
        ssh_spec(alias, &prepare, false),
        CommandSpec {
            program: OsString::from("scp"),
            args: vec![
                "-o".into(),
                "StrictHostKeyChecking=yes".into(),
                artifact.as_os_str().to_owned(),
                destination.into(),
            ],
        },
        ssh_spec(alias, &activate, false),
    ])
}

pub fn doctor_spec(alias: &str) -> io::Result<CommandSpec> {
    validate_alias(alias)?;
    Ok(ssh_spec(
        alias,
        "~/.local/share/codex-cove/current/codex-cove doctor --json",
        true,
    ))
}

pub fn remove_spec(alias: &str) -> io::Result<CommandSpec> {
    validate_alias(alias)?;
    Ok(ssh_spec(
        alias,
        "~/.local/share/codex-cove/current/codex-cove uninstall --remote",
        false,
    ))
}

pub fn execute_specs(
    executor: &mut impl CommandExecutor,
    specs: &[CommandSpec],
) -> io::Result<Vec<CommandResult>> {
    let mut results = Vec::with_capacity(specs.len());
    for spec in specs {
        let result = executor.run(spec)?;
        if !result.success {
            let stderr = String::from_utf8_lossy(&result.stderr);
            return Err(io::Error::other(format!(
                "{} failed: {}",
                PathBuf::from(&spec.program).display(),
                stderr.trim()
            )));
        }
        results.push(result);
    }
    Ok(results)
}

pub fn deploy(
    executor: &mut impl CommandExecutor,
    alias: &str,
    artifact: &Path,
) -> io::Result<Vec<CommandResult>> {
    let checksum = sha256_file(artifact)?;
    execute_specs(executor, &deploy_specs(alias, artifact, &checksum)?)
}

fn ssh_spec(alias: &str, remote_command: &str, batch: bool) -> CommandSpec {
    let mut args: Vec<OsString> =
        vec!["-o".into(), "StrictHostKeyChecking=yes".into(), "-T".into()];
    if batch {
        args.extend(["-o".into(), "BatchMode=yes".into()]);
    }
    args.push(alias.into());
    args.push(remote_command.into());
    CommandSpec {
        program: OsString::from("ssh"),
        args,
    }
}

pub fn validate_alias(alias: &str) -> io::Result<()> {
    if alias.is_empty()
        || alias.len() > 255
        || alias.starts_with('-')
        || !alias
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "SSH alias contains unsupported characters",
        ));
    }
    Ok(())
}

pub fn relay<R: Read, W: Write>(input: &mut R, output: &mut W, max_bytes: usize) -> io::Result<()> {
    while let Some(frame) = read_length_frame(input, max_bytes)? {
        // Relay validates JSON before forwarding. Unknown event types remain
        // forward-compatible, but malformed or oversized frames stop transport.
        let _: serde_json::Value = serde_json::from_slice(&frame)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        write_length_frame(output, &frame, max_bytes)?;
    }
    Ok(())
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RelayControl {
    schema_version: u32,
    #[serde(rename = "type")]
    kind: String,
    control_id: String,
    decision_socket: PathBuf,
    decision: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum RelayDecisionAckStatus {
    Delivered,
    Failed,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct RelayDecisionAck {
    schema_version: u32,
    #[serde(rename = "type")]
    kind: &'static str,
    control_id: String,
    status: RelayDecisionAckStatus,
}

impl RelayDecisionAck {
    fn new(control_id: String, status: RelayDecisionAckStatus) -> Self {
        Self {
            schema_version: 1,
            kind: "decisionAck",
            control_id,
            status,
        }
    }
}

#[derive(Default)]
struct RelayDecisionRegistry {
    requests: HashMap<PathBuf, HashSet<String>>,
}

impl RelayDecisionRegistry {
    fn advertise(&mut self, socket: PathBuf, request_id: String) {
        self.requests.entry(socket).or_default().insert(request_id);
    }

    fn contains(&self, socket: &Path, request_id: &str) -> bool {
        self.requests
            .get(socket)
            .is_some_and(|requests| requests.contains(request_id))
    }

    fn resolve(&mut self, socket: &Path, request_id: &str) {
        let remove_socket = if let Some(requests) = self.requests.get_mut(socket) {
            requests.remove(request_id);
            requests.is_empty()
        } else {
            false
        };
        if remove_socket {
            self.requests.remove(socket);
        }
    }
}

/// Runs the remote half of Cove's single persistent SSH transport.
///
/// Remote hooks and brokers continue to use the same private JSONL event
/// socket they use locally. This server turns those events into bounded
/// length-prefixed stdout frames. Its stdin accepts only decision frames for a
/// socket and request ID previously advertised by an event received during
/// this process lifetime.
pub fn run_relay_server(config: &Config) -> io::Result<()> {
    let max_bytes = config.max_frame_bytes.min(DEFAULT_MAX_FRAME_BYTES);
    fs::create_dir_all(&config.runtime_directory)?;
    fs::set_permissions(&config.runtime_directory, fs::Permissions::from_mode(0o700))?;
    let _singleton = RelaySingletonLock::acquire(&config.runtime_directory)?;
    let listener = bind_private_listener(&config.event_socket)?;
    listener.set_nonblocking(true)?;
    let _socket_guard = RelaySocketGuard::capture(&config.event_socket)?;

    let running = Arc::new(AtomicBool::new(true));
    let registry = Arc::new(Mutex::new(RelayDecisionRegistry::default()));
    let (acknowledgement_sender, acknowledgement_receiver) = mpsc::channel();
    let control_running = Arc::clone(&running);
    let control_registry = Arc::clone(&registry);
    let control_thread = thread::spawn(move || {
        let result = control_loop(
            &mut io::stdin().lock(),
            &control_registry,
            &acknowledgement_sender,
            max_bytes,
        );
        control_running.store(false, Ordering::Release);
        result
    });

    let result = relay_event_loop(
        &listener,
        &mut io::stdout().lock(),
        &registry,
        &acknowledgement_receiver,
        &running,
        max_bytes,
    );
    running.store(false, Ordering::Release);
    let control_result = control_thread
        .join()
        .map_err(|_| io::Error::other("remote relay control thread panicked"))?;
    result.and(control_result)
}

fn relay_event_loop<W: Write>(
    listener: &UnixListener,
    output: &mut W,
    registry: &Arc<Mutex<RelayDecisionRegistry>>,
    acknowledgement_receiver: &Receiver<RelayDecisionAck>,
    running: &AtomicBool,
    max_bytes: usize,
) -> io::Result<()> {
    loop {
        write_pending_acknowledgements(output, acknowledgement_receiver, max_bytes)?;
        if !running.load(Ordering::Acquire) {
            // The control reader sends its last acknowledgement before it
            // lowers `running`. Drain once more so an stdin EOF cannot race
            // the correlated response off stdout.
            write_pending_acknowledgements(output, acknowledgement_receiver, max_bytes)?;
            return Ok(());
        }
        match listener.accept() {
            Ok((stream, _)) => {
                // A malformed or oversized producer is isolated to its
                // connection. It must not take down unrelated remote sessions.
                let _ = forward_event_connection(stream, output, registry, max_bytes);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(20));
            }
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }
    }
}

fn write_pending_acknowledgements<W: Write>(
    output: &mut W,
    receiver: &Receiver<RelayDecisionAck>,
    max_bytes: usize,
) -> io::Result<()> {
    loop {
        match receiver.try_recv() {
            Ok(acknowledgement) => {
                let encoded = serde_json::to_vec(&acknowledgement)
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                write_length_frame(output, &encoded, max_bytes)?;
            }
            Err(TryRecvError::Empty | TryRecvError::Disconnected) => return Ok(()),
        }
    }
}

fn forward_event_connection<W: Write>(
    stream: UnixStream,
    output: &mut W,
    registry: &Arc<Mutex<RelayDecisionRegistry>>,
    max_bytes: usize,
) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(250)))?;
    let mut reader = BufReader::new(stream);
    while let Some(mut line) = read_limited_line(&mut reader, max_bytes)? {
        while matches!(line.last(), Some(b'\n' | b'\r')) {
            line.pop();
        }
        if line.is_empty() {
            continue;
        }
        forward_event_line(&line, output, registry, max_bytes)?;
    }
    Ok(())
}

fn forward_event_line<W: Write>(
    line: &[u8],
    output: &mut W,
    registry: &Arc<Mutex<RelayDecisionRegistry>>,
    max_bytes: usize,
) -> io::Result<()> {
    if line.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "event exceeds maximum frame size",
        ));
    }
    let event: CoveEvent = serde_json::from_slice(line)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if let Some((socket, request_id)) = advertised_decision(&event)
        && validate_private_decision_socket(&socket).is_ok()
    {
        registry.lock().unwrap().advertise(socket, request_id);
    }
    write_length_frame(output, line, max_bytes)
}

fn advertised_decision(event: &CoveEvent) -> Option<(PathBuf, String)> {
    let socket = event
        .payload
        .get("decisionSocket")
        .and_then(Value::as_str)
        .map(PathBuf::from)?;
    let request_id = event
        .payload
        .get("requestId")
        .and_then(relay_request_key)
        .or_else(|| {
            event
                .payload
                .pointer("/message/id")
                .and_then(relay_request_key)
        })
        .unwrap_or_else(|| format!("s:{}", event.event_id));
    Some((socket, request_id))
}

fn control_loop<R: Read>(
    input: &mut R,
    registry: &Arc<Mutex<RelayDecisionRegistry>>,
    acknowledgement_sender: &Sender<RelayDecisionAck>,
    max_bytes: usize,
) -> io::Result<()> {
    while let Some(frame) = read_length_frame(input, max_bytes)? {
        let control = decode_control_frame(&frame)?;
        let control_id = control.control_id.clone();
        let status = match forward_control(control, registry, max_bytes) {
            Ok(()) => RelayDecisionAckStatus::Delivered,
            Err(_) => RelayDecisionAckStatus::Failed,
        };
        acknowledgement_sender
            .send(RelayDecisionAck::new(control_id, status))
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "relay output closed"))?;
    }
    Ok(())
}

#[cfg(test)]
fn forward_control_frame(
    frame: &[u8],
    registry: &Arc<Mutex<RelayDecisionRegistry>>,
    max_bytes: usize,
) -> io::Result<()> {
    let control = decode_control_frame(frame)?;
    forward_control(control, registry, max_bytes)
}

fn decode_control_frame(frame: &[u8]) -> io::Result<RelayControl> {
    let control: RelayControl = serde_json::from_slice(frame)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if control.control_id.is_empty()
        || control.control_id.len() > 128
        || !control
            .control_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "invalid remote relay control ID",
        ));
    }
    Ok(control)
}

fn forward_control(
    control: RelayControl,
    registry: &Arc<Mutex<RelayDecisionRegistry>>,
    max_bytes: usize,
) -> io::Result<()> {
    if control.schema_version != 1 || control.kind != "decision" {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported remote relay control frame",
        ));
    }
    let request_id = control
        .decision
        .get("requestId")
        .and_then(relay_request_key)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "decision requestId missing"))?;
    if control
        .decision
        .get("schemaVersion")
        .and_then(Value::as_u64)
        != Some(1)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "unsupported decision schema",
        ));
    }
    {
        let guard = registry.lock().unwrap();
        if !guard.contains(&control.decision_socket, &request_id) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "decision socket or request was not advertised",
            ));
        }
    }

    validate_private_decision_socket(&control.decision_socket)?;
    let mut stream = UnixStream::connect(&control.decision_socket)?;
    stream.set_write_timeout(Some(Duration::from_millis(750)))?;
    validate_decision_peer(&stream)?;
    let mut encoded = serde_json::to_vec(&control.decision)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    encoded.push(b'\n');
    if encoded.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "decision exceeds maximum frame size",
        ));
    }
    stream.write_all(&encoded)?;
    stream.flush()?;
    // The newline completes the receiver's frame. Closing the write half is
    // best-effort cleanup and must not turn a completed delivery into a false
    // failure if the receiver closes immediately after reading that line.
    let _ = stream.shutdown(std::net::Shutdown::Write);
    registry
        .lock()
        .unwrap()
        .resolve(&control.decision_socket, &request_id);
    Ok(())
}

fn relay_request_key(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(format!("s:{value}")),
        Value::Number(value) if value.is_i64() || value.is_u64() => Some(format!("n:{value}")),
        _ => None,
    }
}

fn validate_private_decision_socket(path: &Path) -> io::Result<()> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "decision socket must be absolute",
        ));
    }
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.file_type().is_socket()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "decision socket is not user-private",
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "socket has no parent"))?;
    let parent_metadata = fs::symlink_metadata(parent)?;
    if !parent_metadata.file_type().is_dir()
        || parent_metadata.uid() != unsafe { libc::geteuid() }
        || parent_metadata.permissions().mode() & 0o077 != 0
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "decision socket parent is not user-private",
        ));
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn validate_decision_peer(stream: &UnixStream) -> io::Result<()> {
    let mut uid = 0;
    let mut gid = 0;
    if unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } != 0
        || uid != unsafe { libc::geteuid() }
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "decision socket peer is not current user",
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn validate_decision_peer(stream: &UnixStream) -> io::Result<()> {
    let mut credentials = libc::ucred {
        pid: 0,
        uid: 0,
        gid: 0,
    };
    let mut length = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let result = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut credentials as *mut libc::ucred).cast(),
            &mut length,
        )
    };
    if result != 0 || credentials.uid != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "decision socket peer is not current user",
        ));
    }
    Ok(())
}

#[derive(Debug)]
struct RelaySingletonLock {
    file: File,
}

impl RelaySingletonLock {
    fn acquire(runtime_directory: &Path) -> io::Result<Self> {
        let path = runtime_directory.join("remote-relay.lock");
        let file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .read(true)
            .write(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW)
            .open(path)?;
        let metadata = file.metadata()?;
        if !metadata.file_type().is_file() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "remote relay lock is not a user-owned file",
            ));
        }
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "another remote relay is already active",
            ));
        }
        Ok(Self { file })
    }
}

impl Drop for RelaySingletonLock {
    fn drop(&mut self) {
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

struct RelaySocketGuard {
    path: PathBuf,
    device: u64,
    inode: u64,
}

impl RelaySocketGuard {
    fn capture(path: &Path) -> io::Result<Self> {
        let metadata = fs::symlink_metadata(path)?;
        if !metadata.file_type().is_socket() || metadata.uid() != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "remote relay socket is not user-owned",
            ));
        }
        Ok(Self {
            path: path.to_owned(),
            device: metadata.dev(),
            inode: metadata.ino(),
        })
    }
}

impl Drop for RelaySocketGuard {
    fn drop(&mut self) {
        if let Ok(metadata) = fs::symlink_metadata(&self.path)
            && metadata.file_type().is_socket()
            && metadata.uid() == unsafe { libc::geteuid() }
            && metadata.dev() == self.device
            && metadata.ino() == self.inode
        {
            let _ = fs::remove_file(&self.path);
        }
    }
}

pub fn run_with_osc_marker(command: &[String], marker: &str) -> io::Result<i32> {
    if command.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "OSC marker requires command",
        ));
    }
    let marker = sanitize_marker(marker);
    let mut stderr = io::stderr().lock();
    stderr.write_all(osc_marker_enter(&marker).as_bytes())?;
    stderr.flush()?;
    let status = std::process::Command::new(&command[0])
        .args(&command[1..])
        .status();
    stderr.write_all(osc_marker_exit().as_bytes())?;
    stderr.flush()?;
    Ok(status?.code().unwrap_or(1))
}

/// Runs a monitored Codex CLI below a tiny POSIX wrapper so the terminal title
/// is restored even when the child exits because of an interactive signal.
/// Arguments are passed through `"$@"`; no command text is interpolated into
/// the shell program.
pub fn run_codex_with_osc_marker(
    real_codex: &Path,
    arguments: &[String],
    marker: &str,
) -> io::Result<i32> {
    let marker = sanitize_marker(marker);
    let script = r#"
restore_cove_title() {
  printf '\033[23;0t' >&2
}
trap 'status=$?; trap - EXIT HUP INT TERM; restore_cove_title; exit "$status"' EXIT HUP INT TERM
printf '\033[22;0t\033]2;codex-cove:%s\007' "$CODEX_COVE_MARKER" >&2
"$@"
"#;
    let status = Command::new("/bin/sh")
        .arg("-c")
        .arg(script)
        .arg("codex-cove-marker")
        .arg(real_codex)
        .args(arguments)
        .env("CODEX_COVE_MARKER", &marker)
        .env("CODEX_COVE_BYPASS", "1")
        .env("CODEX_COVE_LAUNCH_ID", &marker)
        .status()?;
    Ok(status.code().unwrap_or(1))
}

pub fn osc_marker_enter(marker: &str) -> String {
    // CSI 22 pushes the current icon/window title on terminals implementing
    // the xterm title stack. CSI 23 restores it after the remote Codex exits.
    format!(
        "\x1b[22;0t\x1b]2;codex-cove:{}\x07",
        sanitize_marker(marker)
    )
}

pub fn osc_marker_exit() -> &'static str {
    "\x1b[23;0t"
}

pub fn sanitize_marker(value: &str) -> String {
    value
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_'))
        .take(128)
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::bind_private_listener;
    use crate::{CoveEvent, EventSource};
    use serde_json::json;
    use std::fs;
    use std::io::{BufRead, BufReader};
    use tempfile::tempdir;

    #[test]
    fn rejects_alias_shell_injection() {
        assert!(validate_alias("dev249").is_ok());
        assert!(validate_alias("host.example-test").is_ok());
        assert!(validate_alias("host; rm -rf").is_err());
        assert!(validate_alias("-v").is_err());
    }

    #[test]
    fn framed_relay_round_trips_json() {
        let payload = serde_json::to_vec(&json!({"schemaVersion":1})).unwrap();
        let mut input = Vec::new();
        write_length_frame(&mut input, &payload, 1024).unwrap();
        let mut output = Vec::new();
        relay(&mut input.as_slice(), &mut output, 1024).unwrap();
        assert_eq!(input, output);
    }

    #[test]
    fn marker_strips_control_characters() {
        assert_eq!(sanitize_marker("abc\u{7}]2;bad"), "abc2bad");
    }

    #[test]
    fn marker_uses_terminal_title_stack_for_restoration() {
        assert_eq!(
            osc_marker_enter("launch-1"),
            "\u{1b}[22;0t\u{1b}]2;codex-cove:launch-1\u{7}"
        );
        assert_eq!(osc_marker_exit(), "\u{1b}[23;0t");
    }

    #[test]
    fn deploy_builds_strict_scoped_commands() {
        let temp = tempdir().unwrap();
        let artifact = temp.path().join("codex-cove");
        fs::write(&artifact, b"binary").unwrap();
        let specs = deploy_specs("dev249", &artifact, &"a".repeat(64)).unwrap();
        assert_eq!(specs.len(), 3);
        assert_eq!(specs[0].program, "ssh");
        assert!(specs[0].args.contains(&"StrictHostKeyChecking=yes".into()));
        assert_eq!(specs[1].program, "scp");
        assert_eq!(specs[2].program, "ssh");
        assert!(
            specs[2]
                .args
                .last()
                .unwrap()
                .to_string_lossy()
                .contains("remote-install --expected-sha256")
        );
    }

    #[derive(Default)]
    struct MockExecutor {
        seen: Vec<CommandSpec>,
        fail_at: Option<usize>,
    }

    impl CommandExecutor for MockExecutor {
        fn run(&mut self, spec: &CommandSpec) -> io::Result<CommandResult> {
            self.seen.push(spec.clone());
            let success = self.fail_at != Some(self.seen.len() - 1);
            Ok(CommandResult {
                success,
                stdout: Vec::new(),
                stderr: if success {
                    Vec::new()
                } else {
                    b"failed".to_vec()
                },
            })
        }
    }

    #[test]
    fn executor_stops_at_first_failure() {
        let specs = vec![
            ssh_spec("dev249", "true", true),
            ssh_spec("dev249", "false", true),
            ssh_spec("dev249", "never", true),
        ];
        let mut executor = MockExecutor {
            fail_at: Some(1),
            ..Default::default()
        };
        assert!(execute_specs(&mut executor, &specs).is_err());
        assert_eq!(executor.seen.len(), 2);
    }

    #[test]
    fn relay_event_registers_only_advertised_private_decision_socket() {
        let temp = tempdir().unwrap();
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let decision_path = temp.path().join("decision.sock");
        let _listener = bind_private_listener(&decision_path).unwrap();
        let event = CoveEvent::new(
            "approvalRequested",
            EventSource::RemoteCli,
            "session-1",
            Some("launch-1".to_owned()),
            json!({
                "message": {
                    "jsonrpc": "2.0",
                    "id": 42,
                    "method": "item/commandExecution/requestApproval"
                },
                "decisionSocket": decision_path,
            }),
        );
        let encoded = serde_json::to_vec(&event).unwrap();
        let registry = Arc::new(Mutex::new(RelayDecisionRegistry::default()));
        let mut framed = Vec::new();
        forward_event_line(&encoded, &mut framed, &registry, 1_048_576).unwrap();

        assert!(registry.lock().unwrap().contains(&decision_path, "n:42"));
        assert_eq!(
            read_length_frame(&mut framed.as_slice(), 1_048_576).unwrap(),
            Some(encoded)
        );
    }

    #[test]
    fn relay_control_forwards_once_to_matching_private_socket() {
        let temp = tempdir().unwrap();
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let decision_path = temp.path().join("decision.sock");
        let listener = bind_private_listener(&decision_path).unwrap();
        let registry = Arc::new(Mutex::new(RelayDecisionRegistry::default()));
        registry
            .lock()
            .unwrap()
            .advertise(decision_path.clone(), "n:42".to_owned());
        let control = serde_json::to_vec(&json!({
            "schemaVersion": 1,
            "type": "decision",
            "controlId": "control-42",
            "decisionSocket": decision_path,
            "decision": {
                "schemaVersion": 1,
                "requestId": 42,
                "result": {"decision": "accept"}
            }
        }))
        .unwrap();

        forward_control_frame(&control, &registry, 1_048_576).unwrap();
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        let decision: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(decision["requestId"], 42);
        assert_eq!(decision["result"]["decision"], "accept");
        assert!(
            forward_control_frame(&control, &registry, 1_048_576).is_err(),
            "a resolved request must not be replayable"
        );
    }

    #[test]
    fn relay_control_rejects_unadvertised_or_mismatched_requests() {
        let temp = tempdir().unwrap();
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let decision_path = temp.path().join("decision.sock");
        let _listener = bind_private_listener(&decision_path).unwrap();
        let registry = Arc::new(Mutex::new(RelayDecisionRegistry::default()));
        registry
            .lock()
            .unwrap()
            .advertise(decision_path.clone(), "s:request-1".to_owned());
        let mismatched = serde_json::to_vec(&json!({
            "schemaVersion": 1,
            "type": "decision",
            "controlId": "control-mismatch",
            "decisionSocket": decision_path,
            "decision": {
                "schemaVersion": 1,
                "requestId": "request-2",
                "result": {"decision": "accept"}
            }
        }))
        .unwrap();
        let error = forward_control_frame(&mismatched, &registry, 1_048_576).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn relay_control_emits_delivered_ack_only_after_complete_socket_write() {
        let temp = tempdir().unwrap();
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let decision_path = temp.path().join("decision.sock");
        let listener = bind_private_listener(&decision_path).unwrap();
        let registry = Arc::new(Mutex::new(RelayDecisionRegistry::default()));
        registry
            .lock()
            .unwrap()
            .advertise(decision_path.clone(), "n:42".to_owned());
        let control = serde_json::to_vec(&json!({
            "schemaVersion": 1,
            "type": "decision",
            "controlId": "control-delivered",
            "decisionSocket": decision_path,
            "decision": {
                "schemaVersion": 1,
                "requestId": 42,
                "result": {"decision": "accept"}
            }
        }))
        .unwrap();
        let mut framed = Vec::new();
        write_length_frame(&mut framed, &control, 1_048_576).unwrap();
        let (sender, receiver) = mpsc::channel();

        control_loop(&mut framed.as_slice(), &registry, &sender, 1_048_576).unwrap();

        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream).read_line(&mut line).unwrap();
        assert!(line.ends_with('\n'));
        let acknowledgement = receiver.recv().unwrap();
        assert_eq!(acknowledgement.control_id, "control-delivered");
        assert_eq!(acknowledgement.status, RelayDecisionAckStatus::Delivered);
        assert!(!registry.lock().unwrap().contains(&decision_path, "n:42"));
    }

    #[test]
    fn relay_control_emits_failed_ack_and_keeps_route_retryable() {
        let temp = tempdir().unwrap();
        fs::set_permissions(temp.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let decision_path = temp.path().join("missing.sock");
        let registry = Arc::new(Mutex::new(RelayDecisionRegistry::default()));
        registry
            .lock()
            .unwrap()
            .advertise(decision_path.clone(), "s:request-1".to_owned());
        let control = serde_json::to_vec(&json!({
            "schemaVersion": 1,
            "type": "decision",
            "controlId": "control-failed",
            "decisionSocket": decision_path,
            "decision": {
                "schemaVersion": 1,
                "requestId": "request-1",
                "result": {"decision": "decline"}
            }
        }))
        .unwrap();
        let mut framed = Vec::new();
        write_length_frame(&mut framed, &control, 1_048_576).unwrap();
        let (sender, receiver) = mpsc::channel();

        control_loop(&mut framed.as_slice(), &registry, &sender, 1_048_576).unwrap();

        let acknowledgement = receiver.recv().unwrap();
        assert_eq!(acknowledgement.control_id, "control-failed");
        assert_eq!(acknowledgement.status, RelayDecisionAckStatus::Failed);
        assert!(
            registry
                .lock()
                .unwrap()
                .contains(&decision_path, "s:request-1"),
            "a failed delivery must remain retryable"
        );
    }

    #[test]
    fn relay_acknowledgement_is_a_bounded_length_prefixed_frame() {
        let (sender, receiver) = mpsc::channel();
        sender
            .send(RelayDecisionAck::new(
                "control-framed".to_owned(),
                RelayDecisionAckStatus::Delivered,
            ))
            .unwrap();
        let mut output = Vec::new();
        write_pending_acknowledgements(&mut output, &receiver, 1_048_576).unwrap();

        let encoded = read_length_frame(&mut output.as_slice(), 1_048_576)
            .unwrap()
            .unwrap();
        let acknowledgement: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(acknowledgement["schemaVersion"], 1);
        assert_eq!(acknowledgement["type"], "decisionAck");
        assert_eq!(acknowledgement["controlId"], "control-framed");
        assert_eq!(acknowledgement["status"], "delivered");
    }

    #[test]
    fn relay_control_rejects_missing_or_unsafe_control_ids() {
        let registry = Arc::new(Mutex::new(RelayDecisionRegistry::default()));
        for control_id in [Value::Null, json!("bad/control/id")] {
            let mut control = json!({
                "schemaVersion": 1,
                "type": "decision",
                "decisionSocket": "/tmp/not-used.sock",
                "decision": {
                    "schemaVersion": 1,
                    "requestId": 1,
                    "result": {"decision": "cancel"}
                }
            });
            if !control_id.is_null() {
                control["controlId"] = control_id;
            }
            let error =
                forward_control_frame(&serde_json::to_vec(&control).unwrap(), &registry, 1_048_576)
                    .unwrap_err();
            assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        }
    }

    #[test]
    fn relay_request_keys_keep_string_and_integer_ids_distinct() {
        assert_eq!(relay_request_key(&json!("42")).as_deref(), Some("s:42"));
        assert_eq!(relay_request_key(&json!(42)).as_deref(), Some("n:42"));
        assert!(relay_request_key(&json!(42.5)).is_none());
        assert!(relay_request_key(&Value::Null).is_none());
    }

    #[test]
    fn relay_singleton_lock_prevents_two_servers_for_runtime() {
        let temp = tempdir().unwrap();
        let first = RelaySingletonLock::acquire(temp.path()).unwrap();
        let error = RelaySingletonLock::acquire(temp.path()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        drop(first);
        RelaySingletonLock::acquire(temp.path()).unwrap();
    }
}
