//! `tokenstat-mcp` binary: stdio MCP server for local spend queries.

#![forbid(unsafe_code)]

fn main() -> anyhow::Result<()> {
    tokenstat_mcp::serve()
}
