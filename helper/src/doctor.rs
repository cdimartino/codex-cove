use crate::broker::probe_direct_stdio;
use crate::config::{Config, is_executable};
use crate::install::{
    HOOK_EVENTS, InstallLayout, InstallManifest, read_manifest, sha256_file, sha256_tree,
};
use serde::Serialize;
use std::collections::BTreeMap;
use std::env;
use std::fs;
use std::io::{self, Read};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::thread;
use std::time::Duration;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoctorReport {
    pub healthy: bool,
    pub checks: Vec<DoctorCheck>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DoctorCheck {
    pub name: String,
    pub status: CheckStatus,
    pub detail: String,
}

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum CheckStatus {
    Pass,
    Warn,
    Fail,
}

pub fn run(config: &Config, real_codex: Option<&Path>) -> DoctorReport {
    let mut checks = Vec::new();
    match real_codex {
        Some(path) if is_executable(path) => {
            let version = Command::new(path)
                .arg("--version")
                .env("CODEX_COVE_BYPASS", "1")
                .output();
            match version {
                Ok(output) if output.status.success() => {
                    let text = String::from_utf8_lossy(&output.stdout).trim().to_owned();
                    let status = if version_at_least(&text, 0, 145, 0) {
                        CheckStatus::Pass
                    } else {
                        CheckStatus::Fail
                    };
                    checks.push(DoctorCheck {
                        name: "codexVersion".to_owned(),
                        status,
                        detail: text,
                    });
                }
                Ok(output) => checks.push(DoctorCheck {
                    name: "codexVersion".to_owned(),
                    status: CheckStatus::Fail,
                    detail: format!("version exited {}", output.status),
                }),
                Err(error) => checks.push(DoctorCheck {
                    name: "codexVersion".to_owned(),
                    status: CheckStatus::Fail,
                    detail: error.to_string(),
                }),
            }
        }
        _ => checks.push(DoctorCheck {
            name: "realCodex".to_owned(),
            status: CheckStatus::Fail,
            detail: "executable not resolved".to_owned(),
        }),
    }

    if let Ok(layout) = InstallLayout::current() {
        match read_manifest(&layout) {
            Ok(manifest) => {
                let manifest_check = install_manifest_check(&layout, &manifest);
                let manifest_valid = manifest_check.status == CheckStatus::Pass;
                checks.push(manifest_check);
                if manifest_valid {
                    checks.push(managed_binary_integrity_check(&layout, &manifest));
                    checks.push(codex_shim_check(&layout, &manifest));
                    checks.push(owned_link_check(
                        "managementLink",
                        &layout.management_link,
                        &layout.managed_binary,
                    ));
                    checks.push(hook_check(&layout.hooks_path, &manifest.hook_command));
                    checks.push(DoctorCheck {
                        name: "installedApp".to_owned(),
                        status: if manifest.app_path.as_ref().is_none_or(|path| path.exists()) {
                            CheckStatus::Pass
                        } else {
                            CheckStatus::Fail
                        },
                        detail: manifest
                            .app_path
                            .as_deref()
                            .map(Path::display)
                            .map(|path| path.to_string())
                            .unwrap_or_else(|| "remote helper".to_owned()),
                    });
                }
                if manifest_valid && let Some(app_path) = manifest.app_path.as_deref() {
                    checks.push(app_bundle_integrity_check(app_path, &manifest));
                    checks.push(app_identity_check(app_path));
                    checks.push(codesign_check(app_path));
                    checks.push(schema_compatibility_check(app_path));
                    checks.push(remote_artifacts_check(app_path));
                } else if manifest_valid {
                    checks.push(DoctorCheck {
                        name: "appSignature".to_owned(),
                        status: CheckStatus::Warn,
                        detail: "remote helper install has no local app bundle to verify"
                            .to_owned(),
                    });
                    checks.push(DoctorCheck {
                        name: "schemaCompatibility".to_owned(),
                        status: CheckStatus::Warn,
                        detail: "remote helper install has no local bundled schemas to verify"
                            .to_owned(),
                    });
                    checks.push(DoctorCheck {
                        name: "remoteArtifacts".to_owned(),
                        status: CheckStatus::Warn,
                        detail: "remote helper install has no local remote-artifact bundle"
                            .to_owned(),
                    });
                }
                if manifest_valid {
                    checks.push(editor_extension_check(&manifest));
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                checks.push(DoctorCheck {
                    name: "installation".to_owned(),
                    status: CheckStatus::Warn,
                    detail: "install manifest not found".to_owned(),
                });
            }
            Err(error) => checks.push(DoctorCheck {
                name: "installation".to_owned(),
                status: CheckStatus::Fail,
                detail: error.to_string(),
            }),
        }
    }

    if let Some(path) = real_codex {
        checks.push(app_server_transport_check(path));
    }

    checks.push(socket_check(&config.event_socket));
    checks.extend(terminal_permission_checks());
    checks.push(DoctorCheck {
        name: "hookTrust".to_owned(),
        status: CheckStatus::Warn,
        detail: "trust must be reviewed in Codex /hooks".to_owned(),
    });
    DoctorReport {
        healthy: !checks.iter().any(|check| check.status == CheckStatus::Fail),
        checks,
    }
}

const SCHEMA_FILES: [&str; 4] = [
    "cove-event.v1.schema.json",
    "decision-frame.v1.schema.json",
    "interactive-request.v1.schema.json",
    "theme-definition.v1.schema.json",
];

const REMOTE_TARGETS: [(&str, BinaryArchitecture); 4] = [
    ("aarch64-apple-darwin", BinaryArchitecture::MachOArm64),
    ("x86_64-apple-darwin", BinaryArchitecture::MachOX86_64),
    ("aarch64-unknown-linux-musl", BinaryArchitecture::ElfArm64),
    ("x86_64-unknown-linux-musl", BinaryArchitecture::ElfX86_64),
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BinaryArchitecture {
    MachOArm64,
    MachOX86_64,
    ElfArm64,
    ElfX86_64,
}

const EXPECTED_APP_BUNDLE_ID: &str = "local.chris.codexcove";
const EXPECTED_EDITOR_EXTENSION_ID: &str = "codex-cove-local.cove-extension";

fn install_manifest_check(layout: &InstallLayout, manifest: &InstallManifest) -> DoctorCheck {
    let mut problems = Vec::new();
    match fs::symlink_metadata(&layout.manifest_path) {
        Ok(metadata)
            if metadata.file_type().is_file()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0 => {}
        Ok(_) => problems.push("manifest must be a current-user private regular file".to_owned()),
        Err(error) => problems.push(format!("manifest metadata: {error}")),
    }
    if manifest.schema_version != 1 {
        problems.push(format!(
            "unsupported manifest schema {}",
            manifest.schema_version
        ));
    }
    for (label, actual, expected) in [
        (
            "managedBinary",
            &manifest.managed_binary,
            &layout.managed_binary,
        ),
        ("codexShim", &manifest.codex_shim, &layout.codex_shim),
        (
            "managementLink",
            &manifest.management_link,
            &layout.management_link,
        ),
    ] {
        if actual != expected {
            problems.push(format!(
                "{label} does not match the current-user install layout"
            ));
        }
    }
    if let Some(app_path) = manifest.app_path.as_deref() {
        let expected_app = layout.home.join("Applications/Codex Cove.app");
        if app_path != expected_app || !app_path.is_absolute() {
            problems.push("appPath does not match the documented current-user install".to_owned());
        }
    }
    if manifest.hook_command != expected_hook_command(&layout.managed_binary) {
        problems.push("hookCommand does not match the managed helper".to_owned());
    }
    if manifest
        .editor_extension_id
        .as_deref()
        .is_some_and(|value| value != EXPECTED_EDITOR_EXTENSION_ID)
    {
        problems.push("unexpected editor extension identifier".to_owned());
    }
    if let Err(error) = manifest.editor_cleanup_targets() {
        problems.push(format!("invalid editor cleanup obligations: {error}"));
    }
    if !is_sha256_hex(&manifest.binary_sha256)
        || manifest
            .app_bundle_sha256
            .as_deref()
            .is_some_and(|value| !is_sha256_hex(value))
    {
        problems.push("manifest contains an invalid SHA-256 value".to_owned());
    }

    DoctorCheck {
        name: "installManifest".to_owned(),
        status: if problems.is_empty() {
            CheckStatus::Pass
        } else {
            CheckStatus::Fail
        },
        detail: if problems.is_empty() {
            format!(
                "schema 1, private current-user file, and canonical paths verified at {}",
                layout.manifest_path.display()
            )
        } else {
            problems.join("; ")
        },
    }
}

fn expected_hook_command(managed_binary: &Path) -> String {
    let quoted = managed_binary.to_string_lossy().replace('\'', "'\"'\"'");
    format!("'{quoted}' hook")
}

fn is_sha256_hex(value: &str) -> bool {
    value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn managed_binary_integrity_check(
    layout: &InstallLayout,
    manifest: &InstallManifest,
) -> DoctorCheck {
    let result = sha256_file(&layout.managed_binary);
    DoctorCheck {
        name: "managedBinaryIntegrity".to_owned(),
        status: match result.as_ref() {
            Ok(actual) if actual == &manifest.binary_sha256 => CheckStatus::Pass,
            _ => CheckStatus::Fail,
        },
        detail: match result {
            Ok(actual) if actual == manifest.binary_sha256 => {
                format!(
                    "{} matches install manifest",
                    layout.managed_binary.display()
                )
            }
            Ok(_) => "managed helper checksum mismatch".to_owned(),
            Err(error) => format!("managed helper checksum failed: {error}"),
        },
    }
}

fn app_bundle_integrity_check(app_path: &Path, manifest: &InstallManifest) -> DoctorCheck {
    let expected = manifest.app_bundle_sha256.as_deref();
    let result = sha256_tree(app_path);
    DoctorCheck {
        name: "appBundleIntegrity".to_owned(),
        status: match (result.as_ref(), expected) {
            (Ok(actual), Some(expected)) if actual == expected => CheckStatus::Pass,
            _ => CheckStatus::Fail,
        },
        detail: match (result, expected) {
            (Ok(actual), Some(expected)) if actual == expected => {
                format!("{} matches install manifest", app_path.display())
            }
            (Ok(_), Some(_)) => "installed app tree checksum mismatch".to_owned(),
            (Ok(_), None) => "install manifest has no app tree checksum".to_owned(),
            (Err(error), _) => format!("installed app checksum failed: {error}"),
        },
    }
}

fn app_identity_check(app_path: &Path) -> DoctorCheck {
    #[cfg(target_os = "macos")]
    {
        let info = app_path.join("Contents/Info.plist");
        let bundle_id = plist_value(&info, "CFBundleIdentifier");
        let version = plist_value(&info, "CFBundleShortVersionString");
        let expected_version = env!("CARGO_PKG_VERSION");
        let status = if bundle_id
            .as_ref()
            .is_ok_and(|value| value == EXPECTED_APP_BUNDLE_ID)
            && version
                .as_ref()
                .is_ok_and(|value| value == expected_version)
        {
            CheckStatus::Pass
        } else {
            CheckStatus::Fail
        };
        DoctorCheck {
            name: "appIdentity".to_owned(),
            status,
            detail: if status == CheckStatus::Pass {
                format!("{EXPECTED_APP_BUNDLE_ID} version {expected_version}")
            } else {
                format!(
                    "bundle/version mismatch: id={}, version={}",
                    bundle_id.unwrap_or_else(|error| format!("error: {error}")),
                    version.unwrap_or_else(|error| format!("error: {error}"))
                )
            },
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app_path;
        DoctorCheck {
            name: "appIdentity".to_owned(),
            status: CheckStatus::Warn,
            detail: "app identity verification is available only on macOS".to_owned(),
        }
    }
}

#[cfg(target_os = "macos")]
fn plist_value(path: &Path, key: &str) -> io::Result<String> {
    let output = Command::new("/usr/bin/plutil")
        .args(["-extract", key, "raw", "-o", "-"])
        .arg(path)
        .output()?;
    if !output.status.success() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("plutil failed for {key}"),
        ));
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

fn codesign_check(app_path: &Path) -> DoctorCheck {
    #[cfg(target_os = "macos")]
    {
        codesign_check_with(app_path, Path::new("/usr/bin/codesign"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app_path;
        DoctorCheck {
            name: "appSignature".to_owned(),
            status: CheckStatus::Warn,
            detail: "strict codesign verification is available only on macOS".to_owned(),
        }
    }
}

#[cfg(any(target_os = "macos", test))]
fn codesign_check_with(app_path: &Path, codesign: &Path) -> DoctorCheck {
    if !app_path.is_dir() {
        return DoctorCheck {
            name: "appSignature".to_owned(),
            status: CheckStatus::Fail,
            detail: format!("{} is not an installed app bundle", app_path.display()),
        };
    }
    if !is_executable(codesign) {
        return DoctorCheck {
            name: "appSignature".to_owned(),
            status: CheckStatus::Warn,
            detail: format!("{} is unavailable", codesign.display()),
        };
    }

    let mut command = Command::new(codesign);
    command.args(["--verify", "--deep", "--strict"]);
    command.arg(app_path);
    match bounded_stdout(&mut command, Duration::from_secs(10)) {
        Ok((status, _)) if status.success() => DoctorCheck {
            name: "appSignature".to_owned(),
            status: CheckStatus::Pass,
            detail: format!("strict deep verification passed for {}", app_path.display()),
        },
        Ok((status, _)) => DoctorCheck {
            name: "appSignature".to_owned(),
            status: CheckStatus::Fail,
            detail: format!("strict deep verification exited {status}"),
        },
        Err(error) => DoctorCheck {
            name: "appSignature".to_owned(),
            status: CheckStatus::Warn,
            detail: format!("strict deep verification unavailable: {error}"),
        },
    }
}

fn schema_compatibility_check(app_path: &Path) -> DoctorCheck {
    let schema_root = app_path.join("Contents/Resources/schemas");
    schema_compatibility_check_at(&schema_root)
}

fn schema_compatibility_check_at(schema_root: &Path) -> DoctorCheck {
    let mut problems = Vec::new();
    for name in SCHEMA_FILES {
        let path = schema_root.join(name);
        let value = match fs::read(&path)
            .map_err(|error| error.to_string())
            .and_then(|bytes| {
                serde_json::from_slice::<serde_json::Value>(&bytes)
                    .map_err(|error| error.to_string())
            }) {
            Ok(value) => value,
            Err(error) => {
                problems.push(format!("{name}: {error}"));
                continue;
            }
        };
        let declared = value
            .get("schemaVersion")
            .and_then(serde_json::Value::as_u64);
        let envelope_const = value
            .pointer("/properties/schemaVersion/const")
            .and_then(serde_json::Value::as_u64);
        if declared != Some(crate::SCHEMA_VERSION.into())
            || envelope_const.is_some_and(|version| version != u64::from(crate::SCHEMA_VERSION))
        {
            problems.push(format!(
                "{name}: expected top-level and any envelope schema version {}, found {declared:?}/{envelope_const:?}",
                crate::SCHEMA_VERSION
            ));
        }
    }

    DoctorCheck {
        name: "schemaCompatibility".to_owned(),
        status: if problems.is_empty() {
            CheckStatus::Pass
        } else {
            CheckStatus::Fail
        },
        detail: if problems.is_empty() {
            format!(
                "all {} installed schemas are compatible with v{}",
                SCHEMA_FILES.len(),
                crate::SCHEMA_VERSION
            )
        } else {
            problems.join("; ")
        },
    }
}

fn remote_artifacts_check(app_path: &Path) -> DoctorCheck {
    remote_artifacts_check_at(&app_path.join("Contents/Resources/remote"))
}

fn remote_artifacts_check_at(remote_root: &Path) -> DoctorCheck {
    let manifest_path = remote_root.join("SHA256SUMS");
    if !manifest_path.exists() {
        let has_artifacts = fs::read_dir(remote_root)
            .ok()
            .is_some_and(|mut entries| entries.next().is_some());
        return DoctorCheck {
            name: "remoteArtifacts".to_owned(),
            status: if has_artifacts {
                CheckStatus::Fail
            } else {
                CheckStatus::Warn
            },
            detail: if has_artifacts {
                format!(
                    "{} contains artifacts but has no SHA256SUMS",
                    remote_root.display()
                )
            } else {
                "optional remote helpers were not bundled".to_owned()
            },
        };
    }
    let manifest = match read_checksum_manifest(&manifest_path) {
        Ok(manifest) => manifest,
        Err(error) => {
            return DoctorCheck {
                name: "remoteArtifacts".to_owned(),
                status: CheckStatus::Fail,
                detail: format!("{}: {error}", manifest_path.display()),
            };
        }
    };

    let expected_version = format!("codex-cove {}", env!("CARGO_PKG_VERSION"));
    let mut problems = Vec::new();
    for (target, architecture) in REMOTE_TARGETS {
        let relative = format!("./{target}/codex-cove");
        let path = remote_root.join(target).join("codex-cove");
        let expected_checksum = manifest
            .get(&relative)
            .or_else(|| manifest.get(relative.trim_start_matches("./")));
        let Some(expected_checksum) = expected_checksum else {
            problems.push(format!("{target}: checksum manifest entry missing"));
            continue;
        };
        let metadata = match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_file() => metadata,
            Ok(_) => {
                problems.push(format!("{target}: helper is not a regular file"));
                continue;
            }
            Err(error) => {
                problems.push(format!("{target}: {error}"));
                continue;
            }
        };
        if metadata.permissions().mode() & 0o111 == 0 {
            problems.push(format!("{target}: helper is not executable"));
        }
        if metadata.len() > 64 * 1024 * 1024 {
            problems.push(format!("{target}: helper exceeds the 64 MiB safety limit"));
            continue;
        }
        let bytes = match fs::read(&path) {
            Ok(bytes) => bytes,
            Err(error) => {
                problems.push(format!("{target}: {error}"));
                continue;
            }
        };
        if detect_architecture(&bytes) != Some(architecture) {
            problems.push(format!(
                "{target}: binary architecture does not match target"
            ));
        }
        if !bytes
            .windows(expected_version.len())
            .any(|window| window == expected_version.as_bytes())
        {
            problems.push(format!(
                "{target}: embedded helper version is not {}",
                env!("CARGO_PKG_VERSION")
            ));
        }
        match sha256_file(&path) {
            Ok(actual) if &actual == expected_checksum => {}
            Ok(_) => problems.push(format!("{target}: checksum mismatch")),
            Err(error) => problems.push(format!("{target}: checksum failed: {error}")),
        }
    }

    DoctorCheck {
        name: "remoteArtifacts".to_owned(),
        status: if problems.is_empty() {
            CheckStatus::Pass
        } else {
            CheckStatus::Fail
        },
        detail: if problems.is_empty() {
            format!(
                "four target helpers match version {} and SHA256SUMS",
                env!("CARGO_PKG_VERSION")
            )
        } else {
            problems.join("; ")
        },
    }
}

fn read_checksum_manifest(path: &Path) -> io::Result<BTreeMap<String, String>> {
    let text = fs::read_to_string(path)?;
    let mut entries = BTreeMap::new();
    for (index, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let mut fields = line.split_whitespace();
        let checksum = fields.next().unwrap_or_default();
        let relative = fields.next().unwrap_or_default();
        if checksum.len() != 64
            || !checksum.bytes().all(|byte| byte.is_ascii_hexdigit())
            || relative.is_empty()
            || fields.next().is_some()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("invalid checksum line {}", index + 1),
            ));
        }
        if entries
            .insert(relative.to_owned(), checksum.to_ascii_lowercase())
            .is_some()
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("duplicate checksum path on line {}", index + 1),
            ));
        }
    }
    Ok(entries)
}

