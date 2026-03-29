enum ThreadStatus { idle, running, completed, interrupted, failed }

enum SpeechModelState {
  unsupported,
  notInstalled,
  installing,
  ready,
  busy,
  failed,
}

enum BridgeApiRouteKind { tailscale, localNetwork }

class SharedContract {
  static const version = '2026-03-23';
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
    required this.bridgeApiRoutes,
    required this.pairingSession,
    required this.qrPayload,
  });

  final String contractVersion;
  final PairingBridgeIdentityDto bridgeIdentity;
  final List<BridgeApiRouteDto> bridgeApiRoutes;
  final PairingSessionDto pairingSession;
  final String qrPayload;

  factory PairingSessionResponseDto.fromJson(Map<String, dynamic> json) {
    return PairingSessionResponseDto(
      contractVersion:
          json['contract_version'] as String? ?? SharedContract.version,
      bridgeIdentity: PairingBridgeIdentityDto.fromJson(
        json['bridge_identity'] as Map<String, dynamic>? ?? const {},
      ),
      bridgeApiRoutes: _readTypedList(
        json['bridge_api_routes'],
        BridgeApiRouteDto.fromJson,
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
    required this.routes,
    required this.message,
  });

  final bool reachable;
  final String? advertisedBaseUrl;
  final List<BridgeApiRouteDto> routes;
  final String? message;

  factory BridgePairingRouteHealthDto.fromJson(Map<String, dynamic> json) {
    return BridgePairingRouteHealthDto(
      reachable: json['reachable'] as bool? ?? false,
      advertisedBaseUrl: json['advertised_base_url'] as String?,
      routes: _readTypedList(json['routes'], BridgeApiRouteDto.fromJson),
      message: json['message'] as String?,
    );
  }
}

BridgeApiRouteKind bridgeApiRouteKindFromWire(String wireValue) {
  switch (wireValue) {
    case 'local_network':
      return BridgeApiRouteKind.localNetwork;
    case 'tailscale':
    default:
      return BridgeApiRouteKind.tailscale;
  }
}

class BridgeApiRouteDto {
  const BridgeApiRouteDto({
    required this.id,
    required this.kind,
    required this.baseUrl,
    required this.reachable,
    required this.isPreferred,
  });

  final String id;
  final BridgeApiRouteKind kind;
  final String baseUrl;
  final bool reachable;
  final bool isPreferred;

  factory BridgeApiRouteDto.fromJson(Map<String, dynamic> json) {
    return BridgeApiRouteDto(
      id: json['id'] as String? ?? '',
      kind: bridgeApiRouteKindFromWire(json['kind'] as String? ?? 'tailscale'),
      baseUrl: json['base_url'] as String? ?? '',
      reachable: json['reachable'] as bool? ?? false,
      isPreferred: json['is_preferred'] as bool? ?? false,
    );
  }
}

class BridgeNetworkSettingsDto {
  const BridgeNetworkSettingsDto({
    required this.contractVersion,
    required this.localNetworkPairingEnabled,
    required this.routes,
    required this.message,
  });

  final String contractVersion;
  final bool localNetworkPairingEnabled;
  final List<BridgeApiRouteDto> routes;
  final String? message;

  factory BridgeNetworkSettingsDto.fromJson(Map<String, dynamic> json) {
    return BridgeNetworkSettingsDto(
      contractVersion:
          json['contract_version'] as String? ?? SharedContract.version,
      localNetworkPairingEnabled:
          json['local_network_pairing_enabled'] as bool? ?? false,
      routes: _readTypedList(json['routes'], BridgeApiRouteDto.fromJson),
      message: json['message'] as String?,
    );
  }
}

class BridgeTrustedDeviceDto {
  const BridgeTrustedDeviceDto({
    required this.deviceId,
    required this.deviceName,
    required this.pairedAtEpochSeconds,
  });

  final String deviceId;
  final String deviceName;
  final int pairedAtEpochSeconds;

