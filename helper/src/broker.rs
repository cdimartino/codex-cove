use crate::config::Config;
use crate::ipc::{bind_private_listener, read_limited_line, send_event_one_way};
use crate::{CoveEvent, EventSource};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::env;
use std::fs;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::Shutdown;
use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::Duration;
use tungstenite::handshake::server::{Request, Response};
use tungstenite::protocol::{Message, WebSocket, WebSocketConfig};

const DIRECT_STDIO_PROBE_OUTPUT_LIMIT: usize = 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AppServerMode {
    Proxy,
    DirectStdio,
}

impl AppServerMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Proxy => "proxy",
            Self::DirectStdio => "direct-stdio",
        }
    }

    pub fn parse(value: &str) -> io::Result<Self> {
        match value {
            "proxy" => Ok(Self::Proxy),
            "direct-stdio" => Ok(Self::DirectStdio),
            _ => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "broker mode must be proxy or direct-stdio",
            )),
        }
    }

    fn command_args(self) -> &'static [&'static str] {
        match self {
            Self::Proxy => &["app-server", "proxy"],
            Self::DirectStdio => &["app-server", "--stdio"],
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirectStdioProbe {
    pub available: bool,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AppServerProbe {
    pub available: bool,
    pub detail: String,
}

#[derive(Debug, Clone, Copy)]
struct AppServerCommand<'a> {
    real_codex: &'a Path,
    mode: AppServerMode,
}

struct BrokerRunContext<'a> {
    decision_listener: &'a UnixListener,
    decision_path: &'a Path,
    control_listener: &'a UnixListener,
    launch_id: &'a str,
    app_server: AppServerCommand<'a>,
    config: &'a Config,
    observed_sessions: Arc<Mutex<HashSet<String>>>,
}

pub fn probe_direct_stdio(real_codex: &Path, timeout: Duration) -> DirectStdioProbe {
    let child = Command::new(real_codex)
        .args(["app-server", "--help"])
        .env("CODEX_COVE_BYPASS", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let Ok(mut child) = child else {
        return DirectStdioProbe {
            available: false,
            detail: "could not run app-server help".to_owned(),
        };
    };

    let stdout = child
        .stdout
        .take()
        .map(|stdout| thread::spawn(move || read_bounded_output(stdout)));
    let stderr = child
        .stderr
        .take()
        .map(|stderr| thread::spawn(move || read_bounded_output(stderr)));

    let started = std::time::Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < timeout => {
                thread::sleep(Duration::from_millis(20));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let mut output = join_probe_output(stdout);
    output.extend(join_probe_output(stderr));
    let Some(status) = status else {
        return DirectStdioProbe {
            available: false,
            detail: "app-server help timed out".to_owned(),
        };
    };

    let help = String::from_utf8_lossy(&output);
    if status.success() && (help.contains("--stdio") || help.contains("stdio://")) {
        DirectStdioProbe {
            available: true,
            detail: "public app-server stdio transport is available".to_owned(),
        }
    } else if status.success() {
        DirectStdioProbe {
            available: false,
            detail: "app-server help does not advertise stdio transport".to_owned(),
        }
    } else {
        DirectStdioProbe {
            available: false,
            detail: format!("app-server help exited {status}"),
        }
    }
}

fn read_bounded_output(mut output: impl Read) -> Vec<u8> {
    let mut captured = Vec::new();
    let mut buffer = [0_u8; 8_192];
    loop {
        match output.read(&mut buffer) {
            Ok(0) => break,
            Ok(read) => {
                let remaining = DIRECT_STDIO_PROBE_OUTPUT_LIMIT.saturating_sub(captured.len());
                let retained = read.min(remaining);
                captured.extend_from_slice(&buffer[..retained]);
            }
            Err(_) => break,
        }
    }
    captured
}

fn join_probe_output(handle: Option<thread::JoinHandle<Vec<u8>>>) -> Vec<u8> {
    handle
        .and_then(|handle| handle.join().ok())
        .unwrap_or_default()
}

pub fn run_broker(
    listen_path: &Path,
    launch_id: &str,
    real_codex: &Path,
    config: &Config,
    mode: AppServerMode,
) -> io::Result<i32> {
    trace_broker(&format!("broker_start mode={}", mode.as_str()));
    let listener = bind_private_listener(listen_path)?;
    let decision_path = listen_path.with_extension("d");
    let decision_listener = match bind_private_listener(&decision_path) {
        Ok(listener) => listener,
        Err(error) => {
            let _ = fs::remove_file(listen_path);
            return Err(error);
        }
    };
    let control_path = listen_path.with_extension("c");
    let control_listener = match bind_private_listener(&control_path) {
        Ok(listener) => listener,
        Err(error) => {
            let _ = fs::remove_file(listen_path);
            let _ = fs::remove_file(&decision_path);
            return Err(error);
        }
    };
    let accept_timeout = broker_client_claim_timeout(config);
    let observed_sessions = Arc::new(Mutex::new(HashSet::<String>::new()));
    let context = BrokerRunContext {
        decision_listener: &decision_listener,
        decision_path: &decision_path,
        control_listener: &control_listener,
        launch_id,
        app_server: AppServerCommand { real_codex, mode },
        config,
        observed_sessions: Arc::clone(&observed_sessions),
    };
    let result = match accept_with_timeout(&listener, accept_timeout) {
        Ok((client, _)) => {
            trace_broker("broker_socket_claimed");
            run_broker_inner(&client, &context)
        }
        Err(error) => {
            trace_broker(&format!("broker_accept_error kind={:?}", error.kind()));
            Err(error)
        }
    };
    publish_closed_sessions(
        config,
        launch_id,
        &observed_sessions.lock().unwrap(),
        result.as_ref().is_ok_and(|code| *code == 0),
    );
    let _ = fs::remove_file(listen_path);
    let _ = fs::remove_file(decision_path);
    let _ = fs::remove_file(control_path);
    result
}

fn publish_closed_sessions(
    config: &Config,
    launch_id: &str,
    observed_sessions: &HashSet<String>,
    succeeded: bool,
) {
    let source = if env::var_os("CODEX_COVE_HOST_ID").is_some() {
        EventSource::RemoteCli
    } else {
        EventSource::LocalCli
    };
    let mut session_ids = observed_sessions.iter().collect::<Vec<_>>();
    session_ids.sort();
    for session_id in session_ids {
        let event = CoveEvent::new(
            "session_snapshot",
            source,
            session_id.clone(),
            Some(launch_id.to_owned()),
            json!({
                "snapshotId": session_id,
                "status": if succeeded { "completed" } else { "failed" },
                "priority": if succeeded { 8 } else { 90 },
                "title": "Codex CLI",
                "unread": !succeeded,
                "liveness": "closed",
                "activeTurnId": Value::Null,
                "controlRoute": Value::Null,
            }),
        );
        let _ = send_event_one_way(
            &config.event_socket,
            &event,
            Duration::from_millis(50),
            config.max_frame_bytes,
        );
    }
}

fn accept_with_timeout(
    listener: &UnixListener,
    timeout: Duration,
) -> io::Result<(UnixStream, std::os::unix::net::SocketAddr)> {
    listener.set_nonblocking(true)?;
    let started = std::time::Instant::now();
    loop {
        match listener.accept() {
            Ok((stream, address)) => {
                stream.set_nonblocking(false)?;
                return Ok((stream, address));
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                if started.elapsed() >= timeout {
                    return Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "broker client did not connect before startup deadline",
                    ));
                }
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(error),
        }
    }
}

fn broker_client_claim_timeout(config: &Config) -> Duration {
    let configured = config.broker_start_timeout_ms.clamp(250, 120_000);
    if configured <= 1_000 {
        Duration::from_millis(configured)
    } else {
        Duration::from_secs(300)
    }
}

fn spawn_app_server(real_codex: &Path, mode: AppServerMode) -> io::Result<Child> {
    let mut command = Command::new(real_codex);
    command
        .args(mode.command_args())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .env("CODEX_COVE_BYPASS", "1")
        .env_remove("CODEX_COVE_TRACE_BROKER");
    if trace_broker_enabled() {
        command.stderr(Stdio::inherit());
    } else {
        command.env("RUST_LOG", "off").stderr(Stdio::null());
    }
    command.process_group(0);
    let child = command.spawn();
    match &child {
        Ok(child) => trace_broker(&format!(
            "child_spawn mode={} pid={}",
            mode.as_str(),
            child.id()
        )),
        Err(error) => trace_broker(&format!(
            "child_spawn_failed mode={} kind={:?}",
            mode.as_str(),
            error.kind()
        )),
    }
    child
}

pub fn probe_app_server_rpc(
    real_codex: &Path,
    mode: AppServerMode,
    timeout: Duration,
    max_bytes: usize,
) -> AppServerProbe {
    let mut command = Command::new(real_codex);
    command
        .args(mode.command_args())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .env("CODEX_COVE_BYPASS", "1")
        .env("RUST_LOG", "off")
        .env_remove("CODEX_COVE_TRACE_BROKER");
    command.process_group(0);
    let child = command.spawn();
    let Ok(mut child) = child else {
        return AppServerProbe {
            available: false,
            detail: format!("{} app-server could not start", mode.as_str()),
        };
    };
    if let Err(error) = verify_child_started(&mut child) {
        stop_child(&mut child);
        return AppServerProbe {
            available: false,
            detail: probe_failure_detail(
                mode,
                &format!("app-server failed startup check: {error}"),
                "",
            ),
        };
    }

    let Some(mut stdin) = child.stdin.take() else {
        stop_child(&mut child);
        return AppServerProbe {
            available: false,
            detail: format!("{} app-server stdin unavailable", mode.as_str()),
        };
    };
    let Some(stdout) = child.stdout.take() else {
        stop_child(&mut child);
        return AppServerProbe {
            available: false,
            detail: format!("{} app-server stdout unavailable", mode.as_str()),
        };
    };
    let stderr = child
        .stderr
        .take()
        .map(|stderr| thread::spawn(move || read_bounded_output(stderr)));
    let (line_sender, line_receiver) = mpsc::channel::<io::Result<Vec<u8>>>();
    let line_reader = thread::spawn(move || {
        let mut reader = BufReader::new(stdout);
        loop {
            match read_limited_line(&mut reader, max_bytes) {
                Ok(Some(line)) => {
                    if line_sender.send(Ok(line)).is_err() {
                        break;
                    }
                }
                Ok(None) => break,
                Err(error) => {
                    let _ = line_sender.send(Err(error));
                    break;
                }
            }
        }
    });

    let initialize = json!({
        "jsonrpc": "2.0",
        "id": "cove-probe-initialize",
        "method": "initialize",
        "params": {
            "clientInfo": {
                "name": "codex-cove",
                "version": env!("CARGO_PKG_VERSION"),
            }
        }
    });
    let initialized = json!({
        "jsonrpc": "2.0",
        "method": "initialized",
        "params": {}
    });
    let config = json!({
        "jsonrpc": "2.0",
        "id": "cove-probe-config",
        "method": "configRequirements/read",
        "params": {}
    });
    for request in [&initialize, &initialized, &config] {
        let write = serde_json::to_vec(request)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
            .and_then(|bytes| {
                if bytes.len() > max_bytes {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "probe request exceeds maximum frame size",
                    ));
                }
                stdin.write_all(&bytes)?;
                stdin.write_all(b"\n")?;
                stdin.flush()
            });
        if let Err(error) = write {
            stop_child(&mut child);
            let _ = line_reader.join();
            let stderr = String::from_utf8_lossy(&join_probe_output(stderr)).to_string();
            return AppServerProbe {
                available: false,
                detail: probe_failure_detail(
                    mode,
                    &format!("probe write failed: {error}"),
                    &stderr,
                ),
            };
        }
    }

    let started = std::time::Instant::now();
    let mut initialized = false;
    let result = loop {
        let remaining = timeout.saturating_sub(started.elapsed());
        if remaining.is_zero() {
            break Err("probe timed out waiting for configRequirements/read".to_owned());
        }
        match line_receiver.recv_timeout(remaining.min(Duration::from_millis(50))) {
            Ok(Ok(line)) => {
                let value = match serde_json::from_slice::<Value>(&line) {
                    Ok(value) => value,
                    Err(error) => {
                        break Err(format!("probe received invalid JSON: {error}"));
                    }
                };
                match value.get("id").and_then(Value::as_str) {
                    Some("cove-probe-initialize") if value.get("result").is_some() => {
                        initialized = true;
                    }
                    Some("cove-probe-initialize") => {
                        break Err("initialize probe returned an error".to_owned());
                    }
                    Some("cove-probe-config") if initialized && value.get("result").is_some() => {
                        break Ok(());
                    }
                    Some("cove-probe-config") => {
                        break Err("configRequirements/read probe returned an error".to_owned());
                    }
                    _ => {}
                }
            }
            Ok(Err(error)) => break Err(format!("probe read failed: {error}")),
            Err(mpsc::RecvTimeoutError::Timeout) => {
                if child.try_wait().ok().flatten().is_some() {
                    break Err("app-server exited before readiness response".to_owned());
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                break Err("app-server stdout closed before readiness response".to_owned());
            }
        }
    };

    stop_child(&mut child);
    let _ = line_reader.join();
    let stderr = String::from_utf8_lossy(&join_probe_output(stderr)).to_string();
    match result {
        Ok(()) => AppServerProbe {
            available: true,
            detail: format!("{} app-server JSON-RPC readiness confirmed", mode.as_str()),
        },
        Err(detail) => AppServerProbe {
            available: false,
            detail: probe_failure_detail(mode, &detail, &stderr),
        },
    }
}

fn probe_failure_detail(mode: AppServerMode, detail: &str, stderr: &str) -> String {
    let stderr = stderr.trim();
    if stderr.is_empty() {
        format!("{} app-server unavailable: {detail}", mode.as_str())
    } else {
        format!(
            "{} app-server unavailable: {detail}: {stderr}",
            mode.as_str()
        )
    }
}

fn verify_child_started(child: &mut Child) -> io::Result<()> {
    let started = std::time::Instant::now();
    let grace = Duration::from_millis(250);
    while started.elapsed() < grace {
        if let Some(status) = child.try_wait()? {
            return Err(io::Error::other(format!(
                "app-server exited during broker startup with {status}"
            )));
        }
        thread::sleep(Duration::from_millis(5));
    }
    if let Some(status) = child.try_wait()? {
        return Err(io::Error::other(format!(
            "app-server exited during broker startup with {status}"
        )));
    }
    Ok(())
}

fn stop_child(child: &mut Child) {
    let pid = child.id();
    if let Err(error) = terminate_process_group(pid)
        && error.raw_os_error() != Some(libc::ESRCH)
    {
        let _ = child.kill();
    }
    let _ = child.wait();
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

fn run_broker_inner(client: &UnixStream, context: &BrokerRunContext<'_>) -> io::Result<i32> {
    let handshake_timeout = broker_handshake_timeout(context.config);
    match detect_client_transport(client, handshake_timeout)? {
        ClientTransport::WebSocket => {
            run_websocket_broker_inner(client, context, handshake_timeout)
        }
        ClientTransport::RawJsonl => run_raw_broker_inner(client, context),
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ClientTransport {
    RawJsonl,
    WebSocket,
}

fn broker_handshake_timeout(config: &Config) -> Duration {
    Duration::from_millis(config.broker_start_timeout_ms.clamp(250, 5_000))
}

fn detect_client_transport(
    client: &UnixStream,
    detection_timeout: Duration,
) -> io::Result<ClientTransport> {
    let prior_timeout = client.read_timeout()?;
    client.set_read_timeout(Some(Duration::from_millis(25)))?;
    let mut prefix = [0_u8; 3];
    let started = std::time::Instant::now();
    let result = loop {
        match unix_stream_peek(client, &mut prefix) {
            Ok(read) if read >= 3 && &prefix == b"GET" => break Ok(ClientTransport::WebSocket),
            Ok(read) if read > 0 && b"GET".starts_with(&prefix[..read]) => {
                if started.elapsed() >= detection_timeout {
                    break Err(io::Error::new(
                        io::ErrorKind::TimedOut,
                        "partial websocket handshake timed out",
                    ));
                }
            }
            Ok(_) => break Ok(ClientTransport::RawJsonl),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) =>
            {
                if started.elapsed() >= detection_timeout {
                    break Ok(ClientTransport::RawJsonl);
                }
            }
            Err(error) => break Err(error),
        }
    };
    client.set_read_timeout(prior_timeout)?;
    result
}

fn unix_stream_peek(stream: &UnixStream, buffer: &mut [u8]) -> io::Result<usize> {
    let read = unsafe {
        libc::recv(
            stream.as_raw_fd(),
            buffer.as_mut_ptr().cast(),
            buffer.len(),
            libc::MSG_PEEK,
        )
    };
    if read < 0 {
        Err(io::Error::last_os_error())
    } else {
        Ok(read as usize)
    }
}

fn run_raw_broker_inner(client: &UnixStream, context: &BrokerRunContext<'_>) -> io::Result<i32> {
    let decision_listener = context.decision_listener;
    let decision_path = context.decision_path;
    let control_listener = context.control_listener;
    let launch_id = context.launch_id;
    let app_server = &context.app_server;
    let config = context.config;
    let observed_sessions = Arc::clone(&context.observed_sessions);
    let mut child = spawn_app_server(app_server.real_codex, app_server.mode)?;
    if let Err(error) = verify_child_started(&mut child) {
        stop_child(&mut child);
        return Err(error);
    }
    let Some(mut proxy_input) = child.stdin.take() else {
        stop_child(&mut child);
        return Err(io::Error::other("proxy stdin unavailable"));
    };
    let Some(proxy_output) = child.stdout.take() else {
        stop_child(&mut child);
        return Err(io::Error::other("proxy stdout unavailable"));
    };
    let mut client_input = client.try_clone()?;
    client_input.set_read_timeout(Some(Duration::from_millis(25)))?;
    let mut client_output = client.try_clone()?;
    let (decision_sender, decision_receiver) = mpsc::channel::<Vec<u8>>();
    let (worker_sender, worker_receiver) = mpsc::channel::<RawBrokerWorkerResult>();
    let pending = Arc::new(Mutex::new(HashSet::<String>::new()));
    let control_replies = Arc::new(Mutex::new(ThreadControlReplies::new()));
    let active_turns = Arc::new(Mutex::new(HashMap::<String, String>::new()));
    let input_pending = Arc::clone(&pending);
    let max_bytes = config.max_frame_bytes;
    let input_result_sender = worker_sender.clone();
    let input_thread = thread::spawn(move || {
        let result = (|| -> io::Result<()> {
            let mut buffer = [0_u8; 16_384];
            let mut client_frame_buffer = Vec::new();
            let mut traced_inbound_frame = false;
            loop {
                while let Ok(frame) = decision_receiver.try_recv() {
                    proxy_input.write_all(&frame)?;
                    proxy_input.write_all(b"\n")?;
                    proxy_input.flush()?;
                }
                match client_input.read(&mut buffer) {
                    Ok(0) => break,
                    Ok(read) => {
                        if !traced_inbound_frame {
                            trace_broker(&format!("first_inbound_frame source=raw bytes={read}"));
                            traced_inbound_frame = true;
                        }
                        forward_raw_client_bytes(
                            &mut client_frame_buffer,
                            &buffer[..read],
                            &mut proxy_input,
                            &input_pending,
                            max_bytes,
                        )?;
                    }
                    Err(error)
                        if matches!(
                            error.kind(),
                            io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                        ) => {}
                    Err(error) => {
                        return Err(io::Error::new(
                            error.kind(),
                            format!("broker client input read failed: {error}"),
                        ));
                    }
                }
            }
            while let Ok(frame) = decision_receiver.try_recv() {
                proxy_input.write_all(&frame)?;
                proxy_input.write_all(b"\n")?;
            }
            if !client_frame_buffer.is_empty() {
                forward_complete_raw_client_frame(
                    &client_frame_buffer,
                    &mut proxy_input,
                    &input_pending,
                    max_bytes,
                )?;
            }
            Ok(())
        })();
        let _ = input_result_sender.send(RawBrokerWorkerResult::Input(result));
    });

    let socket = config.event_socket.clone();
    let timeout = Duration::from_millis(50);
    let launch_id = launch_id.to_owned();
    let decision_path_text = decision_path.display().to_string();
    let running = Arc::new(AtomicBool::new(true));
    let control_thread = spawn_thread_control_listener(
        control_listener.try_clone()?,
        ThreadControlListenerContext {
            launch_id: launch_id.clone(),
            observed_sessions: Arc::clone(&observed_sessions),
            active_turns: Arc::clone(&active_turns),
            replies: Arc::clone(&control_replies),
            running: Arc::clone(&running),
            app_server_sender: decision_sender.clone(),
            max_bytes,
        },
    )?;
    let decision_thread = spawn_decision_listener(
        decision_listener.try_clone()?,
        launch_id.clone(),
        Arc::clone(&pending),
        Arc::clone(&running),
        decision_sender,
        max_bytes,
    )?;
    let output_pending = Arc::clone(&pending);
    let output_control_replies = Arc::clone(&control_replies);
    let output_observed_sessions = Arc::clone(&observed_sessions);
    let output_active_turns = Arc::clone(&active_turns);
    let output_thread = thread::spawn(move || {
        let result = (|| -> io::Result<()> {
            let mut reader = BufReader::new(proxy_output);
            let mut line = Vec::new();
            let mut traced_outbound_frame = false;
            loop {
                line.clear();
                let read = reader.read_until(b'\n', &mut line)?;
                if read == 0 {
                    break;
                }
                if line.len() > max_bytes {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "app-server message exceeds maximum frame size",
                    ));
                }
                let parsed = serde_json::from_slice::<Value>(&line).ok();
                if !traced_outbound_frame {
                    trace_broker(&format!(
                        "first_outbound_frame source=raw bytes={} method={}",
                        line.len(),
                        frame_method(&line)
                    ));
                    traced_outbound_frame = true;
                }
                if let Some(value) = parsed.as_ref() {
                    if let Some(session_id) = extract_session_id(value) {
                        output_observed_sessions.lock().unwrap().insert(session_id);
                    }
                    observe_active_turn(value, &output_active_turns);
                    if deliver_thread_control_response(value, &line, &output_control_replies) {
                        continue;
                    }
                    if let Some(key) = server_request_key(value) {
                        output_pending.lock().unwrap().insert(key);
                    }
                    if let Some(key) = resolved_request_key(value) {
                        output_pending.lock().unwrap().remove(&key);
                    }
                }
                client_output.write_all(&line).map_err(|error| {
                    io::Error::new(
                        error.kind(),
                        format!("broker client output write failed: {error}"),
                    )
                })?;
                client_output.flush().map_err(|error| {
                    io::Error::new(
                        error.kind(),
                        format!("broker client output flush failed: {error}"),
                    )
                })?;

                if let Some(value) = parsed {
                    let session_id =
                        extract_session_id(&value).unwrap_or_else(|| "unknown".to_owned());
                    let kind = classify_message(&value);
                    let event = CoveEvent::new(
                        kind,
                        EventSource::LocalCli,
                        session_id,
                        Some(launch_id.clone()),
                        json!({
                            "message": value,
                            "decisionSocket": decision_path_text,
                        }),
                    );
                    let _ = send_event_one_way(&socket, &event, timeout, max_bytes);
                }
            }
            Ok(())
        })();
        let _ = worker_sender.send(RawBrokerWorkerResult::Output(result));
    });

    let outcome = loop {
        if let Some(status) = child.try_wait()? {
            trace_broker(&format!("child_exit status={status}"));
            break RawBrokerOutcome::Child(status);
        }
        match worker_receiver.try_recv() {
            Ok(result) => {
                trace_broker(&format!("raw_worker_exit kind={}", result.kind()));
                break RawBrokerOutcome::Worker(result);
            }
            Err(mpsc::TryRecvError::Empty) => {}
            Err(mpsc::TryRecvError::Disconnected) => break RawBrokerOutcome::WorkerChannelClosed,
        }
        thread::sleep(Duration::from_millis(10));
    };

    running.store(false, Ordering::Relaxed);
    match &outcome {
        RawBrokerOutcome::Child(_) => {
            terminate_remaining_process_group(child.id()).map_err(|error| {
                io::Error::new(
                    error.kind(),
                    format!("app-server descendant cleanup failed: {error}"),
                )
            })?;
            let _ = client.shutdown(Shutdown::Read);
        }
        RawBrokerOutcome::Worker(_) | RawBrokerOutcome::WorkerChannelClosed => {
            let _ = client.shutdown(Shutdown::Both);
            stop_child(&mut child);
        }
    }
    input_thread
        .join()
        .map_err(|_| io::Error::other("broker input thread panicked"))?;
    output_thread
        .join()
        .map_err(|_| io::Error::other("broker output thread panicked"))?;
    let _ = decision_thread.join();
    let _ = control_thread.join();

    match outcome {
        RawBrokerOutcome::Child(status) => Ok(status.code().unwrap_or(1)),
        RawBrokerOutcome::Worker(RawBrokerWorkerResult::Input(Ok(())))
        | RawBrokerOutcome::Worker(RawBrokerWorkerResult::Output(Ok(()))) => Ok(0),
        RawBrokerOutcome::Worker(RawBrokerWorkerResult::Input(Err(error)))
        | RawBrokerOutcome::Worker(RawBrokerWorkerResult::Output(Err(error)))
            if raw_client_disconnect(&error) =>
        {
            Ok(0)
        }
        RawBrokerOutcome::Worker(RawBrokerWorkerResult::Input(Err(error)))
        | RawBrokerOutcome::Worker(RawBrokerWorkerResult::Output(Err(error))) => Err(error),
        RawBrokerOutcome::WorkerChannelClosed => Err(io::Error::other(
            "broker proxy workers exited without reporting status",
        )),
    }
}

enum RawBrokerWorkerResult {
    Input(io::Result<()>),
    Output(io::Result<()>),
}

impl RawBrokerWorkerResult {
    fn kind(&self) -> &'static str {
        match self {
            Self::Input(Ok(())) => "input-eof",
            Self::Input(Err(_)) => "input-error",
            Self::Output(Ok(())) => "output-eof",
            Self::Output(Err(_)) => "output-error",
        }
    }
}

