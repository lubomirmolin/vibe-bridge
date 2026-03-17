use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PersistenceScope {
    ThreadsCache,
    TimelineCache,
    SecurityAudit,
}

impl PersistenceScope {
    pub const fn file_name(self) -> &'static str {
        match self {
            Self::ThreadsCache => "threads-cache.sqlite",
            Self::TimelineCache => "timeline-cache.sqlite",
            Self::SecurityAudit => "security-audit.sqlite",
        }
    }

    pub const fn stores_sensitive_data(self) -> bool {
        match self {
            Self::ThreadsCache | Self::TimelineCache | Self::SecurityAudit => false,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PersistenceBoundary {
    base_directory: PathBuf,
}

impl PersistenceBoundary {
    pub fn new(base_directory: impl Into<PathBuf>) -> Self {
        Self {
            base_directory: base_directory.into(),
        }
    }

    pub fn state_directory(&self) -> PathBuf {
        self.base_directory.join("state")
    }

    pub fn sqlite_path_for(&self, scope: PersistenceScope) -> PathBuf {
        self.state_directory().join(scope.file_name())
    }

    pub fn base_directory(&self) -> &Path {
        &self.base_directory
    }

    pub const fn requires_secure_store(scope: PersistenceScope) -> bool {
        scope.stores_sensitive_data()
    }
}

#[cfg(test)]
mod tests {
    use super::{PersistenceBoundary, PersistenceScope};

    #[test]
    fn scopes_are_routed_to_expected_sqlite_files() {
        let boundary = PersistenceBoundary::new("/tmp/bridge-core");

        assert_eq!(
            boundary.sqlite_path_for(PersistenceScope::ThreadsCache),
            std::path::PathBuf::from("/tmp/bridge-core/state/threads-cache.sqlite")
        );
        assert_eq!(
            boundary.sqlite_path_for(PersistenceScope::TimelineCache),
            std::path::PathBuf::from("/tmp/bridge-core/state/timeline-cache.sqlite")
        );
        assert_eq!(
            boundary.sqlite_path_for(PersistenceScope::SecurityAudit),
            std::path::PathBuf::from("/tmp/bridge-core/state/security-audit.sqlite")
        );
    }

    #[test]
    fn sqlite_scopes_do_not_store_sensitive_values() {
        assert!(!PersistenceBoundary::requires_secure_store(
            PersistenceScope::ThreadsCache
        ));
        assert!(!PersistenceBoundary::requires_secure_store(
            PersistenceScope::TimelineCache
        ));
        assert!(!PersistenceBoundary::requires_secure_store(
            PersistenceScope::SecurityAudit
        ));
    }
}
