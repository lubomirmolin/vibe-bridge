enum ThreadStatus { idle, running, completed, interrupted, failed }

enum SpeechModelState {
  unsupported,
  notInstalled,
  installing,
  ready,
  busy,
  failed,
}

class SharedContract {
  static const version = '2026-03-22';
}

ThreadStatus threadStatusFromWire(String wireValue) {
  return ThreadStatus.values.firstWhere(
    (value) => value.name == wireValue,
    orElse: () => ThreadStatus.failed,
  );
}

SpeechModelState speechModelStateFromWire(String wireValue) {
  switch (wireValue) {
    case 'unsupported':
      return SpeechModelState.unsupported;
    case 'not_installed':
      return SpeechModelState.notInstalled;
    case 'installing':
      return SpeechModelState.installing;
    case 'ready':
      return SpeechModelState.ready;
    case 'busy':
      return SpeechModelState.busy;
    case 'failed':
      return SpeechModelState.failed;
    default:
      return SpeechModelState.unsupported;
  }
}

class ThreadSummaryDto {
  const ThreadSummaryDto({
    required this.contractVersion,
    required this.threadId,
    required this.title,
    required this.status,
    required this.workspace,
    required this.repository,
    required this.branch,
    required this.updatedAt,
  });

  final String contractVersion;
  final String threadId;
  final String title;
  final ThreadStatus status;
  final String workspace;
  final String repository;
  final String branch;
  final String updatedAt;

  factory ThreadSummaryDto.fromJson(Map<String, dynamic> json) {
    return ThreadSummaryDto(
      contractVersion:
          json['contract_version'] as String? ?? SharedContract.version,
      threadId: json['thread_id'] as String? ?? '',
      title: json['title'] as String? ?? '',
      status: threadStatusFromWire(json['status'] as String? ?? 'failed'),
      workspace: json['workspace'] as String? ?? '',
      repository: json['repository'] as String? ?? '',
      branch: json['branch'] as String? ?? '',
      updatedAt: json['updated_at'] as String? ?? '',
    );
  }
}

class ThreadListResponseDto {
  const ThreadListResponseDto({
    required this.contractVersion,
    required this.threads,
  });

  final String contractVersion;
  final List<ThreadSummaryDto> threads;
}

class PairingBridgeIdentityDto {
  const PairingBridgeIdentityDto({
    required this.bridgeId,
    required this.displayName,
    required this.apiBaseUrl,
  });

  final String bridgeId;
  final String displayName;
  final String apiBaseUrl;

  factory PairingBridgeIdentityDto.fromJson(Map<String, dynamic> json) {
    return PairingBridgeIdentityDto(
      bridgeId: json['bridge_id'] as String? ?? '',
      displayName: json['display_name'] as String? ?? '',
      apiBaseUrl: json['api_base_url'] as String? ?? '',
    );
  }
}

class PairingSessionDto {
  const PairingSessionDto({
    required this.sessionId,
    required this.pairingToken,
    required this.issuedAtEpochSeconds,
    required this.expiresAtEpochSeconds,
  });

  final String sessionId;
  final String pairingToken;
  final int issuedAtEpochSeconds;
  final int expiresAtEpochSeconds;

