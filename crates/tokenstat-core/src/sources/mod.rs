//! Per-tool log readers.
//!
//! Each source is responsible for finding its own data, mapping vendor field
//! names onto the disjoint [`Counters`](crate::model::Counters) buckets, and
//! deriving a stable identity for each request. Everything downstream of that,
//! deduplication, storage, and aggregation, is shared.
//!
//! Adding a tool should not require touching anything outside its own module.

pub mod antigravity_cache;
pub mod antigravity_cli;
pub mod claude_code;
pub mod claude_stats;
pub mod cline;
pub mod codex;
pub mod copilot;
pub mod grok;
pub mod hermes;
pub mod kilo;
pub mod openclaw;
pub mod opencode;
pub mod pi;
pub mod zed;
