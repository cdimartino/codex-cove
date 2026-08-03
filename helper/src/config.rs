use crate::DEFAULT_MAX_FRAME_BYTES;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;
use std::env;
use std::ffi::CString;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Component, Path, PathBuf};
use tempfile::Builder;

pub const REMOTE_HELPER_PATH: &str = "~/.local/share/codex-cove/current/codex-cove";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Config {
    pub schema_version: u32,
    pub real_codex: Option<PathBuf>,
    pub event_socket: PathBuf,
    pub runtime_directory: PathBuf,
    pub theme_directory: PathBuf,
    pub privacy: PrivacyMode,
    pub hook_timeout_ms: u64,
    pub broker_start_timeout_ms: u64,
    pub max_frame_bytes: usize,
    #[serde(default)]
    pub remote_hosts: Vec<RemoteHost>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum PrivacyMode {
    Auto,
    On,
    Off,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RemoteHost {
    pub alias: String,
    pub helper_path: String,
    pub enabled: bool,
}

impl Config {
    pub fn for_home(home: &Path) -> Self {
        let support = support_directory_for_home(home);
        let runtime = support.join("run");
        Self {
            schema_version: 1,
            real_codex: None,
            event_socket: runtime.join("events.sock"),
            runtime_directory: runtime,
            theme_directory: support.join("Themes"),
            privacy: PrivacyMode::Auto,
            hook_timeout_ms: 1_500,
            broker_start_timeout_ms: 2_000,
            max_frame_bytes: DEFAULT_MAX_FRAME_BYTES,
            remote_hosts: Vec::new(),
        }
    }

    pub fn default_path() -> io::Result<PathBuf> {
        Ok(support_directory()?.join("helper-config.json"))
    }

    pub fn load() -> io::Result<Self> {
        Self::load_from(&Self::default_path()?)
    }

    pub fn load_from(path: &Path) -> io::Result<Self> {
        match fs::symlink_metadata(path) {
            Ok(metadata)
                if metadata.is_file()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == unsafe { libc::geteuid() }
                    && metadata.nlink() == 1
                    && metadata.permissions().mode() & 0o077 == 0
                    && metadata.len() <= 1_048_576 =>
            {
                let expected = (metadata.dev(), metadata.ino());
                let mut file = fs::OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
                    .open(path)?;
                let opened = file.metadata()?;
                if (opened.dev(), opened.ino()) != expected {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        "config changed while it was being opened",
                    ));
                }
                let mut bytes = Vec::with_capacity(metadata.len() as usize);
                file.read_to_end(&mut bytes)?;
                let config: Self = serde_json::from_slice(&bytes)
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                config.validate()?;
                Ok(config)
            }
            Ok(_) => Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "config must be a current-user private regular file with one link and no larger than 1 MiB",
            )),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let home = home_directory()?;
                Ok(Self::for_home(&home))
            }
            Err(error) => Err(error),
        }
    }

    pub fn save(&self) -> io::Result<()> {
        self.save_to(&Self::default_path()?)
    }

    pub fn save_to(&self, path: &Path) -> io::Result<()> {
        self.validate()?;
        let parent = path
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "config has no parent"))?;
        ensure_private_directory(parent)?;
        let parent_metadata = fs::symlink_metadata(parent)?;
        if !parent_metadata.is_dir()
            || parent_metadata.file_type().is_symlink()
            || parent_metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "config parent must be a current-user real directory",
            ));
        }
        fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
        let expected_destination = match fs::symlink_metadata(path) {
            Ok(metadata)
                if metadata.is_file()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == unsafe { libc::geteuid() }
                    && metadata.permissions().mode() & 0o077 == 0 =>
            {
                Some((metadata.dev(), metadata.ino()))
            }
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "existing config must be a current-user private regular file",
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        let mut temporary = Builder::new()
            .prefix(".helper-config.")
            .tempfile_in(parent)?;
        temporary
            .as_file()
            .set_permissions(fs::Permissions::from_mode(0o600))?;
        temporary.write_all(&bytes)?;
        temporary.write_all(b"\n")?;
        temporary.as_file().sync_all()?;
        let temporary_metadata = temporary.as_file().metadata()?;
        let current_destination = match fs::symlink_metadata(path) {
            Ok(metadata) => Some((metadata.dev(), metadata.ino())),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        if current_destination != expected_destination {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "config changed while it was being saved",
            ));
        }
        let staged_original = if let Some(expected) = expected_destination {
            let stage = Builder::new()
                .prefix(".helper-config-stage.")
                .tempdir_in(parent)?;
            fs::set_permissions(stage.path(), fs::Permissions::from_mode(0o700))?;
            let stage_directory = stage.keep();
            let stage_metadata = fs::symlink_metadata(&stage_directory)?;
            let staged_path = stage_directory.join(path.file_name().ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidInput, "config has no file name")
            })?);
            if let Err(error) = rename_noreplace(path, &staged_path) {
                let _ = fs::remove_dir(&stage_directory);
                return Err(error);
            }
            let staged_metadata = fs::symlink_metadata(&staged_path)?;
            if (staged_metadata.dev(), staged_metadata.ino()) != expected {
                let restore = rename_noreplace(&staged_path, path);
                if restore.is_ok() {
                    fs::remove_dir(&stage_directory)?;
                }
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "config changed while it was being staged{}",
                        restore
                            .err()
                            .map(|error| format!(
                                "; raced file retained at {} because restoration failed: {error}",
                                staged_path.display()
                            ))
                            .unwrap_or_default()
                    ),
                ));
            }
            Some((
                staged_path,
                expected,
                stage_directory,
                (stage_metadata.dev(), stage_metadata.ino()),
            ))
        } else {
            if fs::symlink_metadata(path).is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "config appeared while it was being saved",
                ));
            }
            None
        };
        if let Err(error) = temporary.persist_noclobber(path) {
            if let Some((staged, _, directory, _)) = staged_original.as_ref() {
                if let Err(restore_error) = rename_noreplace(staged, path) {
                    return Err(io::Error::other(format!(
                        "{}; original config retained at {} because restoration failed: {restore_error}",
                        error.error,
                        staged.display()
                    )));
                }
                fs::remove_dir(directory)?;
            }
            return Err(error.error);
        }
        let persisted_metadata = fs::symlink_metadata(path)?;
        if persisted_metadata.dev() != temporary_metadata.dev()
            || persisted_metadata.ino() != temporary_metadata.ino()
            || !persisted_metadata.is_file()
            || persisted_metadata.file_type().is_symlink()
        {
            return Err(io::Error::other(
                "persisted config identity does not match its private temporary file",
            ));
        }
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
        if let Some((staged, expected, directory, expected_directory)) = staged_original {
            let metadata = fs::symlink_metadata(&staged)?;
            if (metadata.dev(), metadata.ino()) != expected
                || !metadata.is_file()
                || metadata.file_type().is_symlink()
            {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "original config stage changed; recovery retained at {}",
                        staged.display()
                    ),
                ));
            }
            fs::remove_file(&staged)?;
            let directory_metadata = fs::symlink_metadata(&directory)?;
            if (directory_metadata.dev(), directory_metadata.ino()) != expected_directory
                || !directory_metadata.is_dir()
                || directory_metadata.file_type().is_symlink()
            {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!("config stage directory changed at {}", directory.display()),
                ));
            }
            fs::remove_dir(directory)?;
        }
        Ok(())
    }

    pub fn validate(&self) -> io::Result<()> {
        if self.schema_version != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported config schema {}", self.schema_version),
            ));
        }
        if !(1_024..=16 * 1_048_576).contains(&self.max_frame_bytes) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "maxFrameBytes outside safe range",
            ));
        }
        if !(50..=30_000).contains(&self.hook_timeout_ms) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "hookTimeoutMs outside safe range",
            ));
        }
        if !(250..=120_000).contains(&self.broker_start_timeout_ms) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "brokerStartTimeoutMs outside safe range",
            ));
        }
        if let Some(real_codex) = self.real_codex.as_deref() {
            validate_absolute_clean_path(real_codex, "realCodex")?;
        }
        validate_absolute_clean_path(&self.runtime_directory, "runtimeDirectory")?;
        validate_absolute_clean_path(&self.event_socket, "eventSocket")?;
        validate_absolute_clean_path(&self.theme_directory, "themeDirectory")?;
        if self.event_socket == self.runtime_directory
            || !self.event_socket.starts_with(&self.runtime_directory)
        {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "eventSocket must be inside runtimeDirectory",
            ));
        }

        let mut aliases = BTreeSet::new();
        for host in &self.remote_hosts {
            if host.alias.is_empty()
                || host.alias.len() > 255
                || host.alias.starts_with('-')
                || !host
                    .alias
                    .chars()
                    .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-'))
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "remoteHosts contains an invalid SSH alias",
                ));
            }
            if !aliases.insert(host.alias.as_str()) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "remoteHosts contains a duplicate SSH alias",
                ));
            }
            if host.helper_path != REMOTE_HELPER_PATH {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "remoteHosts contains an unsupported helperPath",
                ));
            }
        }
        Ok(())
    }
}

