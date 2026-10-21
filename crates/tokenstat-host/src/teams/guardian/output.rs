// SPDX-License-Identifier: LicenseRef-tokenstat-source-available

//! Read only this guardian's fresh backend stdout. The stable file handle is
//! never replaced by a provider session file, and EOF is not process exit.

use crate::transcript::{Event, Parser};
use std::{
    fs::{File, OpenOptions},
    io::{self, Read},
    path::{Path, PathBuf},
};

const RAW_LIMIT: u64 = 8 * 1024 * 1024;
pub(super) struct Output {
    path: PathBuf,
    file: Option<File>,
    parser: Parser,
    batch: u32,
}
impl Output {
    pub fn new(path: &Path, backend: &str) -> Self {
        Self {
            path: path.into(),
            file: None,
            parser: Parser::for_team(backend),
            batch: 0,
        }
    }
    pub fn drain(
        &mut self,
        finished: bool,
        mut append: impl FnMut(u32, Vec<Event>) -> io::Result<()>,
    ) -> io::Result<()> {
        if self.file.is_none() {
            let mut options = OpenOptions::new();
            options.read(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.custom_flags(libc::O_NOFOLLOW);
            }
            let file = options.open(&self.path)?;
            let metadata = file.metadata()?;
            #[cfg(windows)]
            {
                use std::os::windows::fs::MetadataExt;
                if metadata.file_attributes() & 0x400 != 0 {
                    return Err(io::Error::other("Invalid output file."));
                }
            }
            if !metadata.is_file() {
                return Err(io::Error::other("Invalid output file."));
            }
            self.file = Some(file);
        }
        let file = self
            .file
            .as_mut()
            .ok_or_else(|| io::Error::other("Missing output."))?;
        if file.metadata()?.len() > RAW_LIMIT {
            return Err(io::Error::other("Team output exceeded its limit."));
        }
        let mut bytes = [0; 32 * 1024];
        // Live drains yield after 128 KiB so output cannot starve authority,
        // Stop or process checks. Final drains happen after owned OS cleanup.
        let chunks = if finished {
            RAW_LIMIT as usize / bytes.len() + 1
        } else {
            4
        };
        for _ in 0..chunks {
            let n = file.read(&mut bytes)?;
            if n == 0 {
                if finished {
                    let events = self.parser.finish_events();
                    self.parser.take_images();
                    if !events.is_empty() {
                        append(self.batch, events)?;
                        self.batch = self
                            .batch
                            .checked_add(1)
                            .ok_or_else(|| io::Error::other("Too many output batches."))?;
                    }
                }
                break;
            }
            let events = self.parser.push_events(&bytes[..n]);
            // Attachments require their own scoped storage flow. Never copy
            // files observed by the personal image collector into this chat.
            self.parser.take_images();
            if !events.is_empty() {
                append(self.batch, events)?;
                self.batch = self
                    .batch
                    .checked_add(1)
                    .ok_or_else(|| io::Error::other("Too many output batches."))?;
            }
        }
        Ok(())
    }
}
