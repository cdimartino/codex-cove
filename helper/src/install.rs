use crate::config::{
    Config, home_directory, support_directory_for_home, user_bin_directory_for_home,
};
use crate::format_rfc3339;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use sha2::{Digest, Sha256};
use std::collections::BTreeSet;
use std::ffi::{CStr, CString};
use std::fs;
use std::io::{self, Read, Write};
use std::mem::MaybeUninit;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::ffi::OsStrExt;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt, symlink};
use std::path::{Path, PathBuf};
use tempfile::Builder;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ManagedPathKind {
    File,
    Directory,
    Symlink,
    Other,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct PathIdentity {
    device: u64,
    inode: u64,
    owner: u32,
    kind: ManagedPathKind,
}

impl PathIdentity {
    fn capture(path: &Path) -> io::Result<Option<Self>> {
        match fs::symlink_metadata(path) {
            Ok(metadata) => Ok(Some(Self::from_metadata(&metadata))),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error),
        }
    }

    fn from_metadata(metadata: &fs::Metadata) -> Self {
        let file_type = metadata.file_type();
        let kind = if file_type.is_symlink() {
            ManagedPathKind::Symlink
        } else if metadata.is_file() {
            ManagedPathKind::File
        } else if metadata.is_dir() {
            ManagedPathKind::Directory
        } else {
            ManagedPathKind::Other
        };
        Self {
            device: metadata.dev(),
            inode: metadata.ino(),
            owner: metadata.uid(),
            kind,
        }
    }

    fn require_current(&self, path: &Path, context: &str) -> io::Result<()> {
        match Self::capture(path)? {
            Some(current) if current == *self => Ok(()),
            Some(_) => Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("{context} changed identity at {}", path.display()),
            )),
            None => Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!("{context} disappeared at {}", path.display()),
            )),
        }
    }
}

#[derive(Debug, Clone)]
enum PathSnapshot {
    Absent,
    File {
        bytes: Vec<u8>,
        mode: u32,
        identity: PathIdentity,
    },
    Symlink {
        target: PathBuf,
        identity: PathIdentity,
    },
}

impl PathSnapshot {
    fn capture(path: &Path) -> io::Result<Self> {
        match fs::symlink_metadata(path) {
            Ok(metadata) if metadata.file_type().is_symlink() => {
                let identity = PathIdentity::from_metadata(&metadata);
                let target = fs::read_link(path)?;
                identity.require_current(path, "snapshot symlink")?;
                Ok(Self::Symlink { target, identity })
            }
            Ok(metadata) if metadata.is_file() => {
                let identity = PathIdentity::from_metadata(&metadata);
                let mut file = fs::OpenOptions::new()
                    .read(true)
                    .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
                    .open(path)?;
                if PathIdentity::from_metadata(&file.metadata()?) != identity {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!("snapshot source changed at {}", path.display()),
                    ));
                }
                let mut bytes = Vec::new();
                file.read_to_end(&mut bytes)?;
                Ok(Self::File {
                    bytes,
                    mode: metadata.permissions().mode() & 0o777,
                    identity,
                })
            }
            Ok(_) => Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("refusing transactional snapshot of {}", path.display()),
            )),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Self::Absent),
            Err(error) => Err(error),
        }
    }

    fn identity(&self) -> Option<PathIdentity> {
        match self {
            Self::Absent => None,
            Self::File { identity, .. } | Self::Symlink { identity, .. } => Some(*identity),
        }
    }

    fn preserve_recovery_copy(&self, path: &Path) -> io::Result<Option<PathBuf>> {
        match self {
            Self::Absent => Ok(None),
            Self::File { bytes, mode, .. } => {
                let mut temporary = exclusive_temporary_file(path, "install-recovery", *mode)?;
                temporary.write_all(bytes)?;
                temporary.as_file().sync_all()?;
                let (_, recovery) = temporary.keep().map_err(|error| error.error)?;
                Ok(Some(recovery))
            }
            Self::Symlink { target, .. } => {
                let recovery = unique_sibling_path(path, "install-recovery")?;
                symlink(target, &recovery)?;
                Ok(Some(recovery))
            }
        }
    }
}

#[derive(Debug)]
struct InstallSnapshot {
    paths: Vec<InstallPathSnapshot>,
    directories: Vec<DirectorySnapshot>,
}

#[derive(Debug)]
struct InstallPathSnapshot {
    path: PathBuf,
    original: PathSnapshot,
    staged_original: Option<OwnedStage>,
    replacement: Option<PathIdentity>,
}

#[derive(Debug)]
struct OwnedStage {
    payload: PathBuf,
    payload_identity: PathIdentity,
    directory: PathBuf,
    directory_identity: PathIdentity,
}

#[derive(Debug)]
struct StageReservation {
    payload: PathBuf,
    directory: PathBuf,
    directory_identity: PathIdentity,
}

#[derive(Debug)]
struct DirectorySnapshot {
    path: PathBuf,
    original: Option<(PathIdentity, u32)>,
    created: Option<PathIdentity>,
}

impl InstallSnapshot {
    fn capture(layout: &InstallLayout) -> io::Result<Self> {
        let paths = [
            &layout.managed_binary,
            &layout.config_path,
            &layout.hooks_path,
            &layout.codex_shim,
            &layout.management_link,
            &layout.manifest_path,
        ]
        .into_iter()
        .map(|path| {
            Ok(InstallPathSnapshot {
                path: path.clone(),
                original: PathSnapshot::capture(path)?,
                staged_original: None,
                replacement: None,
            })
        })
        .collect::<io::Result<Vec<_>>>()?;
        let directories = managed_directory_paths(layout)?
            .into_iter()
            .map(DirectorySnapshot::capture)
            .collect::<io::Result<Vec<_>>>()?;
        Ok(Self { paths, directories })
    }

    fn record_replacement(&mut self, path: &Path, expected: PathIdentity) -> io::Result<()> {
        let entry = self
            .paths
            .iter_mut()
            .find(|entry| entry.path == path)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("untracked install mutation at {}", path.display()),
                )
            })?;
        expected.require_current(path, "install replacement")?;
        entry.replacement = Some(expected);
        Ok(())
    }

    fn stage_original(&mut self, path: &Path) -> io::Result<()> {
        let entry = self
            .paths
            .iter_mut()
            .find(|entry| entry.path == path)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "untracked install path"))?;
        if entry.staged_original.is_some() {
            return Ok(());
        }
        let Some(expected) = entry.original.identity() else {
            return match PathIdentity::capture(path)? {
                None => Ok(()),
                Some(_) => Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!("managed path appeared during install: {}", path.display()),
                )),
            };
        };
        expected.require_current(path, "install stage source")?;
        let staged = reserve_sibling_stage(path, "install-stage")?;
        if let Err(error) = rename_noreplace(path, &staged.payload) {
            let cleanup = remove_stage_directory(&staged.directory, staged.directory_identity);
            return match cleanup {
                Ok(()) => Err(error),
                Err(cleanup_error) => Err(io::Error::other(format!(
                    "{error}; empty install stage cleanup also failed: {cleanup_error}"
                ))),
            };
        }
        match PathIdentity::capture(&staged.payload)? {
            Some(actual) if actual == expected => {
                entry.staged_original = Some(OwnedStage {
                    payload: staged.payload,
                    payload_identity: expected,
                    directory: staged.directory,
                    directory_identity: staged.directory_identity,
                });
                Ok(())
            }
            actual => {
                let restore = rename_noreplace(&staged.payload, path);
                if restore.is_ok() {
                    remove_stage_directory(&staged.directory, staged.directory_identity)?;
                }
                Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "managed path changed while staging {} (expected {expected:?}, found {actual:?}){}",
                        path.display(),
                        restore
                            .err()
                            .map(|error| format!(
                                "; raced object retained at {} because restoration failed: {error}",
                                staged.payload.display()
                            ))
                            .unwrap_or_default()
                    ),
                ))
            }
        }
    }

    fn ensure_directory(&mut self, target: &Path, created_mode: u32) -> io::Result<()> {
        let mut indexes = self
            .directories
            .iter()
            .enumerate()
            .filter(|(_, directory)| target.starts_with(&directory.path))
            .map(|(index, directory)| (index, directory.path.components().count()))
            .collect::<Vec<_>>();
        indexes.sort_by_key(|(_, depth)| *depth);
        for (index, _) in indexes {
            let path = self.directories[index].path.clone();
            let expected = self.directories[index].created.or_else(|| {
                self.directories[index]
                    .original
                    .map(|(identity, _)| identity)
            });
            match (PathIdentity::capture(&path)?, expected) {
                (Some(current), Some(expected)) if current == expected => {}
                (Some(_), Some(_)) => {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!(
                            "managed directory changed during install: {}",
                            path.display()
                        ),
                    ));
                }
                (Some(_), None) => {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!(
                            "managed directory appeared during install: {}",
                            path.display()
                        ),
                    ));
                }
                (None, Some(_)) => {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        format!(
                            "managed directory disappeared during install: {}",
                            path.display()
                        ),
                    ));
                }
                (None, None) => {
                    fs::create_dir(&path)?;
                    fs::set_permissions(&path, fs::Permissions::from_mode(created_mode))?;
                    self.directories[index].record_created()?;
                }
            }
        }
        Ok(())
    }

    fn restore(&self, created_artifacts: &[CreatedArtifact]) -> io::Result<()> {
        let mut first_error = None;
        for entry in self.paths.iter().rev() {
            if let Err(error) = entry.restore() {
                record_first_error(&mut first_error, error);
            }
        }
        for artifact in created_artifacts.iter().rev() {
            if let Err(error) = artifact.remove() {
                record_first_error(&mut first_error, error);
            }
        }
        for directory in self.directories.iter().rev() {
            if let Err(error) = directory.restore() {
                record_first_error(&mut first_error, error);
            }
        }
        if let Some(error) = first_error {
            Err(error)
        } else {
            Ok(())
        }
    }

    fn validate_commit(&self) -> io::Result<()> {
        for entry in &self.paths {
            if entry.staged_original.is_none() && entry.replacement.is_none() {
                if PathIdentity::capture(&entry.path)? != entry.original.identity() {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!(
                            "untouched install path changed before commit: {}",
                            entry.path.display()
                        ),
                    ));
                }
                continue;
            }
            if PathIdentity::capture(&entry.path)? != entry.replacement {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "install destination changed before commit: {}",
                        entry.path.display()
                    ),
                ));
            }
            if let Some(stage) = entry.staged_original.as_ref() {
                stage
                    .payload_identity
                    .require_current(&stage.payload, "install commit original")?;
                stage
                    .directory_identity
                    .require_current(&stage.directory, "install commit stage directory")?;
            }
        }
        for directory in &self.directories {
            let expected = directory
                .created
                .or_else(|| directory.original.map(|(identity, _)| identity));
            if PathIdentity::capture(&directory.path)? != expected {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "install directory changed before commit: {}",
                        directory.path.display()
                    ),
                ));
            }
        }
        Ok(())
    }

    fn commit(&self) -> io::Result<()> {
        let mut first_error = None;
        for entry in &self.paths {
            if let Some(stage) = entry.staged_original.as_ref()
                && let Err(error) = stage.remove_payload_and_directory("install commit original")
            {
                record_first_error(&mut first_error, error);
            }
        }
        if let Some(error) = first_error {
            Err(error)
        } else {
            Ok(())
        }
    }
}

impl InstallPathSnapshot {
    fn restore(&self) -> io::Result<()> {
        let current = PathIdentity::capture(&self.path)?;
        if self.staged_original.is_none() && self.replacement.is_none() {
            return Ok(());
        }

        if current != self.replacement {
            let recovery = self
                .staged_original
                .as_ref()
                .map(|stage| stage.payload.clone())
                .or(self.original.preserve_recovery_copy(&self.path)?);
            return Err(concurrent_install_change_error(&self.path, recovery));
        }
        let quarantined = self
            .replacement
            .map(|replacement| {
                quarantine_verified_leaf(&self.path, replacement, "install-rollback-replacement")
            })
            .transpose()?;
        if let Some(stage) = self.staged_original.as_ref() {
            stage
                .payload_identity
                .require_current(&stage.payload, "install rollback original")?;
            if let Err(error) = rename_noreplace(&stage.payload, &self.path) {
                if let Some(quarantined) = quarantined.as_ref() {
                    let _ = restore_quarantined_leaf(quarantined, &self.path);
                }
                return Err(io::Error::new(
                    error.kind(),
                    format!(
                        "could not restore {}: {error}; original retained at {}",
                        self.path.display(),
                        stage.payload.display()
                    ),
                ));
            }
            stage.remove_empty_directory()?;
        }
        if let Some(quarantined) = quarantined {
            quarantined.remove_payload_and_directory("install rollback quarantine")?;
        }
        Ok(())
    }
}

impl OwnedStage {
    fn remove_empty_directory(&self) -> io::Result<()> {
        remove_stage_directory(&self.directory, self.directory_identity)
    }

    fn remove_payload_and_directory(&self, context: &str) -> io::Result<()> {
        remove_verified_leaf(&self.payload, self.payload_identity, context)?;
        self.remove_empty_directory()
    }
}

impl DirectorySnapshot {
    fn capture(path: PathBuf) -> io::Result<Self> {
        let original = match fs::symlink_metadata(&path) {
            Ok(metadata)
                if metadata.is_dir()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == unsafe { libc::geteuid() } =>
            {
                Some((
                    PathIdentity::from_metadata(&metadata),
                    metadata.permissions().mode() & 0o777,
                ))
            }
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!(
                        "managed directory path must be a current-user real directory: {}",
                        path.display()
                    ),
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        Ok(Self {
            path,
            original,
            created: None,
        })
    }

    fn record_created(&mut self) -> io::Result<()> {
        if self.original.is_some() || self.created.is_some() {
            return Ok(());
        }
        let identity = PathIdentity::capture(&self.path)?.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("created directory is unavailable: {}", self.path.display()),
            )
        })?;
        if identity.kind != ManagedPathKind::Directory
            || identity.owner != unsafe { libc::geteuid() }
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("created directory is unsafe: {}", self.path.display()),
            ));
        }
        self.created = Some(identity);
        Ok(())
    }

    fn restore(&self) -> io::Result<()> {
        if let Some((identity, mode)) = self.original {
            identity.require_current(&self.path, "managed directory")?;
            return fs::set_permissions(&self.path, fs::Permissions::from_mode(mode));
        }
        let Some(created) = self.created else {
            return match PathIdentity::capture(&self.path)? {
                None => Ok(()),
                Some(_) => Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "concurrent directory creation preserved at {}",
                        self.path.display()
                    ),
                )),
            };
        };
        match PathIdentity::capture(&self.path)? {
            None => Ok(()),
            Some(current) if current == created => fs::remove_dir(&self.path).map_err(|error| {
                io::Error::new(
                    error.kind(),
                    format!(
                        "created directory was retained at {}: {error}",
                        self.path.display()
                    ),
                )
            }),
            Some(_) => Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!(
                    "concurrent directory replacement preserved at {}",
                    self.path.display()
                ),
            )),
        }
    }
}

#[derive(Debug)]
struct CreatedArtifact {
    path: PathBuf,
    identity: PathIdentity,
}

impl CreatedArtifact {
    fn capture(path: PathBuf) -> io::Result<Self> {
        let identity = PathIdentity::capture(&path)?.ok_or_else(|| {
            io::Error::new(io::ErrorKind::NotFound, "created artifact disappeared")
        })?;
        if identity.kind != ManagedPathKind::File || identity.owner != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "created artifact is not a current-user regular file",
            ));
        }
        Ok(Self { path, identity })
    }

    fn remove(&self) -> io::Result<()> {
        remove_verified_leaf(&self.path, self.identity, "install rollback artifact")
    }
}

fn concurrent_install_change_error(path: &Path, recovery: Option<PathBuf>) -> io::Error {
    io::Error::new(
        io::ErrorKind::AlreadyExists,
        format!(
            "concurrent replacement preserved at {}{}",
            path.display(),
            recovery
                .as_ref()
                .map(|path| format!("; original retained at {}", path.display()))
                .unwrap_or_default()
        ),
    )
}

fn record_first_error(slot: &mut Option<io::Error>, error: io::Error) {
    if slot.is_none() {
        *slot = Some(error);
    }
}