fn ensure_private_directory(path: &Path) -> io::Result<()> {
    let mut missing = Vec::new();
    let mut current = path;
    loop {
        match fs::symlink_metadata(current) {
            Ok(metadata)
                if metadata.is_dir()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == unsafe { libc::geteuid() } =>
            {
                break;
            }
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!(
                        "config directory component must be a current-user real directory: {}",
                        current.display()
                    ),
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                missing.push(current.to_path_buf());
                current = current.parent().ok_or_else(|| {
                    io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "config path has no current-user directory ancestor",
                    )
                })?;
            }
            Err(error) => return Err(error),
        }
    }
    for directory in missing.into_iter().rev() {
        fs::create_dir(&directory)?;
        fs::set_permissions(&directory, fs::Permissions::from_mode(0o700))?;
        let metadata = fs::symlink_metadata(&directory)?;
        if !metadata.is_dir()
            || metadata.file_type().is_symlink()
            || metadata.uid() != unsafe { libc::geteuid() }
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!(
                    "created config directory is unsafe: {}",
                    directory.display()
                ),
            ));
        }
    }
    Ok(())
}

fn rename_noreplace(source: &Path, destination: &Path) -> io::Result<()> {
    let source = CString::new(source.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "source path contains NUL"))?;
    let destination = CString::new(destination.as_os_str().as_bytes()).map_err(|_| {
        io::Error::new(io::ErrorKind::InvalidInput, "destination path contains NUL")
    })?;
    #[cfg(target_os = "macos")]
    let result = unsafe {
        libc::renameatx_np(
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            libc::RENAME_EXCL,
        )
    };
    #[cfg(target_os = "linux")]
    let result = unsafe {
        libc::syscall(
            libc::SYS_renameat2,
            libc::AT_FDCWD,
            source.as_ptr(),
            libc::AT_FDCWD,
            destination.as_ptr(),
            libc::RENAME_NOREPLACE,
        ) as libc::c_int
    };
    #[cfg(not(any(target_os = "macos", target_os = "linux")))]
    let result = -1;
    if result == 0 {
        Ok(())
    } else {
        #[cfg(not(any(target_os = "macos", target_os = "linux")))]
        return Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "no-replace rename is unsupported on this platform",
        ));
        #[cfg(any(target_os = "macos", target_os = "linux"))]
        return Err(io::Error::last_os_error());
    }
}

