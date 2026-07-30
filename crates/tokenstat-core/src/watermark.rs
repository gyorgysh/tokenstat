//! Per-file scan state, so a rescan reads only what changed.
//!
//! A full scan here walks 4,850 files and 1.2 GB. That is fast enough to feel
//! instant once, but it is wasted work on every subsequent run, and a statusline
//! that runs on every shell prompt cannot afford it at all.
//!
//! The cheap check is `(size, mtime)`. When either moved, a signature over the
//! head of the file distinguishes the three things that can have happened:
//! content was appended, the file was truncated, or it was rewritten in place.
//! Only the first is resumable.

use serde::{Deserialize, Serialize};

/// What changed about a file since it was last read.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Change {
    /// Nothing moved. The file does not need to be opened.
    Unchanged,
    /// Content was added. Everything before `from_byte` was already ingested.
    Appended { from_byte: u64 },
    /// Truncated or rewritten. It has to be read from the start.
    Rewritten,
    /// Never seen before.
    New,
}

/// Recorded state for one file.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Watermark {
    pub size: u64,
    pub mtime_ms: i64,
    /// Signature over the first [`Watermark::sig_len`] bytes of the file.
    pub head_sig: String,
    /// How many bytes the signature covers.
    ///
    /// Needed because a file shorter than [`HEAD_BYTES`] is signed whole. Without
    /// recording the length, appending to a small file would change its
    /// signature and make every append look like a rewrite, so files under 4 KB
    /// would be re-read in full on every scan forever.
    pub sig_len: u64,
    /// Offset of the last complete line that was ingested.
    pub byte_offset: u64,
}

/// How much of a file's head is signed.
///
/// Enough to catch a rewrite, small enough that checking it costs one read of a
/// single disk block.
pub const HEAD_BYTES: usize = 4096;

/// Sign the first `len` bytes, or the whole slice if it is shorter.
pub fn signature_of(contents: &[u8], len: usize) -> String {
    let head = &contents[..contents.len().min(len)];
    blake3::hash(head).to_hex()[..16].to_string()
}

/// Signature and the length it covers, for a freshly read file.
pub fn head_signature(contents: &[u8]) -> (String, u64) {
    let len = contents.len().min(HEAD_BYTES);
    (signature_of(contents, len), len as u64)
}

/// Classify a file against its recorded watermark.
pub fn classify(previous: Option<&Watermark>, size: u64, mtime_ms: i64) -> Change {
    match previous {
        None => Change::New,
        Some(w) => {
            if w.size == size && w.mtime_ms == mtime_ms {
                Change::Unchanged
            } else if size < w.byte_offset {
                // Fewer bytes than were already consumed: the file cannot be an
                // extension of what was read.
                Change::Rewritten
            } else {
                // Provisional. The head signature decides, but that needs the
                // file open, so the caller confirms.
                Change::Appended {
                    from_byte: w.byte_offset,
                }
            }
        }
    }
}

/// Confirm an append by checking the head is unchanged.
///
/// A rotated or rewritten file can be larger than before while sharing none of
/// its history, so growth alone is not proof that the tail is new content.
pub fn confirm(change: Change, previous: Option<&Watermark>, contents: &[u8]) -> Change {
    match (change, previous) {
        (Change::Appended { from_byte }, Some(w)) => {
            // Compare the same prefix that was signed last time. Signing the
            // new file's own head would differ purely because it grew.
            if contents.len() as u64 >= w.sig_len
                && signature_of(contents, w.sig_len as usize) == w.head_sig
            {
                Change::Appended { from_byte }
            } else {
                Change::Rewritten
            }
        }
        (other, _) => other,
    }
}