fn managed_directory_paths(layout: &InstallLayout) -> io::Result<Vec<PathBuf>> {
    let targets = [
        layout.support.clone(),
        layout
            .managed_binary
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "helper has no parent"))?
            .to_path_buf(),
        layout
            .hooks_path
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "hooks have no parent"))?
            .to_path_buf(),
        layout
            .codex_shim
            .parent()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "shim has no parent"))?
            .to_path_buf(),
    ];
    let mut paths = BTreeSet::new();
    for target in targets {
        let relative = target.strip_prefix(&layout.home).map_err(|_| {
            io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("managed directory is outside HOME: {}", target.display()),
            )
        })?;
        let mut current = layout.home.clone();
        for component in relative.components() {
            current.push(component.as_os_str());
            paths.insert(current.clone());
        }
    }
    let mut paths = paths.into_iter().collect::<Vec<_>>();
    paths.sort_by(|left, right| {
        left.components()
            .count()
            .cmp(&right.components().count())
            .then_with(|| {
                left.as_os_str()
                    .as_bytes()
                    .cmp(right.as_os_str().as_bytes())
            })
    });
    Ok(paths)
}

fn exclusive_temporary_file(
    destination: &Path,
    purpose: &str,
    mode: u32,
) -> io::Result<tempfile::NamedTempFile> {
    let parent = destination.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "temporary destination has no parent",
        )
    })?;
    let temporary = Builder::new()
        .prefix(&format!(".codex-cove-{purpose}."))
        .tempfile_in(parent)?;
    temporary
        .as_file()
        .set_permissions(fs::Permissions::from_mode(mode))?;
    let metadata = temporary.as_file().metadata()?;
    if !metadata.is_file() || metadata.uid() != unsafe { libc::geteuid() } || metadata.nlink() != 1
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "exclusive temporary file is unsafe",
        ));
    }
    Ok(temporary)
}

fn unique_sibling_path(path: &Path, purpose: &str) -> io::Result<PathBuf> {
    Ok(reserve_sibling_stage(path, purpose)?.payload)
}

fn reserve_sibling_stage(path: &Path, purpose: &str) -> io::Result<StageReservation> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no parent"))?;
    let directory = Builder::new()
        .prefix(&format!(".codex-cove-{purpose}."))
        .tempdir_in(parent)?;
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700))?;
    let directory = directory.keep();
    let directory_identity = PathIdentity::capture(&directory)?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "exclusive stage directory disappeared",
        )
    })?;
    if directory_identity.kind != ManagedPathKind::Directory
        || directory_identity.owner != unsafe { libc::geteuid() }
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "exclusive stage directory is unsafe",
        ));
    }
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    Ok(StageReservation {
        payload: directory.join(name),
        directory,
        directory_identity,
    })
}

fn remove_stage_directory(path: &Path, expected: PathIdentity) -> io::Result<()> {
    expected.require_current(path, "private stage directory")?;
    fs::remove_dir(path)
}

fn quarantine_verified_leaf(
    path: &Path,
    expected: PathIdentity,
    purpose: &str,
) -> io::Result<OwnedStage> {
    if !matches!(
        expected.kind,
        ManagedPathKind::File | ManagedPathKind::Symlink
    ) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("refusing to quarantine non-leaf {}", path.display()),
        ));
    }
    expected.require_current(path, "quarantine source")?;
    let reservation = reserve_sibling_stage(path, purpose)?;
    if let Err(error) = rename_noreplace(path, &reservation.payload) {
        let cleanup =
            remove_stage_directory(&reservation.directory, reservation.directory_identity);
        return match cleanup {
            Ok(()) => Err(error),
            Err(cleanup_error) => Err(io::Error::other(format!(
                "{error}; empty quarantine cleanup also failed: {cleanup_error}"
            ))),
        };
    }
    if PathIdentity::capture(&reservation.payload)? != Some(expected) {
        let restore = rename_noreplace(&reservation.payload, path);
        if restore.is_ok() {
            remove_stage_directory(&reservation.directory, reservation.directory_identity)?;
        }
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!(
                "quarantine source changed identity{}",
                restore
                    .err()
                    .map(|error| format!(
                        "; raced object retained at {} because restoration failed: {error}",
                        reservation.payload.display()
                    ))
                    .unwrap_or_default()
            ),
        ));
    }
    Ok(OwnedStage {
        payload: reservation.payload,
        payload_identity: expected,
        directory: reservation.directory,
        directory_identity: reservation.directory_identity,
    })
}

fn restore_quarantined_leaf(stage: &OwnedStage, destination: &Path) -> io::Result<()> {
    stage
        .payload_identity
        .require_current(&stage.payload, "quarantined replacement")?;
    rename_noreplace(&stage.payload, destination)?;
    stage.remove_empty_directory()
}

fn remove_verified_leaf(path: &Path, expected: PathIdentity, context: &str) -> io::Result<()> {
    expected.require_current(path, context)?;
    if !matches!(
        expected.kind,
        ManagedPathKind::File | ManagedPathKind::Symlink
    ) {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "refusing recursive removal of unverified {}",
                path.display()
            ),
        ));
    }
    fs::remove_file(path)
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

pub(crate) const HOOK_EVENTS: &[&str] = &[
    "SessionStart",
    "PermissionRequest",
    "PreToolUse",
    "PostToolUse",
    "PreCompact",
    "PostCompact",
    "SubagentStart",
    "SubagentStop",
    "UserPromptSubmit",
    "Stop",
    "SessionEnd",
];

pub const SUPPORTED_EDITOR_TARGETS: &[&str] = &["code", "cursor"];

#[derive(Debug, Clone)]
pub struct InstallLayout {
    pub home: PathBuf,
    pub support: PathBuf,
    pub managed_binary: PathBuf,
    pub config_path: PathBuf,
    pub manifest_path: PathBuf,
    pub hooks_path: PathBuf,
    pub codex_shim: PathBuf,
    pub management_link: PathBuf,
}

impl InstallLayout {
    pub fn for_home(home: &Path) -> Self {
        let support = support_directory_for_home(home);
        let managed_binary = support.join("bin/codex-cove");
        let user_bin = user_bin_directory_for_home(home);
        Self {
            home: home.to_path_buf(),
            config_path: support.join("helper-config.json"),
            manifest_path: support.join("install-manifest.json"),
            hooks_path: home.join(".codex/hooks.json"),
            codex_shim: user_bin.join("codex"),
            management_link: user_bin.join("codex-cove"),
            support,
            managed_binary,
        }
    }

    pub fn current() -> io::Result<Self> {
        Ok(Self::for_home(&home_directory()?))
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MutationPlan {
    pub operation: String,
    pub blocked: bool,
    pub actions: Vec<PlannedAction>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlannedAction {
    pub kind: String,
    pub path: PathBuf,
    pub detail: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InstallManifest {
    pub schema_version: u32,
    pub installed_at: String,
    pub app_path: Option<PathBuf>,
    #[serde(default)]
    pub app_bundle_sha256: Option<String>,
    pub managed_binary: PathBuf,
    pub binary_sha256: String,
    pub hook_command: String,
    pub codex_shim: PathBuf,
    pub management_link: PathBuf,
    pub editor_extension_id: Option<String>,
    /// `None` is the schema-1 legacy representation: the extension ID was
    /// recorded, but the installer did not record which supported editors it
    /// reached. Uninstall must conservatively verify every supported editor in
    /// that case. New manifests always write `Some`, including an empty list.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub editor_extension_targets: Option<Vec<String>>,
}

impl InstallManifest {
    pub fn editor_cleanup_targets(&self) -> io::Result<Vec<String>> {
        let Some(extension_id) = self.editor_extension_id.as_deref() else {
            if self
                .editor_extension_targets
                .as_ref()
                .is_some_and(|targets| !targets.is_empty())
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "manifest records editor targets without an extension identifier",
                ));
            }
            return Ok(Vec::new());
        };
        if extension_id.trim().is_empty() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "manifest editor extension identifier is empty",
            ));
        }

        let Some(recorded) = self.editor_extension_targets.as_ref() else {
            return Ok(SUPPORTED_EDITOR_TARGETS
                .iter()
                .map(|target| (*target).to_owned())
                .collect());
        };
        let mut canonical = Vec::new();
        for target in recorded {
            if !SUPPORTED_EDITOR_TARGETS.contains(&target.as_str()) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("manifest records unsupported editor target {target}"),
                ));
            }
            if canonical.contains(target) {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("manifest records duplicate editor target {target}"),
                ));
            }
            canonical.push(target.clone());
        }
        Ok(canonical)
    }
}

#[derive(Debug, Clone)]
pub struct UninstallPreflight {
    manifest: InstallManifest,
    removable_app: Option<PathBuf>,
    hooks_present: bool,
    identities: Vec<(PathBuf, Option<PathIdentity>)>,
}

impl UninstallPreflight {
    pub fn manifest(&self) -> &InstallManifest {
        &self.manifest
    }

    pub fn removable_app(&self) -> Option<&Path> {
        self.removable_app.as_deref()
    }

    pub fn validate_removable_app(&self) -> io::Result<()> {
        let Some(app_path) = self.removable_app.as_deref() else {
            return Ok(());
        };
        self.identity_for(app_path)?
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "installed app disappeared"))?
            .require_current(app_path, "installed app")?;
        validate_staged_app(app_path, &self.manifest)
    }

    fn identity_for(&self, path: &Path) -> io::Result<Option<PathIdentity>> {
        self.identities
            .iter()
            .find(|(recorded, _)| recorded == path)
            .map(|(_, identity)| *identity)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("untracked uninstall path: {}", path.display()),
                )
            })
    }
}

#[derive(Debug)]
struct UninstallBlocker {
    path: PathBuf,
    detail: String,
}

#[derive(Debug)]
struct UninstallInspection {
    manifest: Option<InstallManifest>,
    removable_app: Option<PathBuf>,
    hooks_present: bool,
    blockers: Vec<UninstallBlocker>,
}

pub fn install_plan(current_executable: &Path, config: &Config) -> io::Result<MutationPlan> {
    install_plan_for_layout(current_executable, config, &InstallLayout::current()?)
}

pub fn install_plan_for_layout(
    current_executable: &Path,
    config: &Config,
    layout: &InstallLayout,
) -> io::Result<MutationPlan> {
    config.validate()?;
    validate_config_paths_for_layout(config, layout)?;
    let mut blocked = false;
    let mut actions = vec![
        PlannedAction {
            kind: "copy".to_owned(),
            path: layout.managed_binary.clone(),
            detail: current_executable.display().to_string(),
        },
        PlannedAction {
            kind: "writeConfig".to_owned(),
            path: layout.config_path.clone(),
            detail: format!(
                "realCodex={}",
                config
                    .real_codex
                    .as_deref()
                    .map(Path::display)
                    .map(|value| value.to_string())
                    .unwrap_or_else(|| "discover".to_owned())
            ),
        },
        PlannedAction {
            kind: "mergeHooks".to_owned(),
            path: layout.hooks_path.clone(),
            detail: "preserve unrelated matcher groups; normal /hooks trust required".to_owned(),
        },
    ];
    for link in [&layout.codex_shim, &layout.management_link] {
        if link.exists() || fs::symlink_metadata(link).is_ok() {
            let owned = fs::symlink_metadata(link)
                .ok()
                .filter(|metadata| {
                    metadata.file_type().is_symlink()
                        && metadata.uid() == unsafe { libc::geteuid() }
                })
                .and_then(|_| fs::read_link(link).ok())
                .is_some_and(|target| target == layout.managed_binary);
            if !owned {
                blocked = true;
                actions.push(PlannedAction {
                    kind: "blocked".to_owned(),
                    path: link.clone(),
                    detail: "existing path is not Cove-owned; preserve it".to_owned(),
                });
            }
        } else {
            actions.push(PlannedAction {
                kind: "symlink".to_owned(),
                path: link.clone(),
                detail: layout.managed_binary.display().to_string(),
            });
        }
    }
    Ok(MutationPlan {
        operation: "install".to_owned(),
        blocked,
        actions,
    })
}

pub fn apply_install(
    current_executable: &Path,
    app_path: Option<&Path>,
    real_codex: &Path,
    layout: &InstallLayout,
    editor_extension_id: Option<&str>,
) -> io::Result<InstallManifest> {
    apply_install_transactional(
        current_executable,
        app_path,
        real_codex,
        layout,
        editor_extension_id,
        || Ok(()),
    )
}

fn apply_install_transactional<F>(
    current_executable: &Path,
    app_path: Option<&Path>,
    real_codex: &Path,
    layout: &InstallLayout,
    editor_extension_id: Option<&str>,
    before_links: F,
) -> io::Result<InstallManifest>
where
    F: FnOnce() -> io::Result<()>,
{
    let config = prepare_install_config(layout, real_codex)?;
    let plan = install_plan_for_layout(current_executable, &config, layout)?;
    if plan.blocked {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "install blocked by existing non-Cove path",
        ));
    }

    // Parse and construct hooks before mutating anything.
    let hook_command = format!("{} hook", shell_quote(&layout.managed_binary));
    let hooks = merged_hooks(
        read_json_object_or_default(&layout.hooks_path)?,
        &hook_command,
    )?;
    let mut snapshot = InstallSnapshot::capture(layout)?;
    let mut created_artifacts = Vec::new();
    let mutation = (|| -> io::Result<InstallManifest> {
        snapshot.ensure_directory(&layout.support, 0o700)?;
        let support_metadata = fs::symlink_metadata(&layout.support)?;
        if !support_metadata.is_dir() || support_metadata.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "support path must be a real directory",
            ));
        }
        fs::set_permissions(&layout.support, fs::Permissions::from_mode(0o700))?;
        snapshot.ensure_directory(layout.managed_binary.parent().unwrap(), 0o700)?;
        snapshot.stage_original(&layout.managed_binary)?;
        let helper_identity =
            atomic_copy_executable_new(current_executable, &layout.managed_binary)?;
        snapshot.record_replacement(&layout.managed_binary, helper_identity)?;
        snapshot.stage_original(&layout.config_path)?;
        let config_identity = atomic_write_json_new(
            &layout.config_path,
            &serde_json::to_value(&config)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
            0o600,
        )?;
        snapshot.record_replacement(&layout.config_path, config_identity)?;
        if let Some(backup) = backup_if_present(&layout.hooks_path)? {
            created_artifacts.push(backup);
        }
        snapshot.ensure_directory(layout.hooks_path.parent().unwrap(), 0o700)?;
        snapshot.stage_original(&layout.hooks_path)?;
        let hooks_identity = atomic_write_json_new(&layout.hooks_path, &hooks, 0o600)?;
        snapshot.record_replacement(&layout.hooks_path, hooks_identity)?;

        let user_bin = layout.codex_shim.parent().unwrap();
        let created_bin = PathIdentity::capture(user_bin)?.is_none();
        snapshot.ensure_directory(user_bin, 0o755)?;
        let bin_metadata = fs::symlink_metadata(user_bin)?;
        if !bin_metadata.is_dir() || bin_metadata.file_type().is_symlink() {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "user bin path must be a real directory",
            ));
        }
        if created_bin {
            fs::set_permissions(user_bin, fs::Permissions::from_mode(0o755))?;
        }
        before_links()?;
        if let Some(identity) = ensure_owned_symlink(&layout.codex_shim, &layout.managed_binary)? {
            snapshot.record_replacement(&layout.codex_shim, identity)?;
        }
        if let Some(identity) =
            ensure_owned_symlink(&layout.management_link, &layout.managed_binary)?
        {
            snapshot.record_replacement(&layout.management_link, identity)?;
        }

        let manifest = InstallManifest {
            schema_version: 1,
            installed_at: format_rfc3339(crate::unix_millis()),
            app_path: app_path.map(Path::to_path_buf),
            app_bundle_sha256: app_path.map(sha256_tree).transpose()?,
            managed_binary: layout.managed_binary.clone(),
            binary_sha256: sha256_file(&layout.managed_binary)?,
            hook_command,
            codex_shim: layout.codex_shim.clone(),
            management_link: layout.management_link.clone(),
            editor_extension_id: editor_extension_id.map(str::to_owned),
            editor_extension_targets: editor_extension_id.is_none().then(Vec::new),
        };
        snapshot.stage_original(&layout.manifest_path)?;
        let manifest_identity = atomic_write_json_new(
            &layout.manifest_path,
            &serde_json::to_value(&manifest)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
            0o600,
        )?;
        snapshot.record_replacement(&layout.manifest_path, manifest_identity)?;
        Ok(manifest)
    })();

    match mutation {
        Ok(manifest) => {
            if let Err(error) = snapshot.validate_commit() {
                return match snapshot.restore(&created_artifacts) {
                    Ok(()) => Err(error),
                    Err(rollback_error) => Err(io::Error::other(format!(
                        "{error}; rollback also failed: {rollback_error}"
                    ))),
                };
            }
            match snapshot.commit() {
                Ok(()) => Ok(manifest),
                Err(error) => Err(io::Error::new(
                    error.kind(),
                    format!(
                        "install completed, but verified rollback-stage cleanup failed: {error}"
                    ),
                )),
            }
        }
        Err(error) => match snapshot.restore(&created_artifacts) {
            Ok(()) => Err(error),
            Err(rollback_error) => Err(io::Error::other(format!(
                "{error}; rollback also failed: {rollback_error}"
            ))),
        },
    }
}