fn detect_architecture(bytes: &[u8]) -> Option<BinaryArchitecture> {
    if bytes.len() >= 8 && bytes[..4] == [0xcf, 0xfa, 0xed, 0xfe] {
        return match bytes[4..8] {
            [0x0c, 0x00, 0x00, 0x01] => Some(BinaryArchitecture::MachOArm64),
            [0x07, 0x00, 0x00, 0x01] => Some(BinaryArchitecture::MachOX86_64),
            _ => None,
        };
    }
    if bytes.len() >= 20 && bytes[..6] == [0x7f, b'E', b'L', b'F', 2, 1] {
        return match bytes[18..20] {
            [0xb7, 0x00] => Some(BinaryArchitecture::ElfArm64),
            [0x3e, 0x00] => Some(BinaryArchitecture::ElfX86_64),
            _ => None,
        };
    }
    None
}

fn terminal_permission_checks() -> [DoctorCheck; 2] {
    [
        DoctorCheck {
            name: "terminalAutomation".to_owned(),
            status: CheckStatus::Warn,
            detail: "not probed: per-terminal Automation access cannot be established read-only without potentially prompting; Cove requests it only when an enabled adapter needs it".to_owned(),
        },
        DoctorCheck {
            name: "terminalAccessibility".to_owned(),
            status: CheckStatus::Warn,
            detail: "not prompted: Accessibility is used only by enabled fallback adapters and must be reviewed in System Settings".to_owned(),
        },
    ]
}

