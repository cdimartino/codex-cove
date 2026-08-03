use crate::config::Config;
use crate::ipc::{bind_private_listener, read_limited_line, send_event_one_way};
use crate::{CoveEvent, EventSource};
use serde_json::{Value, json};
use std::fs;
use std::io::{self, BufReader, Read, Write};
use std::thread;
use std::time::{Duration, Instant};

pub fn run_hook(config: &Config) -> io::Result<()> {
    run_hook_with_io(config, &mut io::stdin().lock(), &mut io::stdout().lock())
}

pub fn run_hook_with_io<R: Read, W: Write>(
    config: &Config,
    input: &mut R,
    output: &mut W,
) -> io::Result<()> {
    let mut bytes = Vec::new();
    input
        .take(config.max_frame_bytes.saturating_add(1) as u64)
        .read_to_end(&mut bytes)?;
    if bytes.len() > config.max_frame_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "hook input exceeds maximum frame size",
        ));
    }
    let payload: Value = serde_json::from_slice(&bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let hook_name = payload
        .get("hookEventName")
        .or_else(|| payload.get("hook_event_name"))
        .and_then(Value::as_str)
        .unwrap_or("Unknown");

    // Codex's automated approval reviewer is an internal subagent. Its hook
    // events share the parent session id, so forwarding even a SessionStart or
    // Stop would make the parent look like a separate actionable Cove task.
    // The public hook contract's stable marker is its dedicated model slug.
    if is_approval_review_subagent(&payload) {
        return Ok(());
    }

    // Current PermissionRequest hook input does not identify whether this
    // individual request is routed to the user or Codex's automated reviewer.
    // Never turn an ambiguous hook into Cove attention. Broker-routed CLI
    // approvals arrive separately as authoritative app-server requests;
    // Desktop/fallback sessions retain their native approval surface. A future
    // A future public hook revision can add a reviewer discriminator and a
    // versioned contract. Until then every PermissionRequest stays native.
    if hook_name == "PermissionRequest" {
        return Ok(());
    }
    let session_id = payload
        .get("session_id")
        .or_else(|| payload.get("sessionId"))
        .or_else(|| payload.get("thread_id"))
        .or_else(|| payload.get("threadId"))
        .or_else(|| payload.get("conversation_id"))
        .or_else(|| payload.get("conversationId"))
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let turn_id = payload
        .get("turn_id")
        .or_else(|| payload.get("turnId"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let launch_id = std::env::var("CODEX_COVE_LAUNCH_ID").ok();
    let source = if let Some(source) = configured_source(&payload) {
        source
    } else if std::env::var_os("CODEX_COVE_HOST_ID").is_some() {
        EventSource::RemoteCli
    } else if launch_id.is_none() && std::env::var_os("TERM").is_none() {
        EventSource::CodexDesktop
    } else {
        EventSource::LocalCli
    };
    let mut event = CoveEvent::new(
        "hook",
        source,
        session_id,
        launch_id,
        json!({"hookEventName": hook_name, "data": payload}),
    );
    event.turn_id = turn_id;

    if hook_name == "PermissionRequest" {
        let decision_path = config.runtime_directory.join(format!(
            "h-{}-{:x}.sock",
            std::process::id(),
            crate::unix_millis() & 0xffff_ffff
        ));
        let listener = bind_private_listener(&decision_path)?;
        listener.set_nonblocking(true)?;
        if let Some(object) = event.payload.as_object_mut() {
            object.insert(
                "decisionSocket".to_owned(),
                Value::String(decision_path.display().to_string()),
            );
            object.insert(
                "requestId".to_owned(),
                Value::String(event.event_id.clone()),
            );
            object.insert(
                "choices".to_owned(),
                json!([
                    {"id":"accept","label":"Allow"},
                    {"id":"decline","label":"Deny"},
                    {"id":"cancel","label":"Open native prompt"}
                ]),
            );
        }
        let sent = send_event_one_way(
            &config.event_socket,
            &event,
            Duration::from_millis(50),
            config.max_frame_bytes,
        );
        let decision = if sent.is_ok() {
            wait_for_permission_decision(
                &listener,
                &event.event_id,
                Duration::from_millis(config.hook_timeout_ms),
                config.max_frame_bytes,
            )?
        } else {
            None
        };
        let _ = fs::remove_file(&decision_path);
        if sent.is_ok() {
            let resolution = if decision.is_some() {
                "responded"
            } else {
                "expired"
            };
            let mut resolved = CoveEvent::new(
                "serverRequestResolved",
                event.source,
                event.session_id.clone(),
                event.launch_id.clone(),
                json!({
                    "method": "serverRequest/resolved",
                    "params": {
                        "requestId": event.event_id,
                        "resolution": resolution
                    }
                }),
            );
            resolved.turn_id = event.turn_id.clone();
            let _ = send_event_one_way(
                &config.event_socket,
                &resolved,
                Duration::from_millis(50),
                config.max_frame_bytes,
            );
        }
        if let Some(decision) = decision {
            serde_json::to_writer(&mut *output, &decision)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            output.write_all(b"\n")?;
        }
    } else {
        let _ = send_event_one_way(
            &config.event_socket,
            &event,
            Duration::from_millis(50),
            config.max_frame_bytes,
        );
    }
    Ok(())
}

fn configured_source(payload: &Value) -> Option<EventSource> {
    let raw = std::env::var("CODEX_COVE_SOURCE")
        .ok()
        .or_else(|| {
            payload
                .get("source")
                .and_then(Value::as_str)
                .map(str::to_owned)
        })
        .or_else(|| {
            payload
                .get("source_kind")
                .or_else(|| payload.get("sourceKind"))
                .and_then(Value::as_str)
                .map(str::to_owned)
        })?;
    match raw.trim().to_ascii_lowercase().as_str() {
        "localcli" | "local_cli" | "cli" => Some(EventSource::LocalCli),
        "codexdesktop" | "codex_desktop" | "desktop" => Some(EventSource::CodexDesktop),
        "remotecli" | "remote_cli" | "remote" => Some(EventSource::RemoteCli),
        _ => None,
    }
}

fn is_approval_review_subagent(payload: &Value) -> bool {
    payload.get("model").and_then(Value::as_str) == Some("codex-auto-review")
}

fn wait_for_permission_decision(
    listener: &std::os::unix::net::UnixListener,
    request_id: &str,
    timeout: Duration,
    max_bytes: usize,
) -> io::Result<Option<Value>> {
    let started = Instant::now();
    while started.elapsed() < timeout {
        match listener.accept() {
            Ok((stream, _)) => {
                stream.set_read_timeout(Some(timeout.saturating_sub(started.elapsed())))?;
                let mut reader = BufReader::new(stream);
                let Some(bytes) = read_limited_line(&mut reader, max_bytes)? else {
                    return Ok(None);
                };
                return validated_permission_frame(&bytes, request_id);
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                thread::sleep(Duration::from_millis(10));
            }
            Err(error) => return Err(error),
        }
    }
    Ok(None)
}

fn validated_permission_frame(bytes: &[u8], request_id: &str) -> io::Result<Option<Value>> {
    let value: Value = serde_json::from_slice(bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if value.get("schemaVersion").and_then(Value::as_u64) != Some(1)
        || value.get("requestId").and_then(Value::as_str) != Some(request_id)
    {
        return Ok(None);
    }
    let decision = value.pointer("/result/decision").and_then(Value::as_str);
    let Some(decision) = decision else {
        return Ok(None);
    };
    let hook_decision = match decision {
        "accept" | "acceptForSession" => json!({"behavior": "allow"}),
        "decline" => json!({"behavior": "deny", "message": "Denied in Codex Cove"}),
        "cancel" => return Ok(None),
        _ => return Ok(None),
    };
    Ok(Some(json!({
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": hook_decision
        }
    })))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::bind_private_listener;
    use std::io::{BufRead, BufReader, ErrorKind};
    use std::thread;
    use tempfile::tempdir;

    #[test]
    fn absent_socket_returns_no_decision() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        config.runtime_directory = temp.path().to_path_buf();
        config.event_socket = temp.path().join("absent.sock");
        let mut output = Vec::new();
        run_hook_with_io(
            &config,
            &mut br#"{"hookEventName":"PermissionRequest","session_id":"s1"}"#.as_slice(),
            &mut output,
        )
        .unwrap();
        assert!(output.is_empty());
    }

    #[test]
    fn malformed_input_is_rejected_without_decision() {
        let temp = tempdir().unwrap();
        let config = Config::for_home(temp.path());
        let mut output = Vec::new();
        assert!(run_hook_with_io(&config, &mut b"not-json".as_slice(), &mut output).is_err());
        assert!(output.is_empty());
    }

    #[test]
    fn permission_hook_never_opens_a_cove_decision_channel() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        config.runtime_directory = temp.path().to_path_buf();
        config.event_socket = temp.path().join("cove.sock");
        let listener = bind_private_listener(&config.event_socket).unwrap();
        listener.set_nonblocking(true).unwrap();

        let mut output = Vec::new();
        run_hook_with_io(
            &config,
            &mut br#"{"hookEventName":"PermissionRequest","session_id":"s1","turn_id":"turn-1"}"#
                .as_slice(),
            &mut output,
        )
        .unwrap();
        assert!(output.is_empty());
        assert!(matches!(listener.accept(), Err(error) if error.kind() == ErrorKind::WouldBlock));
    }

    #[test]
    fn non_permission_hook_ignores_response() {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        config.event_socket = temp.path().join("cove.sock");
        let listener = bind_private_listener(&config.event_socket).unwrap();
        let server = thread::spawn(move || {
            let (stream, _) = listener.accept().unwrap();
            let mut request = String::new();
            BufReader::new(stream.try_clone().unwrap())
                .read_line(&mut request)
                .unwrap();
        });

        let mut output = Vec::new();
        run_hook_with_io(
            &config,
            &mut br#"{"hookEventName":"Stop","session_id":"s1"}"#.as_slice(),
            &mut output,
        )
        .unwrap();
        server.join().unwrap();
        assert!(output.is_empty());
    }

    #[test]
    fn permission_response_rejects_reserved_or_unknown_decisions() {
        assert!(
            validated_permission_frame(
                br#"{"schemaVersion":1,"requestId":"request-1","result":{"decision":"interrupt"}}"#,
                "request-1"
            )
            .unwrap()
            .is_none()
        );
        assert!(
            validated_permission_frame(
                br#"{"schemaVersion":1,"requestId":"wrong","result":{"decision":"accept"}}"#,
                "request-1"
            )
            .unwrap()
            .is_none()
        );
    }
}