enum RawBrokerOutcome {
    Child(std::process::ExitStatus),
    Worker(RawBrokerWorkerResult),
    WorkerChannelClosed,
}

fn raw_client_disconnect(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::BrokenPipe
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::NotConnected
    )
}

fn run_websocket_broker_inner(
    client: &UnixStream,
    context: &BrokerRunContext<'_>,
    handshake_timeout: Duration,
) -> io::Result<i32> {
    let decision_listener = context.decision_listener;
    let decision_path = context.decision_path;
    let control_listener = context.control_listener;
    let launch_id = context.launch_id;
    let app_server = &context.app_server;
    let config = context.config;
    let observed_sessions = Arc::clone(&context.observed_sessions);
    let max_bytes = config.max_frame_bytes;
    let mut websocket = accept_rpc_websocket(client.try_clone()?, max_bytes, handshake_timeout)?;
    trace_broker("ws_accepted");
    websocket
        .get_mut()
        .set_read_timeout(Some(Duration::from_millis(25)))?;
    let (decision_sender, decision_receiver) = mpsc::channel::<Vec<u8>>();
    let (output_sender, output_receiver) = mpsc::channel::<Vec<u8>>();
    let pending = Arc::new(Mutex::new(HashSet::<String>::new()));
    let control_replies = Arc::new(Mutex::new(ThreadControlReplies::new()));
    let active_turns = Arc::new(Mutex::new(HashMap::<String, String>::new()));
    let socket = config.event_socket.clone();
    let timeout = Duration::from_millis(50);
    let launch_id_text = launch_id.to_owned();
    let decision_path_text = decision_path.display().to_string();
    let running = Arc::new(AtomicBool::new(true));
    let control_thread = spawn_thread_control_listener(
        control_listener.try_clone()?,
        ThreadControlListenerContext {
            launch_id: launch_id_text.clone(),
            observed_sessions: Arc::clone(&observed_sessions),
            active_turns: Arc::clone(&active_turns),
            replies: Arc::clone(&control_replies),
            running: Arc::clone(&running),
            app_server_sender: decision_sender.clone(),
            max_bytes,
        },
    )?;
    let decision_thread = spawn_decision_listener(
        decision_listener.try_clone()?,
        launch_id_text.clone(),
        Arc::clone(&pending),
        Arc::clone(&running),
        decision_sender,
        max_bytes,
    )?;

    let output_context = WebsocketOutputContext {
        pending: Arc::clone(&pending),
        control_replies: Arc::clone(&control_replies),
        observed_sessions: Arc::clone(&observed_sessions),
        active_turns: Arc::clone(&active_turns),
        output_sender: output_sender.clone(),
        event_socket: socket.clone(),
        launch_id: launch_id_text.clone(),
        decision_path: decision_path_text.clone(),
        timeout,
        max_bytes,
    };
    let mut runtime: Option<WebsocketRuntime> = None;

    let mut saw_protocol_activity = false;
    let mut inbound_frame_count = 0_u64;
    let mut outbound_frame_count = 0_u64;
    loop {
        while let Ok(frame) = decision_receiver.try_recv() {
            inbound_frame_count += 1;
            if inbound_frame_count <= 256 {
                trace_broker(&format!(
                    "inbound_frame sequence={inbound_frame_count} source=decision bytes={} method={}",
                    frame.len(),
                    frame_method(&frame)
                ));
            }
            let runtime = websocket_runtime(&mut runtime, app_server, output_context.clone())?;
            write_jsonl_to_app_server(&mut runtime.proxy_input, &frame)?;
            saw_protocol_activity = true;
        }
        while let Ok(line) = output_receiver.try_recv() {
            outbound_frame_count += 1;
            if outbound_frame_count <= 256 {
                trace_broker(&format!(
                    "outbound_frame sequence={outbound_frame_count} bytes={} method={}",
                    line.len(),
                    frame_method(&line)
                ));
            }
            websocket_send_jsonl(&mut websocket, line, max_bytes)?;
            saw_protocol_activity = true;
        }

        if runtime
            .as_ref()
            .is_some_and(|active| active.output_thread.is_finished())
        {
            let mut finished = runtime.take().expect("runtime is present");
            let output_result = join_websocket_output_thread(finished.output_thread);
            if output_result.is_ok() {
                while let Ok(line) = output_receiver.try_recv() {
                    if let Err(error) = websocket_send_jsonl(&mut websocket, line, max_bytes) {
                        stop_child(&mut finished.child);
                        running.store(false, Ordering::Relaxed);
                        let _ = decision_thread.join();
                        let _ = control_thread.join();
                        return Err(error);
                    }
                }

                let started = std::time::Instant::now();
                let grace = Duration::from_millis(250);
                loop {
                    if let Some(status) = finished.child.try_wait()? {
                        terminate_remaining_process_group(finished.child.id())?;
                        running.store(false, Ordering::Relaxed);
                        let _ = decision_thread.join();
                        let _ = control_thread.join();
                        let _ = close_websocket_ignoring_closed(&mut websocket, None);
                        return Ok(status.code().unwrap_or(1));
                    }
                    if started.elapsed() >= grace {
                        break;
                    }
                    thread::sleep(Duration::from_millis(5));
                }
            }

            stop_child(&mut finished.child);
            running.store(false, Ordering::Relaxed);
            let _ = decision_thread.join();
            let _ = control_thread.join();
            let _ = close_websocket_ignoring_closed(&mut websocket, None);
            return match output_result {
                Ok(()) => Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "app-server output closed while the client was connected",
                )),
                Err(error) => Err(error),
            };
        }

        if let Some(active) = runtime.as_mut() {
            if let Some(status) = active.child.try_wait().inspect_err(|error| {
                trace_broker(&format!("child_try_wait_error kind={:?}", error.kind()));
            })? {
                trace_broker(&format!(
                    "child_exit status={status} before_protocol_activity={}",
                    !saw_protocol_activity
                ));
                let finished = runtime.take().expect("runtime is present");
                terminate_remaining_process_group(finished.child.id())?;
                join_websocket_output_thread(finished.output_thread)?;
                while let Ok(line) = output_receiver.try_recv() {
                    websocket_send_jsonl(&mut websocket, line, max_bytes)?;
                }
                running.store(false, Ordering::Relaxed);
                let _ = decision_thread.join();
                let _ = control_thread.join();
                let _ = close_websocket_ignoring_closed(&mut websocket, None);
                return Ok(status.code().unwrap_or(1));
            }
        }

        match websocket.read() {
            Ok(message) => match message {
                Message::Text(text) => {
                    let bytes = text.as_bytes();
                    inbound_frame_count += 1;
                    if inbound_frame_count <= 256 {
                        trace_broker(&format!(
                            "inbound_frame sequence={inbound_frame_count} source=websocket bytes={} method={}",
                            bytes.len(),
                            frame_method(bytes)
                        ));
                    }
                    let runtime =
                        websocket_runtime(&mut runtime, app_server, output_context.clone())?;
                    write_websocket_client_message(
                        &mut runtime.proxy_input,
                        bytes,
                        &pending,
                        max_bytes,
                    )?;
                    saw_protocol_activity = true;
                }
                Message::Binary(bytes) => {
                    inbound_frame_count += 1;
                    if inbound_frame_count <= 256 {
                        trace_broker(&format!(
                            "inbound_frame sequence={inbound_frame_count} source=websocket bytes={} method={}",
                            bytes.len(),
                            frame_method(&bytes)
                        ));
                    }
                    let runtime =
                        websocket_runtime(&mut runtime, app_server, output_context.clone())?;
                    write_websocket_client_message(
                        &mut runtime.proxy_input,
                        &bytes,
                        &pending,
                        max_bytes,
                    )?;
                    saw_protocol_activity = true;
                }
                Message::Ping(payload) => {
                    websocket_send_message(&mut websocket, Message::Pong(payload), "pong")?
                }
                Message::Pong(_) => {}
                Message::Close(frame) => {
                    close_websocket_ignoring_closed(&mut websocket, frame)?;
                    if let Some(mut active) = runtime.take() {
                        stop_child(&mut active.child);
                        join_websocket_output_thread(active.output_thread)?;
                    }
                    running.store(false, Ordering::Relaxed);
                    let _ = decision_thread.join();
                    let _ = control_thread.join();
                    return Ok(0);
                }
                Message::Frame(_) => {}
            },
            Err(tungstenite::Error::Io(error))
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) => {}
            Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => {
                if let Some(mut active) = runtime.take() {
                    stop_child(&mut active.child);
                    join_websocket_output_thread(active.output_thread)?;
                }
                running.store(false, Ordering::Relaxed);
                let _ = decision_thread.join();
                let _ = control_thread.join();
                return Ok(0);
            }
            Err(error) => {
                if let Some(mut active) = runtime.take() {
                    stop_child(&mut active.child);
                }
                running.store(false, Ordering::Relaxed);
                let _ = decision_thread.join();
                let _ = control_thread.join();
                trace_broker(&format!(
                    "ws_error kind={:?}",
                    websocket_io_error_kind(&error)
                ));
                return Err(websocket_io_error(error));
            }
        }
    }
}