fn validate_absolute_clean_path(path: &Path, field: &str) -> io::Result<()> {
    if !path.is_absolute()
        || path.as_os_str().as_bytes().contains(&0)
        || path
            .components()
            .any(|component| matches!(component, Component::CurDir | Component::ParentDir))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} must be an absolute normalized path"),
        ));
    }
    Ok(())
}

pub fn home_directory() -> io::Result<PathBuf> {
    if let Some(path) = env::var_os("CODEX_COVE_HOME") {
        return Ok(PathBuf::from(path));
    }
    env::var_os("HOME")
        .map(PathBuf::from)
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "HOME missing; set CODEX_COVE_HOME"))
}

pub fn support_directory() -> io::Result<PathBuf> {
    Ok(support_directory_for_home(&home_directory()?))
}

pub fn support_directory_for_home(home: &Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home.join("Library/Application Support/Codex Cove")
    }
    #[cfg(not(target_os = "macos"))]
    {
        home.join(".local/share/codex-cove")
    }
}

pub fn user_bin_directory_for_home(home: &Path) -> PathBuf {
    #[cfg(target_os = "macos")]
    {
        home.join("bin")
    }
    #[cfg(not(target_os = "macos"))]
    {
        home.join(".local/bin")
    }
}

pub fn find_real_codex(config: &Config, current_executable: &Path) -> io::Result<PathBuf> {
    if let Some(value) = env::var_os("CODEX_COVE_REAL_CODEX")
        && let Ok(path) = validate_executable(PathBuf::from(value), current_executable)
    {
        return Ok(path);
    }
    if let Some(path) = &config.real_codex
        && let Ok(path) = validate_executable(path.clone(), current_executable)
    {
        return Ok(path);
    }

    find_real_codex_on_path(current_executable)
}

