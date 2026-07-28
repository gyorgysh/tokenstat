//! tokenstat command line front end.
//!
//! Argument parsing and output formatting only. Collection, pricing, and
//! aggregation belong in `tokenstat-core`.

#![forbid(unsafe_code)]

fn main() {
    // Placeholder entry point. The command surface is still being designed, so
    // this only proves the workspace builds and the core crate links.
    println!("tokenstat {}", tokenstat_core::VERSION);
}