fn editor_extension_check(manifest: &InstallManifest) -> DoctorCheck {
    let Some(extension_id) = manifest.editor_extension_id.as_deref() else {
        return DoctorCheck {
            name: "editorExtension".to_owned(),
            status: CheckStatus::Warn,
            detail: "install manifest does not declare an editor extension".to_owned(),
        };
    };
    let targets = match manifest.editor_cleanup_targets() {
        Ok(targets) => targets,
        Err(error) => {
            return DoctorCheck {
                name: "editorExtension".to_owned(),
                status: CheckStatus::Fail,
                detail: error.to_string(),
            };
        }
    };
    if targets.is_empty() {
        return DoctorCheck {
            name: "editorExtension".to_owned(),
            status: CheckStatus::Warn,
            detail: format!(
                "{extension_id} has no recorded editor installation or cleanup obligation"
            ),
        };
    }

    let mut installed = Vec::new();
    let mut problems = Vec::new();
    for editor in &targets {
        let Some(executable) = find_on_path(editor) else {
            problems.push(format!("{editor} CLI unavailable"));
            continue;
        };
        let mut command = Command::new(executable);
        command.args(["--list-extensions", "--show-versions"]);
        match bounded_stdout(&mut command, Duration::from_secs(10)) {
            Ok((status, output)) if status.success() => {
                if extension_list_contains_version(&output, extension_id, env!("CARGO_PKG_VERSION"))
                {
                    installed.push(editor.as_str());
                } else {
                    problems.push(format!(
                        "{editor} is missing {extension_id}@{}",
                        env!("CARGO_PKG_VERSION")
                    ));
                }
            }
            Ok((status, _)) => {
                problems.push(format!("{editor} extension query exited {status}"));
            }
            Err(error) => {
                problems.push(format!("{editor} extension query failed: {error}"));
            }
        }
    }

    if problems.is_empty() {
        DoctorCheck {
            name: "editorExtension".to_owned(),
            status: CheckStatus::Pass,
            detail: format!(
                "{extension_id} installed in {}{}",
                installed.join(" and "),
                if manifest.editor_extension_targets.is_none() {
                    " (legacy manifest requires every supported editor)"
                } else {
                    ""
                }
            ),
        }
    } else {
        DoctorCheck {
            name: "editorExtension".to_owned(),
            status: CheckStatus::Warn,
            detail: problems.join("; "),
        }
    }
}