fn prepare_install_config(layout: &InstallLayout, real_codex: &Path) -> io::Result<Config> {
    validate_install_layout_paths(layout)?;
    validate_existing_support_directory(layout)?;
    let mut config = match fs::symlink_metadata(&layout.config_path) {
        Ok(metadata) => {
            if !metadata.file_type().is_file()
                || metadata.uid() != unsafe { libc::geteuid() }
                || metadata.permissions().mode() & 0o077 != 0
                || metadata.len() > 1_048_576
            {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "existing helper config must be a current-user private regular file no larger than 1 MiB",
                ));
            }
            let bytes = read_current_user_regular_file(&layout.config_path, Some(1_048_576))?;
            let config: Config = serde_json::from_slice(&bytes)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
            config.validate()?;
            validate_config_paths_for_layout(&config, layout)?;
            config
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => Config::for_home(&layout.home),
        Err(error) => return Err(error),
    };
    if config.max_frame_bytes == 1_048_576 {
        config.max_frame_bytes = crate::DEFAULT_MAX_FRAME_BYTES;
    }
    config.real_codex = Some(real_codex.to_path_buf());
    config.validate()?;
    validate_config_paths_for_layout(&config, layout)?;
    Ok(config)
}

fn validate_install_layout_paths(layout: &InstallLayout) -> io::Result<()> {
    let home_metadata = fs::symlink_metadata(&layout.home)?;
    if !home_metadata.is_dir()
        || home_metadata.file_type().is_symlink()
        || home_metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "HOME must be a current-user real directory",
        ));
    }
    for directory in managed_directory_paths(layout)? {
        match fs::symlink_metadata(&directory) {
            Ok(metadata)
                if metadata.is_dir()
                    && !metadata.file_type().is_symlink()
                    && metadata.uid() == unsafe { libc::geteuid() } => {}
            Ok(_) => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!(
                        "managed directory component must be a current-user real directory: {}",
                        directory.display()
                    ),
                ));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => return Err(error),
        }
    }

    validate_managed_regular_leaf(&layout.config_path, "helper config", true, Some(1_048_576))?;
    validate_managed_regular_leaf(
        &layout.manifest_path,
        "install manifest",
        true,
        Some(1_048_576),
    )?;
    validate_managed_regular_leaf(&layout.managed_binary, "managed helper", false, None)?;
    validate_managed_regular_leaf(&layout.hooks_path, "Codex hooks", false, Some(1_048_576))?;
    Ok(())
}

fn validate_managed_regular_leaf(
    path: &Path,
    label: &str,
    private: bool,
    maximum_size: Option<u64>,
) -> io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.nlink() == 1
                && (!private || metadata.permissions().mode() & 0o077 == 0)
                && maximum_size.is_none_or(|maximum| metadata.len() <= maximum) =>
        {
            Ok(())
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "existing {label} must be a current-user{} regular file with one link: {}",
                if private { " private" } else { "" },
                path.display()
            ),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn validate_existing_support_directory(layout: &InstallLayout) -> io::Result<()> {
    match fs::symlink_metadata(&layout.support) {
        Ok(metadata)
            if metadata.file_type().is_dir()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.permissions().mode() & 0o077 == 0 =>
        {
            Ok(())
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "existing support path must be a current-user private real directory",
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn validate_config_paths_for_layout(config: &Config, layout: &InstallLayout) -> io::Result<()> {
    validate_descendant_path(
        "runtimeDirectory",
        &config.runtime_directory,
        &layout.support,
    )?;
    validate_descendant_path("themeDirectory", &config.theme_directory, &layout.support)?;
    validate_descendant_path(
        "eventSocket",
        &config.event_socket,
        &config.runtime_directory,
    )?;
    validate_existing_directory_chain(
        &layout.support,
        &config.runtime_directory,
        "runtimeDirectory",
    )?;
    validate_existing_directory_chain(&layout.support, &config.theme_directory, "themeDirectory")?;
    if let Some(event_parent) = config.event_socket.parent() {
        validate_existing_directory_chain(
            &config.runtime_directory,
            event_parent,
            "eventSocket parent",
        )?;
    }
    Ok(())
}

fn validate_descendant_path(field: &str, path: &Path, parent: &Path) -> io::Result<()> {
    if path == parent || !path.starts_with(parent) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} must be contained within {}", parent.display()),
        ));
    }
    Ok(())
}

fn validate_existing_directory_chain(root: &Path, path: &Path, field: &str) -> io::Result<()> {
    let relative = path.strip_prefix(root).map_err(|_| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("{field} is outside its managed root"),
        )
    })?;
    let mut current = root.to_path_buf();
    for component in relative.components() {
        current.push(component.as_os_str());
        match fs::symlink_metadata(&current) {
            Ok(metadata) if metadata.file_type().is_symlink() || !metadata.is_dir() => {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    format!("{field} has an unsafe existing path component"),
                ));
            }
            Ok(_) => {}
            Err(error) if error.kind() == io::ErrorKind::NotFound => break,
            Err(error) => return Err(error),
        }
    }
    Ok(())
}

pub fn uninstall_plan() -> io::Result<MutationPlan> {
    uninstall_plan_for_layout_with_options(&InstallLayout::current()?, false, false)
}

pub fn uninstall_plan_for_layout(layout: &InstallLayout) -> io::Result<MutationPlan> {
    uninstall_plan_for_layout_with_options(layout, false, false)
}

pub fn uninstall_plan_for_layout_with_settings(
    layout: &InstallLayout,
    keep_settings: bool,
) -> io::Result<MutationPlan> {
    uninstall_plan_for_layout_with_options(layout, keep_settings, false)
}

pub fn uninstall_plan_for_layout_with_options(
    layout: &InstallLayout,
    keep_settings: bool,
    keep_app: bool,
) -> io::Result<MutationPlan> {
    let inspection = inspect_uninstall(layout);
    let mut actions = Vec::new();
    for blocker in &inspection.blockers {
        actions.push(PlannedAction {
            kind: "blocked".to_owned(),
            path: blocker.path.clone(),
            detail: blocker.detail.clone(),
        });
    }

    if let Some(manifest) = inspection.manifest.as_ref() {
        if let Some(extension_id) = manifest.editor_extension_id.as_deref() {
            let targets = manifest
                .editor_cleanup_targets()
                .map(|targets| {
                    if manifest.editor_extension_targets.is_none() {
                        "all supported editors (legacy manifest)".to_owned()
                    } else if targets.is_empty() {
                        "no recorded editors".to_owned()
                    } else {
                        targets.join(" and ")
                    }
                })
                .unwrap_or_else(|error| format!("invalid targets: {error}"));
            actions.push(PlannedAction {
                kind: "removeEditorExtensionFirst".to_owned(),
                path: layout.manifest_path.clone(),
                detail: format!(
                    "verify and remove {extension_id} from {targets}; an unreachable recorded editor or any cleanup failure preserves local retry state"
                ),
            });
        }
        if let Some(app_path) = inspection.removable_app.as_ref() {
            actions.push(PlannedAction {
                kind: "unregisterLoginItemFirst".to_owned(),
                path: app_path.clone(),
                detail: "complete launch-at-login cleanup before local artifact removal".to_owned(),
            });
        }
    }

    actions.push(PlannedAction {
        kind: if inspection.hooks_present {
            "removeOwnedHooks"
        } else {
            "alreadyAbsent"
        }
        .to_owned(),
        path: layout.hooks_path.clone(),
        detail: if inspection.hooks_present {
            "remove only entries whose command exactly matches the manifest".to_owned()
        } else {
            "hooks file is already absent".to_owned()
        },
    });
    for link in [&layout.codex_shim, &layout.management_link] {
        let present = fs::symlink_metadata(link).is_ok();
        actions.push(PlannedAction {
            kind: if present {
                "removeOwnedSymlink"
            } else {
                "alreadyAbsent"
            }
            .to_owned(),
            path: link.clone(),
            detail: if present {
                "remove only after the complete preflight proves the target is Cove-owned"
                    .to_owned()
            } else {
                "owned link is already absent".to_owned()
            },
        });
    }
    if let Some(app_path) = inspection.removable_app.as_ref() {
        actions.push(PlannedAction {
            kind: if keep_app {
                "preserveExternallyManagedApp"
            } else {
                "removeChecksumMatchingApp"
            }
            .to_owned(),
            path: app_path.clone(),
            detail: if keep_app {
                "leave the verified bundle for the external package manager to remove or replace"
                    .to_owned()
            } else {
                "bundle identity and full-tree checksum match the install manifest".to_owned()
            },
        });
    }
    actions.push(PlannedAction {
        kind: if keep_settings {
            "removeIntegrationKeepSettings"
        } else {
            "removeIntegrationAndSettings"
        }
        .to_owned(),
        path: if keep_settings {
            layout.managed_binary.clone()
        } else {
            layout.support.clone()
        },
        detail: if keep_settings {
            "transactionally remove the helper and manifest; retain config, preferences, and session metadata"
                .to_owned()
        } else {
            "transactionally remove the Cove support directory, including settings and session metadata"
                .to_owned()
        },
    });
    Ok(MutationPlan {
        operation: "uninstall".to_owned(),
        blocked: !inspection.blockers.is_empty(),
        actions,
    })
}

pub fn preflight_uninstall(layout: &InstallLayout) -> io::Result<UninstallPreflight> {
    let inspection = inspect_uninstall(layout);
    if !inspection.blockers.is_empty() {
        let details = inspection
            .blockers
            .iter()
            .map(|blocker| format!("{}: {}", blocker.path.display(), blocker.detail))
            .collect::<Vec<_>>()
            .join("; ");
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("uninstall blocked; installation left unchanged: {details}"),
        ));
    }
    let manifest = inspection.manifest.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "uninstall blocked; install manifest is unavailable",
        )
    })?;
    let mut identities = Vec::new();
    for (path, required, kind) in [
        (&layout.support, true, ManagedPathKind::Directory),
        (&layout.manifest_path, true, ManagedPathKind::File),
        (&layout.managed_binary, true, ManagedPathKind::File),
        (
            &layout.hooks_path,
            inspection.hooks_present,
            ManagedPathKind::File,
        ),
        (&layout.codex_shim, false, ManagedPathKind::Symlink),
        (&layout.management_link, false, ManagedPathKind::Symlink),
    ] {
        identities.push((
            path.clone(),
            capture_uninstall_identity(path, required, kind)?,
        ));
    }
    if !inspection.hooks_present
        && identities
            .iter()
            .find(|(path, _)| path == &layout.hooks_path)
            .and_then(|(_, identity)| *identity)
            .is_some()
    {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "hooks appeared while uninstall preflight was running",
        ));
    }
    if let Some(app_path) = inspection.removable_app.as_ref() {
        identities.push((
            app_path.clone(),
            capture_uninstall_identity(app_path, true, ManagedPathKind::Directory)?,
        ));
    }
    Ok(UninstallPreflight {
        manifest,
        removable_app: inspection.removable_app,
        hooks_present: inspection.hooks_present,
        identities,
    })
}

fn capture_uninstall_identity(
    path: &Path,
    required: bool,
    kind: ManagedPathKind,
) -> io::Result<Option<PathIdentity>> {
    let Some(identity) = PathIdentity::capture(path)? else {
        return if required {
            Err(io::Error::new(
                io::ErrorKind::NotFound,
                format!(
                    "uninstall path disappeared after preflight: {}",
                    path.display()
                ),
            ))
        } else {
            Ok(None)
        };
    };
    if identity.kind != kind || identity.owner != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "uninstall path is not a current-user {kind:?}: {}",
                path.display()
            ),
        ));
    }
    if kind == ManagedPathKind::File && fs::symlink_metadata(path)?.nlink() != 1 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("uninstall file has multiple links: {}", path.display()),
        ));
    }
    identity.require_current(path, "uninstall preflight identity")?;
    Ok(Some(identity))
}

pub fn apply_uninstall(layout: &InstallLayout, keep_settings: bool) -> io::Result<()> {
    apply_uninstall_with_options(layout, keep_settings, false)
}

pub fn apply_uninstall_with_options(
    layout: &InstallLayout,
    keep_settings: bool,
    keep_app: bool,
) -> io::Result<()> {
    apply_uninstall_with_options_before_commit(layout, keep_settings, keep_app, |_| Ok(()))
}

pub fn apply_uninstall_with_options_before_commit<F>(
    layout: &InstallLayout,
    keep_settings: bool,
    keep_app: bool,
    before_commit: F,
) -> io::Result<()>
where
    F: FnOnce(&UninstallPreflight) -> io::Result<()>,
{
    apply_uninstall_transactional_with_cleanup_options(
        layout,
        keep_settings,
        keep_app,
        before_commit,
        remove_staged_path_identity_bound,
    )
}

#[cfg(test)]
fn apply_uninstall_transactional<F>(
    layout: &InstallLayout,
    keep_settings: bool,
    before_commit: F,
) -> io::Result<()>
where
    F: FnOnce() -> io::Result<()>,
{
    apply_uninstall_transactional_with_options(layout, keep_settings, false, before_commit)
}

#[cfg(test)]
fn apply_uninstall_transactional_with_options<F>(
    layout: &InstallLayout,
    keep_settings: bool,
    keep_app: bool,
    before_commit: F,
) -> io::Result<()>
where
    F: FnOnce() -> io::Result<()>,
{
    apply_uninstall_with_options_before_commit(layout, keep_settings, keep_app, |_| before_commit())
}

#[cfg(test)]
fn apply_uninstall_transactional_with_cleanup<F, C>(
    layout: &InstallLayout,
    keep_settings: bool,
    before_commit: F,
    cleanup: C,
) -> io::Result<()>
where
    F: FnOnce() -> io::Result<()>,
    C: FnMut(&StagedPath) -> io::Result<()>,
{
    apply_uninstall_transactional_with_cleanup_options(
        layout,
        keep_settings,
        false,
        |_| before_commit(),
        cleanup,
    )
}

fn apply_uninstall_transactional_with_cleanup_options<F, C>(
    layout: &InstallLayout,
    keep_settings: bool,
    keep_app: bool,
    before_commit: F,
    cleanup: C,
) -> io::Result<()>
where
    F: FnOnce(&UninstallPreflight) -> io::Result<()>,
    C: FnMut(&StagedPath) -> io::Result<()>,
{
    apply_uninstall_transactional_with_cleanup_inner(
        layout,
        keep_settings,
        keep_app,
        before_commit,
        cleanup,
    )
}

fn apply_uninstall_transactional_with_cleanup_inner<F, C>(
    layout: &InstallLayout,
    keep_settings: bool,
    keep_app: bool,
    before_commit: F,
    cleanup: C,
) -> io::Result<()>
where
    F: FnOnce(&UninstallPreflight) -> io::Result<()>,
    C: FnMut(&StagedPath) -> io::Result<()>,
{
    apply_uninstall_transactional_with_cleanup_at_validation_boundary(
        layout,
        keep_settings,
        keep_app,
        || Ok(()),
        before_commit,
        cleanup,
    )
}

