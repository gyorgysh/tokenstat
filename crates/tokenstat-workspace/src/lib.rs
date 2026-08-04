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
//! Nothing here writes to a user's repository. See [`git`] for why that is a
//! rule rather than a coincidence.

pub mod git;
pub mod registry;

pub use git::{ChangeKind, FileChange, GitStatus};
pub use registry::{Registry, RegistryError, Workspace};