  factory BridgeTrustedDeviceDto.fromJson(Map<String, dynamic> json) {
    return BridgeTrustedDeviceDto(
      deviceId:
          (json['device_id'] as String?) ?? (json['phone_id'] as String?) ?? '',
      deviceName:
          (json['device_name'] as String?) ??
          (json['phone_name'] as String?) ??
          '',
      pairedAtEpochSeconds:
          (json['paired_at_epoch_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class BridgeTrustedSessionDto {
  const BridgeTrustedSessionDto({
    required this.deviceId,
    required this.sessionId,
    required this.finalizedAtEpochSeconds,
  });

  final String deviceId;
  final String sessionId;
  final int finalizedAtEpochSeconds;

  factory BridgeTrustedSessionDto.fromJson(Map<String, dynamic> json) {
    return BridgeTrustedSessionDto(
      deviceId:
          (json['device_id'] as String?) ?? (json['phone_id'] as String?) ?? '',
      sessionId: json['session_id'] as String? ?? '',
      finalizedAtEpochSeconds:
          (json['finalized_at_epoch_seconds'] as num?)?.toInt() ?? 0,
    );
  }
}

class BridgeTrustStatusDto {
  const BridgeTrustStatusDto({
    required this.trustedDevices,
    required this.trustedSessions,
  });

  final List<BridgeTrustedDeviceDto> trustedDevices;
  final List<BridgeTrustedSessionDto> trustedSessions;

  bool get hasTrustedDevices => trustedDevices.isNotEmpty;

  factory BridgeTrustStatusDto.fromJson(Map<String, dynamic> json) {
    final trustedDevices = _readTypedList(
      json['trusted_devices'],
      BridgeTrustedDeviceDto.fromJson,
    );
    final trustedSessions = _readTypedList(
      json['trusted_sessions'],
      BridgeTrustedSessionDto.fromJson,
    );

    final fallbackTrustedDevice = json['trusted_phone'] is Map<String, dynamic>
        ? BridgeTrustedDeviceDto.fromJson(
            json['trusted_phone'] as Map<String, dynamic>,
          )
        : null;
    final fallbackTrustedSession =
        json['active_session'] is Map<String, dynamic>
        ? BridgeTrustedSessionDto.fromJson(
            json['active_session'] as Map<String, dynamic>,
          )
        : null;
    final resolvedTrustedDevices = trustedDevices.isNotEmpty
        ? trustedDevices
        : _singleOrEmpty(fallbackTrustedDevice);
    final resolvedTrustedSessions = trustedSessions.isNotEmpty
        ? trustedSessions
        : _singleOrEmpty(fallbackTrustedSession);

    return BridgeTrustStatusDto(
      trustedDevices: resolvedTrustedDevices,
      trustedSessions: resolvedTrustedSessions,
    );
  }
}

List<T> _singleOrEmpty<T>(T? value) {
  if (value == null) {
    return const [];
  }
  return <T>[value];
}

List<T> _readTypedList<T>(
  Object? value,
  T Function(Map<String, dynamic>) fromJson,
) {
  if (value is! List<dynamic>) {
    return const [];
  }

  return value
      .whereType<Map<dynamic, dynamic>>()
      .map((entry) => fromJson(Map<String, dynamic>.from(entry)))
      .toList(growable: false);
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
    required this.networkSettings,
    required this.trust,
    required this.api,
  });

  final String status;
  final BridgeRuntimeSnapshotDto runtime;
  final BridgePairingRouteHealthDto pairingRoute;
  final BridgeNetworkSettingsDto networkSettings;
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

class SpeechModelMutationAcceptedDto {
  const SpeechModelMutationAcceptedDto({
    required this.contractVersion,
    required this.provider,
    required this.modelId,
    required this.state,
    required this.message,
  });

  final String contractVersion;
  final String provider;
  final String modelId;
  final SpeechModelState state;
  final String message;

  factory SpeechModelMutationAcceptedDto.fromJson(Map<String, dynamic> json) {
    return SpeechModelMutationAcceptedDto(
      contractVersion:
          json['contract_version'] as String? ?? SharedContract.version,
      provider: json['provider'] as String? ?? '',
      modelId: json['model_id'] as String? ?? '',
      state: speechModelStateFromWire(json['state'] as String? ?? 'unsupported'),
      message: json['message'] as String? ?? '',
    );
  }
}
