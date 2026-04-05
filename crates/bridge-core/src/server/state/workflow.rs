use super::*;

pub(super) const PLAN_WORKFLOW_KIND: &str = "plan_questionnaire";
pub(super) const PLAN_WORKFLOW_STATE_AWAITING_QUESTIONS: &str = "awaiting_questions";
pub(super) const PLAN_WORKFLOW_STATE_AWAITING_RESPONSE: &str = "awaiting_response";
pub(super) const PLAN_WORKFLOW_STATE_EXPIRED: &str = "expired";
pub(super) const PROVIDER_APPROVAL_WORKFLOW_KIND: &str = "provider_approval";
pub(super) const PROVIDER_APPROVAL_WORKFLOW_STATE_PENDING: &str = "pending";
pub(super) const PROVIDER_APPROVAL_WORKFLOW_STATE_EXPIRED: &str = "expired";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ThreadWorkflow {
    PlanQuestionnaire(PlanWorkflowState),
    ProviderApproval(ProviderApprovalWorkflowState),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum PlanWorkflowState {
    AwaitingQuestions {
        original_prompt: String,
    },
    AwaitingResponse {
        original_prompt: String,
        request_id: String,
        provider_request_id: Option<String>,
    },
    Expired {
        original_prompt: String,
        request_id: Option<String>,
        provider_request_id: Option<String>,
    },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum ProviderApprovalWorkflowState {
    Pending {
        request_id: String,
        provider_request_id: String,
    },
    Expired {
        request_id: String,
        provider_request_id: Option<String>,
    },
}

impl ThreadWorkflow {
    pub(super) fn plan_awaiting_questions(original_prompt: &str) -> Self {
        Self::PlanQuestionnaire(PlanWorkflowState::AwaitingQuestions {
            original_prompt: original_prompt.trim().to_string(),
        })
    }

    pub(super) fn plan_awaiting_response(
        original_prompt: &str,
        request_id: &str,
        provider_request_id: Option<&str>,
    ) -> Self {
        Self::PlanQuestionnaire(PlanWorkflowState::AwaitingResponse {
            original_prompt: original_prompt.trim().to_string(),
            request_id: request_id.to_string(),
            provider_request_id: provider_request_id.map(ToString::to_string),
        })
    }

    pub(super) fn expired_plan_questionnaire(
        original_prompt: &str,
        request_id: Option<&str>,
        provider_request_id: Option<&str>,
    ) -> Self {
        Self::PlanQuestionnaire(PlanWorkflowState::Expired {
            original_prompt: original_prompt.trim().to_string(),
            request_id: request_id.map(ToString::to_string),
            provider_request_id: provider_request_id.map(ToString::to_string),
        })
    }

    pub(super) fn pending_provider_approval(request_id: &str, provider_request_id: &str) -> Self {
        Self::ProviderApproval(ProviderApprovalWorkflowState::Pending {
            request_id: request_id.to_string(),
            provider_request_id: provider_request_id.to_string(),
        })
    }

    pub(super) fn expired_provider_approval(
        request_id: &str,
        provider_request_id: Option<&str>,
    ) -> Self {
        Self::ProviderApproval(ProviderApprovalWorkflowState::Expired {
            request_id: request_id.to_string(),
            provider_request_id: provider_request_id.map(ToString::to_string),
        })
    }

    pub(super) fn current_plan_prompt(
        workflow_state: Option<ThreadWorkflowStateDto>,
    ) -> Option<String> {
        match workflow_state.and_then(Self::from_dto) {
            Some(ThreadWorkflow::PlanQuestionnaire(state)) => {
                Some(state.original_prompt().to_string())
            }
            _ => None,
        }
        .filter(|prompt| !prompt.trim().is_empty())
    }

    pub(super) fn is_expired_plan_request(
        workflow_state: Option<ThreadWorkflowStateDto>,
        request_id: &str,
    ) -> bool {
        matches!(
            workflow_state.and_then(Self::from_dto),
            Some(ThreadWorkflow::PlanQuestionnaire(PlanWorkflowState::Expired {
                request_id: Some(existing_request_id),
                ..
            })) if existing_request_id == request_id
        )
    }

    pub(super) fn from_dto(dto: ThreadWorkflowStateDto) -> Option<Self> {
        match dto.workflow_kind.as_str() {
            PLAN_WORKFLOW_KIND => Some(Self::PlanQuestionnaire(PlanWorkflowState::from_dto(dto))),
            PROVIDER_APPROVAL_WORKFLOW_KIND => Some(Self::ProviderApproval(
                ProviderApprovalWorkflowState::from_dto(dto),
            )),
            _ => None,
        }
    }

    pub(super) fn into_dto(self) -> ThreadWorkflowStateDto {
        match self {
            ThreadWorkflow::PlanQuestionnaire(state) => state.into_dto(),
            ThreadWorkflow::ProviderApproval(state) => state.into_dto(),
        }
    }
}

impl PlanWorkflowState {
    fn from_dto(dto: ThreadWorkflowStateDto) -> Self {
        match dto.state.as_str() {
            PLAN_WORKFLOW_STATE_AWAITING_RESPONSE => Self::AwaitingResponse {
                original_prompt: dto.original_prompt.unwrap_or_default(),
                request_id: dto.request_id.unwrap_or_default(),
                provider_request_id: dto.provider_request_id,
            },
            PLAN_WORKFLOW_STATE_EXPIRED => Self::Expired {
                original_prompt: dto.original_prompt.unwrap_or_default(),
                request_id: dto.request_id,
                provider_request_id: dto.provider_request_id,
            },
            _ => Self::AwaitingQuestions {
                original_prompt: dto.original_prompt.unwrap_or_default(),
            },
        }
    }

    fn into_dto(self) -> ThreadWorkflowStateDto {
        match self {
            Self::AwaitingQuestions { original_prompt } => ThreadWorkflowStateDto {
                workflow_kind: PLAN_WORKFLOW_KIND.to_string(),
                state: PLAN_WORKFLOW_STATE_AWAITING_QUESTIONS.to_string(),
                request_id: None,
                original_prompt: Some(original_prompt),
                provider_request_id: None,
            },
            Self::AwaitingResponse {
                original_prompt,
                request_id,
                provider_request_id,
            } => ThreadWorkflowStateDto {
                workflow_kind: PLAN_WORKFLOW_KIND.to_string(),
                state: PLAN_WORKFLOW_STATE_AWAITING_RESPONSE.to_string(),
                request_id: Some(request_id),
                original_prompt: Some(original_prompt),
                provider_request_id,
            },
            Self::Expired {
                original_prompt,
                request_id,
                provider_request_id,
            } => ThreadWorkflowStateDto {
                workflow_kind: PLAN_WORKFLOW_KIND.to_string(),
                state: PLAN_WORKFLOW_STATE_EXPIRED.to_string(),
                request_id,
                original_prompt: Some(original_prompt),
                provider_request_id,
            },
        }
    }

    fn original_prompt(&self) -> &str {
        match self {
            Self::AwaitingQuestions { original_prompt }
            | Self::AwaitingResponse {
                original_prompt, ..
            }
            | Self::Expired {
                original_prompt, ..
            } => original_prompt.as_str(),
        }
    }
}

impl ProviderApprovalWorkflowState {
    fn from_dto(dto: ThreadWorkflowStateDto) -> Self {
        match dto.state.as_str() {
            PROVIDER_APPROVAL_WORKFLOW_STATE_EXPIRED => Self::Expired {
                request_id: dto.request_id.unwrap_or_default(),
                provider_request_id: dto.provider_request_id,
            },
            _ => Self::Pending {
                request_id: dto.request_id.unwrap_or_default(),
                provider_request_id: dto.provider_request_id.unwrap_or_default(),
            },
        }
    }

    fn into_dto(self) -> ThreadWorkflowStateDto {
        match self {
            Self::Pending {
                request_id,
                provider_request_id,
            } => ThreadWorkflowStateDto {
                workflow_kind: PROVIDER_APPROVAL_WORKFLOW_KIND.to_string(),
                state: PROVIDER_APPROVAL_WORKFLOW_STATE_PENDING.to_string(),
                request_id: Some(request_id),
                original_prompt: None,
                provider_request_id: Some(provider_request_id),
            },
            Self::Expired {
                request_id,
                provider_request_id,
            } => ThreadWorkflowStateDto {
                workflow_kind: PROVIDER_APPROVAL_WORKFLOW_KIND.to_string(),
                state: PROVIDER_APPROVAL_WORKFLOW_STATE_EXPIRED.to_string(),
                request_id: Some(request_id),
                original_prompt: None,
                provider_request_id,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plan_workflow_round_trips_through_dto() {
        let workflow = ThreadWorkflow::plan_awaiting_response(
            "Investigate the streaming gap",
            "request-1",
            Some("item-1"),
        );
        let dto = workflow.clone().into_dto();
        assert_eq!(dto.workflow_kind, PLAN_WORKFLOW_KIND);
        assert_eq!(dto.state, PLAN_WORKFLOW_STATE_AWAITING_RESPONSE);
        assert_eq!(ThreadWorkflow::from_dto(dto), Some(workflow));
    }

    #[test]
    fn provider_approval_workflow_round_trips_through_dto() {
        let workflow = ThreadWorkflow::expired_provider_approval("approval-1", Some("provider-1"));
        let dto = workflow.clone().into_dto();
        assert_eq!(dto.workflow_kind, PROVIDER_APPROVAL_WORKFLOW_KIND);
        assert_eq!(dto.state, PROVIDER_APPROVAL_WORKFLOW_STATE_EXPIRED);
        assert_eq!(ThreadWorkflow::from_dto(dto), Some(workflow));
    }

    #[test]
    fn current_plan_prompt_extracts_only_plan_workflows() {
        let prompt = ThreadWorkflow::current_plan_prompt(Some(
            ThreadWorkflow::plan_awaiting_questions("Clarify the bridge architecture").into_dto(),
        ));
        assert_eq!(prompt.as_deref(), Some("Clarify the bridge architecture"));

        let absent = ThreadWorkflow::current_plan_prompt(Some(
            ThreadWorkflow::pending_provider_approval("approval-1", "provider-1").into_dto(),
        ));
        assert!(absent.is_none());
    }
}