pub fn find_real_codex_without_config(current_executable: &Path) -> io::Result<PathBuf> {
    if let Some(value) = env::var_os("CODEX_COVE_REAL_CODEX") {
        if let Ok(path) = validate_executable(PathBuf::from(value), current_executable) {
            return Ok(path);
        }
    }

    find_real_codex_on_path(current_executable)
}

pub fn find_real_codex_on_path(current_executable: &Path) -> io::Result<PathBuf> {
    let search_path = env::var_os("PATH")
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "PATH missing"))?;
    for directory in env::split_paths(&search_path) {
        let candidate = directory.join("codex");
        if !candidate.is_file() {
            continue;
        }
        let canonical = fs::canonicalize(&candidate).unwrap_or(candidate.clone());
        if !resolves_to_cove_helper(&canonical, current_executable) && is_executable(&candidate) {
            return Ok(canonical);
        }
    }
    Err(io::Error::new(
        io::ErrorKind::NotFound,
        "real Codex CLI not found; set CODEX_COVE_REAL_CODEX",
    ))
}

fn validate_executable(path: PathBuf, current: &Path) -> io::Result<PathBuf> {
    if !path.is_absolute() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "real Codex path must be absolute",
        ));
    }
    if !is_executable(&path) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("real Codex is not executable: {}", path.display()),
        ));
    }
    let canonical = fs::canonicalize(&path)?;
    if resolves_to_cove_helper(&canonical, current) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "real Codex path resolves to Codex Cove shim",
        ));
    }
    Ok(canonical)
}

fn resolves_to_cove_helper(candidate: &Path, current: &Path) -> bool {
    let candidate = fs::canonicalize(candidate).unwrap_or_else(|_| candidate.to_path_buf());
    let current = fs::canonicalize(current).unwrap_or_else(|_| current.to_path_buf());
    if candidate == current
        || candidate.file_name().and_then(|name| name.to_str()) == Some("codex-cove")
    {
        return true;
    }

    let Ok(home) = home_directory() else {
        return false;
    };
    let known_helpers = [
        support_directory_for_home(&home).join("bin/codex-cove"),
        user_bin_directory_for_home(&home).join("codex-cove"),
        user_bin_directory_for_home(&home).join("codex"),
    ];
    known_helpers.into_iter().any(|path| {
        fs::canonicalize(&path)
            .map(|path| path == candidate)
            .unwrap_or(path == candidate)
    })
}

