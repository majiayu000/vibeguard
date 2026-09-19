//! Preserve user-file metadata on the temporary inode before atomic replacement.
use std::fs::File;
use std::io;
use std::os::unix::fs::{MetadataExt, fchown};
use xattr::FileExt;

pub(super) fn copy(source: &File, destination: &File) -> io::Result<()> {
    let source_stat = source.metadata()?;
    let destination_stat = destination.metadata()?;
    if source_stat.uid() != destination_stat.uid() || source_stat.gid() != destination_stat.gid() {
        fchown(
            destination,
            Some(source_stat.uid()),
            Some(source_stat.gid()),
        )?;
    }
    let names: Vec<_> = source.list_xattr()?.collect();
    // Installing an owner-read-only POSIX ACL immediately changes the mode.
    // Copy user xattrs first while the new inode is still writable.
    #[cfg(target_os = "linux")]
    let names = {
        let mut names = names;
        names.sort_by_key(|name| name == "system.posix_acl_access");
        names
    };
    for name in destination.list_xattr()? {
        if !names.contains(&name) {
            destination.remove_xattr(&name)?;
        }
    }
    for name in names {
        let value = source.get_xattr(&name)?.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::NotFound,
                "source extended attribute disappeared",
            )
        })?;
        destination.set_xattr(&name, &value)?;
    }
    // Apply the source mode after xattrs: a read-only source mode would prevent
    // writing user xattrs. Its group bits already reflect its POSIX ACL mask.
    // This also restores any mode bits cleared by chown.
    destination.set_permissions(source_stat.permissions())?;
    #[cfg(target_os = "macos")]
    copy_acl(source, destination)?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn copy_acl(source: &File, destination: &File) -> io::Result<()> {
    use std::ffi::{c_int, c_void};
    use std::os::fd::AsRawFd;

    // Darwin <sys/acl.h>: ACL_TYPE_EXTENDED and the opaque acl_t API.
    const ACL_TYPE_EXTENDED: c_int = 0x100;
    unsafe extern "C" {
        fn acl_get_fd_np(fd: c_int, kind: c_int) -> *mut c_void;
        fn acl_set_fd_np(fd: c_int, acl: *mut c_void, kind: c_int) -> c_int;
        fn acl_free(acl: *mut c_void) -> c_int;
        fn acl_init(count: c_int) -> *mut c_void;
    }
    // SAFETY: both descriptors belong to live Files. The returned ACL is an
    // opaque owned allocation, passed unchanged to set and freed exactly once.
    let mut acl = unsafe { acl_get_fd_np(source.as_raw_fd(), ACL_TYPE_EXTENDED) };
    if acl.is_null() {
        let error = io::Error::last_os_error();
        // Darwin returns ENOENT for an existing file without an extended ACL.
        // Install an empty ACL to remove any ACL inherited by the temporary file.
        if error.kind() != io::ErrorKind::NotFound {
            return Err(error);
        }
        acl = unsafe { acl_init(0) };
        if acl.is_null() {
            return Err(io::Error::last_os_error());
        }
    }
    let set_result =
        if unsafe { acl_set_fd_np(destination.as_raw_fd(), acl, ACL_TYPE_EXTENDED) } == 0 {
            Ok(())
        } else {
            Err(io::Error::last_os_error())
        };
    let free_result = if unsafe { acl_free(acl) } == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    };
    set_result.and(free_result)
}