struct WebsocketRuntime {
    child: Child,
    proxy_input: ChildStdin,
    output_thread: thread::JoinHandle<io::Result<()>>,
}

fn websocket_runtime<'a>(
    runtime: &'a mut Option<WebsocketRuntime>,
    app_server: &AppServerCommand<'_>,
    output_context: WebsocketOutputContext,
) -> io::Result<&'a mut WebsocketRuntime> {
    if runtime.is_none() {
        let mut child = spawn_app_server(app_server.real_codex, app_server.mode)?;
        if let Err(error) = verify_child_started(&mut child) {
            stop_child(&mut child);
            return Err(error);
        }
        let Some(proxy_input) = child.stdin.take() else {
            stop_child(&mut child);
            return Err(io::Error::other("proxy stdin unavailable"));
        };
        let Some(proxy_output) = child.stdout.take() else {
            stop_child(&mut child);
            return Err(io::Error::other("proxy stdout unavailable"));
        };
        let output_thread = spawn_websocket_output_thread(proxy_output, output_context);
        *runtime = Some(WebsocketRuntime {
            child,
            proxy_input,
            output_thread,
        });
    }
    Ok(runtime.as_mut().expect("runtime was initialized"))
}

#[derive(Clone)]
struct WebsocketOutputContext {
    pending: Arc<Mutex<HashSet<String>>>,
    control_replies: Arc<Mutex<ThreadControlReplies>>,
    observed_sessions: Arc<Mutex<HashSet<String>>>,
    active_turns: Arc<Mutex<HashMap<String, String>>>,
    output_sender: mpsc::Sender<Vec<u8>>,
    event_socket: PathBuf,
    launch_id: String,
    decision_path: String,
    timeout: Duration,
    max_bytes: usize,
}