fn apply_uninstall_transactional_with_cleanup_at_validation_boundary<V, F, C>(
    layout: &InstallLayout,
    keep_settings: bool,
    keep_app: bool,
    before_retained_app_validation: V,
    before_commit: F,
    cleanup: C,
) -> io::Result<()>
where
    V: FnOnce() -> io::Result<()>,
    F: FnOnce(&UninstallPreflight) -> io::Result<()>,
    C: FnMut(&StagedPath) -> io::Result<()>,
{
    // This preflight runs inside the transaction. Callers may perform an early
    // read-only plan, but only this snapshot authorizes the staged mutations.
    let preflight = preflight_uninstall(layout)?;
    let manifest = preflight.manifest.clone();
    let mut transaction = UninstallTransaction::default();
    let mutation = (|| -> io::Result<()> {
        if preflight.hooks_present {
            let staged = transaction
                .stage(
                    &layout.hooks_path,
                    preflight.identity_for(&layout.hooks_path)?,
                )?
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "hooks changed after preflight")
                })?;
            let hooks = remove_owned_hooks(read_json_object(&staged)?, &manifest.hook_command)?;
            let replacement = atomic_write_json_new(&layout.hooks_path, &hooks, 0o600)?;
            transaction.mark_replacement(&layout.hooks_path, replacement)?;
        }

        for link in [&layout.codex_shim, &layout.management_link] {
            if let Some(staged) = transaction.stage(link, preflight.identity_for(link)?)?
                && fs::read_link(&staged)? != manifest.managed_binary
            {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{} changed after preflight", link.display()),
                ));
            }
        }

        if !keep_app && let Some(app_path) = preflight.removable_app.as_ref() {
            let staged = transaction
                .stage(app_path, preflight.identity_for(app_path)?)?
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "app changed after preflight")
                })?;
            validate_staged_app(&staged, &manifest)?;
        }

        if keep_settings {
            let staged_helper = transaction
                .stage(
                    &layout.managed_binary,
                    preflight.identity_for(&layout.managed_binary)?,
                )?
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "helper disappeared"))?;
            validate_staged_helper(&staged_helper, &manifest)?;

            let staged_manifest = transaction
                .stage(
                    &layout.manifest_path,
                    preflight.identity_for(&layout.manifest_path)?,
                )?
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "manifest disappeared"))?;
            validate_staged_manifest(&staged_manifest, &manifest)?;

            if let Some(bin_directory) = layout.managed_binary.parent() {
                transaction.remove_empty_directory_on_commit(bin_directory)?;
            }
        } else {
            let staged_support = transaction
                .stage(&layout.support, preflight.identity_for(&layout.support)?)?
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::NotFound, "support directory disappeared")
                })?;
            let helper_relative = layout
                .managed_binary
                .strip_prefix(&layout.support)
                .map_err(io::Error::other)?;
            let manifest_relative = layout
                .manifest_path
                .strip_prefix(&layout.support)
                .map_err(io::Error::other)?;
            preflight
                .identity_for(&layout.managed_binary)?
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "helper disappeared"))?
                .require_current(
                    &staged_support.join(helper_relative),
                    "staged managed helper",
                )?;
            preflight
                .identity_for(&layout.manifest_path)?
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "manifest disappeared"))?
                .require_current(
                    &staged_support.join(manifest_relative),
                    "staged install manifest",
                )?;
            validate_staged_helper(&staged_support.join(helper_relative), &manifest)?;
            validate_staged_manifest(&staged_support.join(manifest_relative), &manifest)?;
        }

        // In package-manager mode the app remains at its canonical path so
        // Homebrew can remove or replace it. Revalidate both the directory
        // identity and the complete bundle after every local uninstall
        // mutation has been staged and before any external cleanup begins.
        // Otherwise a concurrent app replacement could consume the integration
        // manifest or leave editor/login-item cleanup partially applied.
        before_retained_app_validation()?;
        if keep_app {
            preflight.validate_removable_app()?;
        }

        transaction.validate_commit().map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("uninstall commit validation failed before external cleanup: {error}"),
            )
        })?;
        before_commit(&preflight)?;

        // The callback may involve bounded external processes. Revalidate the
        // retained bundle and every staged local artifact before crossing the
        // commit point. Callers that mutate external state are responsible for
        // compensating it if this check rolls the local transaction back.
        if keep_app {
            preflight.validate_removable_app()?;
        }
        transaction.validate_commit().map_err(|error| {
            io::Error::new(
                error.kind(),
                format!("uninstall commit validation failed after external cleanup: {error}"),
            )
        })?;
        Ok(())
    })();

    match mutation {
        // Validation is complete on both sides of the callback above. Local
        // removal is the commit point; cleanup failures after it retain only
        // private recovery artifacts and never reinstall integration.
        Ok(()) => transaction.commit_prevalidated_with(cleanup),
        Err(error) => match transaction.rollback() {
            Ok(()) => Err(error),
            Err(rollback_error) => Err(io::Error::other(format!(
                "{error}; rollback also failed: {rollback_error}"
            ))),
        },
    }
}

fn inspect_uninstall(layout: &InstallLayout) -> UninstallInspection {
    let mut blockers = Vec::new();
    let mut hooks_present = false;
    let mut removable_app = None;

    match fs::symlink_metadata(&layout.support) {
        Ok(metadata) if metadata.is_dir() && !metadata.file_type().is_symlink() => {}
        Ok(_) => push_blocker(
            &mut blockers,
            &layout.support,
            "support path is not a Cove-owned real directory",
        ),
        Err(error) => push_blocker(
            &mut blockers,
            &layout.support,
            format!("support directory is unavailable: {error}"),
        ),
    }

    let manifest = match fs::symlink_metadata(&layout.manifest_path) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            match read_manifest(layout) {
                Ok(manifest) => Some(manifest),
                Err(error) => {
                    push_blocker(
                        &mut blockers,
                        &layout.manifest_path,
                        format!("install manifest is invalid: {error}"),
                    );
                    None
                }
            }
        }
        Ok(_) => {
            push_blocker(
                &mut blockers,
                &layout.manifest_path,
                "install manifest is not a regular Cove-owned file",
            );
            None
        }
        Err(error) => {
            push_blocker(
                &mut blockers,
                &layout.manifest_path,
                format!("install manifest is unavailable: {error}"),
            );
            None
        }
    };

    if let Some(manifest) = manifest.as_ref() {
        if manifest.schema_version != 1 {
            push_blocker(
                &mut blockers,
                &layout.manifest_path,
                format!("unsupported manifest schema {}", manifest.schema_version),
            );
        }
        if let Err(error) = manifest.editor_cleanup_targets() {
            push_blocker(
                &mut blockers,
                &layout.manifest_path,
                format!("invalid editor cleanup obligations: {error}"),
            );
        }
        for (recorded, expected, label) in [
            (
                &manifest.managed_binary,
                &layout.managed_binary,
                "managed helper",
            ),
            (&manifest.codex_shim, &layout.codex_shim, "Codex shim"),
            (
                &manifest.management_link,
                &layout.management_link,
                "management link",
            ),
        ] {
            if recorded != expected {
                push_blocker(
                    &mut blockers,
                    &layout.manifest_path,
                    format!(
                        "manifest {label} path {} does not match expected {}",
                        recorded.display(),
                        expected.display()
                    ),
                );
            }
        }
        let expected_hook_command = format!("{} hook", shell_quote(&layout.managed_binary));
        if manifest.hook_command != expected_hook_command {
            push_blocker(
                &mut blockers,
                &layout.manifest_path,
                "manifest hook command is not the canonical Cove-owned command",
            );
        }

        validate_helper_for_preflight(layout, manifest, &mut blockers);
        validate_link_for_preflight(&layout.codex_shim, &layout.managed_binary, &mut blockers);
        validate_link_for_preflight(
            &layout.management_link,
            &layout.managed_binary,
            &mut blockers,
        );

        match fs::symlink_metadata(&layout.hooks_path) {
            Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
                hooks_present = true;
                match read_json_object(&layout.hooks_path)
                    .and_then(|hooks| remove_owned_hooks(hooks, &manifest.hook_command))
                {
                    Ok(_) => {}
                    Err(error) => push_blocker(
                        &mut blockers,
                        &layout.hooks_path,
                        format!("hooks cannot be safely transformed: {error}"),
                    ),
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Ok(_) => push_blocker(
                &mut blockers,
                &layout.hooks_path,
                "hooks path is not a regular file",
            ),
            Err(error) => push_blocker(
                &mut blockers,
                &layout.hooks_path,
                format!("hooks path cannot be inspected: {error}"),
            ),
        }

        match (
            manifest.app_path.as_ref(),
            manifest.app_bundle_sha256.as_ref(),
        ) {
            (None, None) => {}
            (None, Some(_)) => push_blocker(
                &mut blockers,
                &layout.manifest_path,
                "manifest has an app checksum without an app path",
            ),
            (Some(app_path), None) => push_blocker(
                &mut blockers,
                app_path,
                "installed app lacks a recorded bundle checksum",
            ),
            (Some(app_path), Some(expected)) => match fs::symlink_metadata(app_path) {
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => push_blocker(
                    &mut blockers,
                    app_path,
                    format!("installed app cannot be inspected: {error}"),
                ),
                Ok(metadata) if !metadata.is_dir() || metadata.file_type().is_symlink() => {
                    push_blocker(
                        &mut blockers,
                        app_path,
                        "installed app is not a real directory",
                    )
                }
                Ok(_)
                    if [
                        &layout.support,
                        &layout.hooks_path,
                        &layout.codex_shim,
                        &layout.management_link,
                    ]
                    .into_iter()
                    .any(|managed_path| paths_overlap(app_path, managed_path)) =>
                {
                    push_blocker(
                        &mut blockers,
                        app_path,
                        "installed app overlaps another managed path and cannot be removed safely",
                    )
                }
                Ok(_) if !app_path.is_absolute() || !is_cove_bundle(app_path) => push_blocker(
                    &mut blockers,
                    app_path,
                    "installed app does not have the expected Cove bundle identity",
                ),
                Ok(_) => match sha256_tree(app_path) {
                    Ok(actual) if &actual == expected => removable_app = Some(app_path.clone()),
                    Ok(_) => push_blocker(
                        &mut blockers,
                        app_path,
                        "installed app bundle checksum changed; preserving the entire installation",
                    ),
                    Err(error) => push_blocker(
                        &mut blockers,
                        app_path,
                        format!("installed app checksum failed: {error}"),
                    ),
                },
            },
        }
    } else {
        for link in [&layout.codex_shim, &layout.management_link] {
            if fs::symlink_metadata(link).is_ok() {
                push_blocker(
                    &mut blockers,
                    link,
                    "cannot prove ownership without a valid install manifest",
                );
            }
        }
    }

    UninstallInspection {
        manifest,
        removable_app,
        hooks_present,
        blockers,
    }
}

fn validate_helper_for_preflight(
    layout: &InstallLayout,
    manifest: &InstallManifest,
    blockers: &mut Vec<UninstallBlocker>,
) {
    match fs::symlink_metadata(&layout.managed_binary) {
        Ok(metadata) if metadata.is_file() && !metadata.file_type().is_symlink() => {
            match sha256_file(&layout.managed_binary) {
                Ok(actual) if actual == manifest.binary_sha256 => {}
                Ok(_) => push_blocker(
                    blockers,
                    &layout.managed_binary,
                    "managed helper checksum changed",
                ),
                Err(error) => push_blocker(
                    blockers,
                    &layout.managed_binary,
                    format!("managed helper checksum failed: {error}"),
                ),
            }
        }
        Ok(_) => push_blocker(
            blockers,
            &layout.managed_binary,
            "managed helper is not a regular Cove-owned file",
        ),
        Err(error) => push_blocker(
            blockers,
            &layout.managed_binary,
            format!("managed helper is unavailable: {error}"),
        ),
    }
}

fn validate_link_for_preflight(path: &Path, target: &Path, blockers: &mut Vec<UninstallBlocker>) {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() => match fs::read_link(path) {
            Ok(actual) if actual == target => {}
            Ok(actual) => push_blocker(
                blockers,
                path,
                format!(
                    "symlink target {} is not the Cove-managed helper",
                    actual.display()
                ),
            ),
            Err(error) => push_blocker(
                blockers,
                path,
                format!("symlink target cannot be inspected: {error}"),
            ),
        },
        Ok(_) => push_blocker(
            blockers,
            path,
            "path replaced the Cove-owned symlink; preserving the entire installation",
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => push_blocker(
            blockers,
            path,
            format!("symlink cannot be inspected: {error}"),
        ),
    }
}

fn push_blocker(
    blockers: &mut Vec<UninstallBlocker>,
    path: impl AsRef<Path>,
    detail: impl Into<String>,
) {
    blockers.push(UninstallBlocker {
        path: path.as_ref().to_path_buf(),
        detail: detail.into(),
    });
}

fn paths_overlap(left: &Path, right: &Path) -> bool {
    left.starts_with(right) || right.starts_with(left)
}

fn validate_staged_helper(path: &Path, manifest: &InstallManifest) -> io::Result<()> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "managed helper changed type after preflight",
        ));
    }
    if sha256_file(path)? != manifest.binary_sha256 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "managed helper changed after preflight",
        ));
    }
    Ok(())
}

fn validate_staged_manifest(path: &Path, expected: &InstallManifest) -> io::Result<()> {
    let actual: InstallManifest =
        serde_json::from_slice(&read_current_user_regular_file(path, Some(1_048_576))?)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if &actual != expected {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "install manifest changed after preflight",
        ));
    }
    Ok(())
}

fn validate_staged_app(path: &Path, manifest: &InstallManifest) -> io::Result<()> {
    let expected = manifest
        .app_bundle_sha256
        .as_deref()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "app checksum is missing"))?;
    if !has_cove_bundle_identifier(path) || sha256_tree(path)? != expected {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "installed app changed after preflight",
        ));
    }
    Ok(())
}

#[derive(Debug)]
struct StagedPath {
    original: PathBuf,
    staged: PathBuf,
    staged_identity: PathIdentity,
    stage_directory: PathBuf,
    stage_directory_identity: PathIdentity,
    replacement: Option<PathIdentity>,
}

#[derive(Debug, Default)]
struct UninstallTransaction {
    paths: Vec<StagedPath>,
    empty_directories: Vec<(PathBuf, PathIdentity)>,
}