fn extension_list_contains_version(output: &[u8], extension_id: &str, version: &str) -> bool {
    let expected = format!("{extension_id}@{version}");
    String::from_utf8_lossy(output)
        .lines()
        .any(|line| line.trim() == expected)
}

fn find_on_path(executable: &str) -> Option<PathBuf> {
    env::var_os("PATH")
        .into_iter()
        .flat_map(|path| env::split_paths(&path).collect::<Vec<_>>())
        .map(|directory| directory.join(executable))
        .find(|candidate| is_executable(candidate))
}

fn bounded_stdout(command: &mut Command, timeout: Duration) -> io::Result<(ExitStatus, Vec<u8>)> {
    let mut child = command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()?;
    let started = std::time::Instant::now();
    let status = loop {
        match child.try_wait()? {
            Some(status) => break status,
            None if started.elapsed() < timeout => thread::sleep(Duration::from_millis(20)),
            None => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(io::Error::new(io::ErrorKind::TimedOut, "query timed out"));
            }
        }
    };
    let mut output = Vec::new();
    if let Some(mut stdout) = child.stdout.take() {
        stdout.read_to_end(&mut output)?;
    }
    Ok((status, output))
}

fn app_server_transport_check(path: &Path) -> DoctorCheck {
    let daemon = Command::new(path)
        .args(["app-server", "daemon", "version"])
        .env("CODEX_COVE_BYPASS", "1")
        .output();
    match daemon {
        Ok(output) if output.status.success() => DoctorCheck {
            name: "appServerTransport".to_owned(),
            status: CheckStatus::Pass,
            detail: format!(
                "durable daemon available: {}",
                String::from_utf8_lossy(&output.stdout).trim()
            ),
        },
        daemon_result => {
            let daemon_detail = match daemon_result {
                Ok(output) => format!("version exited {}", output.status),
                Err(error) => error.to_string(),
            };
            let direct = probe_direct_stdio(path, Duration::from_secs(2));
            if direct.available {
                DoctorCheck {
                    name: "appServerTransport".to_owned(),
                    status: CheckStatus::Warn,
                    detail: format!(
                        "durable daemon unavailable ({daemon_detail}); direct stdio fallback available"
                    ),
                }
            } else {
                DoctorCheck {
                    name: "appServerTransport".to_owned(),
                    status: CheckStatus::Fail,
                    detail: format!(
                        "durable daemon unavailable ({daemon_detail}); direct stdio fallback unavailable ({})",
                        direct.detail
                    ),
                }
            }
        }
    }
}

