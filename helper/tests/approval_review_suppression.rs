use codex_cove::config::Config;
use codex_cove::hook::run_hook_with_io;
use codex_cove::ipc::bind_private_listener;
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, ErrorKind};
use tempfile::tempdir;

#[test]
fn approval_review_hooks_never_reach_cove() {
    for (hook_name, suffix) in [
        ("SessionStart", "start"),
        ("PermissionRequest", "permission"),
        ("Stop", "stop"),
    ] {
        let temp = tempdir().unwrap();
        let mut config = Config::for_home(temp.path());
        config.runtime_directory = temp.path().join("run");
        config.event_socket = config.runtime_directory.join("events.sock");
        config.hook_timeout_ms = 50;
        let listener = bind_private_listener(&config.event_socket).unwrap();
        listener.set_nonblocking(true).unwrap();

        let input = json!({
            "hookEventName": hook_name,
            "session_id": "parent-task",
            "turn_id": format!("approval-review-{suffix}"),
            "model": "codex-auto-review"
        });
        let input = serde_json::to_vec(&input).unwrap();
        let mut output = Vec::new();
        run_hook_with_io(&config, &mut input.as_slice(), &mut output).unwrap();

        assert!(output.is_empty(), "reviewer hooks cannot answer themselves");
        assert!(
            matches!(listener.accept(), Err(error) if error.kind() == ErrorKind::WouldBlock),
            "{hook_name} from codex-auto-review must not emit a Cove event"
        );
    }
}

#[test]
fn ordinary_subagents_still_reach_cove() {
    let temp = tempdir().unwrap();
    let mut config = Config::for_home(temp.path());
    config.runtime_directory = temp.path().join("run");
    config.event_socket = config.runtime_directory.join("events.sock");
    let listener = bind_private_listener(&config.event_socket).unwrap();

    let input = json!({
        "hookEventName": "SubagentStart",
        "session_id": "parent-task",
        "turn_id": "ordinary-child-turn",
        "model": "gpt-5.6",
        "agent_id": "ordinary-child",
        "agent_type": "explorer",
    });
    let input = serde_json::to_vec(&input).unwrap();
    let mut output = Vec::new();
    run_hook_with_io(&config, &mut input.as_slice(), &mut output).unwrap();

    let (stream, _) = listener.accept().unwrap();
    let mut encoded = String::new();
    BufReader::new(stream).read_line(&mut encoded).unwrap();
    let event: Value = serde_json::from_str(&encoded).unwrap();
    assert_eq!(event["kind"], "hook");
    assert_eq!(event["sessionId"], "parent-task");
    assert_eq!(event["payload"]["hookEventName"], "SubagentStart");
    assert_eq!(event["payload"]["data"]["agent_type"], "explorer");
    assert!(output.is_empty());
}

#[test]
fn approval_model_near_miss_remains_visible() {
    let temp = tempdir().unwrap();
    let mut config = Config::for_home(temp.path());
    config.runtime_directory = temp.path().join("run");
    config.event_socket = config.runtime_directory.join("events.sock");
    let listener = bind_private_listener(&config.event_socket).unwrap();

    let input = serde_json::to_vec(&json!({
        "hookEventName": "SessionStart",
        "session_id": "ordinary-task",
        "model": "codex-auto-reviewer"
    }))
    .unwrap();
    let mut output = Vec::new();
    run_hook_with_io(&config, &mut input.as_slice(), &mut output).unwrap();

    let (stream, _) = listener.accept().unwrap();
    let mut encoded = String::new();
    BufReader::new(stream).read_line(&mut encoded).unwrap();
    let event: Value = serde_json::from_str(&encoded).unwrap();
    assert_eq!(event["sessionId"], "ordinary-task");
    assert_eq!(event["payload"]["data"]["model"], "codex-auto-reviewer");
    assert!(output.is_empty());
}

#[test]
fn ambiguous_permission_hook_never_reaches_cove() {
    let temp = tempdir().unwrap();
    let mut config = Config::for_home(temp.path());
    config.runtime_directory = temp.path().join("run");
    config.event_socket = config.runtime_directory.join("events.sock");
    config.hook_timeout_ms = 50;
    let listener = bind_private_listener(&config.event_socket).unwrap();
    listener.set_nonblocking(true).unwrap();

    let input = serde_json::to_vec(&json!({
        "hookEventName": "PermissionRequest",
        "session_id": "parent-task",
        "turn_id": "auto-routed-turn",
        "model": "gpt-5.6"
    }))
    .unwrap();
    let mut output = Vec::new();
    run_hook_with_io(&config, &mut input.as_slice(), &mut output).unwrap();

    assert!(output.is_empty());
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == ErrorKind::WouldBlock),
        "reviewer-ambiguous PermissionRequest must stay in native Codex"
    );
}

#[test]
fn invented_reviewer_field_cannot_bypass_native_routing() {
    let temp = tempdir().unwrap();
    let mut config = Config::for_home(temp.path());
    config.runtime_directory = temp.path().join("run");
    config.event_socket = config.runtime_directory.join("events.sock");
    config.hook_timeout_ms = 50;
    let listener = bind_private_listener(&config.event_socket).unwrap();
    listener.set_nonblocking(true).unwrap();

    let input = json!({
        "hookEventName": "PermissionRequest",
        "session_id": "parent-task",
        "turn_id": "parent-turn",
        "model": "gpt-5.6",
        "approvalsReviewer": "user"
    });
    let input = serde_json::to_vec(&input).unwrap();
    let mut output = Vec::new();
    run_hook_with_io(&config, &mut input.as_slice(), &mut output).unwrap();
    assert!(output.is_empty());
    assert!(
        matches!(listener.accept(), Err(error) if error.kind() == ErrorKind::WouldBlock),
        "unknown hook fields cannot fabricate reviewer certainty"
    );
}