impl UninstallTransaction {
    fn stage(
        &mut self,
        path: &Path,
        expected: Option<PathIdentity>,
    ) -> io::Result<Option<PathBuf>> {
        let Some(original_identity) = expected else {
            return match PathIdentity::capture(path)? {
                None => Ok(None),
                Some(_) => Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "uninstall path appeared after preflight: {}",
                        path.display()
                    ),
                )),
            };
        };
        original_identity.require_current(path, "uninstall stage source")?;
        let reservation = reserve_sibling_stage(path, "uninstall-stage")?;
        if let Err(error) = rename_noreplace(path, &reservation.payload) {
            let cleanup =
                remove_stage_directory(&reservation.directory, reservation.directory_identity);
            return match cleanup {
                Ok(()) => Err(error),
                Err(cleanup_error) => Err(io::Error::other(format!(
                    "{error}; empty uninstall stage cleanup also failed: {cleanup_error}"
                ))),
            };
        }
        if PathIdentity::capture(&reservation.payload)? != Some(original_identity) {
            let restore = rename_noreplace(&reservation.payload, path);
            if restore.is_ok() {
                remove_stage_directory(&reservation.directory, reservation.directory_identity)?;
            }
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!(
                    "uninstall stage identity changed{}",
                    restore
                        .err()
                        .map(|error| format!(
                            "; raced object retained at {} because restoration failed: {error}",
                            reservation.payload.display()
                        ))
                        .unwrap_or_default()
                ),
            ));
        }
        self.paths.push(StagedPath {
            original: path.to_path_buf(),
            staged: reservation.payload.clone(),
            staged_identity: original_identity,
            stage_directory: reservation.directory,
            stage_directory_identity: reservation.directory_identity,
            replacement: None,
        });
        Ok(Some(reservation.payload))
    }

    fn mark_replacement(&mut self, path: &Path, expected: PathIdentity) -> io::Result<()> {
        let entry = self
            .paths
            .iter_mut()
            .rev()
            .find(|entry| entry.original == path)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "unstaged replacement"))?;
        expected.require_current(path, "uninstall replacement")?;
        if expected.kind != ManagedPathKind::File || expected.owner != unsafe { libc::geteuid() } {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "transaction replacement is not a current-user regular file",
            ));
        }
        entry.replacement = Some(expected);
        Ok(())
    }

    fn remove_empty_directory_on_commit(&mut self, path: &Path) -> io::Result<()> {
        let identity = PathIdentity::capture(path)?.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "empty-directory cleanup target disappeared",
            )
        })?;
        if identity.kind != ManagedPathKind::Directory
            || identity.owner != unsafe { libc::geteuid() }
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "empty-directory cleanup target is unsafe",
            ));
        }
        self.empty_directories.push((path.to_path_buf(), identity));
        Ok(())
    }

    fn rollback(self) -> io::Result<()> {
        let mut first_error = None;
        for entry in self.paths.into_iter().rev() {
            let result = (|| -> io::Result<()> {
                let quarantined = if let Some(replacement) = entry.replacement {
                    if PathIdentity::capture(&entry.original)? != Some(replacement) {
                        return Err(io::Error::new(
                            io::ErrorKind::AlreadyExists,
                            format!(
                                "concurrent replacement preserved at {}; original retained at {}",
                                entry.original.display(),
                                entry.staged.display()
                            ),
                        ));
                    }
                    Some(quarantine_verified_leaf(
                        &entry.original,
                        replacement,
                        "uninstall-rollback-replacement",
                    )?)
                } else if fs::symlink_metadata(&entry.original).is_ok() {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!(
                            "concurrent replacement preserved at {}; original retained at {}",
                            entry.original.display(),
                            entry.staged.display()
                        ),
                    ));
                } else {
                    None
                };
                entry
                    .staged_identity
                    .require_current(&entry.staged, "uninstall rollback source")?;
                if let Err(error) = rename_noreplace(&entry.staged, &entry.original) {
                    if let Some(quarantined) = quarantined.as_ref() {
                        let _ = restore_quarantined_leaf(quarantined, &entry.original);
                    }
                    return Err(io::Error::new(
                        error.kind(),
                        format!(
                            "could not restore {}; original retained at {}: {error}",
                            entry.original.display(),
                            entry.staged.display()
                        ),
                    ));
                }
                entry.stage_directory_identity.require_current(
                    &entry.stage_directory,
                    "uninstall rollback stage directory",
                )?;
                fs::remove_dir(&entry.stage_directory)?;
                if let Some(quarantined) = quarantined {
                    quarantined.remove_payload_and_directory("uninstall rollback quarantine")?;
                }
                Ok(())
            })();
            if let Err(error) = result
                && first_error.is_none()
            {
                first_error = Some(error);
            }
        }
        if let Some(error) = first_error {
            Err(error)
        } else {
            Ok(())
        }
    }

    fn validate_commit(&self) -> io::Result<()> {
        for entry in &self.paths {
            entry
                .staged_identity
                .require_current(&entry.staged, "uninstall commit snapshot")?;
            entry
                .stage_directory_identity
                .require_current(&entry.stage_directory, "uninstall commit stage directory")?;
            match (entry.replacement, PathIdentity::capture(&entry.original)?) {
                (Some(expected), Some(current)) if expected == current => {}
                (None, None) => {}
                _ => {
                    return Err(io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        format!(
                            "uninstall destination changed after staging: {}",
                            entry.original.display()
                        ),
                    ));
                }
            }
        }
        for (directory, identity) in &self.empty_directories {
            identity.require_current(directory, "uninstall empty-directory cleanup")?;
        }
        Ok(())
    }

    #[cfg(test)]
    fn commit_with<F>(self, remove_staged: F) -> io::Result<()>
    where
        F: FnMut(&StagedPath) -> io::Result<()>,
    {
        if let Err(error) = self.validate_commit() {
            let recovery_paths = self
                .paths
                .iter()
                .map(|entry| entry.staged.display().to_string())
                .collect::<Vec<_>>()
                .join(", ");
            return match self.rollback() {
                Ok(()) => Err(io::Error::new(
                    error.kind(),
                    format!(
                        "uninstall commit validation failed: {error}; staged artifacts were restored for a safe retry"
                    ),
                )),
                Err(recovery_error) => Err(io::Error::other(format!(
                    "uninstall commit validation failed: {error}; recovery also failed: {recovery_error}; inspect retained recovery paths: {recovery_paths}"
                ))),
            };
        }
        self.commit_prevalidated_with(remove_staged)
    }

    fn commit_prevalidated_with<F>(self, mut remove_staged: F) -> io::Result<()>
    where
        F: FnMut(&StagedPath) -> io::Result<()>,
    {
        // The local snapshots were validated before the caller's external
        // cleanup callback. Once that callback succeeds, local uninstall is
        // logically committed: owned hooks have been removed and the other
        // integration artifacts are staged out of their canonical paths. A
        // later cleanup failure must never restore integration behind the
        // external stores. Preserve failed random-private stages, continue
        // independent cleanup, and report committed-but-incomplete state.
        let mut cleanup_failures = Vec::new();
        let mut first_cleanup_kind = None;
        for entry in &self.paths {
            let destination = PathIdentity::capture(&entry.original);
            let destination_matches = match (entry.replacement, destination.as_ref()) {
                (Some(expected), Ok(Some(current))) if expected == *current => true,
                (None, Ok(None)) => true,
                _ => false,
            };
            if !destination_matches {
                let kind = destination
                    .as_ref()
                    .err()
                    .map(io::Error::kind)
                    .unwrap_or(io::ErrorKind::AlreadyExists);
                first_cleanup_kind.get_or_insert(kind);
                cleanup_failures.push(format!(
                    "managed destination changed after the uninstall commit point at {} ({destination:?}); {}",
                    entry.original.display(),
                    staged_recovery_description(entry)
                ));
                continue;
            }
            match remove_staged(entry) {
                Ok(()) => match PathIdentity::capture(&entry.staged) {
                    Ok(None) => {
                        if let Err(error) = remove_stage_directory(
                            &entry.stage_directory,
                            entry.stage_directory_identity,
                        ) {
                            first_cleanup_kind.get_or_insert(error.kind());
                            cleanup_failures.push(format!(
                                "empty private stage directory retained at {}: {error}",
                                entry.stage_directory.display()
                            ));
                        }
                    }
                    Ok(Some(current)) => {
                        first_cleanup_kind.get_or_insert(io::ErrorKind::Other);
                        cleanup_failures.push(format!(
                            "cleanup reported success but retained {} with identity {current:?}",
                            entry.staged.display()
                        ));
                    }
                    Err(error) => {
                        first_cleanup_kind.get_or_insert(error.kind());
                        cleanup_failures.push(format!(
                            "could not verify cleanup of {}: {error}",
                            entry.staged.display()
                        ));
                    }
                },
                Err(error) => {
                    first_cleanup_kind.get_or_insert(error.kind());
                    cleanup_failures.push(format!(
                        "could not clean committed snapshot {}: {error}; {}",
                        entry.staged.display(),
                        staged_recovery_description(entry)
                    ));
                }
            }
        }
        for (directory, identity) in self.empty_directories {
            let result = identity
                .require_current(&directory, "uninstall empty-directory cleanup")
                .and_then(|()| fs::remove_dir(&directory));
            match result {
                Ok(()) => {}
                Err(error)
                    if matches!(
                        error.kind(),
                        io::ErrorKind::NotFound | io::ErrorKind::DirectoryNotEmpty
                    ) => {}
                Err(error) => {
                    first_cleanup_kind.get_or_insert(error.kind());
                    cleanup_failures.push(format!(
                        "empty managed directory retained at {}: {error}",
                        directory.display()
                    ));
                }
            }
        }
        if cleanup_failures.is_empty() {
            Ok(())
        } else {
            Err(io::Error::new(
                first_cleanup_kind.unwrap_or(io::ErrorKind::Other),
                format!(
                    "uninstall committed but cleanup incomplete: {}",
                    cleanup_failures.join("; ")
                ),
            ))
        }
    }
}

fn staged_recovery_description(entry: &StagedPath) -> String {
    match PathIdentity::capture(&entry.staged) {
        Ok(Some(current)) if current == entry.staged_identity => format!(
            "verified private recovery retained at {}",
            entry.staged.display()
        ),
        Ok(Some(current)) => format!(
            "stage path {} changed identity to {current:?}; it was preserved",
            entry.staged.display()
        ),
        Ok(None) => format!(
            "stage path {} is no longer available",
            entry.staged.display()
        ),
        Err(error) => format!(
            "stage path {} could not be verified: {error}",
            entry.staged.display()
        ),
    }
}

fn remove_staged_path_identity_bound(entry: &StagedPath) -> io::Result<()> {
    let stage_directory = open_verified_directory(
        &entry.stage_directory,
        entry.stage_directory_identity,
        "uninstall private stage directory",
    )?;
    let name = path_file_name_cstring(&entry.staged)?;
    let current = identity_at(stage_directory.as_raw_fd(), &name)?;
    if current != entry.staged_identity {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!(
                "uninstall staged root changed identity at {}",
                entry.staged.display()
            ),
        ));
    }
    remove_entry_at(
        stage_directory.as_raw_fd(),
        &name,
        entry.staged_identity,
        entry.staged_identity.device,
        &entry.staged,
    )
}

fn open_verified_directory(
    path: &Path,
    expected: PathIdentity,
    context: &str,
) -> io::Result<OwnedFd> {
    let path_string = CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "directory path contains NUL"))?;
    let descriptor = unsafe {
        libc::open(
            path_string.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `open` returned a new owned descriptor.
    let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let current = identity_for_fd(descriptor.as_raw_fd())?;
    if current != expected || current.kind != ManagedPathKind::Directory {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("{context} changed identity at {}", path.display()),
        ));
    }
    Ok(descriptor)
}

fn openat_verified_directory(
    parent: RawFd,
    name: &CStr,
    expected: PathIdentity,
    display_path: &Path,
) -> io::Result<OwnedFd> {
    let descriptor = unsafe {
        libc::openat(
            parent,
            name.as_ptr(),
            libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC | libc::O_NOFOLLOW,
        )
    };
    if descriptor < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: `openat` returned a new owned descriptor.
    let descriptor = unsafe { OwnedFd::from_raw_fd(descriptor) };
    let current = identity_for_fd(descriptor.as_raw_fd())?;
    if current != expected || current.kind != ManagedPathKind::Directory {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!(
                "uninstall directory changed while opening {}",
                display_path.display()
            ),
        ));
    }
    Ok(descriptor)
}

fn remove_entry_at(
    parent: RawFd,
    name: &CStr,
    expected: PathIdentity,
    staged_device: u64,
    display_path: &Path,
) -> io::Result<()> {
    validate_recursive_device_boundary(expected, staged_device, display_path)?;
    let current = identity_at(parent, name)?;
    if current != expected {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!(
                "uninstall cleanup entry changed identity at {}",
                display_path.display()
            ),
        ));
    }
    match expected.kind {
        ManagedPathKind::Directory => {
            let directory = openat_verified_directory(parent, name, expected, display_path)?;
            remove_directory_contents(directory.as_raw_fd(), staged_device, display_path)?;
            if identity_at(parent, name)? != expected {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "uninstall directory changed before removal at {}",
                        display_path.display()
                    ),
                ));
            }
            unlinkat_checked(parent, name, libc::AT_REMOVEDIR)
        }
        ManagedPathKind::File | ManagedPathKind::Symlink => {
            if identity_at(parent, name)? != expected {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!(
                        "uninstall leaf changed before removal at {}",
                        display_path.display()
                    ),
                ));
            }
            unlinkat_checked(parent, name, 0)
        }
        ManagedPathKind::Other => Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "refusing to remove unsupported staged entry {}",
                display_path.display()
            ),
        )),
    }
}

fn validate_recursive_device_boundary(
    identity: PathIdentity,
    staged_device: u64,
    display_path: &Path,
) -> io::Result<()> {
    if identity.device == staged_device {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "refusing to cross a filesystem boundary while cleaning {}",
                display_path.display()
            ),
        ))
    }
}

fn remove_directory_contents(
    directory: RawFd,
    staged_device: u64,
    display_path: &Path,
) -> io::Result<()> {
    for name in directory_entry_names(directory)? {
        let child_path = display_path.join(std::ffi::OsStr::from_bytes(name.as_bytes()));
        let expected = identity_at(directory, &name)?;
        remove_entry_at(directory, &name, expected, staged_device, &child_path)?;
    }
    Ok(())
}

fn directory_entry_names(directory: RawFd) -> io::Result<Vec<CString>> {
    let duplicate = unsafe { libc::fcntl(directory, libc::F_DUPFD_CLOEXEC, 0) };
    if duplicate < 0 {
        return Err(io::Error::last_os_error());
    }
    let stream = unsafe { libc::fdopendir(duplicate) };
    if stream.is_null() {
        let error = io::Error::last_os_error();
        unsafe { libc::close(duplicate) };
        return Err(error);
    }

    let mut names = Vec::new();
    let mut read_error = None;
    loop {
        set_errno_zero();
        let item = unsafe { libc::readdir(stream) };
        if item.is_null() {
            let error_number = current_errno();
            if error_number != 0 {
                read_error = Some(io::Error::from_raw_os_error(error_number));
            }
            break;
        }
        let name = unsafe { CStr::from_ptr((*item).d_name.as_ptr()) };
        if name.to_bytes() != b"." && name.to_bytes() != b".." {
            names.push(name.to_owned());
        }
    }
    let close_result = unsafe { libc::closedir(stream) };
    if let Some(error) = read_error {
        return Err(error);
    }
    if close_result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(names)
}

fn identity_at(parent: RawFd, name: &CStr) -> io::Result<PathIdentity> {
    let mut metadata = MaybeUninit::<libc::stat>::zeroed();
    let result = unsafe {
        libc::fstatat(
            parent,
            name.as_ptr(),
            metadata.as_mut_ptr(),
            libc::AT_SYMLINK_NOFOLLOW,
        )
    };
    if result != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(path_identity_from_stat(unsafe { metadata.assume_init() }))
}

fn identity_for_fd(descriptor: RawFd) -> io::Result<PathIdentity> {
    let mut metadata = MaybeUninit::<libc::stat>::zeroed();
    if unsafe { libc::fstat(descriptor, metadata.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(path_identity_from_stat(unsafe { metadata.assume_init() }))
}

fn path_identity_from_stat(metadata: libc::stat) -> PathIdentity {
    let kind = match metadata.st_mode & libc::S_IFMT {
        libc::S_IFREG => ManagedPathKind::File,
        libc::S_IFDIR => ManagedPathKind::Directory,
        libc::S_IFLNK => ManagedPathKind::Symlink,
        _ => ManagedPathKind::Other,
    };
    PathIdentity {
        device: metadata.st_dev as u64,
        inode: metadata.st_ino,
        owner: metadata.st_uid,
        kind,
    }
}

fn unlinkat_checked(parent: RawFd, name: &CStr, flags: libc::c_int) -> io::Result<()> {
    if unsafe { libc::unlinkat(parent, name.as_ptr(), flags) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

fn path_file_name_cstring(path: &Path) -> io::Result<CString> {
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "path has no file name"))?;
    CString::new(name.as_bytes())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "file name contains NUL"))
}

#[cfg(target_os = "macos")]
fn set_errno_zero() {
    unsafe { *libc::__error() = 0 };
}

#[cfg(target_os = "linux")]
fn set_errno_zero() {
    unsafe { *libc::__errno_location() = 0 };
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn set_errno_zero() {}

#[cfg(target_os = "macos")]
fn current_errno() -> libc::c_int {
    unsafe { *libc::__error() }
}

#[cfg(target_os = "linux")]
fn current_errno() -> libc::c_int {
    unsafe { *libc::__errno_location() }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn current_errno() -> libc::c_int {
    0
}

pub fn read_manifest(layout: &InstallLayout) -> io::Result<InstallManifest> {
    serde_json::from_slice(&read_current_user_regular_file(
        &layout.manifest_path,
        Some(1_048_576),
    )?)
    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

pub fn record_editor_extension_installation(
    layout: &InstallLayout,
    extension_id: Option<&str>,
    targets: &[String],
) -> io::Result<InstallManifest> {
    let mut canonical = Vec::new();
    for supported in SUPPORTED_EDITOR_TARGETS {
        let count = targets
            .iter()
            .filter(|target| target.as_str() == *supported)
            .count();
        if count > 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                format!("duplicate editor cleanup target {supported}"),
            ));
        }
        if count == 1 {
            canonical.push((*supported).to_owned());
        }
    }
    if canonical.len() != targets.len() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported editor cleanup target",
        ));
    }
    if extension_id.is_none() && !canonical.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "editor cleanup targets require an extension identifier",
        ));
    }

    let mut manifest = read_manifest(layout)?;
    manifest.editor_extension_id = extension_id.map(str::to_owned);
    manifest.editor_extension_targets = Some(canonical);
    manifest.editor_cleanup_targets()?;
    atomic_write_json(
        &layout.manifest_path,
        &serde_json::to_value(&manifest)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
        0o600,
    )?;
    Ok(manifest)
}

pub fn merged_hooks(mut root: Map<String, Value>, command: &str) -> io::Result<Value> {
    let hooks = root
        .entry("hooks".to_owned())
        .or_insert_with(|| Value::Object(Map::new()));
    let hooks = hooks
        .as_object_mut()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "hooks must be an object"))?;
    remove_command_from_hook_map(hooks, command)?;
    for event in HOOK_EVENTS {
        let groups = hooks
            .entry((*event).to_owned())
            .or_insert_with(|| Value::Array(Vec::new()))
            .as_array_mut()
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("hooks.{event} must be an array"),
                )
            })?;
        let timeout = if *event == "SessionEnd" { 1 } else { 2 };
        groups.push(json!({
            "hooks": [{
                "type": "command",
                "command": command,
                "timeout": timeout
            }]
        }));
    }
    root.entry("description".to_owned())
        .or_insert_with(|| Value::String("User lifecycle hooks, including Codex Cove.".to_owned()));
    Ok(Value::Object(root))
}

pub fn remove_owned_hooks(mut root: Map<String, Value>, command: &str) -> io::Result<Value> {
    if let Some(hooks) = root.get_mut("hooks") {
        let hooks = hooks
            .as_object_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "hooks must be an object"))?;
        remove_command_from_hook_map(hooks, command)?;
    }
    Ok(Value::Object(root))
}

