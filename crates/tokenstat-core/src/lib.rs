//! Core types and logic for tokenstat.
//!
//! Parsing, normalization, pricing, and aggregation live here so that the CLI,
//! the desktop app, and any future sync agent share one implementation.

#![forbid(unsafe_code)]

/// Version of the crate, taken from the workspace manifest.
pub const VERSION: &str = env!("CARGO_PKG_VERSION");

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_is_populated() {
        assert!(!VERSION.is_empty());
    }
}