fn owned_link_check(name: &str, path: &Path, target: &Path) -> DoctorCheck {
    match fs::read_link(path) {
        Ok(actual) if actual == target => DoctorCheck {
            name: name.to_owned(),
            status: CheckStatus::Pass,
            detail: path.display().to_string(),
        },
        Ok(actual) => DoctorCheck {
            name: name.to_owned(),
            status: CheckStatus::Fail,
            detail: format!("points to {}", actual.display()),
        },
        Err(error) => DoctorCheck {
            name: name.to_owned(),
            status: CheckStatus::Fail,
            detail: error.to_string(),
        },
    }
}

fn codex_shim_check(layout: &InstallLayout, manifest: &InstallManifest) -> DoctorCheck {
    if manifest.manages_codex_shim {
        return owned_link_check("codexShim", &layout.codex_shim, &layout.managed_binary);
    }
    match fs::symlink_metadata(&layout.codex_shim) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => DoctorCheck {
            name: "codexShim".to_owned(),
            status: CheckStatus::Pass,
            detail: "unmanaged; native Codex remains unmodified".to_owned(),
        },
        Ok(metadata) if metadata.file_type().is_symlink() => {
            match fs::read_link(&layout.codex_shim) {
                Ok(_)
                    if fs::canonicalize(&layout.codex_shim)
                        .ok()
                        .zip(fs::canonicalize(&layout.managed_binary).ok())
                        .is_some_and(|(shim, helper)| shim == helper) =>
                {
                    DoctorCheck {
                        name: "codexShim".to_owned(),
                        status: CheckStatus::Fail,
                        detail: format!(
                            "legacy Cove interception remains at {}",
                            layout.codex_shim.display()
                        ),
                    }
                }
                Ok(_) => DoctorCheck {
                    name: "codexShim".to_owned(),
                    status: CheckStatus::Pass,
                    detail: "unmanaged; preserved existing Codex path".to_owned(),
                },
                Err(error) => DoctorCheck {
                    name: "codexShim".to_owned(),
                    status: CheckStatus::Fail,
                    detail: error.to_string(),
                },
            }
        }
        Ok(_) => DoctorCheck {
            name: "codexShim".to_owned(),
            status: CheckStatus::Pass,
            detail: "unmanaged; preserved existing Codex path".to_owned(),
        },
        Err(error) => DoctorCheck {
            name: "codexShim".to_owned(),
            status: CheckStatus::Fail,
            detail: error.to_string(),
        },
    }
}

fn hook_check(path: &Path, command: &str) -> DoctorCheck {
    let parsed = fs::read(path)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<serde_json::Value>(&bytes).ok());
    let valid = parsed.as_ref().is_some_and(|value| {
        let Some(hooks) = value.get("hooks").and_then(serde_json::Value::as_object) else {
            return false;
        };
        HOOK_EVENTS.iter().all(|event| {
            hooks
                .get(*event)
                .is_some_and(|value| count_command(value, command) == 1)
        }) && count_command(&serde_json::Value::Object(hooks.clone()), command) == HOOK_EVENTS.len()
    });
    DoctorCheck {
        name: "hooks".to_owned(),
        status: if valid {
            CheckStatus::Pass
        } else {
            CheckStatus::Fail
        },
        detail: if valid {
            format!(
                "all {} owned hook groups contain exactly one handler",
                HOOK_EVENTS.len()
            )
        } else {
            "owned hook groups missing or changed".to_owned()
        },
    }
}

fn count_command(value: &serde_json::Value, command: &str) -> usize {
    match value {
        serde_json::Value::Object(map) => map
            .iter()
            .map(|(key, value)| {
                usize::from(key == "command" && value.as_str() == Some(command))
                    + count_command(value, command)
            })
            .sum(),
        serde_json::Value::Array(values) => values
            .iter()
            .map(|value| count_command(value, command))
            .sum(),
        _ => 0,
    }
}

fn socket_check(path: &Path) -> DoctorCheck {
    socket_check_for_uid(path, unsafe { libc::geteuid() })
}

