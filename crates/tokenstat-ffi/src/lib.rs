// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! C ABI bridge exposing the tokenstat core to native front ends.
//!
//! # Why JSON rather than a generated binding
//!
//! The desktop plan puts a host daemon between the UI and the core, speaking
//! versioned JSON-RPC, so that an iPad can drive a session running on a Mac.
//! This bridge uses the *same* method names and the same request and response
//! shapes. Moving a front end from in-process to remote is then a change of
//! transport, not a rewrite of the client layer, and one set of wire types is
//! tested rather than two.
//!
//! It also keeps the dependency budget at zero: `serde_json` is already in the
//! tree, and the boundary needs no codegen step in the build.
//!
//! # Layout
//!
//! - [`dto`] is the wire contract. Change it deliberately, it is public API.
//! - [`api`] is the dispatch, and is pure safe Rust so it can be tested
//!   directly without going through a pointer.
//! - [`abi`] is the only module with `unsafe`, and does nothing but move
//!   strings across the boundary.

pub mod abi;
pub mod api;
pub mod dto;

/// Version of the wire contract, not of the crate.
///
/// A front end should refuse to talk to a bridge whose major version it does
/// not recognize, which is what makes the eventual remote transport safe to
/// upgrade independently at each end.
pub const PROTOCOL_VERSION: &str = "1";