fn spawn_websocket_output_thread(
    proxy_output: impl Read + Send + 'static,
    context: WebsocketOutputContext,
) -> thread::JoinHandle<io::Result<()>> {
    thread::spawn(move || websocket_output_thread(proxy_output, context))
}

fn websocket_output_thread(
    proxy_output: impl Read,
    context: WebsocketOutputContext,
) -> io::Result<()> {
    let mut reader = BufReader::new(proxy_output);
    let mut line = Vec::new();
    loop {
        line.clear();
        let read = reader.read_until(b'\n', &mut line)?;
        if read == 0 {
            break;
        }
        if line.len() > context.max_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "app-server message exceeds maximum frame size",
            ));
        }
        if let Some(value) = parse_json_line(&line) {
            if let Some(session_id) = extract_session_id(&value) {
                context.observed_sessions.lock().unwrap().insert(session_id);
            }
            observe_active_turn(&value, &context.active_turns);
            if deliver_thread_control_response(&value, &line, &context.control_replies) {
                continue;
            }
            observe_server_message(
                &value,
                &context.pending,
                &context.event_socket,
                &context.launch_id,
                &context.decision_path,
                context.timeout,
                context.max_bytes,
            );
        }
        context
            .output_sender
            .send(line.clone())
            .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "websocket closed"))?;
    }
    Ok(())
}

fn join_websocket_output_thread(
    output_thread: thread::JoinHandle<io::Result<()>>,
) -> io::Result<()> {
    output_thread
        .join()
        .map_err(|_| io::Error::other("broker output thread panicked"))?
}

#[allow(clippy::result_large_err)]
fn accept_rpc_websocket(
    stream: UnixStream,
    max_bytes: usize,
    handshake_timeout: Duration,
) -> io::Result<WebSocket<UnixStream>> {
    stream.set_read_timeout(Some(handshake_timeout))?;
    stream.set_write_timeout(Some(handshake_timeout))?;
    let config = WebSocketConfig::default()
        .write_buffer_size(0)
        .max_write_buffer_size(max_bytes.saturating_mul(2).max(max_bytes.saturating_add(1)))
        .max_message_size(Some(max_bytes))
        .max_frame_size(Some(max_bytes));
    tungstenite::accept_hdr_with_config(
        stream,
        |request: &Request, response: Response| {
            if request.uri().path() == "/rpc" {
                Ok(response)
            } else {
                Err(tungstenite::handshake::server::ErrorResponse::new(Some(
                    "Codex Cove broker only accepts /rpc".to_owned(),
                )))
            }
        },
        Some(config),
    )
    .map_err(|error| match error {
        tungstenite::HandshakeError::Failure(tungstenite::Error::Io(error))
            if matches!(
                error.kind(),
                io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
            ) =>
        {
            io::Error::new(io::ErrorKind::TimedOut, "websocket handshake timed out")
        }
        tungstenite::HandshakeError::Failure(tungstenite::Error::Io(error)) => error,
        tungstenite::HandshakeError::Failure(tungstenite::Error::Protocol(
            tungstenite::error::ProtocolError::HandshakeIncomplete,
        )) => io::Error::new(io::ErrorKind::TimedOut, "websocket handshake timed out"),
        tungstenite::HandshakeError::Interrupted(_) => {
            io::Error::new(io::ErrorKind::TimedOut, "websocket handshake timed out")
        }
        other => io::Error::new(io::ErrorKind::InvalidData, other),
    })
}

fn websocket_send_jsonl(
    websocket: &mut WebSocket<UnixStream>,
    mut line: Vec<u8>,
    max_bytes: usize,
) -> io::Result<()> {
    if line.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "app-server message exceeds maximum frame size",
        ));
    }
    while matches!(line.last(), Some(b'\n' | b'\r')) {
        line.pop();
    }
    let text = String::from_utf8(line)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    websocket_send_message(websocket, Message::Text(text.into()), "outbound")
}

fn close_websocket_ignoring_closed(
    websocket: &mut WebSocket<UnixStream>,
    frame: Option<tungstenite::protocol::CloseFrame>,
) -> io::Result<()> {
    match websocket.close(frame) {
        Ok(()) => Ok(()),
        Err(tungstenite::Error::ConnectionClosed | tungstenite::Error::AlreadyClosed) => Ok(()),
        Err(error) if websocket_error_is_transient(&error) => {
            trace_broker(&format!(
                "ws_close_transient kind={:?}",
                websocket_io_error_kind(&error)
            ));
            retry_websocket_flush(websocket, "close")
        }
        Err(error) => {
            trace_broker(&format!(
                "ws_close_error kind={:?}",
                websocket_io_error_kind(&error)
            ));
            Err(websocket_io_error(error))
        }
    }
}

fn websocket_send_message(
    websocket: &mut WebSocket<UnixStream>,
    message: Message,
    context: &str,
) -> io::Result<()> {
    match websocket.send(message) {
        Ok(()) => Ok(()),
        Err(error) if websocket_error_is_transient(&error) => {
            trace_broker(&format!(
                "ws_send_transient context={context} kind={:?}",
                websocket_io_error_kind(&error)
            ));
            retry_websocket_flush(websocket, context)
        }
        Err(error) => {
            trace_broker(&format!(
                "ws_send_error context={context} kind={:?}",
                websocket_io_error_kind(&error)
            ));
            Err(websocket_io_error(error))
        }
    }
}

fn retry_websocket_flush(websocket: &mut WebSocket<UnixStream>, context: &str) -> io::Result<()> {
    let started = std::time::Instant::now();
    let deadline = Duration::from_secs(2);
    loop {
        match websocket.flush() {
            Ok(()) => return Ok(()),
            Err(error) if websocket_error_is_transient(&error) && started.elapsed() < deadline => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) if websocket_error_is_transient(&error) => {
                trace_broker(&format!(
                    "ws_flush_timeout context={context} kind={:?}",
                    websocket_io_error_kind(&error)
                ));
                return Err(io::Error::new(
                    io::ErrorKind::TimedOut,
                    format!("websocket {context} flush timed out"),
                ));
            }
            Err(error) => {
                trace_broker(&format!(
                    "ws_flush_error context={context} kind={:?}",
                    websocket_io_error_kind(&error)
                ));
                return Err(websocket_io_error(error));
            }
        }
    }
}

fn write_websocket_client_message(
    proxy_input: &mut impl Write,
    bytes: &[u8],
    pending: &Arc<Mutex<HashSet<String>>>,
    max_bytes: usize,
) -> io::Result<()> {
    if bytes.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "websocket message exceeds maximum frame size",
        ));
    }
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    reject_reserved_thread_control_id(&value)?;
    if let Some(key) = client_response_key(&value) {
        pending.lock().unwrap().remove(&key);
    }
    proxy_input.write_all(bytes)?;
    proxy_input.write_all(b"\n")?;
    proxy_input.flush()
}

fn write_jsonl_to_app_server(proxy_input: &mut impl Write, frame: &[u8]) -> io::Result<()> {
    proxy_input.write_all(frame)?;
    proxy_input.write_all(b"\n")?;
    proxy_input.flush()
}

fn forward_raw_client_bytes(
    buffered: &mut Vec<u8>,
    bytes: &[u8],
    proxy_input: &mut impl Write,
    pending: &Arc<Mutex<HashSet<String>>>,
    max_bytes: usize,
) -> io::Result<()> {
    if buffered.len().saturating_add(bytes.len()) > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "client message exceeds maximum frame size",
        ));
    }
    buffered.extend_from_slice(bytes);
    while let Some(newline) = buffered.iter().position(|byte| *byte == b'\n') {
        let line = buffered.drain(..=newline).collect::<Vec<_>>();
        forward_complete_raw_client_frame(&line, proxy_input, pending, max_bytes)?;
    }
    Ok(())
}

fn forward_complete_raw_client_frame(
    line: &[u8],
    proxy_input: &mut impl Write,
    pending: &Arc<Mutex<HashSet<String>>>,
    max_bytes: usize,
) -> io::Result<()> {
    if line.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "client message exceeds maximum frame size",
        ));
    }
    if let Ok(value) = serde_json::from_slice::<Value>(line) {
        reject_reserved_thread_control_id(&value)?;
        if let Some(key) = client_response_key(&value) {
            pending.lock().unwrap().remove(&key);
        }
    }
    proxy_input.write_all(line)?;
    proxy_input.flush()
}

fn reject_reserved_thread_control_id(value: &Value) -> io::Result<()> {
    if value.get("method").is_some()
        && value
            .get("id")
            .and_then(Value::as_str)
            .is_some_and(|id| id.starts_with("cove-thread-control:"))
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "client request uses Cove's reserved control ID namespace",
        ));
    }
    Ok(())
}