fn socket_check_for_uid(path: &Path, expected_uid: u32) -> DoctorCheck {
    match fs::symlink_metadata(path) {
        Ok(metadata) if !metadata.file_type().is_socket() => DoctorCheck {
            name: "eventSocket".to_owned(),
            status: CheckStatus::Fail,
            detail: format!("{} is not a Unix socket", path.display()),
        },
        Ok(metadata) if metadata.uid() != expected_uid => DoctorCheck {
            name: "eventSocket".to_owned(),
            status: CheckStatus::Fail,
            detail: format!(
                "{} is owned by uid {}, expected uid {expected_uid}",
                path.display(),
                metadata.uid()
            ),
        },
        Ok(metadata) if metadata.permissions().mode() & 0o077 != 0 => DoctorCheck {
            name: "eventSocket".to_owned(),
            status: CheckStatus::Fail,
            detail: format!(
                "{} permissions {:03o} are not private",
                path.display(),
                metadata.permissions().mode() & 0o777
            ),
        },
        Ok(metadata) => match UnixStream::connect(path) {
            Ok(_) => DoctorCheck {
                name: "eventSocket".to_owned(),
                status: CheckStatus::Pass,
                detail: format!(
                    "{} owner uid {} mode {:03o}; listener accepted a connection",
                    path.display(),
                    metadata.uid(),
                    metadata.permissions().mode() & 0o777
                ),
            },
            Err(error) => DoctorCheck {
                name: "eventSocket".to_owned(),
                status: CheckStatus::Fail,
                detail: format!("{} has no reachable listener: {error}", path.display()),
            },
        },
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => DoctorCheck {
            name: "eventSocket".to_owned(),
            status: CheckStatus::Warn,
            detail: "Cove app is not running".to_owned(),
        },
        Err(error) => DoctorCheck {
            name: "eventSocket".to_owned(),
            status: CheckStatus::Fail,
            detail: error.to_string(),
        },
    }
}

