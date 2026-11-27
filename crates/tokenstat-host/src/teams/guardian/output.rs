// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
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
    backend: String,
    batch: u32,
}
impl Output {
    pub fn new(path: &Path, backend: &str) -> Self {
        Self {
            path: path.into(),
            file: None,
            parser: Parser::for_team(backend),
            backend: backend.into(),
            batch: 0,
        }
    }
    /// Read a later attempt's output file, continuing the batch numbering.
    pub fn follow(&mut self, path: &Path) {
        self.path = path.into();
        self.file = None;
        self.parser = Parser::for_team(&self.backend);
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
    /// One line from tokenstat itself after the agent's own output, such as
    /// what happened when its work was landed.
    pub fn note(
        &mut self,
        text: &str,
        mut append: impl FnMut(u32, Vec<Event>) -> io::Result<()>,
    ) -> io::Result<()> {
        append(self.batch, vec![Event::Text { delta: text.into() }])?;
        self.batch = self
            .batch
            .checked_add(1)
            .ok_or_else(|| io::Error::other("Too many output batches."))?;
        Ok(())
    }
}