/// Offset of the end of the last complete line.
///
/// A scan can race a tool that is midway through writing a line. Stopping at the
/// last newline means the partial line is re-read next time rather than being
/// parsed as truncated JSON and warned about forever.
pub fn last_complete_line_end(contents: &[u8]) -> u64 {
    match contents.iter().rposition(|b| *b == b'\n') {
        Some(i) => i as u64 + 1,
        None => 0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn wm(size: u64, mtime: i64, sig: &str, offset: u64) -> Watermark {
        Watermark {
            size,
            mtime_ms: mtime,
            head_sig: sig.to_string(),
            sig_len: size,
            byte_offset: offset,
        }
    }

    fn wm_of(contents: &[u8], mtime: i64, offset: u64) -> Watermark {
        let (sig, sig_len) = head_signature(contents);
        Watermark {
            size: contents.len() as u64,
            mtime_ms: mtime,
            head_sig: sig,
            sig_len,
            byte_offset: offset,
        }
    }

    #[test]
    fn unseen_files_are_new() {
        assert_eq!(classify(None, 100, 1), Change::New);
    }

    #[test]
    fn identical_size_and_mtime_means_skip() {
        let w = wm(100, 5, "sig", 100);
        assert_eq!(classify(Some(&w), 100, 5), Change::Unchanged);
    }

    #[test]
    fn growth_is_provisionally_an_append() {
        let w = wm(100, 5, "sig", 100);
        assert_eq!(
            classify(Some(&w), 250, 9),
            Change::Appended { from_byte: 100 }
        );
    }

    #[test]
    fn shrinking_below_the_offset_is_a_rewrite() {
        let w = wm(100, 5, "sig", 100);
        assert_eq!(classify(Some(&w), 40, 9), Change::Rewritten);
    }

    #[test]
    fn a_changed_head_turns_an_append_into_a_rewrite() {
        let original = b"line one\nline two\n";
        let w = wm_of(original, 5, 18);

        let appended = b"line one\nline two\nline three\n";
        assert_eq!(
            confirm(classify(Some(&w), 28, 9), Some(&w), appended),
            Change::Appended { from_byte: 18 }
        );

        // Same length as the append, entirely different content.
        let rotated = b"different!\nentirely new\ncontent\n";
        assert_eq!(
            confirm(classify(Some(&w), 32, 9), Some(&w), rotated),
            Change::Rewritten
        );
    }

    #[test]
    fn partial_trailing_lines_are_not_consumed() {
        assert_eq!(last_complete_line_end(b"a\nb\n"), 4);
        // A line still being written must not advance the offset past it.
        assert_eq!(last_complete_line_end(b"a\nb\npartial"), 4);
        assert_eq!(last_complete_line_end(b"no newline at all"), 0);
    }

    #[test]
    fn head_signature_ignores_content_past_the_window() {
        let mut a = vec![b'x'; HEAD_BYTES];
        let mut b = a.clone();
        a.extend_from_slice(b"tail one");
        b.extend_from_slice(b"tail two, much longer");
        // Only the head is signed, so appends never invalidate it.
        assert_eq!(head_signature(&a), head_signature(&b));
    }

    #[test]
    fn short_files_are_signed_whole() {
        assert_ne!(head_signature(b"abc"), head_signature(b"abd"));
    }

    #[test]
    fn appending_to_a_small_file_stays_an_append() {
        // Regression: signing the new file's own head would differ purely
        // because it grew, so every file under HEAD_BYTES would be re-read in
        // full on every scan.
        let original = b"one\n";
        let w = wm_of(original, 1, 4);
        let grown = b"one\ntwo\nthree\n";
        assert_eq!(
            confirm(classify(Some(&w), grown.len() as u64, 2), Some(&w), grown),
            Change::Appended { from_byte: 4 }
        );
    }

    #[test]
    fn a_small_file_replaced_with_different_content_is_a_rewrite() {
        let w = wm_of(b"one\n", 1, 4);
        let replaced = b"xxx\ntwo\n";
        assert_eq!(
            confirm(
                classify(Some(&w), replaced.len() as u64, 2),
                Some(&w),
                replaced
            ),
            Change::Rewritten
        );
    }
}