pub fn version_at_least(text: &str, major: u64, minor: u64, patch: u64) -> bool {
    let version = text
        .split_whitespace()
        .find(|part| part.chars().next().is_some_and(|ch| ch.is_ascii_digit()));
    let Some(version) = version else {
        return false;
    };
    let values: Vec<u64> = version
        .split('.')
        .take(3)
        .map(|part| {
            part.chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .unwrap_or(0)
        })
        .collect();
    values.as_slice() >= [major, minor, patch].as_slice()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::os::unix::net::UnixListener;
    use tempfile::tempdir;

    fn write_schema_set(root: &Path) {
        fs::create_dir_all(root).unwrap();
        for name in SCHEMA_FILES {
            let contents = if name == "interactive-request.v1.schema.json" {
                br#"{"schemaVersion":1,"properties":{}}"#.as_slice()
            } else {
                br#"{"schemaVersion":1,"properties":{"schemaVersion":{"const":1}}}"#.as_slice()
            };
            fs::write(root.join(name), contents).unwrap();
        }
    }

    fn architecture_fixture(architecture: BinaryArchitecture) -> Vec<u8> {
        let mut bytes = match architecture {
            BinaryArchitecture::MachOArm64 => {
                vec![0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]
            }
            BinaryArchitecture::MachOX86_64 => {
                vec![0xcf, 0xfa, 0xed, 0xfe, 0x07, 0x00, 0x00, 0x01]
            }
            BinaryArchitecture::ElfArm64 => {
                let mut header = vec![0x7f, b'E', b'L', b'F', 2, 1];
                header.resize(18, 0);
                header.extend([0xb7, 0x00]);
                header
            }
            BinaryArchitecture::ElfX86_64 => {
                let mut header = vec![0x7f, b'E', b'L', b'F', 2, 1];
                header.resize(18, 0);
                header.extend([0x3e, 0x00]);
                header
            }
        };
        bytes.extend_from_slice(format!("codex-cove {}", env!("CARGO_PKG_VERSION")).as_bytes());
        bytes
    }

    fn write_remote_set(root: &Path) {
        fs::create_dir_all(root).unwrap();
        let mut manifest = String::new();
        for (target, architecture) in REMOTE_TARGETS {
            let directory = root.join(target);
            let path = directory.join("codex-cove");
            fs::create_dir_all(&directory).unwrap();
            fs::write(&path, architecture_fixture(architecture)).unwrap();
            fs::set_permissions(&path, fs::Permissions::from_mode(0o755)).unwrap();
            manifest.push_str(&format!(
                "{}  ./{target}/codex-cove\n",
                sha256_file(&path).unwrap()
            ));
        }
        fs::write(root.join("SHA256SUMS"), manifest).unwrap();
    }

    #[test]
    fn parses_codex_version() {
        assert!(version_at_least("codex-cli 0.145.0", 0, 145, 0));
        assert!(version_at_least("codex-cli 1.0.0", 0, 145, 0));
        assert!(!version_at_least("codex-cli 0.144.9", 0, 145, 0));
        assert!(!version_at_least("unknown", 0, 145, 0));
    }

    #[test]
    fn editor_extension_parser_requires_an_exact_line() {
        let id = "codex-cove-local.cove-extension";
        assert!(extension_list_contains_version(
            b"publisher.other@1.0.0\ncodex-cove-local.cove-extension@0.2.0\n",
            id,
            "0.2.0"
        ));
        assert!(extension_list_contains_version(
            b"  codex-cove-local.cove-extension@0.2.0  \n",
            id,
            "0.2.0"
        ));
        assert!(!extension_list_contains_version(
            b"codex-cove-local.cove-extension-extra@0.2.0\n",
            id,
            "0.2.0"
        ));
        assert!(!extension_list_contains_version(
            b"Codex-Cove-Local.Cove-Extension@0.2.0\n",
            id,
            "0.2.0"
        ));
        assert!(!extension_list_contains_version(
            b"codex-cove-local.cove-extension@0.1.9\n",
            id,
            "0.2.0"
        ));
    }

    #[test]
    fn fake_app_codesign_invocation_is_strict_and_deep() {
        let temp = tempdir().unwrap();
        let app = temp.path().join("Codex Cove.app");
        let codesign = temp.path().join("codesign");
        fs::create_dir(&app).unwrap();
        fs::write(
            &codesign,
            format!(
                "#!/bin/sh\n[ \"$1\" = --verify ] && [ \"$2\" = --deep ] && [ \"$3\" = --strict ] && [ \"$4\" = '{}' ]\n",
                app.display()
            ),
        )
        .unwrap();
        fs::set_permissions(&codesign, fs::Permissions::from_mode(0o755)).unwrap();
        let check = codesign_check_with(&app, &codesign);
        assert_eq!(check.status, CheckStatus::Pass);
    }

    #[test]
    fn codesign_tool_unavailability_warns_instead_of_panicking() {
        let temp = tempdir().unwrap();
        let app = temp.path().join("Codex Cove.app");
        fs::create_dir(&app).unwrap();
        let check = codesign_check_with(&app, &temp.path().join("missing-codesign"));
        assert_eq!(check.status, CheckStatus::Warn);
    }

    #[test]
    fn fake_layout_requires_all_four_compatible_schemas() {
        let temp = tempdir().unwrap();
        let schemas = temp.path().join("schemas");
        write_schema_set(&schemas);
        assert_eq!(
            schema_compatibility_check_at(&schemas).status,
            CheckStatus::Pass
        );

        fs::write(
            schemas.join(SCHEMA_FILES[2]),
            br#"{"schemaVersion":2,"properties":{"schemaVersion":{"const":2}}}"#,
        )
        .unwrap();
        let check = schema_compatibility_check_at(&schemas);
        assert_eq!(check.status, CheckStatus::Fail);
        assert!(check.detail.contains(SCHEMA_FILES[2]));
    }

    #[test]
    fn architecture_detection_table_covers_all_remote_targets() {
        for (_, expected) in REMOTE_TARGETS {
            assert_eq!(
                detect_architecture(&architecture_fixture(expected)),
                Some(expected)
            );
        }
        assert_eq!(detect_architecture(b"not a binary"), None);
    }

    #[test]
    fn fake_remote_layout_checks_version_architecture_and_checksums() {
        let temp = tempdir().unwrap();
        write_remote_set(temp.path());
        assert_eq!(
            remote_artifacts_check_at(temp.path()).status,
            CheckStatus::Pass
        );

        let changed = temp.path().join("x86_64-unknown-linux-musl/codex-cove");
        let mut bytes = fs::read(&changed).unwrap();
        bytes.push(1);
        fs::write(&changed, bytes).unwrap();
        let check = remote_artifacts_check_at(temp.path());
        assert_eq!(check.status, CheckStatus::Fail);
        assert!(check.detail.contains("checksum mismatch"));
    }

    #[test]
    fn absent_optional_remote_bundle_warns_but_partial_bundle_fails() {
        let temp = tempdir().unwrap();
        let absent = remote_artifacts_check_at(temp.path());
        assert_eq!(absent.status, CheckStatus::Warn);
        assert!(absent.detail.contains("not bundled"));

        fs::write(temp.path().join("unexpected-helper"), b"partial").unwrap();
        let partial = remote_artifacts_check_at(temp.path());
        assert_eq!(partial.status, CheckStatus::Fail);
        assert!(partial.detail.contains("no SHA256SUMS"));
    }

    #[test]
    fn install_manifest_requires_private_expected_paths_and_matching_helper() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        fs::create_dir_all(layout.managed_binary.parent().unwrap()).unwrap();
        fs::write(&layout.managed_binary, b"managed helper").unwrap();
        let manifest = InstallManifest {
            schema_version: 1,
            installed_at: "2026-08-01T00:00:00Z".to_owned(),
            app_path: None,
            app_bundle_sha256: None,
            managed_binary: layout.managed_binary.clone(),
            binary_sha256: sha256_file(&layout.managed_binary).unwrap(),
            hook_command: expected_hook_command(&layout.managed_binary),
            codex_shim: layout.codex_shim.clone(),
            manages_codex_shim: false,
            management_link: layout.management_link.clone(),
            editor_extension_id: None,
            editor_extension_targets: Some(Vec::new()),
        };
        fs::create_dir_all(layout.manifest_path.parent().unwrap()).unwrap();
        fs::write(
            &layout.manifest_path,
            serde_json::to_vec(&manifest).unwrap(),
        )
        .unwrap();
        fs::set_permissions(&layout.manifest_path, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            install_manifest_check(&layout, &manifest).status,
            CheckStatus::Pass
        );
        assert_eq!(
            managed_binary_integrity_check(&layout, &manifest).status,
            CheckStatus::Pass
        );

        fs::write(&layout.managed_binary, b"changed helper").unwrap();
        assert_eq!(
            managed_binary_integrity_check(&layout, &manifest).status,
            CheckStatus::Fail
        );
        let mut wrong_path = manifest;
        wrong_path.codex_shim = temp.path().join("other/codex");
        assert_eq!(
            install_manifest_check(&layout, &wrong_path).status,
            CheckStatus::Fail
        );
    }

    #[test]
    fn codex_shim_check_accepts_native_state_and_flags_owned_legacy_interception() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        fs::create_dir_all(layout.managed_binary.parent().unwrap()).unwrap();
        fs::write(&layout.managed_binary, b"managed helper").unwrap();
        let mut manifest = InstallManifest {
            schema_version: 1,
            installed_at: "2026-08-01T00:00:00Z".to_owned(),
            app_path: None,
            app_bundle_sha256: None,
            managed_binary: layout.managed_binary.clone(),
            binary_sha256: sha256_file(&layout.managed_binary).unwrap(),
            hook_command: expected_hook_command(&layout.managed_binary),
            codex_shim: layout.codex_shim.clone(),
            manages_codex_shim: false,
            management_link: layout.management_link.clone(),
            editor_extension_id: None,
            editor_extension_targets: Some(Vec::new()),
        };

        assert_eq!(
            codex_shim_check(&layout, &manifest).status,
            CheckStatus::Pass
        );

        fs::create_dir_all(layout.codex_shim.parent().unwrap()).unwrap();
        std::os::unix::fs::symlink(&layout.managed_binary, &layout.codex_shim).unwrap();
        let leftover = codex_shim_check(&layout, &manifest);
        assert_eq!(leftover.status, CheckStatus::Fail);
        assert!(leftover.detail.contains("legacy Cove interception remains"));

        manifest.manages_codex_shim = true;
        assert_eq!(
            codex_shim_check(&layout, &manifest).status,
            CheckStatus::Pass
        );

        manifest.manages_codex_shim = false;
        fs::remove_file(&layout.codex_shim).unwrap();
        let chained_target = layout.codex_shim.with_file_name("legacy-cove");
        std::os::unix::fs::symlink(&layout.managed_binary, &chained_target).unwrap();
        std::os::unix::fs::symlink("legacy-cove", &layout.codex_shim).unwrap();
        assert_eq!(
            codex_shim_check(&layout, &manifest).status,
            CheckStatus::Fail
        );

        fs::remove_file(&layout.codex_shim).unwrap();
        fs::remove_file(chained_target).unwrap();
        let user_target = temp.path().join("user-codex");
        std::os::unix::fs::symlink(&user_target, &layout.codex_shim).unwrap();
        assert_eq!(
            codex_shim_check(&layout, &manifest).status,
            CheckStatus::Pass
        );
    }

    #[test]
    fn hook_check_requires_exactly_one_owned_handler_in_every_group() {
        let temp = tempdir().unwrap();
        let hooks_path = temp.path().join("hooks.json");
        let command = "'/tmp/codex-cove' hook";
        let mut hooks = crate::install::merged_hooks(serde_json::Map::new(), command).unwrap();
        fs::write(&hooks_path, serde_json::to_vec(&hooks).unwrap()).unwrap();
        assert_eq!(hook_check(&hooks_path, command).status, CheckStatus::Pass);

        let first = hooks
            .pointer_mut("/hooks/SessionStart")
            .and_then(serde_json::Value::as_array_mut)
            .unwrap();
        first.push(serde_json::json!({
            "hooks": [{"type": "command", "command": command, "timeout": 2}]
        }));
        fs::write(&hooks_path, serde_json::to_vec(&hooks).unwrap()).unwrap();
        assert_eq!(hook_check(&hooks_path, command).status, CheckStatus::Fail);
    }

    #[test]
    fn socket_check_requires_current_owner_and_private_mode() {
        let temp = tempdir().unwrap();
        let socket = temp.path().join("events.sock");
        let listener = UnixListener::bind(&socket).unwrap();
        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)).unwrap();
        let uid = unsafe { libc::geteuid() };

        let pass = socket_check_for_uid(&socket, uid);
        assert_eq!(pass.status, CheckStatus::Pass);
        assert!(pass.detail.contains("mode 600"));

        let wrong_owner = socket_check_for_uid(&socket, uid.wrapping_add(1));
        assert_eq!(wrong_owner.status, CheckStatus::Fail);
        assert!(wrong_owner.detail.contains("expected uid"));

        fs::set_permissions(&socket, fs::Permissions::from_mode(0o660)).unwrap();
        let public = socket_check_for_uid(&socket, uid);
        assert_eq!(public.status, CheckStatus::Fail);
        assert!(public.detail.contains("not private"));

        fs::set_permissions(&socket, fs::Permissions::from_mode(0o600)).unwrap();
        drop(listener);
        let stale = socket_check_for_uid(&socket, uid);
        assert_eq!(stale.status, CheckStatus::Fail);
        assert!(stale.detail.contains("no reachable listener"));
    }

    #[cfg(target_os = "macos")]
    #[test]
    fn app_identity_requires_expected_bundle_and_version() {
        let temp = tempdir().unwrap();
        let app = temp.path().join("Codex Cove.app");
        fs::create_dir_all(app.join("Contents")).unwrap();
        fs::write(
            app.join("Contents/Info.plist"),
            format!(
                "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n\
                 <!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n\
                 <plist version=\"1.0\"><dict>\
                 <key>CFBundleIdentifier</key><string>{EXPECTED_APP_BUNDLE_ID}</string>\
                 <key>CFBundleShortVersionString</key><string>{}</string>\
                 </dict></plist>",
                env!("CARGO_PKG_VERSION")
            ),
        )
        .unwrap();
        assert_eq!(app_identity_check(&app).status, CheckStatus::Pass);
        fs::write(
            app.join("Contents/Info.plist"),
            "<plist><dict><key>CFBundleIdentifier</key><string>wrong</string></dict></plist>",
        )
        .unwrap();
        assert_eq!(app_identity_check(&app).status, CheckStatus::Fail);
    }

    #[test]
    fn terminal_permission_checks_are_non_prompting_warnings() {
        let checks = terminal_permission_checks();
        assert_eq!(checks[0].name, "terminalAutomation");
        assert_eq!(checks[1].name, "terminalAccessibility");
        assert!(checks.iter().all(|check| check.status == CheckStatus::Warn));
        assert!(checks[0].detail.contains("not probed"));
        assert!(checks[1].detail.contains("not prompted"));
    }

    #[test]
    fn doctor_warns_when_direct_stdio_is_the_working_fallback() {
        let temp = tempdir().unwrap();
        let codex = temp.path().join("codex");
        fs::write(
            &codex,
            b"#!/bin/sh\n\
              if [ \"$1 $2 $3\" = \"app-server daemon version\" ]; then exit 1; fi\n\
              if [ \"$1 $2\" = \"app-server --help\" ]; then printf '%s\\n' '--stdio stdio://'; exit 0; fi\n\
              exit 1\n",
        )
        .unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

        let check = app_server_transport_check(&codex);
        assert_eq!(check.name, "appServerTransport");
        assert_eq!(check.status, CheckStatus::Warn);
        assert!(check.detail.contains("direct stdio fallback available"));
    }

    #[test]
    fn doctor_fails_only_when_both_app_server_transports_are_unavailable() {
        let temp = tempdir().unwrap();
        let codex = temp.path().join("codex");
        fs::write(&codex, b"#!/bin/sh\nexit 1\n").unwrap();
        fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

        let check = app_server_transport_check(&codex);
        assert_eq!(check.status, CheckStatus::Fail);
        assert!(check.detail.contains("direct stdio fallback unavailable"));
    }
}
