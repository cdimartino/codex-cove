pub mod broker;
pub mod config;
pub mod doctor;
pub mod hook;
pub mod install;
pub mod ipc;
pub mod redact;
pub mod remote;
pub mod route;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::{SystemTime, UNIX_EPOCH};

pub const SCHEMA_VERSION: u32 = 1;
pub const DEFAULT_MAX_FRAME_BYTES: usize = 8 * 1_048_576;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct CoveEvent {
    pub schema_version: u32,
    pub event_id: String,
    pub timestamp: String,
    pub kind: String,
    pub source: EventSource,
    pub session_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub launch_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub host_id: Option<String>,
    pub payload: Value,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum EventSource {
    LocalCli,
    CodexDesktop,
    RemoteCli,
}

impl CoveEvent {
    pub fn new(
        kind: impl Into<String>,
        source: EventSource,
        session_id: impl Into<String>,
        launch_id: Option<String>,
        payload: Value,
    ) -> Self {
        let timestamp_millis = unix_millis();
        let payload = match payload {
            Value::Object(_) => payload,
            other => serde_json::json!({ "value": other }),
        };
        Self {
            schema_version: SCHEMA_VERSION,
            event_id: format!(
                "{timestamp_millis:x}-{:x}-{:x}",
                std::process::id(),
                monotonic_nonce()
            ),
            timestamp: format_rfc3339(timestamp_millis),
            kind: kind.into(),
            source,
            session_id: session_id.into(),
            turn_id: None,
            launch_id,
            host_id: std::env::var("CODEX_COVE_HOST_ID").ok(),
            payload,
        }
    }
}

pub fn unix_millis() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis()
        .try_into()
        .unwrap_or(u64::MAX)
}

pub fn format_rfc3339(milliseconds: u64) -> String {
    let total_seconds = milliseconds / 1_000;
    let millis = milliseconds % 1_000;
    let days = (total_seconds / 86_400) as i64;
    let seconds_in_day = total_seconds % 86_400;
    let hour = seconds_in_day / 3_600;
    let minute = (seconds_in_day % 3_600) / 60;
    let second = seconds_in_day % 60;
    let (year, month, day) = civil_from_days(days);
    format!("{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}.{millis:03}Z")
}

// Gregorian calendar conversion for days since 1970-01-01. Adapted from the
// public-domain civil calendar algorithm by Howard Hinnant.
fn civil_from_days(days_since_epoch: i64) -> (i64, u64, u64) {
    let days = days_since_epoch + 719_468;
    let era = if days >= 0 { days } else { days - 146_096 } / 146_097;
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let mut year = year_of_era + era * 400;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_prime = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_prime + 2) / 5 + 1;
    let month = month_prime + if month_prime < 10 { 3 } else { -9 };
    year += i64::from(month <= 2);
    (year, month as u64, day as u64)
}

fn monotonic_nonce() -> u128 {
    use std::sync::atomic::{AtomicU64, Ordering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    ((unix_millis() as u128) << 64) | NEXT.fetch_add(1, Ordering::Relaxed) as u128
}

pub fn is_truthy(value: Option<&str>) -> bool {
    matches!(
        value.map(str::trim).map(str::to_ascii_lowercase).as_deref(),
        Some("1" | "true" | "yes" | "on")
    )
}

pub fn generate_launch_id() -> String {
    format!(
        "cove-{:x}-{:x}-{:x}",
        unix_millis(),
        std::process::id(),
        monotonic_nonce()
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn formats_rfc3339_utc() {
        assert_eq!(format_rfc3339(0), "1970-01-01T00:00:00.000Z");
        assert_eq!(
            format_rfc3339(1_722_355_200_123),
            "2024-07-30T16:00:00.123Z"
        );
    }

    #[test]
    fn event_matches_rich_wire_contract() {
        let event = CoveEvent::new(
            "launch",
            EventSource::LocalCli,
            "pending",
            Some("launch-1".to_owned()),
            json!({"status":"working"}),
        );
        let value = serde_json::to_value(event).unwrap();
        assert_eq!(value["schemaVersion"], 1);
        assert_eq!(value["kind"], "launch");
        assert_eq!(value["source"], "localCli");
        assert_eq!(value["sessionId"], "pending");
        assert!(value["timestamp"].as_str().unwrap().ends_with('Z'));
        assert!(value["payload"].is_object());
    }

    #[test]
    fn decodes_shared_cross_language_event_fixtures() {
        let fixture = include_str!("../../Fixtures/cove-events.v1.jsonl");
        let events: Vec<CoveEvent> = fixture
            .lines()
            .filter(|line| !line.trim().is_empty())
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(events.len(), 6);
        assert_eq!(events[0].kind, "launch");
        assert_eq!(events[2].kind, "approvalRequested");
        assert_eq!(events[3].kind, "questionRequested");
        assert_eq!(events[3].source, EventSource::LocalCli);
        assert_eq!(events[5].kind, "hook");
        assert_eq!(events[5].source, EventSource::CodexDesktop);
        assert_eq!(events[5].session_id, "thread-desktop");
    }
}