#[cfg(test)]
fn observe_client_frames(
    buffered: &mut Vec<u8>,
    bytes: &[u8],
    pending: &Arc<Mutex<HashSet<String>>>,
    max_bytes: usize,
) {
    if buffered.len().saturating_add(bytes.len()) > max_bytes {
        buffered.clear();
        return;
    }
    buffered.extend_from_slice(bytes);
    while let Some(newline) = buffered.iter().position(|byte| *byte == b'\n') {
        let line = buffered.drain(..=newline).collect::<Vec<_>>();
        let Ok(value) = serde_json::from_slice::<Value>(&line) else {
            continue;
        };
        if let Some(key) = client_response_key(&value) {
            pending.lock().unwrap().remove(&key);
        }
    }
}

fn parse_json_line(line: &[u8]) -> Option<Value> {
    serde_json::from_slice::<Value>(line).ok()
}

fn observe_server_message(
    value: &Value,
    pending: &Arc<Mutex<HashSet<String>>>,
    event_socket: &Path,
    launch_id: &str,
    decision_path_text: &str,
    timeout: Duration,
    max_bytes: usize,
) {
    if let Some(key) = server_request_key(value) {
        pending.lock().unwrap().insert(key);
    }
    if let Some(key) = resolved_request_key(value) {
        pending.lock().unwrap().remove(&key);
    }
    let session_id = extract_session_id(value).unwrap_or_else(|| "unknown".to_owned());
    let kind = classify_message(value);
    let event = CoveEvent::new(
        kind,
        EventSource::LocalCli,
        session_id,
        Some(launch_id.to_owned()),
        json!({
            "message": value,
            "decisionSocket": decision_path_text,
        }),
    );
    let _ = send_event_one_way(event_socket, &event, timeout, max_bytes);
}

fn client_response_key(value: &Value) -> Option<String> {
    if value.get("method").is_some() {
        return None;
    }
    let has_result = value.get("result").is_some();
    let has_error = value.get("error").is_some();
    if has_result == has_error {
        return None;
    }
    value.get("id").and_then(value_key)
}

pub fn broker_socket(runtime_directory: &Path, launch_id: &str) -> PathBuf {
    runtime_directory.join(format!("{}.b", socket_token(launch_id)))
}

pub fn decision_socket(runtime_directory: &Path, launch_id: &str) -> PathBuf {
    runtime_directory.join(format!("{}.d", socket_token(launch_id)))
}

fn socket_token(launch_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(launch_id.as_bytes());
    let digest = hasher.finalize();
    digest[..8]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect::<String>()
}

fn websocket_io_error(error: tungstenite::Error) -> io::Error {
    match error {
        tungstenite::Error::Io(error) => error,
        other => io::Error::new(io::ErrorKind::InvalidData, other),
    }
}

fn websocket_io_error_kind(error: &tungstenite::Error) -> io::ErrorKind {
    match error {
        tungstenite::Error::Io(error) => error.kind(),
        _ => io::ErrorKind::InvalidData,
    }
}

fn websocket_error_is_transient(error: &tungstenite::Error) -> bool {
    matches!(
        websocket_io_error_kind(error),
        io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut | io::ErrorKind::Interrupted
    )
}

fn frame_method(bytes: &[u8]) -> String {
    let Ok(value) = serde_json::from_slice::<Value>(bytes) else {
        return "invalid-json".to_owned();
    };
    value
        .get("method")
        .and_then(Value::as_str)
        .unwrap_or("response")
        .to_owned()
}

fn trace_broker_enabled() -> bool {
    env::var("CODEX_COVE_TRACE_BROKER")
        .ok()
        .is_some_and(|value| matches!(value.as_str(), "1" | "true" | "TRUE" | "yes" | "on"))
}

fn trace_broker(message: &str) {
    if trace_broker_enabled() {
        eprintln!("codex-cove-trace: {message}");
    }
}

pub fn wait_for_socket(path: &Path, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if path.exists() {
            return true;
        }
        thread::sleep(Duration::from_millis(20));
    }
    false
}

pub fn extract_session_id(value: &Value) -> Option<String> {
    for pointer in [
        "/params/threadId",
        "/params/thread/id",
        "/result/thread/id",
        "/threadId",
        "/sessionId",
    ] {
        if let Some(id) = value.pointer(pointer).and_then(Value::as_str) {
            return Some(id.to_owned());
        }
    }
    None
}

pub fn classify_message(value: &Value) -> &'static str {
    match value.get("method").and_then(Value::as_str) {
        Some(
            "item/commandExecution/requestApproval"
            | "item/fileChange/requestApproval"
            | "item/permissions/requestApproval"
            | "item/tool/requestApproval"
            | "execCommandApproval"
            | "applyPatchApproval",
        ) => "approvalRequested",
        Some("item/tool/requestUserInput" | "requestUserInput") => "questionRequested",
        Some("serverRequest/resolved") => "serverRequestResolved",
        _ => "appServer",
    }
}

pub fn validate_decision_frame(
    value: &Value,
    launch_id: &str,
    pending: &HashSet<String>,
) -> io::Result<Vec<u8>> {
    if value.get("schemaVersion").and_then(Value::as_u64) != Some(1)
        || value.get("launchId").and_then(Value::as_str) != Some(launch_id)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "decision frame version or launch ID mismatch",
        ));
    }
    let id = value.get("requestId").ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "decision frame missing requestId",
        )
    })?;
    let key = value_key(id)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid decision id"))?;
    if !pending.contains(&key) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "decision does not match pending request",
        ));
    }
    let has_result = value.get("result").is_some();
    let has_error = value.get("error").is_some();
    if has_result == has_error {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "decision requires exactly one of result or error",
        ));
    }
    let mut response = serde_json::Map::new();
    response.insert("jsonrpc".to_owned(), Value::String("2.0".to_owned()));
    response.insert("id".to_owned(), id.clone());
    if let Some(result) = value.get("result") {
        response.insert("result".to_owned(), result.clone());
    }
    if let Some(error) = value.get("error") {
        response.insert("error".to_owned(), error.clone());
    }
    serde_json::to_vec(&Value::Object(response))
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn spawn_decision_listener(
    listener: UnixListener,
    launch_id: String,
    pending: Arc<Mutex<HashSet<String>>>,
    running: Arc<AtomicBool>,
    sender: mpsc::Sender<Vec<u8>>,
    max_bytes: usize,
) -> io::Result<thread::JoinHandle<()>> {
    listener.set_nonblocking(true)?;
    Ok(thread::spawn(move || {
        while running.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let _ =
                        handle_decision_stream(stream, &launch_id, &pending, &sender, max_bytes);
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(20));
                }
                Err(_) => break,
            }
        }
    }))
}

type ThreadControlReplies = HashMap<String, mpsc::Sender<Vec<u8>>>;

struct ThreadControlListenerContext {
    launch_id: String,
    observed_sessions: Arc<Mutex<HashSet<String>>>,
    active_turns: Arc<Mutex<HashMap<String, String>>>,
    replies: Arc<Mutex<ThreadControlReplies>>,
    running: Arc<AtomicBool>,
    app_server_sender: mpsc::Sender<Vec<u8>>,
    max_bytes: usize,
}

fn spawn_thread_control_listener(
    listener: UnixListener,
    context: ThreadControlListenerContext,
) -> io::Result<thread::JoinHandle<()>> {
    listener.set_nonblocking(true)?;
    Ok(thread::spawn(move || {
        let ThreadControlListenerContext {
            launch_id,
            observed_sessions,
            active_turns,
            replies,
            running,
            app_server_sender,
            max_bytes,
        } = context;
        while running.load(Ordering::Relaxed) {
            match listener.accept() {
                Ok((stream, _)) => {
                    let _ = handle_thread_control_stream(
                        stream,
                        &launch_id,
                        &observed_sessions,
                        &active_turns,
                        &replies,
                        &app_server_sender,
                        max_bytes,
                    );
                }
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                    thread::sleep(Duration::from_millis(20));
                }
                Err(_) => break,
            }
        }
    }))
}

fn handle_thread_control_stream(
    stream: UnixStream,
    launch_id: &str,
    observed_sessions: &Arc<Mutex<HashSet<String>>>,
    active_turns: &Arc<Mutex<HashMap<String, String>>>,
    replies: &Arc<Mutex<ThreadControlReplies>>,
    app_server_sender: &mpsc::Sender<Vec<u8>>,
    max_bytes: usize,
) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(500)))?;
    stream.set_write_timeout(Some(Duration::from_millis(500)))?;
    let mut reader = BufReader::new(stream);
    let Some(line) = read_limited_line(&mut reader, max_bytes)? else {
        return Ok(());
    };
    let value: Value = serde_json::from_slice(&line)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let (response_id, request) = match validate_thread_control_frame(
        &value,
        launch_id,
        &observed_sessions.lock().unwrap(),
        &active_turns.lock().unwrap(),
    ) {
        Ok(validated) => validated,
        Err(error) => {
            let Some(control_id) = value
                .get("clientMessageId")
                .and_then(Value::as_str)
                .filter(|value| valid_control_id(value))
            else {
                return Err(error);
            };
            let acknowledgement = serde_json::to_vec(&json!({
                "schemaVersion": 1,
                "type": "threadControlAck",
                "controlId": control_id,
                "status": "rejected",
                "rejection": thread_control_rejection(&error),
            }))
            .map_err(|encode_error| io::Error::new(io::ErrorKind::InvalidData, encode_error))?;
            reader.get_mut().write_all(&acknowledgement)?;
            reader.get_mut().write_all(b"\n")?;
            reader.get_mut().flush()?;
            return Ok(());
        }
    };
    let (reply_sender, reply_receiver) = mpsc::channel();
    {
        let mut pending = replies.lock().unwrap();
        if pending.len() >= 32 || pending.contains_key(&response_id) {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "thread control is already pending",
            ));
        }
        pending.insert(response_id.clone(), reply_sender);
    }
    if app_server_sender.send(request).is_err() {
        replies.lock().unwrap().remove(&response_id);
        return Err(io::Error::new(
            io::ErrorKind::BrokenPipe,
            "broker input closed",
        ));
    }
    let response = match reply_receiver.recv_timeout(Duration::from_secs(3)) {
        Ok(response) => response,
        Err(mpsc::RecvTimeoutError::Timeout) => {
            replies.lock().unwrap().remove(&response_id);
            serde_json::to_vec(&json!({
                "schemaVersion": 1,
                "type": "threadControlAck",
                "controlId": value["clientMessageId"],
                "status": "uncertain",
            }))
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
        }
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            replies.lock().unwrap().remove(&response_id);
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "control response closed",
            ));
        }
    };
    reader.get_mut().write_all(&response)?;
    if !response.ends_with(b"\n") {
        reader.get_mut().write_all(b"\n")?;
    }
    reader.get_mut().flush()
}

