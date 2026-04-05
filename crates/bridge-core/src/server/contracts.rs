use serde::Serialize;
use shared_contracts::{CONTRACT_VERSION, ThreadStatus};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RepositoryContextDto {
    pub workspace: String,
    pub repository: String,
    pub branch: String,
    pub remote: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GitMutationStatusDto {
    pub dirty: bool,
    pub ahead_by: u32,
    pub behind_by: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct GitStatusResponse {
    pub contract_version: String,
    pub thread_id: String,
    pub repository: RepositoryContextDto,
    pub status: GitMutationStatusDto,
}

impl GitStatusResponse {
    pub fn new(
        thread_id: impl Into<String>,
        repository: RepositoryContextDto,
        status: GitMutationStatusDto,
    ) -> Self {
        Self {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.into(),
            repository,
            status,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct MutationResultResponse {
    pub contract_version: String,
    pub thread_id: String,
    pub operation: String,
    pub outcome: String,
    pub message: String,
    pub thread_status: ThreadStatus,
    pub repository: RepositoryContextDto,
    pub status: GitMutationStatusDto,
}

impl MutationResultResponse {
    pub fn new(
        thread_id: impl Into<String>,
        operation: impl Into<String>,
        outcome: impl Into<String>,
        message: impl Into<String>,
        thread_status: ThreadStatus,
        repository: RepositoryContextDto,
        status: GitMutationStatusDto,
    ) -> Self {
        Self {
            contract_version: CONTRACT_VERSION.to_string(),
            thread_id: thread_id.into(),
            operation: operation.into(),
            outcome: outcome.into(),
            message: message.into(),
            thread_status,
            repository,
            status,
        }
    }
}
