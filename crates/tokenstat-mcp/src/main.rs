// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available: source sharing and own builds are permitted.
// Distribution of builds is reserved. See LICENSE for terms.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! `tokenstat-mcp` binary: stdio MCP server for local usage and workspace management.

#![forbid(unsafe_code)]

fn main() -> anyhow::Result<()> {
    tokenstat_mcp::serve(None)
}