fn validate_thread_control_frame(
    value: &Value,
    launch_id: &str,
    observed_sessions: &HashSet<String>,
    active_turns: &HashMap<String, String>,
) -> io::Result<(String, Vec<u8>)> {
    if value.get("schemaVersion").and_then(Value::as_u64) != Some(1)
        || value.get("launchId").and_then(Value::as_str) != Some(launch_id)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "thread control version or launch ID mismatch",
        ));
    }
    let control_id = value
        .get("clientMessageId")
        .and_then(Value::as_str)
        .filter(|id| valid_control_id(id))
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid control ID"))?;
    let target = value
        .get("target")
        .and_then(Value::as_object)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing control target"))?;
    let session_id = target
        .get("sessionId")
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty() && id.len() <= 512)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid target session"))?;
    if !matches!(
        target.get("source").and_then(Value::as_str),
        Some("localCli" | "remoteCli")
    ) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "thread control target origin is invalid",
        ));
    }
    if !observed_sessions.contains(session_id) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "thread control target was not observed by this broker",
        ));
    }
    let input = value
        .get("input")
        .and_then(Value::as_str)
        .filter(|text| !text.trim().is_empty() && text.len() <= 32 * 1_024)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "invalid control input"))?;
    let operation = value
        .get("operation")
        .and_then(Value::as_str)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing control operation"))?;
    let method = match operation {
        "start" => "turn/start",
        "steer" => "turn/steer",
        _ => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported control operation",
            ));
        }
    };
    let mut params = serde_json::Map::new();
    params.insert("threadId".to_owned(), Value::String(session_id.to_owned()));
    params.insert(
        "clientUserMessageId".to_owned(),
        Value::String(control_id.to_owned()),
    );
    params.insert("input".to_owned(), json!([{"type":"text", "text": input}]));
    if operation == "start" && active_turns.contains_key(session_id) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "thread state changed before start",
        ));
    }
    if operation == "steer" {
        let expected = value
            .get("expectedTurnId")
            .and_then(Value::as_str)
            .filter(|id| !id.is_empty() && id.len() <= 512)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "missing expected turn"))?;
        if active_turns.get(session_id).map(String::as_str) != Some(expected) {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "thread state changed before steer",
            ));
        }
        params.insert(
            "expectedTurnId".to_owned(),
            Value::String(expected.to_owned()),
        );
    }
    let response_id = format!("cove-thread-control:{control_id}");
    let request = serde_json::to_vec(&json!({
        "jsonrpc": "2.0",
        "id": response_id,
        "method": method,
        "params": params,
    }))
    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    Ok((response_id, request))
}

fn thread_control_rejection(error: &io::Error) -> &'static str {
    let message = error.to_string();
    if message.contains("state changed") {
        "turnMismatch"
    } else if message.contains("origin") {
        "wrongOrigin"
    } else if message.contains("not observed") || message.contains("launch ID mismatch") {
        "staleRoute"
    } else if message.contains("unsupported") {
        "unsupported"
    } else {
        "invalidInput"
    }
}

fn valid_control_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value
            .bytes()
            .all(|byte| matches!(byte, b'-' | b'_' | b'0'..=b'9' | b'A'..=b'Z' | b'a'..=b'z'))
}

fn observe_active_turn(value: &Value, active_turns: &Arc<Mutex<HashMap<String, String>>>) {
    let Some(session_id) = extract_session_id(value) else {
        return;
    };
    let method = value.get("method").and_then(Value::as_str).unwrap_or("");
    if method == "turn/started" {
        if let Some(turn_id) = value
            .pointer("/params/turn/id")
            .or_else(|| value.pointer("/params/turnId"))
            .and_then(Value::as_str)
        {
            active_turns
                .lock()
                .unwrap()
                .insert(session_id, turn_id.to_owned());
        }
    } else if matches!(
        method,
        "turn/completed" | "turn/aborted" | "turn/interrupted" | "turn/failed"
    ) || (method == "thread/status/changed"
        && (value.pointer("/params/status/type").and_then(Value::as_str) == Some("idle")
            || value.pointer("/params/status").and_then(Value::as_str) == Some("idle")))
    {
        active_turns.lock().unwrap().remove(&session_id);
    }
}

fn deliver_thread_control_response(
    value: &Value,
    line: &[u8],
    replies: &Arc<Mutex<ThreadControlReplies>>,
) -> bool {
    let Some(id) = value.get("id").and_then(Value::as_str) else {
        return false;
    };
    if !id.starts_with("cove-thread-control:") {
        return false;
    }
    if let Some(sender) = replies.lock().unwrap().remove(id) {
        let _ = sender.send(line.to_vec());
    }
    true
}

fn handle_decision_stream(
    stream: UnixStream,
    launch_id: &str,
    pending: &Arc<Mutex<HashSet<String>>>,
    sender: &mpsc::Sender<Vec<u8>>,
    max_bytes: usize,
) -> io::Result<()> {
    stream.set_read_timeout(Some(Duration::from_millis(500)))?;
    let mut reader = BufReader::new(stream);
    let Some(line) = read_limited_line(&mut reader, max_bytes)? else {
        return Ok(());
    };
    let value: Value = serde_json::from_slice(&line)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let mut pending = pending.lock().unwrap();
    let response = validate_decision_frame(&value, launch_id, &pending)?;
    let key = value_key(&value["requestId"]).unwrap();
    pending.remove(&key);
    sender
        .send(response)
        .map_err(|_| io::Error::new(io::ErrorKind::BrokenPipe, "broker input closed"))
}

fn server_request_key(value: &Value) -> Option<String> {
    value.get("method")?;
    value.get("id").and_then(value_key)
}

fn resolved_request_key(value: &Value) -> Option<String> {
    if value.get("method").and_then(Value::as_str) != Some("serverRequest/resolved") {
        return None;
    }
    value
        .pointer("/params/requestId")
        .or_else(|| value.pointer("/params/id"))
        .and_then(value_key)
}