pub fn is_executable(path: &Path) -> bool {
    path.metadata()
        .map(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::Mutex;
    use tempfile::tempdir;

    static ENVIRONMENT_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn round_trips_config_with_private_permissions() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("support/config.json");
        let mut config = Config::for_home(temp.path());
        config.privacy = PrivacyMode::On;
        config.save_to(&path).unwrap();
        assert_eq!(Config::load_from(&path).unwrap(), config);
        config.privacy = PrivacyMode::Off;
        config.save_to(&path).unwrap();
        assert_eq!(Config::load_from(&path).unwrap(), config);
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        let entries = fs::read_dir(path.parent().unwrap())
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .collect::<Vec<_>>();
        assert_eq!(entries, [path.file_name().unwrap()]);
    }

    #[test]
    fn rejects_unsafe_frame_limit() {
        let temp = tempdir().unwrap();
        let path = temp.path().join("config.json");
        let mut config = Config::for_home(temp.path());
        config.max_frame_bytes = usize::MAX;
        assert!(config.save_to(&path).is_err());
    }

    #[test]
    fn load_rejects_a_symlinked_config_without_reading_its_target() {
        let temp = tempdir().unwrap();
        let target = temp.path().join("target.json");
        let link = temp.path().join("config.json");
        fs::write(&target, b"not a Cove config").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        std::os::unix::fs::symlink(&target, &link).unwrap();

        let error = Config::load_from(&link).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read(&target).unwrap(), b"not a Cove config");
    }

    #[test]
    fn save_rejects_a_symlinked_parent_without_mutating_its_target() {
        let temp = tempdir().unwrap();
        let external = temp.path().join("external");
        let linked_parent = temp.path().join("support");
        fs::create_dir(&external).unwrap();
        fs::write(external.join("sentinel"), b"untouched").unwrap();
        std::os::unix::fs::symlink(&external, &linked_parent).unwrap();
        let config = Config::for_home(temp.path());

        let error = config
            .save_to(&linked_parent.join("helper-config.json"))
            .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read(external.join("sentinel")).unwrap(), b"untouched");
        assert!(!external.join("helper-config.json").exists());
    }

    #[test]
    fn refuses_real_codex_that_resolves_to_shim() {
        let _environment = ENVIRONMENT_LOCK.lock().unwrap();
        let temp = tempdir().unwrap();
        let shim = temp.path().join("codex-cove");
        fs::write(&shim, b"binary").unwrap();
        fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();
        let mut config = Config::for_home(temp.path());
        config.real_codex = Some(shim.clone());
        let old_path = env::var_os("PATH");
        let old_override = env::var_os("CODEX_COVE_REAL_CODEX");
        // SAFETY: this test is single-threaded with respect to its temporary
        // process environment and restores the value before returning.
        unsafe {
            env::set_var("PATH", temp.path());
            env::remove_var("CODEX_COVE_REAL_CODEX");
        }
        assert!(find_real_codex(&config, &shim).is_err());
        if let Some(path) = old_path {
            // SAFETY: see the note above.
            unsafe { env::set_var("PATH", path) };
        } else {
            // SAFETY: see the note above.
            unsafe { env::remove_var("PATH") };
        }
        if let Some(value) = old_override {
            // SAFETY: see the note above.
            unsafe { env::set_var("CODEX_COVE_REAL_CODEX", value) };
        }
    }

    #[test]
    fn stale_recorded_binary_falls_back_to_path() {
        let _environment = ENVIRONMENT_LOCK.lock().unwrap();
        let temp = tempdir().unwrap();
        let shim = temp.path().join("shim/codex");
        let real = temp.path().join("real/codex");
        fs::create_dir_all(shim.parent().unwrap()).unwrap();
        fs::create_dir_all(real.parent().unwrap()).unwrap();
        fs::write(&shim, b"shim").unwrap();
        fs::write(&real, b"real").unwrap();
        fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();
        fs::set_permissions(&real, fs::Permissions::from_mode(0o755)).unwrap();
        let mut config = Config::for_home(temp.path());
        config.real_codex = Some(temp.path().join("missing-codex"));
        let old_path = env::var_os("PATH");
        let old_override = env::var_os("CODEX_COVE_REAL_CODEX");
        // SAFETY: this test restores the process environment before returning.
        unsafe {
            env::set_var("PATH", real.parent().unwrap());
            env::remove_var("CODEX_COVE_REAL_CODEX");
        }
        assert_eq!(
            find_real_codex(&config, &shim).unwrap(),
            fs::canonicalize(real).unwrap()
        );
        if let Some(path) = old_path {
            // SAFETY: see the note above.
            unsafe { env::set_var("PATH", path) };
        } else {
            // SAFETY: see the note above.
            unsafe { env::remove_var("PATH") };
        }
        if let Some(value) = old_override {
            // SAFETY: see the note above.
            unsafe { env::set_var("CODEX_COVE_REAL_CODEX", value) };
        }
    }

    #[test]
    fn path_search_skips_a_stale_managed_cove_shim() {
        let _environment = ENVIRONMENT_LOCK.lock().unwrap();
        let temp = tempdir().unwrap();
        let old_bin = temp.path().join("old-bin");
        let real_bin = temp.path().join("real-bin");
        fs::create_dir_all(&old_bin).unwrap();
        fs::create_dir_all(&real_bin).unwrap();
        let old_helper = old_bin.join("codex-cove");
        let old_shim = old_bin.join("codex");
        let real = real_bin.join("codex");
        let current = temp.path().join("new-package-helper");
        for path in [&old_helper, &real, &current] {
            fs::write(path, b"binary").unwrap();
            fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
        }
        std::os::unix::fs::symlink(&old_helper, &old_shim).unwrap();

        let old_path = env::var_os("PATH");
        let search_path = env::join_paths([old_bin, real_bin]).unwrap();
        // SAFETY: this test serializes and restores the process environment.
        unsafe { env::set_var("PATH", search_path) };
        assert_eq!(
            find_real_codex_on_path(&current).unwrap(),
            fs::canonicalize(real).unwrap()
        );
        if let Some(path) = old_path {
            // SAFETY: see the note above.
            unsafe { env::set_var("PATH", path) };
        } else {
            // SAFETY: see the note above.
            unsafe { env::remove_var("PATH") };
        }
    }
}
