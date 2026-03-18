import 'package:codex_mobile_companion/foundation/contracts/bridge_contracts.dart';

String approvalActionLabel(String action) {
  switch (action) {
    case 'git_branch_switch':
      return 'Branch switch';
    case 'git_pull':
      return 'Git pull';
    case 'git_push':
      return 'Git push';
    default:
      return action;
  }
}

String approvalStatusLabel(ApprovalStatus status) {
  switch (status) {
    case ApprovalStatus.pending:
      return 'Pending';
    case ApprovalStatus.approved:
      return 'Approved';
    case ApprovalStatus.rejected:
      return 'Rejected';
  }
}

String approvalTargetLabel(ApprovalRecordDto approval) {
  switch (approval.action) {
    case 'git_branch_switch':
      return 'Target branch context: ${approval.repository.branch}';
    case 'git_pull':
    case 'git_push':
      return 'Target remote: ${approval.repository.remote}';
    default:
      return 'Target: ${approval.target}';
  }
}