fn value_key(value: &Value) -> Option<String> {
    match value {
        Value::String(value) => Some(format!("s:{value}")),
        Value::Number(value) => Some(format!("n:{value}")),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::Config;
    use crate::ipc::bind_private_listener;
    use serde_json::json;
    use std::collections::HashSet;
    use std::fs;
    use std::io::{BufRead, BufReader, Write};
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixStream;
    use std::thread;
    use std::time::Duration;
    use tempfile::{TempDir, tempdir, tempdir_in};

    fn short_tempdir() -> TempDir {
        tempdir_in("/tmp").unwrap()
    }

    fn fd_is_nonblocking(stream: &UnixStream) -> bool {
        let flags = unsafe { libc::fcntl(stream.as_raw_fd(), libc::F_GETFL) };
        assert!(flags >= 0, "fcntl(F_GETFL) failed");
        flags & libc::O_NONBLOCK != 0
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
        panic!("process {pid} remained after broker cleanup");
    }

    #[test]
    fn extracts_known_session_id_locations() {
        assert_eq!(
            extract_session_id(&json!({"params":{"threadId":"t1"}})).as_deref(),
            Some("t1")
        );
        assert_eq!(
            extract_session_id(&json!({"result":{"thread":{"id":"t2"}}})).as_deref(),
            Some("t2")
        );
        assert_eq!(extract_session_id(&json!({"method":"initialized"})), None);
    }

    #[test]
    fn classifies_interactive_requests() {
        assert_eq!(
            classify_message(&json!({"method":"item/commandExecution/requestApproval"})),
            "approvalRequested"
        );
        assert_eq!(
            classify_message(&json!({"method":"item/tool/requestUserInput"})),
            "questionRequested"
        );
        assert_eq!(
            classify_message(&json!({"method":"turn/started"})),
            "appServer"
        );
    }

    #[test]
    fn decision_frame_encodes_exact_json_rpc_response() {
        let pending = HashSet::from(["n:42".to_owned()]);
        let encoded = validate_decision_frame(
            &json!({
                "schemaVersion": 1,
                "launchId": "launch-1",
                "requestId": 42,
                "result": {"decision": "accept"}
            }),
            "launch-1",
            &pending,
        )
        .unwrap();
        let response: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(
            response,
            json!({"jsonrpc":"2.0","id":42,"result":{"decision":"accept"}})
        );
    }

    #[test]
    fn shared_decision_fixture_encodes_json_rpc_response() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../Fixtures/decision-frame.v1.json")).unwrap();
        let pending = HashSet::from(["n:42".to_owned()]);
        let encoded = validate_decision_frame(&fixture, "launch-fixture", &pending).unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&encoded).unwrap(),
            json!({"jsonrpc":"2.0","id":42,"result":{"decision":"accept"}})
        );
    }

    #[test]
    fn decision_frame_rejects_wrong_launch_and_non_pending_id() {
        let pending = HashSet::from(["s:req-1".to_owned()]);
        assert!(
            validate_decision_frame(
                &json!({
                    "schemaVersion":1,
                    "launchId":"other",
                    "requestId":"req-1",
                    "result":{}
                }),
                "launch-1",
                &pending
            )
            .is_err()
        );
    }

    #[test]
    fn thread_control_allowlist_builds_only_start_and_exact_steer() {
        let observed = HashSet::from(["thread-1".to_owned()]);
        let no_active_turns = HashMap::new();
        let start = json!({
            "schemaVersion": 1,
            "launchId": "launch-1",
            "target": {"source": "localCli", "sessionId": "thread-1"},
            "operation": "start",
            "clientMessageId": "message-1",
            "input": "Continue"
        });
        let (response_id, encoded) =
            validate_thread_control_frame(&start, "launch-1", &observed, &no_active_turns).unwrap();
        let request: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(response_id, "cove-thread-control:message-1");
        assert_eq!(request["method"], "turn/start");
        assert_eq!(request["params"]["threadId"], "thread-1");
        assert_eq!(request["params"]["input"][0]["text"], "Continue");

        let steer = json!({
            "schemaVersion": 1,
            "launchId": "launch-1",
            "target": {"source": "remoteCli", "sessionId": "thread-1"},
            "operation": "steer",
            "expectedTurnId": "turn-9",
            "clientMessageId": "message-2",
            "input": "Change direction"
        });
        let active_turns = HashMap::from([("thread-1".to_owned(), "turn-9".to_owned())]);
        let (_, encoded) =
            validate_thread_control_frame(&steer, "launch-1", &observed, &active_turns).unwrap();
        let request: Value = serde_json::from_slice(&encoded).unwrap();
        assert_eq!(request["method"], "turn/steer");
        assert_eq!(request["params"]["expectedTurnId"], "turn-9");
    }

    #[test]
    fn thread_control_rejects_stale_wrong_origin_and_missing_turn() {
        let observed = HashSet::from(["thread-1".to_owned()]);
        let active_turns = HashMap::new();
        let base = json!({
            "schemaVersion": 1,
            "launchId": "launch-1",
            "target": {"source": "localCli", "sessionId": "thread-1"},
            "operation": "steer",
            "clientMessageId": "message-1",
            "input": "Continue"
        });
        assert!(
            validate_thread_control_frame(&base, "launch-1", &observed, &active_turns).is_err()
        );
        let mut wrong_origin = base.clone();
        wrong_origin["operation"] = json!("start");
        wrong_origin["target"]["source"] = json!("codexDesktop");
        assert!(
            validate_thread_control_frame(&wrong_origin, "launch-1", &observed, &active_turns)
                .is_err()
        );
        let mut stale = wrong_origin;
        stale["target"]["source"] = json!("localCli");
        stale["target"]["sessionId"] = json!("unobserved");
        assert!(
            validate_thread_control_frame(&stale, "launch-1", &observed, &active_turns).is_err()
        );
        assert!(
            validate_thread_control_frame(&stale, "other-launch", &observed, &active_turns)
                .is_err()
        );
    }

    #[test]
    fn thread_control_rejects_state_changes_before_delivery() {
        let observed = HashSet::from(["thread-1".to_owned()]);
        let active_turns = HashMap::from([("thread-1".to_owned(), "turn-2".to_owned())]);
        let mut request = json!({
            "schemaVersion": 1,
            "launchId": "launch-1",
            "target": {"source": "localCli", "sessionId": "thread-1"},
            "operation": "start",
            "clientMessageId": "message-1",
            "input": "Continue"
        });
        assert!(
            validate_thread_control_frame(&request, "launch-1", &observed, &active_turns).is_err()
        );

        request["operation"] = json!("steer");
        request["expectedTurnId"] = json!("turn-1");
        assert!(
            validate_thread_control_frame(&request, "launch-1", &observed, &active_turns).is_err()
        );

        request["expectedTurnId"] = json!("turn-2");
        assert!(
            validate_thread_control_frame(&request, "launch-1", &observed, &active_turns).is_ok()
        );

        let no_active_turns = HashMap::new();
        assert!(
            validate_thread_control_frame(&request, "launch-1", &observed, &no_active_turns)
                .is_err()
        );
    }

    #[test]
    fn active_turn_observation_tracks_started_and_terminal_events() {
        let active_turns = Arc::new(Mutex::new(HashMap::new()));
        observe_active_turn(
            &json!({
                "method": "turn/started",
                "params": {
                    "threadId": "thread-1",
                    "turn": {"id": "turn-1"}
                }
            }),
            &active_turns,
        );
        assert_eq!(
            active_turns.lock().unwrap().get("thread-1"),
            Some(&"turn-1".to_owned())
        );

        observe_active_turn(
            &json!({
                "method": "turn/completed",
                "params": {"threadId": "thread-1", "turn": {"id": "turn-1"}}
            }),
            &active_turns,
        );
        assert!(!active_turns.lock().unwrap().contains_key("thread-1"));
    }

    #[test]
    fn reserved_thread_control_response_is_intercepted_once() {
        let replies = Arc::new(Mutex::new(ThreadControlReplies::new()));
        let (sender, receiver) = mpsc::channel();
        replies
            .lock()
            .unwrap()
            .insert("cove-thread-control:message-1".to_owned(), sender);
        let value = json!({
            "jsonrpc": "2.0",
            "id": "cove-thread-control:message-1",
            "result": {"turn": {"id": "turn-1"}}
        });
        let line = serde_json::to_vec(&value).unwrap();
        assert!(deliver_thread_control_response(&value, &line, &replies));
        assert_eq!(receiver.recv().unwrap(), line);
        assert!(deliver_thread_control_response(
            &value, b"ignored", &replies
        ));
        assert!(replies.lock().unwrap().is_empty());
    }

    #[test]
    fn client_cannot_claim_reserved_thread_control_ids() {
        assert!(
            reject_reserved_thread_control_id(&json!({
                "id": "cove-thread-control:message-1",
                "method": "turn/start",
                "params": {}
            }))
            .is_err()
        );
        assert!(
            reject_reserved_thread_control_id(&json!({
                "id": "ordinary-client-id",
                "method": "turn/start",
                "params": {}
            }))
            .is_ok()
        );
    }

    #[test]
    fn broker_close_event_separates_liveness_from_failure_status() {
        let temp = short_tempdir();
        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("events.sock");
        let listener = bind_private_listener(&config.event_socket).unwrap();
        let receiver = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream).read_line(&mut line).unwrap();
            serde_json::from_str::<CoveEvent>(&line).unwrap()
        });
        publish_closed_sessions(
            &config,
            "launch-1",
            &HashSet::from(["thread-1".to_owned()]),
            false,
        );
        let event = receiver.join().unwrap();
        assert_eq!(event.kind, "session_snapshot");
        assert_eq!(event.session_id, "thread-1");
        assert_eq!(event.payload["status"], "failed");
        assert_eq!(event.payload["liveness"], "closed");
        assert_eq!(event.payload["unread"], true);
    }

    #[test]
    fn native_client_response_retires_only_its_exact_pending_request() {
        let pending = Arc::new(Mutex::new(HashSet::from([
            "n:42".to_owned(),
            "s:42".to_owned(),
        ])));
        let mut buffered = Vec::new();
        observe_client_frames(
            &mut buffered,
            br#"{"id":42,"result":{"answers":{}}}
"#,
            &pending,
            1_024,
        );
        let pending = pending.lock().unwrap();
        assert!(!pending.contains("n:42"));
        assert!(pending.contains("s:42"));
    }

    #[test]
    fn client_request_or_malformed_response_does_not_retire_pending_request() {
        let pending = Arc::new(Mutex::new(HashSet::from(["n:7".to_owned()])));
        let mut buffered = Vec::new();
        observe_client_frames(
            &mut buffered,
            br#"{"id":7,"method":"thread/start","params":{}}
{"id":7,"result":{},"error":{}}
"#,
            &pending,
            1_024,
        );
        assert!(pending.lock().unwrap().contains("n:7"));
    }

    #[test]
    fn websocket_client_response_retires_only_its_exact_pending_request() {
        let pending = Arc::new(Mutex::new(HashSet::from([
            "n:42".to_owned(),
            "s:42".to_owned(),
        ])));
        let mut app_server_input = Vec::new();
        write_websocket_client_message(
            &mut app_server_input,
            br#"{"jsonrpc":"2.0","id":"42","result":{"answers":{}}}"#,
            &pending,
            1_024,
        )
        .unwrap();
        assert_eq!(
            serde_json::from_slice::<Value>(&app_server_input[..app_server_input.len() - 1])
                .unwrap()["id"],
            "42"
        );
        let pending = pending.lock().unwrap();
        assert!(pending.contains("n:42"));
        assert!(!pending.contains("s:42"));
    }

    #[test]
    fn broker_modes_are_explicit_and_closed() {
        assert_eq!(AppServerMode::parse("proxy").unwrap(), AppServerMode::Proxy);
        assert_eq!(
            AppServerMode::parse("direct-stdio").unwrap(),
            AppServerMode::DirectStdio
        );
        assert!(AppServerMode::parse("auto").is_err());
        assert!(AppServerMode::parse("").is_err());
    }

    #[test]
    fn direct_stdio_probe_requires_advertised_public_transport() {
        let temp = short_tempdir();
        let supported = temp.path().join("supported-codex");
        fs::write(
            &supported,
            b"#!/bin/sh\nprintf '%s\\n' 'Options: --stdio --listen stdio://'\n",
        )
        .unwrap();
        fs::set_permissions(&supported, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            probe_direct_stdio(&supported, Duration::from_secs(5)).available,
            "advertised stdio transport should be accepted"
        );

        let unsupported = temp.path().join("unsupported-codex");
        fs::write(&unsupported, b"#!/bin/sh\nprintf '%s\\n' 'no transport'\n").unwrap();
        fs::set_permissions(&unsupported, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(
            !probe_direct_stdio(&unsupported, Duration::from_secs(5)).available,
            "successful help without stdio must not be treated as compatible"
        );
    }

    #[test]
    fn direct_stdio_probe_drains_large_help_output_without_deadlock() {
        let temp = short_tempdir();
        let supported = temp.path().join("large-help-codex");
        fs::write(
            &supported,
            b"#!/bin/sh\ni=0\nwhile [ \"$i\" -lt 8192 ]; do printf '%s\\n' 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'; i=$((i + 1)); done\nprintf '%s\\n' 'Options: --stdio --listen stdio://'\n",
        )
        .unwrap();
        fs::set_permissions(&supported, fs::Permissions::from_mode(0o755)).unwrap();

        let probe = probe_direct_stdio(&supported, Duration::from_secs(5));

        assert!(
            probe.available,
            "large advertised help output should be accepted: {probe:?}"
        );
    }

    #[test]
    fn transparent_proxy_observes_request_and_injects_decision() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        fs::write(
            &fake_codex,
            b"#!/bin/sh\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"item/tool/requestUserInput\",\"params\":{\"threadId\":\"t1\"}}'\nIFS= read -r response\nprintf '%s\\n' \"$response\"\n",
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("events.sock");
        config.runtime_directory = temp.path().join("run");
        let event_listener = bind_private_listener(&config.event_socket).unwrap();
        let observed = thread::spawn(move || {
            let (stream, _) = event_listener.accept().unwrap();
            let mut line = String::new();
            BufReader::new(stream).read_line(&mut line).unwrap();
            let value: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(value["kind"], "questionRequested");
            assert_eq!(value["sessionId"], "t1");
        });

        let listen = broker_socket(&config.runtime_directory, "launch-1");
        let decision = decision_socket(&config.runtime_directory, "launch-1");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-1",
                &fake_codex,
                &broker_config,
                AppServerMode::Proxy,
            )
            .unwrap()
        });
        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        assert_eq!(
            fs::metadata(&decision).unwrap().permissions().mode() & 0o777,
            0o600
        );

        let client = UnixStream::connect(&listen).unwrap();
        let mut reader = BufReader::new(client);
        let mut request = String::new();
        reader.read_line(&mut request).unwrap();
        assert!(request.contains("requestUserInput"));

        let mut decision_client = UnixStream::connect(&decision).unwrap();
        decision_client
            .write_all(
                b"{\"schemaVersion\":1,\"launchId\":\"launch-1\",\"requestId\":7,\"result\":{\"answers\":{}}}\n",
            )
            .unwrap();
        let mut echoed = String::new();
        reader.read_line(&mut echoed).unwrap();
        assert_eq!(
            serde_json::from_str::<Value>(&echoed).unwrap(),
            json!({"jsonrpc":"2.0","id":7,"result":{"answers":{}}})
        );
        drop(reader);
        observed.join().unwrap();
        assert_eq!(broker.join().unwrap(), 0);
    }

    #[test]
    fn websocket_proxy_over_unix_socket_preserves_typed_pending_ids() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        fs::write(
            &fake_codex,
            b"#!/bin/sh\nIFS= read -r bootstrap || exit 20\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"item/tool/requestUserInput\",\"params\":{\"threadId\":\"t1\"}}'\nprintf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":\"7\",\"method\":\"item/tool/requestUserInput\",\"params\":{\"threadId\":\"t1\"}}'\nIFS= read -r first\nprintf '%s\\n' \"$first\"\nIFS= read -r second\nprintf '%s\\n' \"$second\"\n",
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        let listen = broker_socket(&config.runtime_directory, "launch-ws");
        let decision = decision_socket(&config.runtime_directory, "launch-ws");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-ws",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
            .unwrap()
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        let stream = UnixStream::connect(&listen).unwrap();
        let (mut websocket, _) = tungstenite::client("ws://localhost/rpc", stream).unwrap();
        websocket
            .send(Message::Text(
                r#"{"jsonrpc":"2.0","id":"bootstrap","method":"initialize","params":{}}"#
                    .to_owned()
                    .into(),
            ))
            .unwrap();

        let first_request = websocket.read().unwrap();
        let second_request = websocket.read().unwrap();
        assert!(first_request.to_text().unwrap().contains("\"id\":7"));
        assert!(second_request.to_text().unwrap().contains("\"id\":\"7\""));

        websocket
            .send(Message::Text(
                r#"{"jsonrpc":"2.0","id":"7","result":{"answers":{"q":"native"}}}"#
                    .to_owned()
                    .into(),
            ))
            .unwrap();
        let mut decision_client = UnixStream::connect(&decision).unwrap();
        decision_client
            .write_all(
                b"{\"schemaVersion\":1,\"launchId\":\"launch-ws\",\"requestId\":7,\"result\":{\"answers\":{\"q\":\"cove\"}}}\n",
            )
            .unwrap();

        let first_response: Value =
            serde_json::from_str(websocket.read().unwrap().to_text().unwrap()).unwrap();
        let second_response: Value =
            serde_json::from_str(websocket.read().unwrap().to_text().unwrap()).unwrap();
        assert_eq!(first_response["id"], "7");
        assert_eq!(first_response["result"]["answers"]["q"], "native");
        assert_eq!(second_response["id"], 7);
        assert_eq!(second_response["result"]["answers"]["q"], "cove");
        // The fake app-server exits after echoing both responses, so its broker
        // may complete the close first. Dropping the client still exercises the
        // cleanup path without treating that valid close race as a test failure.
        drop(websocket);
        assert_eq!(broker.join().unwrap(), 0);
    }

    #[test]
    fn websocket_partial_http_handshake_times_out_and_cleans_up() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        fs::write(&fake_codex, b"#!/bin/sh\nexec sleep 30\n").unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.broker_start_timeout_ms = 250;
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        let listen = broker_socket(&config.runtime_directory, "launch-ws-partial");
        let decision = decision_socket(&config.runtime_directory, "launch-ws-partial");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-ws-partial",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        let mut stream = UnixStream::connect(&listen).unwrap();
        stream.write_all(b"GET").unwrap();

        let error = broker.join().unwrap().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(!listen.exists());
        assert!(!decision.exists());
    }

    #[test]
    fn websocket_rejects_invalid_client_key_before_starting_app_server() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        let marker = temp.path().join("started");
        fs::write(
            &fake_codex,
            format!(
                "#!/bin/sh\nprintf started > '{}'\nexec sleep 30\n",
                marker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        let listen = broker_socket(&config.runtime_directory, "launch-ws-invalid-key");
        let decision = decision_socket(&config.runtime_directory, "launch-ws-invalid-key");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-ws-invalid-key",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        let mut stream = UnixStream::connect(&listen).unwrap();
        stream
            .write_all(
                b"GET /rpc HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: invalid\r\n\r\n",
            )
            .unwrap();

        let error = broker.join().unwrap().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(!marker.exists());
        assert!(!listen.exists());
        assert!(!decision.exists());
    }

    #[test]
    fn accepted_broker_client_is_restored_to_blocking_mode() {
        let temp = short_tempdir();
        let listen = temp.path().join("blocking-client.sock");
        let listener = bind_private_listener(&listen).unwrap();
        let client_thread = thread::spawn({
            let listen = listen.clone();
            move || UnixStream::connect(listen).unwrap()
        });

        let (accepted, _) = accept_with_timeout(&listener, Duration::from_secs(1)).unwrap();
        assert!(
            !fd_is_nonblocking(&accepted),
            "accepted broker client must not inherit the nonblocking accept loop"
        );
        drop(accepted);
        drop(client_thread.join().unwrap());
    }

    #[test]
    fn transient_websocket_io_errors_are_retryable() {
        assert!(websocket_error_is_transient(&tungstenite::Error::Io(
            io::Error::from(io::ErrorKind::WouldBlock),
        )));
        assert!(websocket_error_is_transient(&tungstenite::Error::Io(
            io::Error::from(io::ErrorKind::TimedOut),
        )));
        assert!(!websocket_error_is_transient(&tungstenite::Error::Io(
            io::Error::from(io::ErrorKind::BrokenPipe),
        )));
    }

    #[test]
    fn websocket_defers_child_start_until_first_protocol_frame() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        let marker = temp.path().join("started");
        fs::write(
            &fake_codex,
            format!(
                "#!/bin/sh\nprintf started > '{}'\nexec sleep 30\n",
                marker.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        let listen = broker_socket(&config.runtime_directory, "launch-ws-lazy");
        let decision = decision_socket(&config.runtime_directory, "launch-ws-lazy");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-ws-lazy",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        let stream = UnixStream::connect(&listen).unwrap();
        let (mut websocket, _) = tungstenite::client("ws://localhost/rpc", stream).unwrap();
        thread::sleep(Duration::from_millis(500));
        assert!(
            !marker.exists(),
            "app-server must not start for an idle websocket handshake"
        );

        websocket.close(None).unwrap();
        assert_eq!(broker.join().unwrap().unwrap(), 0);
        assert!(!listen.exists());
        assert!(!decision.exists());
    }

    #[test]
    fn websocket_proxy_rejects_oversized_client_message_and_cleans_up() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        fs::write(&fake_codex, b"#!/bin/sh\nexec sleep 30\n").unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        config.max_frame_bytes = 96;
        let listen = broker_socket(&config.runtime_directory, "launch-ws-large");
        let decision = decision_socket(&config.runtime_directory, "launch-ws-large");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-ws-large",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        let stream = UnixStream::connect(&listen).unwrap();
        let (mut websocket, _) = tungstenite::client("ws://localhost/rpc", stream).unwrap();
        websocket
            .send(Message::Text("x".repeat(128).into()))
            .unwrap();
        let error = broker.join().unwrap().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(!listen.exists());
        assert!(!decision.exists());
    }

    #[test]
    fn websocket_proxy_reports_oversized_app_server_output_and_cleans_up() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        fs::write(
            &fake_codex,
            b"#!/bin/sh\nIFS= read -r request || exit 20\nprintf '%0128d\\n' 0\nexec sleep 30\n",
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        config.max_frame_bytes = 96;
        let listen = broker_socket(&config.runtime_directory, "launch-ws-output-large");
        let decision = decision_socket(&config.runtime_directory, "launch-ws-output-large");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-ws-output-large",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        let stream = UnixStream::connect(&listen).unwrap();
        let (mut websocket, _) = tungstenite::client("ws://localhost/rpc", stream).unwrap();
        websocket
            .send(Message::Text(
                r#"{"jsonrpc":"2.0","id":"bootstrap","method":"initialize","params":{}}"#
                    .to_owned()
                    .into(),
            ))
            .unwrap();

        let error = broker.join().unwrap().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(!listen.exists());
        assert!(!decision.exists());
    }

    #[test]
    fn raw_proxy_rejects_oversized_client_line_before_forwarding_and_cleans_up() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        fs::write(&fake_codex, b"#!/bin/sh\nexec sleep 30\n").unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        config.max_frame_bytes = 96;
        let listen = broker_socket(&config.runtime_directory, "launch-raw-large");
        let decision = decision_socket(&config.runtime_directory, "launch-raw-large");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-raw-large",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        assert!(wait_for_socket(&decision, Duration::from_secs(1)));
        let mut client = UnixStream::connect(&listen).unwrap();
        client.write_all(&[b'x'; 128]).unwrap();

        let error = broker.join().unwrap().unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(!listen.exists());
        assert!(!decision.exists());
    }

    #[test]
    fn direct_mode_invokes_public_stdio_server_and_proxies_bytes() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        let arguments = temp.path().join("arguments");
        fs::write(
            &fake_codex,
            format!(
                "#!/bin/sh\nprintf '%s' \"$*\" > '{}'\nIFS= read -r request\nprintf '%s\\n' \"$request\"\n",
                arguments.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        let listen = broker_socket(&config.runtime_directory, "launch-direct");
        let broker_config = config.clone();
        let broker_listen = listen.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-direct",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
            .unwrap()
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        let mut client = UnixStream::connect(&listen).unwrap();
        client
            .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n")
            .unwrap();
        let mut response = String::new();
        BufReader::new(client).read_line(&mut response).unwrap();
        assert!(response.contains("\"initialize\""));
        assert_eq!(fs::read_to_string(arguments).unwrap(), "app-server --stdio");
        assert_eq!(broker.join().unwrap(), 0);
    }

    #[test]
    fn app_server_child_forces_tracing_off_for_protocol_stdout() {
        let temp = tempdir().unwrap();
        let fake_codex = temp.path().join("fake-codex");
        let rust_log = temp.path().join("rust-log");
        fs::write(
            &fake_codex,
            format!(
                "#!/bin/sh\nprintf '%s' \"$RUST_LOG\" > '{}'\n",
                rust_log.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut child = spawn_app_server(&fake_codex, AppServerMode::DirectStdio).unwrap();
        assert!(child.wait().unwrap().success());
        assert_eq!(fs::read_to_string(rust_log).unwrap(), "off");
    }

    #[test]
    fn raw_client_disconnect_terminates_app_server_descendants() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        let descendant_pid_path = temp.path().join("descendant.pid");
        fs::write(
            &fake_codex,
            format!(
                "#!/bin/sh\nsleep 30 &\ndescendant=$!\nprintf '%s' \"$descendant\" > '{}.tmp'\nmv '{}.tmp' '{}'\nIFS= read -r request || exit 0\nwhile :; do printf '%s\\n' '{{\"jsonrpc\":\"2.0\",\"method\":\"tick\"}}'; done\n",
                descendant_pid_path.display(),
                descendant_pid_path.display(),
                descendant_pid_path.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();

        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("missing-events.sock");
        config.runtime_directory = temp.path().join("run");
        let listen = broker_socket(&config.runtime_directory, "launch-disconnect");
        let broker_listen = listen.clone();
        let broker_config = config.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-disconnect",
                &fake_codex,
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        let mut client = UnixStream::connect(&listen).unwrap();
        client
            .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n")
            .unwrap();
        for _ in 0..100 {
            if descendant_pid_path.exists() {
                break;
            }
            thread::sleep(Duration::from_millis(10));
        }
        let descendant_pid = fs::read_to_string(&descendant_pid_path)
            .unwrap()
            .parse::<libc::pid_t>()
            .unwrap();

        thread::sleep(Duration::from_millis(350));
        drop(client);
        assert!(broker.join().unwrap().is_ok());
        assert_process_is_gone(descendant_pid);
        assert!(!listen.exists());
    }

    #[test]
    fn broker_cleans_up_when_app_server_exits_after_client_claim() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        config.runtime_directory = temp.path().join("run");
        let listen = broker_socket(&config.runtime_directory, "launch-failed");
        let broker_listen = listen.clone();
        let broker_config = config.clone();
        let broker = thread::spawn(move || {
            run_broker(
                &broker_listen,
                "launch-failed",
                Path::new("/usr/bin/false"),
                &broker_config,
                AppServerMode::DirectStdio,
            )
        });

        assert!(wait_for_socket(&listen, Duration::from_secs(1)));
        let mut client = UnixStream::connect(&listen).unwrap();
        client
            .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}\n")
            .unwrap();

        let error = broker.join().unwrap().unwrap_err();
        assert!(
            error.to_string().contains("exited during broker startup"),
            "unexpected error: {error}"
        );
        assert!(!listen.exists());
    }

    #[test]
    fn broker_and_decision_socket_names_are_short_and_deterministic() {
        let runtime =
            Path::new("/tmp/codex-cove-runtime-path-with-representative-length-for-sunpath");
        let launch_id = "launch-".to_owned() + &"very-long-opaque-title-marker".repeat(20);
        let first = broker_socket(runtime, &launch_id);
        let second = broker_socket(runtime, &launch_id);
        let decision = decision_socket(runtime, &launch_id);

        assert_eq!(first, second);
        assert_ne!(first, decision);
        assert_eq!(first.file_name().unwrap().to_string_lossy().len(), 18);
        assert_eq!(decision.file_name().unwrap().to_string_lossy().len(), 18);
        assert!(first.to_string_lossy().len() < 103, "{}", first.display());
        assert!(
            decision.to_string_lossy().len() < 103,
            "{}",
            decision.display()
        );
    }

    #[test]
    fn broker_expires_when_no_client_claims_its_socket() {
        let temp = short_tempdir();
        let fake_codex = temp.path().join("fake-codex");
        fs::write(&fake_codex, b"#!/bin/sh\nexec sleep 30\n").unwrap();
        fs::set_permissions(&fake_codex, fs::Permissions::from_mode(0o755)).unwrap();
        let mut config = Config::for_home(temp.path());
        config.broker_start_timeout_ms = 250;
        config.runtime_directory = temp.path().join("run");
        fs::create_dir_all(&config.runtime_directory).unwrap();
        let listen = broker_socket(&config.runtime_directory, "launch-unclaimed");

        let started = std::time::Instant::now();
        let error = run_broker(
            &listen,
            "launch-unclaimed",
            &fake_codex,
            &config,
            AppServerMode::DirectStdio,
        )
        .unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(2));
        assert!(!listen.exists());
        assert!(!decision_socket(&config.runtime_directory, "launch-unclaimed").exists());
    }
}