fn remove_command_from_hook_map(hooks: &mut Map<String, Value>, command: &str) -> io::Result<()> {
    for groups in hooks.values_mut() {
        let groups = groups.as_array_mut().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidData, "hook event must be an array")
        })?;
        for group in groups.iter_mut() {
            let Some(handlers) = group.get_mut("hooks").and_then(Value::as_array_mut) else {
                continue;
            };
            handlers
                .retain(|handler| handler.get("command").and_then(Value::as_str) != Some(command));
        }
        groups.retain(|group| {
            group
                .get("hooks")
                .and_then(Value::as_array)
                .is_none_or(|handlers| !handlers.is_empty())
        });
    }
    Ok(())
}

fn read_json_object_or_default(path: &Path) -> io::Result<Map<String, Value>> {
    match read_current_user_regular_file(path, Some(1_048_576)) {
        Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
            .as_object()
            .cloned()
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "JSON root must be object")),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Map::new()),
        Err(error) => Err(error),
    }
}

fn read_json_object(path: &Path) -> io::Result<Map<String, Value>> {
    serde_json::from_slice::<Value>(&read_current_user_regular_file(path, Some(1_048_576))?)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?
        .as_object()
        .cloned()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "JSON root must be object"))
}

fn read_current_user_regular_file(path: &Path, maximum_size: Option<u64>) -> io::Result<Vec<u8>> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file()
        || metadata.file_type().is_symlink()
        || metadata.uid() != unsafe { libc::geteuid() }
        || metadata.nlink() != 1
        || maximum_size.is_some_and(|maximum| metadata.len() > maximum)
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("refusing to read unsafe managed file: {}", path.display()),
        ));
    }
    let expected = PathIdentity::from_metadata(&metadata);
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?;
    if PathIdentity::from_metadata(&file.metadata()?) != expected {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("managed file changed while opening: {}", path.display()),
        ));
    }
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.read_to_end(&mut bytes)?;
    Ok(bytes)
}

fn backup_if_present(path: &Path) -> io::Result<Option<CreatedArtifact>> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.is_file()
                && !metadata.file_type().is_symlink()
                && metadata.uid() == unsafe { libc::geteuid() }
                && metadata.nlink() == 1 =>
        {
            metadata
        }
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("refusing to back up unsafe {}", path.display()),
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    };
    let expected = PathIdentity::from_metadata(&metadata);
    let mut source = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?;
    if PathIdentity::from_metadata(&source.metadata()?) != expected {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("{} changed while preparing its backup", path.display()),
        ));
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "backup path has no parent"))?;
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("hooks.json");
    let mut backup = Builder::new()
        .prefix(&format!("{name}.cove-backup-{}-", crate::unix_millis()))
        .tempfile_in(parent)?;
    backup
        .as_file()
        .set_permissions(fs::Permissions::from_mode(
            metadata.permissions().mode() & 0o777,
        ))?;
    io::copy(&mut source, &mut backup)?;
    backup.as_file().sync_all()?;
    let (_, backup_path) = backup.keep().map_err(|error| error.error)?;
    Ok(Some(CreatedArtifact::capture(backup_path)?))
}

fn atomic_copy_executable_new(source: &Path, destination: &Path) -> io::Result<PathIdentity> {
    let source_metadata = fs::symlink_metadata(source)?;
    if !source_metadata.is_file() || source_metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "helper source must be a regular file",
        ));
    }
    let expected_source = PathIdentity::from_metadata(&source_metadata);
    let mut source_file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(source)?;
    if PathIdentity::from_metadata(&source_file.metadata()?) != expected_source {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "helper source changed while it was opened",
        ));
    }
    let mut temporary = exclusive_temporary_file(destination, "helper", 0o755)?;
    io::copy(&mut source_file, &mut temporary)?;
    temporary.as_file().sync_all()?;
    persist_new_file_with_identity(temporary, destination)
}

fn atomic_write_json_new(path: &Path, value: &Value, mode: u32) -> io::Result<PathIdentity> {
    let bytes = serde_json::to_vec_pretty(value)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let mut temporary = exclusive_temporary_file(path, "json", mode)?;
    temporary.write_all(&bytes)?;
    temporary.write_all(b"\n")?;
    temporary.as_file().sync_all()?;
    persist_new_file_with_identity(temporary, path)
}

fn atomic_write_json(path: &Path, value: &Value, mode: u32) -> io::Result<()> {
    let staged_original = match PathIdentity::capture(path)? {
        Some(identity)
            if identity.kind == ManagedPathKind::File
                && identity.owner == unsafe { libc::geteuid() } =>
        {
            Some(quarantine_verified_leaf(
                path,
                identity,
                "json-update-original",
            )?)
        }
        Some(_) => {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                format!("refusing to replace unsafe JSON path: {}", path.display()),
            ));
        }
        None => None,
    };
    match atomic_write_json_new(path, value, mode) {
        Ok(_) => {
            if let Some(stage) = staged_original {
                stage.remove_payload_and_directory("completed JSON update")?;
            }
            Ok(())
        }
        Err(error) => {
            let Some(stage) = staged_original else {
                return Err(error);
            };
            match restore_quarantined_leaf(&stage, path) {
                Ok(()) => Err(error),
                Err(restore_error) => Err(io::Error::other(format!(
                    "{error}; original JSON retained at {} because restoration failed: {restore_error}",
                    stage.payload.display()
                ))),
            }
        }
    }
}

fn persist_new_file_with_identity(
    temporary: tempfile::NamedTempFile,
    destination: &Path,
) -> io::Result<PathIdentity> {
    let expected = PathIdentity::from_metadata(&temporary.as_file().metadata()?);
    temporary
        .persist_noclobber(destination)
        .map_err(|error| error.error)?;
    expected.require_current(destination, "persisted temporary file")?;
    Ok(expected)
}

fn ensure_owned_symlink(path: &Path, target: &Path) -> io::Result<Option<PathIdentity>> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_symlink() && fs::read_link(path)? == target => {
            Ok(None)
        }
        Ok(_) => Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("refusing to replace {}", path.display()),
        )),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {
            let reservation = reserve_sibling_stage(path, "symlink")?;
            symlink(target, &reservation.payload)?;
            let identity = PathIdentity::capture(&reservation.payload)?.ok_or_else(|| {
                io::Error::new(io::ErrorKind::NotFound, "created symlink disappeared")
            })?;
            if identity.kind != ManagedPathKind::Symlink
                || identity.owner != unsafe { libc::geteuid() }
            {
                let staged = OwnedStage {
                    payload: reservation.payload,
                    payload_identity: identity,
                    directory: reservation.directory,
                    directory_identity: reservation.directory_identity,
                };
                let _ = staged.remove_payload_and_directory("unsafe staged symlink");
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "created symlink is unsafe",
                ));
            }
            if let Err(error) = rename_noreplace(&reservation.payload, path) {
                let cleanup = OwnedStage {
                    payload: reservation.payload,
                    payload_identity: identity,
                    directory: reservation.directory,
                    directory_identity: reservation.directory_identity,
                }
                .remove_payload_and_directory("failed symlink installation");
                return match cleanup {
                    Ok(()) => Err(error),
                    Err(cleanup_error) => Err(io::Error::other(format!(
                        "{error}; symlink stage cleanup also failed: {cleanup_error}"
                    ))),
                };
            }
            if let Err(error) = identity.require_current(path, "installed symlink") {
                let _ =
                    remove_stage_directory(&reservation.directory, reservation.directory_identity);
                return Err(io::Error::new(
                    error.kind(),
                    format!("{error}; installed symlink changed before it could be recorded"),
                ));
            }
            remove_stage_directory(&reservation.directory, reservation.directory_identity)?;
            Ok(Some(identity))
        }
        Err(error) => Err(error),
    }
}

