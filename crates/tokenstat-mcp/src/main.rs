// SPDX-License-Identifier: LicenseRef-tokenstat-source-available
//
// Source-available for review, NOT open source. See LICENSE: no rights to
// redistribute, publish, or ship a build are granted. Read it, study it, run
// your own build of it.
// "tokenstat" and the tokenstat marks are trademarks of pueev OU and are not
// licensed with the code. See TRADEMARK.md.

//! `tokenstat-mcp` binary: stdio MCP server for local spend queries.

#![forbid(unsafe_code)]

fn main() -> anyhow::Result<()> {
    tokenstat_mcp::serve()
}
