//! Legacy compatibility surface for the original synchronous bridge server.
//!
//! The production binary uses `crate::server::run_from_env()`. This module exists
//! to make the older crate-root entrypoint explicit while the remaining legacy
//! implementation is still retained for compatibility and tests.

pub use crate::run_from_env;