pub fn sha256_file(path: &Path) -> io::Result<String> {
    let metadata = fs::symlink_metadata(path)?;
    if !metadata.is_file() || metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("checksum source must be a regular file: {}", path.display()),
        ));
    }
    let expected = PathIdentity::from_metadata(&metadata);
    let mut file = fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
        .open(path)?;
    if PathIdentity::from_metadata(&file.metadata()?) != expected {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("checksum source changed while opening: {}", path.display()),
        ));
    }
    let mut digest = Sha256::new();
    let mut buffer = [0_u8; 64 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        digest.update(&buffer[..count]);
    }
    Ok(digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

pub fn sha256_tree(root: &Path) -> io::Result<String> {
    let root_metadata = fs::symlink_metadata(root)?;
    if !root_metadata.is_dir() || root_metadata.file_type().is_symlink() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "tree checksum root must be a real directory",
        ));
    }

    let mut entries = Vec::new();
    collect_tree_entries(root, &mut entries)?;
    entries.sort_by(|left, right| {
        left.strip_prefix(root)
            .unwrap()
            .as_os_str()
            .as_bytes()
            .cmp(right.strip_prefix(root).unwrap().as_os_str().as_bytes())
    });

    let mut digest = Sha256::new();
    for path in entries {
        let relative = path.strip_prefix(root).map_err(io::Error::other)?;
        let metadata = fs::symlink_metadata(&path)?;
        digest.update(relative.as_os_str().as_bytes());
        digest.update([0]);
        digest.update((metadata.permissions().mode() & 0o7777).to_be_bytes());
        if metadata.is_dir() {
            digest.update(b"d");
        } else if metadata.is_file() {
            digest.update(b"f");
            let expected = PathIdentity::from_metadata(&metadata);
            let mut file = fs::OpenOptions::new()
                .read(true)
                .custom_flags(libc::O_CLOEXEC | libc::O_NOFOLLOW)
                .open(&path)?;
            if PathIdentity::from_metadata(&file.metadata()?) != expected {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    format!("bundle file changed while opening: {}", path.display()),
                ));
            }
            let mut buffer = [0_u8; 64 * 1024];
            loop {
                let count = file.read(&mut buffer)?;
                if count == 0 {
                    break;
                }
                digest.update(&buffer[..count]);
            }
        } else if metadata.file_type().is_symlink() {
            digest.update(b"l");
            digest.update(fs::read_link(&path)?.as_os_str().as_bytes());
        } else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                format!("unsupported bundle entry {}", path.display()),
            ));
        }
        digest.update([0xff]);
    }
    Ok(digest
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

fn collect_tree_entries(directory: &Path, entries: &mut Vec<PathBuf>) -> io::Result<()> {
    for item in fs::read_dir(directory)? {
        let path = item?.path();
        let metadata = fs::symlink_metadata(&path)?;
        entries.push(path.clone());
        if metadata.is_dir() && !metadata.file_type().is_symlink() {
            collect_tree_entries(&path, entries)?;
        }
    }
    Ok(())
}

fn shell_quote(path: &Path) -> String {
    format!("'{}'", path.display().to_string().replace('\'', "'\"'\"'"))
}

fn is_cove_bundle(path: &Path) -> bool {
    if path.file_name().and_then(|name| name.to_str()) != Some("Codex Cove.app") {
        return false;
    }
    has_cove_bundle_identifier(path)
}

fn has_cove_bundle_identifier(path: &Path) -> bool {
    fs::read(path.join("Contents/Info.plist"))
        .map(|bytes| {
            bytes
                .windows(b"local.chris.codexcove".len())
                .any(|window| window == b"local.chris.codexcove")
        })
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{PrivacyMode, REMOTE_HELPER_PATH, RemoteHost};
    use tempfile::tempdir;

    fn executable(path: &Path, contents: &[u8]) {
        fs::write(path, contents).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    fn fake_app(root: &Path) -> PathBuf {
        let app = root.join("Codex Cove.app");
        let contents = app.join("Contents");
        let app_executable = contents.join("MacOS/CodexCove");
        fs::create_dir_all(app_executable.parent().unwrap()).unwrap();
        fs::write(
            contents.join("Info.plist"),
            b"<plist><string>local.chris.codexcove</string></plist>",
        )
        .unwrap();
        executable(&app_executable, b"app");
        app
    }

    fn managed_install_state(layout: &InstallLayout) -> [String; 3] {
        [
            sha256_tree(&layout.support).unwrap(),
            sha256_tree(layout.hooks_path.parent().unwrap()).unwrap(),
            sha256_tree(layout.codex_shim.parent().unwrap()).unwrap(),
        ]
    }

    #[test]
    fn install_plan_preserves_existing_unowned_shim() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        fs::create_dir_all(layout.codex_shim.parent().unwrap()).unwrap();
        fs::write(&layout.codex_shim, b"user binary").unwrap();
        let config = Config::for_home(temp.path());
        let plan = install_plan_for_layout(Path::new("/tmp/helper"), &config, &layout).unwrap();
        assert!(plan.blocked);
    }

    #[test]
    fn structural_merge_preserves_unrelated_hooks_and_is_idempotent() {
        let command = "'/tmp/codex-cove' hook";
        let existing = serde_json::from_value::<Map<String, Value>>(json!({
            "description":"mine",
            "hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}
        }))
        .unwrap();
        let once = merged_hooks(existing, command).unwrap();
        let twice = merged_hooks(once.as_object().unwrap().clone(), command).unwrap();
        assert_eq!(once, twice);
        let stop = twice.pointer("/hooks/Stop").unwrap().as_array().unwrap();
        assert_eq!(stop.len(), 2);
        assert_eq!(
            stop[0].pointer("/hooks/0/command").and_then(Value::as_str),
            Some("mine")
        );
    }

    #[test]
    fn install_and_uninstall_round_trip_in_explicit_temp_home() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        fs::create_dir_all(layout.hooks_path.parent().unwrap()).unwrap();
        fs::write(
            &layout.hooks_path,
            br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#,
        )
        .unwrap();

        apply_install(&source, None, &real, &layout, None).unwrap();
        assert_eq!(
            fs::read_link(&layout.codex_shim).unwrap(),
            layout.managed_binary
        );
        assert_eq!(
            fs::metadata(&layout.managed_binary)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o755
        );
        let hooks: Value = serde_json::from_slice(&fs::read(&layout.hooks_path).unwrap()).unwrap();
        assert_eq!(
            hooks
                .pointer("/hooks/Stop")
                .unwrap()
                .as_array()
                .unwrap()
                .len(),
            2
        );

        apply_uninstall(&layout, false).unwrap();
        assert!(!layout.codex_shim.exists());
        let hooks: Value = serde_json::from_slice(&fs::read(&layout.hooks_path).unwrap()).unwrap();
        assert_eq!(
            hooks.pointer("/hooks/Stop/0/hooks/0/command"),
            Some(&Value::String("mine".to_owned()))
        );
    }

    #[test]
    fn reinstall_preserves_every_valid_config_field_except_real_codex() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source_v1 = temp.path().join("source-helper-v1");
        let source_v2 = temp.path().join("source-helper-v2");
        let real_v1 = temp.path().join("real-codex-v1");
        let real_v2 = temp.path().join("real-codex-v2");
        executable(&source_v1, b"helper-v1");
        executable(&source_v2, b"helper-v2");
        executable(&real_v1, b"codex-v1");
        executable(&real_v2, b"codex-v2");
        apply_install(&source_v1, None, &real_v1, &layout, None).unwrap();

        let mut customized = Config::load_from(&layout.config_path).unwrap();
        customized.runtime_directory = layout.support.join("custom-runtime");
        customized.event_socket = customized.runtime_directory.join("custom-events.sock");
        customized.theme_directory = layout.support.join("Custom Themes");
        customized.privacy = PrivacyMode::On;
        customized.hook_timeout_ms = 4_321;
        customized.broker_start_timeout_ms = 6_789;
        customized.max_frame_bytes = 2_097_152;
        customized.remote_hosts = vec![RemoteHost {
            alias: "dev_host-1.example".to_owned(),
            helper_path: REMOTE_HELPER_PATH.to_owned(),
            enabled: false,
        }];
        customized.save_to(&layout.config_path).unwrap();

        let mut expected = customized.clone();
        expected.real_codex = Some(real_v2.clone());
        apply_install(&source_v2, None, &real_v2, &layout, None).unwrap();

        assert_eq!(Config::load_from(&layout.config_path).unwrap(), expected);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), b"helper-v2");
    }

    #[test]
    fn reinstall_migrates_the_legacy_default_frame_limit() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source_v1 = temp.path().join("source-helper-v1");
        let source_v2 = temp.path().join("source-helper-v2");
        let real_v1 = temp.path().join("real-codex-v1");
        let real_v2 = temp.path().join("real-codex-v2");
        executable(&source_v1, b"helper-v1");
        executable(&source_v2, b"helper-v2");
        executable(&real_v1, b"codex-v1");
        executable(&real_v2, b"codex-v2");
        apply_install(&source_v1, None, &real_v1, &layout, None).unwrap();

        let mut legacy = Config::load_from(&layout.config_path).unwrap();
        legacy.max_frame_bytes = 1_048_576;
        legacy.save_to(&layout.config_path).unwrap();

        apply_install(&source_v2, None, &real_v2, &layout, None).unwrap();

        assert_eq!(
            Config::load_from(&layout.config_path)
                .unwrap()
                .max_frame_bytes,
            crate::DEFAULT_MAX_FRAME_BYTES
        );
    }

    #[test]
    fn malformed_existing_config_blocks_reinstall_without_mutation() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source_v1 = temp.path().join("source-helper-v1");
        let source_v2 = temp.path().join("source-helper-v2");
        let real_v1 = temp.path().join("real-codex-v1");
        let real_v2 = temp.path().join("real-codex-v2");
        executable(&source_v1, b"helper-v1");
        executable(&source_v2, b"helper-v2");
        executable(&real_v1, b"codex-v1");
        executable(&real_v2, b"codex-v2");
        apply_install(&source_v1, None, &real_v1, &layout, None).unwrap();
        fs::write(&layout.config_path, b"{malformed-json\n").unwrap();
        let before = managed_install_state(&layout);

        let error = apply_install(&source_v2, None, &real_v2, &layout, None).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert_eq!(managed_install_state(&layout), before);
    }

    #[test]
    fn unsafe_existing_config_paths_block_reinstall_without_mutation() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source_v1 = temp.path().join("source-helper-v1");
        let source_v2 = temp.path().join("source-helper-v2");
        let real_v1 = temp.path().join("real-codex-v1");
        let real_v2 = temp.path().join("real-codex-v2");
        executable(&source_v1, b"helper-v1");
        executable(&source_v2, b"helper-v2");
        executable(&real_v1, b"codex-v1");
        executable(&real_v2, b"codex-v2");
        apply_install(&source_v1, None, &real_v1, &layout, None).unwrap();
        let mut unsafe_config = Config::load_from(&layout.config_path).unwrap();
        unsafe_config.runtime_directory = temp.path().join("outside-support-runtime");
        unsafe_config.event_socket = unsafe_config.runtime_directory.join("events.sock");
        unsafe_config.save_to(&layout.config_path).unwrap();
        let before = managed_install_state(&layout);

        let error = apply_install(&source_v2, None, &real_v2, &layout, None).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
        assert!(
            error
                .to_string()
                .contains("runtimeDirectory must be contained")
        );
        assert_eq!(managed_install_state(&layout), before);
    }

    #[test]
    fn failed_reinstall_restores_the_exact_existing_config_snapshot() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source_v1 = temp.path().join("source-helper-v1");
        let source_v2 = temp.path().join("source-helper-v2");
        let real_v1 = temp.path().join("real-codex-v1");
        let real_v2 = temp.path().join("real-codex-v2");
        executable(&source_v1, b"helper-v1");
        executable(&source_v2, b"helper-v2");
        executable(&real_v1, b"codex-v1");
        executable(&real_v2, b"codex-v2");
        apply_install(&source_v1, None, &real_v1, &layout, None).unwrap();
        let mut customized = Config::load_from(&layout.config_path).unwrap();
        customized.privacy = PrivacyMode::Off;
        customized.hook_timeout_ms = 2_345;
        customized.save_to(&layout.config_path).unwrap();
        let config_before = fs::read(&layout.config_path).unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let hooks_before = fs::read(&layout.hooks_path).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let shim_before = fs::read_link(&layout.codex_shim).unwrap();
        let management_before = fs::read_link(&layout.management_link).unwrap();

        let error = apply_install_transactional(&source_v2, None, &real_v2, &layout, None, || {
            Err(io::Error::other("injected reinstall failure"))
        })
        .unwrap_err();

        assert!(error.to_string().contains("injected reinstall failure"));
        assert_eq!(fs::read(&layout.config_path).unwrap(), config_before);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.hooks_path).unwrap(), hooks_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert_eq!(fs::read_link(&layout.codex_shim).unwrap(), shim_before);
        assert_eq!(
            fs::read_link(&layout.management_link).unwrap(),
            management_before
        );
    }

    #[test]
    fn schema_one_editor_obligations_are_legacy_safe_and_new_records_are_precise() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");

        let legacy = apply_install(
            &source,
            None,
            &real,
            &layout,
            Some("codex-cove-local.cove-extension"),
        )
        .unwrap();
        assert_eq!(legacy.schema_version, 1);
        assert_eq!(legacy.editor_extension_targets, None);
        assert_eq!(
            legacy.editor_cleanup_targets().unwrap(),
            ["code".to_owned(), "cursor".to_owned()]
        );
        assert!(
            !String::from_utf8(fs::read(&layout.manifest_path).unwrap())
                .unwrap()
                .contains("editorExtensionTargets")
        );

        let precise = record_editor_extension_installation(
            &layout,
            Some("codex-cove-local.cove-extension"),
            &["code".to_owned()],
        )
        .unwrap();
        assert_eq!(precise.editor_cleanup_targets().unwrap(), ["code"]);
        assert_eq!(
            read_manifest(&layout).unwrap().editor_extension_targets,
            Some(vec!["code".to_owned()])
        );
        assert_eq!(
            fs::metadata(&layout.manifest_path)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o600
        );
    }

    #[test]
    fn malformed_editor_cleanup_targets_block_uninstall_preflight() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        apply_install(
            &source,
            None,
            &real,
            &layout,
            Some("codex-cove-local.cove-extension"),
        )
        .unwrap();
        let mut value: Value =
            serde_json::from_slice(&fs::read(&layout.manifest_path).unwrap()).unwrap();
        value["editorExtensionTargets"] = json!(["unknown-editor"]);
        atomic_write_json(&layout.manifest_path, &value, 0o600).unwrap();

        let error = preflight_uninstall(&layout).unwrap_err();
        assert!(
            error
                .to_string()
                .contains("invalid editor cleanup obligations")
        );
        assert!(layout.managed_binary.exists());
        assert!(layout.manifest_path.exists());
    }

    #[test]
    fn uninstall_preserves_modified_managed_binary() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        apply_install(&source, None, &real, &layout, None).unwrap();
        fs::write(&layout.managed_binary, b"modified").unwrap();
        assert!(apply_uninstall(&layout, false).is_err());
        assert!(layout.managed_binary.exists());
        assert!(layout.codex_shim.exists());
    }

    #[test]
    fn replaced_shim_blocks_uninstall_without_mutating_any_artifact() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_app(temp.path());
        executable(&source, b"helper");
        executable(&real, b"codex");
        fs::create_dir_all(layout.hooks_path.parent().unwrap()).unwrap();
        fs::write(
            &layout.hooks_path,
            br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#,
        )
        .unwrap();
        apply_install(&source, Some(&app), &real, &layout, None).unwrap();

        fs::remove_file(&layout.codex_shim).unwrap();
        fs::write(&layout.codex_shim, b"user replacement").unwrap();
        let hooks_before = fs::read(&layout.hooks_path).unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let app_before = sha256_tree(&app).unwrap();
        let management_before = fs::read_link(&layout.management_link).unwrap();

        let plan = uninstall_plan_for_layout(&layout).unwrap();
        assert!(plan.blocked);
        assert!(plan.actions.iter().any(|action| {
            action.kind == "blocked"
                && action.path == layout.codex_shim
                && action.detail.contains("replaced")
        }));
        let error = apply_uninstall(&layout, false).unwrap_err();
        assert!(error.to_string().contains("installation left unchanged"));
        assert_eq!(fs::read(&layout.codex_shim).unwrap(), b"user replacement");
        assert_eq!(fs::read(&layout.hooks_path).unwrap(), hooks_before);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert_eq!(
            fs::read_link(&layout.management_link).unwrap(),
            management_before
        );
        assert_eq!(sha256_tree(&app).unwrap(), app_before);
    }

    #[test]
    fn uninstall_removes_an_unchanged_checksum_matching_app() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_app(temp.path());
        executable(&source, b"helper");
        executable(&real, b"codex");

        let manifest = apply_install(&source, Some(&app), &real, &layout, None).unwrap();
        assert!(manifest.app_bundle_sha256.is_some());
        apply_uninstall(&layout, false).unwrap();
        assert!(!app.exists());
    }

    #[test]
    fn externally_managed_uninstall_preserves_app_and_settings() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_app(temp.path());
        executable(&source, b"helper");
        executable(&real, b"codex");

        apply_install(&source, Some(&app), &real, &layout, None).unwrap();
        let settings = layout.support.join("settings.json");
        fs::write(&settings, b"settings").unwrap();
        let config_before = fs::read(&layout.config_path).unwrap();
        let app_before = sha256_tree(&app).unwrap();

        let plan = uninstall_plan_for_layout_with_options(&layout, true, true).unwrap();
        assert!(!plan.blocked);
        assert!(plan.actions.iter().any(|action| {
            action.kind == "preserveExternallyManagedApp"
                && action.path == app
                && action.detail.contains("external package manager")
        }));

        apply_uninstall_with_options(&layout, true, true).unwrap();

        assert_eq!(sha256_tree(&app).unwrap(), app_before);
        assert_eq!(fs::read(&layout.config_path).unwrap(), config_before);
        assert_eq!(fs::read(&settings).unwrap(), b"settings");
        assert!(!layout.managed_binary.exists());
        assert!(!layout.manifest_path.exists());
        assert!(fs::symlink_metadata(&layout.codex_shim).is_err());
        assert!(fs::symlink_metadata(&layout.management_link).is_err());
    }

    #[test]
    fn externally_managed_uninstall_validates_app_before_external_cleanup() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_app(temp.path());
        executable(&source, b"helper");
        executable(&real, b"codex");

        apply_install(&source, Some(&app), &real, &layout, None).unwrap();
        let hooks_before = fs::read(&layout.hooks_path).unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let app_mutation = app.join("Contents/concurrent-change.txt");

        let mut external_cleanup_called = false;
        let error = apply_uninstall_transactional_with_cleanup_at_validation_boundary(
            &layout,
            true,
            true,
            || {
                fs::write(&app_mutation, b"preserve concurrent app change")?;
                Ok(())
            },
            |_| {
                external_cleanup_called = true;
                Ok(())
            },
            remove_staged_path_identity_bound,
        )
        .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("installed app changed after preflight")
        );
        assert!(
            !external_cleanup_called,
            "external cleanup must not begin until the retained app passes late validation"
        );
        assert_eq!(
            fs::read(&app_mutation).unwrap(),
            b"preserve concurrent app change"
        );
        assert_eq!(fs::read(&layout.hooks_path).unwrap(), hooks_before);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert_eq!(
            fs::read_link(&layout.codex_shim).unwrap(),
            layout.managed_binary
        );
        assert_eq!(
            fs::read_link(&layout.management_link).unwrap(),
            layout.managed_binary
        );
    }

    #[test]
    fn modified_app_blocks_uninstall_and_preserves_every_artifact() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_app(temp.path());
        executable(&source, b"helper");
        executable(&real, b"codex");

        apply_install(&source, Some(&app), &real, &layout, None).unwrap();
        fs::write(app.join("Contents/user-change.txt"), b"preserve me").unwrap();
        let hooks_before = fs::read(&layout.hooks_path).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let error = apply_uninstall(&layout, false).unwrap_err();
        assert!(error.to_string().contains("app bundle checksum changed"));
        assert!(app.exists());
        assert!(layout.managed_binary.exists());
        assert!(layout.codex_shim.exists());
        assert!(layout.management_link.exists());
        assert_eq!(fs::read(&layout.hooks_path).unwrap(), hooks_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
    }

    #[test]
    fn keep_settings_removes_only_integration_artifacts() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        apply_install(&source, None, &real, &layout, None).unwrap();
        let preferences = layout.support.join("preferences.json");
        let sessions = layout.support.join("sessions.sqlite3");
        fs::write(&preferences, b"preferences").unwrap();
        fs::write(&sessions, b"sessions").unwrap();
        let config_before = fs::read(&layout.config_path).unwrap();

        let plan = uninstall_plan_for_layout_with_settings(&layout, true).unwrap();
        assert!(!plan.blocked);
        assert!(plan.actions.iter().any(|action| {
            action.kind == "removeIntegrationKeepSettings"
                && action
                    .detail
                    .contains("retain config, preferences, and session metadata")
        }));
        apply_uninstall(&layout, true).unwrap();

        assert_eq!(fs::read(&layout.config_path).unwrap(), config_before);
        assert_eq!(fs::read(&preferences).unwrap(), b"preferences");
        assert_eq!(fs::read(&sessions).unwrap(), b"sessions");
        assert!(!layout.managed_binary.exists());
        assert!(!layout.manifest_path.exists());
        assert!(!layout.managed_binary.parent().unwrap().exists());
        assert!(fs::symlink_metadata(&layout.codex_shim).is_err());
        assert!(fs::symlink_metadata(&layout.management_link).is_err());
    }

    #[test]
    fn late_install_failure_restores_every_managed_path() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        fs::create_dir_all(layout.hooks_path.parent().unwrap()).unwrap();
        let original_hooks =
            br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#;
        fs::write(&layout.hooks_path, original_hooks).unwrap();
        let before = sha256_tree(temp.path()).unwrap();

        let error = apply_install_transactional(&source, None, &real, &layout, None, || {
            Err(io::Error::other("injected late failure"))
        })
        .unwrap_err();
        assert!(error.to_string().contains("injected late failure"));
        assert!(!layout.managed_binary.exists());
        assert!(!layout.config_path.exists());
        assert!(!layout.manifest_path.exists());
        assert!(fs::symlink_metadata(&layout.codex_shim).is_err());
        assert!(fs::symlink_metadata(&layout.management_link).is_err());
        assert_eq!(fs::read(&layout.hooks_path).unwrap(), original_hooks);
        assert_eq!(sha256_tree(temp.path()).unwrap(), before);
    }

    #[test]
    fn failed_first_install_restores_the_exact_home_tree() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        let before = sha256_tree(temp.path()).unwrap();

        let error = apply_install_transactional(&source, None, &real, &layout, None, || {
            Err(io::Error::other("injected first-install failure"))
        })
        .unwrap_err();

        assert!(error.to_string().contains("injected first-install failure"));
        assert_eq!(sha256_tree(temp.path()).unwrap(), before);
    }

    #[test]
    fn failed_install_restores_existing_support_mode() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        fs::create_dir_all(&layout.support).unwrap();
        fs::set_permissions(&layout.support, fs::Permissions::from_mode(0o500)).unwrap();

        apply_install_transactional(&source, None, &real, &layout, None, || {
            Err(io::Error::other("injected mode rollback"))
        })
        .unwrap_err();

        assert_eq!(
            fs::symlink_metadata(&layout.support)
                .unwrap()
                .permissions()
                .mode()
                & 0o777,
            0o500
        );
        assert_eq!(fs::read_dir(&layout.support).unwrap().count(), 0);
    }

    #[test]
    fn install_rejects_symlinked_managed_parent_without_touching_target() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let external = temp.path().join("external-bin");
        executable(&source, b"helper");
        executable(&real, b"codex");
        fs::create_dir_all(&layout.support).unwrap();
        fs::set_permissions(&layout.support, fs::Permissions::from_mode(0o700)).unwrap();
        fs::create_dir(&external).unwrap();
        fs::write(external.join("sentinel"), b"do not touch").unwrap();
        symlink(&external, layout.managed_binary.parent().unwrap()).unwrap();
        let before = sha256_tree(&external).unwrap();

        let error = apply_install(&source, None, &real, &layout, None).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(sha256_tree(&external).unwrap(), before);
        assert!(!external.join("codex-cove").exists());
    }

    #[test]
    fn install_rejects_symlinked_hooks_leaf_without_touching_target() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let external = temp.path().join("external-hooks.json");
        executable(&source, b"helper");
        executable(&real, b"codex");
        fs::write(&external, b"sentinel hooks").unwrap();
        fs::create_dir_all(layout.hooks_path.parent().unwrap()).unwrap();
        symlink(&external, &layout.hooks_path).unwrap();

        let error = apply_install(&source, None, &real, &layout, None).unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert_eq!(fs::read(&external).unwrap(), b"sentinel hooks");
        assert_eq!(fs::read_link(&layout.hooks_path).unwrap(), external);
    }

    #[test]
    fn install_rollback_preserves_same_contents_new_inode_and_retains_original() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source_v1 = temp.path().join("source-helper-v1");
        let source_v2 = temp.path().join("source-helper-v2");
        let real = temp.path().join("real-codex");
        executable(&source_v1, b"helper-v1");
        executable(&source_v2, b"helper-v2");
        executable(&real, b"codex");
        apply_install(&source_v1, None, &real, &layout, None).unwrap();
        let original = fs::read(&layout.config_path).unwrap();

        let error = apply_install_transactional(&source_v2, None, &real, &layout, None, || {
            fs::remove_file(&layout.config_path)?;
            fs::write(&layout.config_path, &original)?;
            fs::set_permissions(&layout.config_path, fs::Permissions::from_mode(0o600))?;
            Err(io::Error::other("injected concurrent config replacement"))
        })
        .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("concurrent replacement preserved")
        );
        assert_eq!(fs::read(&layout.config_path).unwrap(), original);
        let retained = fs::read_dir(&layout.support)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".codex-cove-install-stage."))
                    && path.join("helper-config.json").is_file()
            })
            .expect("the original config inode must remain in a recovery stage");
        assert_eq!(
            fs::read(retained.join("helper-config.json")).unwrap(),
            original
        );
    }

    #[test]
    fn install_rollback_never_removes_a_concurrent_directory_replacement() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source_v1 = temp.path().join("source-helper-v1");
        let source_v2 = temp.path().join("source-helper-v2");
        let real = temp.path().join("real-codex");
        executable(&source_v1, b"helper-v1");
        executable(&source_v2, b"helper-v2");
        executable(&real, b"codex");
        apply_install(&source_v1, None, &real, &layout, None).unwrap();

        let error = apply_install_transactional(&source_v2, None, &real, &layout, None, || {
            fs::remove_file(&layout.config_path)?;
            fs::create_dir(&layout.config_path)?;
            fs::write(layout.config_path.join("sentinel"), b"concurrent")?;
            Err(io::Error::other("injected concurrent directory"))
        })
        .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("concurrent replacement preserved")
        );
        assert_eq!(
            fs::read(layout.config_path.join("sentinel")).unwrap(),
            b"concurrent"
        );
    }

    #[test]
    fn late_uninstall_failure_rolls_back_hooks_links_app_and_support_tree() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        let app = fake_app(temp.path());
        executable(&source, b"helper");
        executable(&real, b"codex");
        fs::create_dir_all(layout.hooks_path.parent().unwrap()).unwrap();
        fs::write(
            &layout.hooks_path,
            br#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"mine"}]}]}}"#,
        )
        .unwrap();
        apply_install(&source, Some(&app), &real, &layout, None).unwrap();
        let settings = layout.support.join("preferences.json");
        fs::write(&settings, b"settings").unwrap();
        let hooks_before = fs::read(&layout.hooks_path).unwrap();
        let helper_before = fs::read(&layout.managed_binary).unwrap();
        let manifest_before = fs::read(&layout.manifest_path).unwrap();
        let config_before = fs::read(&layout.config_path).unwrap();
        let app_before = sha256_tree(&app).unwrap();

        let error = apply_uninstall_transactional(&layout, false, || {
            Err(io::Error::other("injected late uninstall failure"))
        })
        .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("injected late uninstall failure")
        );
        assert_eq!(fs::read(&layout.hooks_path).unwrap(), hooks_before);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), helper_before);
        assert_eq!(fs::read(&layout.manifest_path).unwrap(), manifest_before);
        assert_eq!(fs::read(&layout.config_path).unwrap(), config_before);
        assert_eq!(fs::read(&settings).unwrap(), b"settings");
        assert_eq!(
            fs::read_link(&layout.codex_shim).unwrap(),
            layout.managed_binary
        );
        assert_eq!(
            fs::read_link(&layout.management_link).unwrap(),
            layout.managed_binary
        );
        assert_eq!(sha256_tree(&app).unwrap(), app_before);
        let rollback_names = [
            layout.support.parent().unwrap(),
            layout.hooks_path.parent().unwrap(),
            layout.codex_shim.parent().unwrap(),
            app.parent().unwrap(),
        ]
        .into_iter()
        .flat_map(|directory| fs::read_dir(directory).unwrap())
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.contains(".codex-cove-uninstall-"))
        .collect::<Vec<_>>();
        assert!(rollback_names.is_empty(), "{rollback_names:?}");
    }

    #[test]
    fn uninstall_stage_rejects_same_contents_new_inode_after_preflight() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        apply_install(&source, None, &real, &layout, None).unwrap();
        let preflight = preflight_uninstall(&layout).unwrap();
        let original_copy = temp.path().join("original-helper");
        fs::rename(&layout.managed_binary, &original_copy).unwrap();
        executable(&layout.managed_binary, b"helper");

        let mut transaction = UninstallTransaction::default();
        let error = transaction
            .stage(
                &layout.managed_binary,
                preflight.identity_for(&layout.managed_binary).unwrap(),
            )
            .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&layout.managed_binary).unwrap(), b"helper");
        assert_eq!(fs::read(&original_copy).unwrap(), b"helper");
    }

    #[test]
    fn uninstall_rollback_never_recursively_deletes_unverified_replacement() {
        let temp = tempdir().unwrap();
        let original = temp.path().join("hooks.json");
        fs::write(&original, b"original").unwrap();
        let expected = PathIdentity::capture(&original).unwrap();
        let mut transaction = UninstallTransaction::default();
        let staged = transaction.stage(&original, expected).unwrap().unwrap();
        fs::write(&original, b"transaction replacement").unwrap();
        let replacement = PathIdentity::capture(&original).unwrap().unwrap();
        transaction
            .mark_replacement(&original, replacement)
            .unwrap();
        fs::remove_file(&original).unwrap();
        fs::create_dir(&original).unwrap();
        fs::write(original.join("sentinel"), b"concurrent").unwrap();

        let error = transaction.rollback().unwrap_err();

        assert!(
            error
                .to_string()
                .contains("concurrent replacement preserved")
        );
        assert_eq!(fs::read(original.join("sentinel")).unwrap(), b"concurrent");
        assert_eq!(fs::read(&staged).unwrap(), b"original");
    }

    #[test]
    fn uninstall_commit_refuses_a_replaced_staged_root() {
        let temp = tempdir().unwrap();
        let original = temp.path().join("support");
        fs::create_dir(&original).unwrap();
        fs::write(original.join("settings.json"), b"original").unwrap();
        let expected = PathIdentity::capture(&original).unwrap();
        let mut transaction = UninstallTransaction::default();
        let staged = transaction.stage(&original, expected).unwrap().unwrap();
        let retained_original = staged.with_file_name("retained-original");
        fs::rename(&staged, &retained_original).unwrap();
        fs::create_dir(&staged).unwrap();
        fs::write(staged.join("sentinel"), b"concurrent").unwrap();

        let error = transaction
            .commit_with(remove_staged_path_identity_bound)
            .unwrap_err();

        assert!(error.to_string().contains("commit validation failed"));
        assert_eq!(fs::read(staged.join("sentinel")).unwrap(), b"concurrent");
        assert_eq!(
            fs::read(retained_original.join("settings.json")).unwrap(),
            b"original"
        );
    }

    #[test]
    fn uninstall_cleanup_never_recurses_into_a_root_swapped_after_commit_validation() {
        let temp = tempdir().unwrap();
        let original = temp.path().join("support");
        fs::create_dir(&original).unwrap();
        fs::write(original.join("settings.json"), b"original").unwrap();
        let expected = PathIdentity::capture(&original).unwrap();
        let mut transaction = UninstallTransaction::default();
        let staged = transaction.stage(&original, expected).unwrap().unwrap();
        let retained_original = staged.with_file_name("retained-original");

        let error = transaction
            .commit_with(|entry| {
                fs::rename(&entry.staged, &retained_original)?;
                fs::create_dir(&entry.staged)?;
                fs::write(entry.staged.join("sentinel"), b"concurrent")?;
                remove_staged_path_identity_bound(entry)
            })
            .unwrap_err();

        assert!(
            error
                .to_string()
                .contains("uninstall committed but cleanup incomplete")
        );
        assert!(!original.exists(), "commit point must never roll back");
        assert_eq!(fs::read(staged.join("sentinel")).unwrap(), b"concurrent");
        assert_eq!(
            fs::read(retained_original.join("settings.json")).unwrap(),
            b"original"
        );
    }

    #[test]
    fn recursive_cleanup_refuses_an_injected_cross_filesystem_entry() {
        let staged_device = 41;
        for kind in [ManagedPathKind::Directory, ManagedPathKind::File] {
            let mounted_entry = PathIdentity {
                device: staged_device + 1,
                inode: 99,
                owner: unsafe { libc::geteuid() },
                kind,
            };

            let error = validate_recursive_device_boundary(
                mounted_entry,
                staged_device,
                Path::new("/private-stage/mounted-entry"),
            )
            .unwrap_err();

            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
            assert!(error.to_string().contains("filesystem boundary"));
        }
    }

    #[test]
    fn recursive_cleanup_unlinks_a_symlink_without_touching_its_external_target() {
        let temp = tempdir().unwrap();
        let external = temp.path().join("external");
        fs::create_dir(&external).unwrap();
        fs::write(external.join("sentinel"), b"preserve").unwrap();

        let original = temp.path().join("support");
        fs::create_dir(&original).unwrap();
        symlink(&external, original.join("external-link")).unwrap();
        let expected = PathIdentity::capture(&original).unwrap();
        let mut transaction = UninstallTransaction::default();
        transaction.stage(&original, expected).unwrap().unwrap();

        transaction
            .commit_with(remove_staged_path_identity_bound)
            .unwrap();

        assert!(!original.exists());
        assert_eq!(fs::read(external.join("sentinel")).unwrap(), b"preserve");
    }

    #[test]
    fn partial_recursive_cleanup_failure_retains_only_recovery_and_stays_committed() {
        let temp = tempdir().unwrap();
        let original = temp.path().join("support");
        fs::create_dir(&original).unwrap();
        fs::write(original.join("already-removed.json"), b"removed").unwrap();
        fs::write(original.join("retained.json"), b"retained").unwrap();
        let expected = PathIdentity::capture(&original).unwrap();
        let mut transaction = UninstallTransaction::default();
        let staged = transaction.stage(&original, expected).unwrap().unwrap();

        let error = transaction
            .commit_with(|entry| {
                fs::remove_file(entry.staged.join("already-removed.json"))?;
                Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "injected mid-tree cleanup denial",
                ))
            })
            .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(
            error
                .to_string()
                .contains("uninstall committed but cleanup incomplete")
        );
        assert!(error.to_string().contains("verified private recovery"));
        assert!(!original.exists(), "commit point must never roll back");
        assert!(!staged.join("already-removed.json").exists());
        assert_eq!(fs::read(staged.join("retained.json")).unwrap(), b"retained");
    }

    #[test]
    fn staging_directories_are_random_exclusive_and_private() {
        let temp = tempdir().unwrap();
        let first = temp.path().join("first");
        let second = temp.path().join("second");
        fs::write(&first, b"first").unwrap();
        fs::write(&second, b"second").unwrap();
        let first_identity = PathIdentity::capture(&first).unwrap();
        let second_identity = PathIdentity::capture(&second).unwrap();
        let mut transaction = UninstallTransaction::default();
        let first_stage = transaction.stage(&first, first_identity).unwrap().unwrap();
        let second_stage = transaction
            .stage(&second, second_identity)
            .unwrap()
            .unwrap();

        assert_ne!(first_stage.parent(), second_stage.parent());
        for directory in [
            first_stage.parent().unwrap(),
            second_stage.parent().unwrap(),
        ] {
            let metadata = fs::symlink_metadata(directory).unwrap();
            assert!(metadata.is_dir());
            assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
            assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
        }

        transaction.rollback().unwrap();
        assert_eq!(fs::read(&first).unwrap(), b"first");
        assert_eq!(fs::read(&second).unwrap(), b"second");
    }

    #[test]
    fn commit_cleanup_failure_is_explicit_and_retains_private_recovery() {
        let temp = tempdir().unwrap();
        let original = temp.path().join("Codex Cove");
        fs::create_dir(&original).unwrap();
        fs::write(original.join("install-manifest.json"), b"retry state").unwrap();
        let mut transaction = UninstallTransaction::default();
        let expected = PathIdentity::capture(&original).unwrap();
        let staged = transaction.stage(&original, expected).unwrap().unwrap();

        let error = transaction
            .commit_with(|entry| {
                if entry.staged == staged {
                    Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "injected cleanup denial",
                    ))
                } else {
                    remove_staged_path_identity_bound(entry)
                }
            })
            .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(
            error
                .to_string()
                .contains("uninstall committed but cleanup incomplete")
        );
        assert!(error.to_string().contains("verified private recovery"));
        assert!(!original.exists());
        assert_eq!(
            fs::read(staged.join("install-manifest.json")).unwrap(),
            b"retry state"
        );
    }

    #[test]
    fn uninstall_commit_cleanup_failure_keeps_logically_uninstalled_state() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        apply_install(&source, None, &real, &layout, None).unwrap();
        fs::write(layout.support.join("settings.json"), b"settings").unwrap();

        let support_name = layout.support.file_name().unwrap().to_owned();
        let error = apply_uninstall_transactional_with_cleanup(
            &layout,
            false,
            || Ok(()),
            |entry| {
                let is_staged_support = entry
                    .staged
                    .file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name == support_name)
                    && entry
                        .staged
                        .parent()
                        .and_then(Path::file_name)
                        .and_then(|name| name.to_str())
                        .is_some_and(|name| name.starts_with(".codex-cove-uninstall-stage."));
                if is_staged_support {
                    Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "injected staged support cleanup denial",
                    ))
                } else {
                    remove_staged_path_identity_bound(entry)
                }
            },
        )
        .unwrap_err();

        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(
            error
                .to_string()
                .contains("uninstall committed but cleanup incomplete")
        );
        assert!(!layout.support.exists());
        assert!(fs::symlink_metadata(&layout.codex_shim).is_err());
        assert!(fs::symlink_metadata(&layout.management_link).is_err());
        let recovery = fs::read_dir(layout.support.parent().unwrap())
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".codex-cove-uninstall-stage."))
                    && path.join(&support_name).is_dir()
            })
            .expect("support recovery must remain private and discoverable");
        assert_eq!(
            fs::read(recovery.join(&support_name).join("settings.json")).unwrap(),
            b"settings"
        );
    }

    #[test]
    fn keep_settings_commit_failure_after_helper_cleanup_stays_committed() {
        let temp = tempdir().unwrap();
        let layout = InstallLayout::for_home(temp.path());
        let source = temp.path().join("source-helper");
        let real = temp.path().join("real-codex");
        executable(&source, b"helper");
        executable(&real, b"codex");
        apply_install(&source, None, &real, &layout, None).unwrap();
        let settings = layout.support.join("settings.json");
        fs::write(&settings, b"settings").unwrap();
        let helper_parent = layout.managed_binary.parent().unwrap().to_path_buf();
        let manifest_parent = layout.manifest_path.parent().unwrap().to_path_buf();
        let mut helper_snapshot_deleted = false;
        let error = apply_uninstall_transactional_with_cleanup(
            &layout,
            true,
            || Ok(()),
            |entry| {
                let name = entry
                    .staged
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or_default();
                let stage_parent = entry.staged.parent();
                let is_random_stage = stage_parent
                    .and_then(Path::file_name)
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".codex-cove-uninstall-stage."));
                let original_parent = stage_parent.and_then(Path::parent);
                let is_helper_snapshot = original_parent == Some(helper_parent.as_path())
                    && is_random_stage
                    && name == "codex-cove";
                let is_manifest_snapshot = original_parent == Some(manifest_parent.as_path())
                    && is_random_stage
                    && name == "install-manifest.json";
                if is_manifest_snapshot {
                    assert!(
                        helper_snapshot_deleted,
                        "helper cleanup must precede the injected manifest failure"
                    );
                    return Err(io::Error::new(
                        io::ErrorKind::PermissionDenied,
                        "injected staged manifest cleanup denial",
                    ));
                }
                remove_staged_path_identity_bound(entry)?;
                if is_helper_snapshot {
                    helper_snapshot_deleted = true;
                }
                Ok(())
            },
        )
        .unwrap_err();

        assert!(helper_snapshot_deleted);
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
        assert!(
            error
                .to_string()
                .contains("uninstall committed but cleanup incomplete")
        );
        assert!(!layout.managed_binary.exists());
        assert!(!layout.manifest_path.exists());
        assert_eq!(fs::read(&settings).unwrap(), b"settings");
        let manifest_recovery = fs::read_dir(&layout.support)
            .unwrap()
            .filter_map(Result::ok)
            .map(|entry| entry.path())
            .find(|path| {
                path.file_name()
                    .and_then(|name| name.to_str())
                    .is_some_and(|name| name.starts_with(".codex-cove-uninstall-stage."))
                    && path.join("install-manifest.json").is_file()
            })
            .expect("manifest recovery stage must be retained");
        assert!(manifest_recovery.join("install-manifest.json").exists());
    }

    #[test]
    fn shell_quotes_paths() {
        assert_eq!(
            shell_quote(Path::new("/tmp/Codex Cove's/bin")),
            "'/tmp/Codex Cove'\"'\"'s/bin'"
        );
    }
}
