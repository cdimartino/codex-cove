use crate::CoveEvent;
use std::fs;
use std::io::{self, BufRead, Read, Write};
use std::os::unix::fs::{FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::time::Duration;

pub fn send_event(
    socket: &Path,
    event: &CoveEvent,
    timeout: Duration,
    max_bytes: usize,
) -> io::Result<Option<Vec<u8>>> {
    let encoded = serde_json::to_vec(event)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if encoded.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "event exceeds maximum frame size",
        ));
    }
    let mut stream = UnixStream::connect(socket)?;
    stream.set_write_timeout(Some(timeout))?;
    stream.set_read_timeout(Some(timeout))?;
    stream.write_all(&encoded)?;
    stream.write_all(b"\n")?;
    stream.flush()?;

    let mut response = Vec::new();
    let mut chunk = [0_u8; 4_096];
    loop {
        match stream.read(&mut chunk) {
            Ok(0) => break,
            Ok(read) => {
                response.extend_from_slice(&chunk[..read]);
                if response.len() > max_bytes {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "response exceeds maximum frame size",
                    ));
                }
                if response.contains(&b'\n') {
                    break;
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::TimedOut | io::ErrorKind::WouldBlock
                ) =>
            {
                break;
            }
            Err(error) => return Err(error),
        }
    }
    if response.is_empty() {
        Ok(None)
    } else {
        Ok(Some(response))
    }
}

pub fn send_event_one_way(
    socket: &Path,
    event: &CoveEvent,
    timeout: Duration,
    max_bytes: usize,
) -> io::Result<()> {
    let encoded = serde_json::to_vec(event)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if encoded.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "event exceeds maximum frame size",
        ));
    }
    let mut stream = UnixStream::connect(socket)?;
    stream.set_write_timeout(Some(timeout))?;
    stream.write_all(&encoded)?;
    stream.write_all(b"\n")?;
    stream.flush()?;
    stream.shutdown(std::net::Shutdown::Write)
}

pub fn bind_private_listener(path: &Path) -> io::Result<UnixListener> {
    match fs::symlink_metadata(path) {
        Ok(metadata)
            if metadata.file_type().is_socket() && metadata.uid() == unsafe { libc::geteuid() } =>
        {
            fs::remove_file(path)?;
        }
        Ok(_) => {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!(
                    "refusing to replace non-owned or non-socket {}",
                    path.display()
                ),
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "socket has no parent"))?;
    fs::create_dir_all(parent)?;
    let parent_metadata = fs::symlink_metadata(parent)?;
    if !parent_metadata.file_type().is_dir() || parent_metadata.uid() != unsafe { libc::geteuid() }
    {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "socket parent must be a user-owned directory",
        ));
    }
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let listener = UnixListener::bind(path)?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

pub fn read_limited_line<R: BufRead>(
    reader: &mut R,
    max_bytes: usize,
) -> io::Result<Option<Vec<u8>>> {
    let mut line = Vec::new();
    let read = reader
        .take(max_bytes.saturating_add(1) as u64)
        .read_until(b'\n', &mut line)?;
    if read == 0 {
        return Ok(None);
    }
    if line.len() > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "line exceeds maximum frame size",
        ));
    }
    Ok(Some(line))
}

pub fn write_length_frame<W: Write>(
    writer: &mut W,
    payload: &[u8],
    max_bytes: usize,
) -> io::Result<()> {
    if payload.len() > max_bytes || payload.len() > u32::MAX as usize {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "payload exceeds maximum frame size",
        ));
    }
    writer.write_all(&(payload.len() as u32).to_be_bytes())?;
    writer.write_all(payload)?;
    writer.flush()
}

pub fn read_length_frame<R: Read>(reader: &mut R, max_bytes: usize) -> io::Result<Option<Vec<u8>>> {
    let mut header = [0_u8; 4];
    match reader.read_exact(&mut header) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(error) => return Err(error),
    }
    let length = u32::from_be_bytes(header) as usize;
    if length > max_bytes {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds maximum frame size",
        ));
    }
    let mut payload = vec![0_u8; length];
    reader.read_exact(&mut payload)?;
    Ok(Some(payload))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn length_frames_round_trip() {
        let mut bytes = Vec::new();
        write_length_frame(&mut bytes, b"hello", 100).unwrap();
        assert_eq!(
            read_length_frame(&mut bytes.as_slice(), 100).unwrap(),
            Some(b"hello".to_vec())
        );
    }

    #[test]
    fn length_frames_enforce_limit_before_allocation() {
        let bytes = (1_000_u32).to_be_bytes();
        let error = read_length_frame(&mut bytes.as_slice(), 10).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn private_listener_refuses_regular_file() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("events.sock");
        fs::write(&path, b"preserve").unwrap();
        let error = bind_private_listener(&path).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
        assert_eq!(fs::read(&path).unwrap(), b"preserve");
    }
}
