use shared_contracts::AccessMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyAction {
    TurnStart,
    TurnSteer,
    TurnInterrupt,
    ApprovalResolve,
    GitBranchSwitch,
    GitPull,
    GitPush,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PolicyDecision {
    Allow,
    Deny { reason: &'static str },
    RequireApproval { reason: &'static str },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PolicyEngine {
    access_mode: AccessMode,
}

impl Default for PolicyEngine {
    fn default() -> Self {
        Self {
            access_mode: AccessMode::ControlWithApprovals,
        }
    }
}

impl PolicyEngine {
    pub fn new(access_mode: AccessMode) -> Self {
        Self { access_mode }
    }

    pub fn access_mode(&self) -> AccessMode {
        self.access_mode
    }

    pub fn set_access_mode(&mut self, access_mode: AccessMode) {
        self.access_mode = access_mode;
    }

    pub fn decide(&self, action: PolicyAction) -> PolicyDecision {
        match self.access_mode {
            AccessMode::ReadOnly => match action {
                PolicyAction::TurnStart
                | PolicyAction::TurnSteer
                | PolicyAction::TurnInterrupt
                | PolicyAction::ApprovalResolve
                | PolicyAction::GitBranchSwitch
                | PolicyAction::GitPull
                | PolicyAction::GitPush => PolicyDecision::Deny {
                    reason: "read_only_mode",
                },
            },
            AccessMode::ControlWithApprovals => match action {
                PolicyAction::TurnStart | PolicyAction::TurnSteer | PolicyAction::TurnInterrupt => {
                    PolicyDecision::Allow
                }
                PolicyAction::ApprovalResolve => PolicyDecision::Deny {
                    reason: "approval_resolution_requires_full_control",
                },
                PolicyAction::GitBranchSwitch | PolicyAction::GitPull | PolicyAction::GitPush => {
                    PolicyDecision::RequireApproval {
                        reason: "dangerous_action_requires_approval",
                    }
                }
            },
            AccessMode::FullControl => PolicyDecision::Allow,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{PolicyAction, PolicyDecision, PolicyEngine};
    use shared_contracts::AccessMode;

    #[test]
    fn read_only_denies_mutating_actions() {
        let engine = PolicyEngine::new(AccessMode::ReadOnly);

        assert_eq!(
            engine.decide(PolicyAction::TurnStart),
            PolicyDecision::Deny {
                reason: "read_only_mode"
            }
        );
        assert_eq!(
            engine.decide(PolicyAction::GitPush),
            PolicyDecision::Deny {
                reason: "read_only_mode"
            }
        );
        assert_eq!(
            engine.decide(PolicyAction::ApprovalResolve),
            PolicyDecision::Deny {
                reason: "read_only_mode"
            }
        );
    }

    #[test]
    fn control_with_approvals_allows_turn_controls_and_gates_dangerous_git() {
        let engine = PolicyEngine::new(AccessMode::ControlWithApprovals);

        assert_eq!(
            engine.decide(PolicyAction::TurnSteer),
            PolicyDecision::Allow
        );
        assert_eq!(
            engine.decide(PolicyAction::GitPull),
            PolicyDecision::RequireApproval {
                reason: "dangerous_action_requires_approval"
            }
        );
        assert_eq!(
            engine.decide(PolicyAction::ApprovalResolve),
            PolicyDecision::Deny {
                reason: "approval_resolution_requires_full_control"
            }
        );
    }

    #[test]
    fn full_control_allows_mutating_actions_and_approval_resolution() {
        let engine = PolicyEngine::new(AccessMode::FullControl);

        assert_eq!(
            engine.decide(PolicyAction::TurnInterrupt),
            PolicyDecision::Allow
        );
        assert_eq!(
            engine.decide(PolicyAction::GitBranchSwitch),
            PolicyDecision::Allow
        );
        assert_eq!(
            engine.decide(PolicyAction::ApprovalResolve),
            PolicyDecision::Allow
        );
    }
}
