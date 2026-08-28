// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! Workspace folders and the state of the git repositories in them.
//!
//! A workspace is a folder **the user chose**, not one inferred from the usage
//! archive. Those are different things and conflating them would be wrong in
//! both directions: the archive's `project` is a display label recovered from a
//! slug that lost the difference between `/` and `-`, so it cannot name a
//! folder on disk; and a folder an agent touched once is not somewhere you want
//! a terminal open.
//!
//! Reading and writing are separate modules on purpose. [`git`] and [`tree`]
//! are read-only and are safe to call from a timer, a watcher, or a status
//! path, which is where they are called from. [`gitwrite`] is the only module
//! that changes a repository, and everything in it runs because a person
//! pressed a button. Keep new code on the correct side of that line.

pub mod git;
pub mod gitwrite;
pub mod registry;
pub mod tree;

pub use git::{ChangeKind, Commit, CommitDetail, FileChange, FileDiff, GitStatus, Remote};
pub use gitwrite::GitOutcome;
pub use registry::{Registry, RegistryError, Workspace};
pub use tree::{TreeEntry, TreeError};