  factory PairingSessionDto.fromJson(Map<String, dynamic> json) {
    return PairingSessionDto(
      sessionId: json['session_id'] as String? ?? '',
      pairingToken: json['pairing_token'] as String? ?? '',
      issuedAtEpochSeconds:
          (json['issued_at_epoch_seconds'] as num?)?.toInt() ?? 0,
      expiresAtEpochSeconds:
          (json['expires_at_epoch_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class PairingSessionResponseDto {
  const PairingSessionResponseDto({
    required this.contractVersion,
    required this.bridgeIdentity,
    required this.pairingSession,
    required this.qrPayload,
  });

  final String contractVersion;
  final PairingBridgeIdentityDto bridgeIdentity;
  final PairingSessionDto pairingSession;
  final String qrPayload;

  factory PairingSessionResponseDto.fromJson(Map<String, dynamic> json) {
    return PairingSessionResponseDto(
      contractVersion:
          json['contract_version'] as String? ?? SharedContract.version,
      bridgeIdentity: PairingBridgeIdentityDto.fromJson(
        json['bridge_identity'] as Map<String, dynamic>? ?? const {},
      ),
      pairingSession: PairingSessionDto.fromJson(
        json['pairing_session'] as Map<String, dynamic>? ?? const {},
      ),
      qrPayload: json['qr_payload'] as String? ?? '',
    );
  }
}

class PairingRevokeResponseDto {
  const PairingRevokeResponseDto({
    required this.contractVersion,
    required this.revoked,
  });

  final String contractVersion;
  final bool revoked;

  factory PairingRevokeResponseDto.fromJson(Map<String, dynamic> json) {
    return PairingRevokeResponseDto(
      contractVersion:
          json['contract_version'] as String? ?? SharedContract.version,
      revoked: json['revoked'] as bool? ?? false,
    );
  }
}

class BridgeRuntimeSnapshotDto {
  const BridgeRuntimeSnapshotDto({
    required this.mode,
    required this.state,
    required this.endpoint,
    required this.pid,
    required this.detail,
  });

  final String mode;
  final String state;
  final String? endpoint;
  final int? pid;
  final String detail;
}

class BridgePairingRouteHealthDto {
  const BridgePairingRouteHealthDto({
    required this.reachable,
    required this.advertisedBaseUrl,
    required this.message,
  });

  final bool reachable;
  final String? advertisedBaseUrl;
  final String? message;

  factory BridgePairingRouteHealthDto.fromJson(Map<String, dynamic> json) {
    return BridgePairingRouteHealthDto(
      reachable: json['reachable'] as bool? ?? false,
      advertisedBaseUrl: json['advertised_base_url'] as String?,
      message: json['message'] as String?,
    );
  }
}

class BridgeTrustedPhoneDto {
  const BridgeTrustedPhoneDto({
    required this.phoneId,
    required this.phoneName,
    required this.pairedAtEpochSeconds,
  });

  final String phoneId;
  final String phoneName;
  final int pairedAtEpochSeconds;

  factory BridgeTrustedPhoneDto.fromJson(Map<String, dynamic> json) {
    return BridgeTrustedPhoneDto(
      phoneId: json['phone_id'] as String? ?? '',
      phoneName: json['phone_name'] as String? ?? '',
      pairedAtEpochSeconds:
          (json['paired_at_epoch_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class BridgeActiveSessionDto {
  const BridgeActiveSessionDto({
    required this.phoneId,
    required this.sessionId,
    required this.finalizedAtEpochSeconds,
  });

  final String phoneId;
  final String sessionId;
  final int finalizedAtEpochSeconds;

  factory BridgeActiveSessionDto.fromJson(Map<String, dynamic> json) {
    return BridgeActiveSessionDto(
      phoneId: json['phone_id'] as String? ?? '',
      sessionId: json['session_id'] as String? ?? '',
      finalizedAtEpochSeconds:
          (json['finalized_at_epoch_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class BridgeTrustStatusDto {
  const BridgeTrustStatusDto({
    required this.trustedPhone,
    required this.activeSession,
  });

  final BridgeTrustedPhoneDto? trustedPhone;
  final BridgeActiveSessionDto? activeSession;

  factory BridgeTrustStatusDto.fromJson(Map<String, dynamic> json) {
    return BridgeTrustStatusDto(
      trustedPhone: json['trusted_phone'] is Map<String, dynamic>
          ? BridgeTrustedPhoneDto.fromJson(
              json['trusted_phone'] as Map<String, dynamic>,
            )
          : null,
      activeSession: json['active_session'] is Map<String, dynamic>
          ? BridgeActiveSessionDto.fromJson(
              json['active_session'] as Map<String, dynamic>,
            )
          : null,
    );
  }
}

class BridgeApiSurfaceDto {
  const BridgeApiSurfaceDto({
    required this.endpoints,
    required this.seededThreadCount,
  });

  final List<String> endpoints;
  final int seededThreadCount;
}

class BridgeHealthResponseDto {
  const BridgeHealthResponseDto({
    required this.status,
    required this.runtime,
    required this.pairingRoute,
    required this.trust,
    required this.api,
  });

  final String status;
  final BridgeRuntimeSnapshotDto runtime;
  final BridgePairingRouteHealthDto pairingRoute;
  final BridgeTrustStatusDto? trust;
  final BridgeApiSurfaceDto api;
}

class SpeechModelStatusDto {
  const SpeechModelStatusDto({
    required this.contractVersion,
    required this.provider,
    required this.modelId,
    required this.state,
    required this.downloadProgress,
    required this.lastError,
    required this.installedBytes,
  });

  final String contractVersion;
  final String provider;
  final String modelId;
  final SpeechModelState state;
  final int? downloadProgress;
  final String? lastError;
  final int? installedBytes;

  factory SpeechModelStatusDto.fromJson(Map<String, dynamic> json) {
    return SpeechModelStatusDto(
      contractVersion:
          json['contract_version'] as String? ?? SharedContract.version,
      provider: json['provider'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      state: speechModelStateFromWire(
        json['state'] as String? ?? 'unsupported',
      ),
      downloadProgress: (json['download_progress'] as num?)?.toInt(),
      lastError: json['last_error'] as String?,
      installedBytes: (json['installed_bytes'] as num?)?.toInt(),
    );
  }
}
