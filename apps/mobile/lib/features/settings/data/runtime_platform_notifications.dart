import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final runtimePlatformNotificationsProvider =
    Provider.autoDispose<RuntimePlatformNotifications>((ref) {
      final service = FlutterLocalRuntimePlatformNotifications();
      ref.onDispose(() {
        unawaited(service.dispose());
      });
      return service;
    });

class RuntimePlatformNotificationBootstrap {
  const RuntimePlatformNotificationBootstrap({
    required this.systemNotificationsAvailable,
    this.initialLaunchPayload,
  });

  final bool systemNotificationsAvailable;
  final String? initialLaunchPayload;
}

abstract class RuntimePlatformNotifications {
  Stream<String> get openedPayloads;

  Future<RuntimePlatformNotificationBootstrap> initialize();

  Future<bool> showNotification({
    required int notificationId,
    required String title,
    required String body,
    required String payload,
  });

  Future<void> dispose();
}

class FlutterLocalRuntimePlatformNotifications
    implements RuntimePlatformNotifications {
  FlutterLocalRuntimePlatformNotifications({
    FlutterLocalNotificationsPlugin? plugin,
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final StreamController<String> _openedPayloadController =
      StreamController<String>.broadcast();

  Future<RuntimePlatformNotificationBootstrap>? _bootstrapFuture;
  bool _systemNotificationsAvailable = false;

  @override
  Stream<String> get openedPayloads => _openedPayloadController.stream;

  @override
  Future<RuntimePlatformNotificationBootstrap> initialize() {
    final existing = _bootstrapFuture;
    if (existing != null) {
      return existing;
    }

    final created = _initializeInternal();
    _bootstrapFuture = created;
    return created;
  }

  Future<RuntimePlatformNotificationBootstrap> _initializeInternal() async {
    try {
      const androidSettings = AndroidInitializationSettings(
        '@mipmap/ic_launcher',
      );
      const darwinSettings = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: false,
        requestSoundPermission: true,
      );

      const settings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
      );

      final initialized =
          await _plugin.initialize(
            settings,
            onDidReceiveNotificationResponse: _handleNotificationResponse,
          ) ??
          true;

      final permissionsGranted = await _requestNotificationPermissions();
      final checkedAvailability =
          await _resolveSystemNotificationAvailability();
      final systemNotificationsAvailable =
          initialized && permissionsGranted && (checkedAvailability ?? true);

      final launchDetails = await _plugin.getNotificationAppLaunchDetails();
      final launchPayload = launchDetails?.didNotificationLaunchApp == true
          ? launchDetails?.notificationResponse?.payload
          : null;

      _systemNotificationsAvailable = systemNotificationsAvailable;
      return RuntimePlatformNotificationBootstrap(
        systemNotificationsAvailable: systemNotificationsAvailable,
        initialLaunchPayload: _normalizePayload(launchPayload),
      );
    } catch (_) {
      _systemNotificationsAvailable = false;
      return const RuntimePlatformNotificationBootstrap(
        systemNotificationsAvailable: false,
      );
    }
  }

  Future<bool> _requestNotificationPermissions() async {
    final results = <bool?>[];

    results.add(
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission(),
    );

    results.add(
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: true),
    );

    results.add(
      await _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: false, sound: true),
    );

    for (final result in results) {
      if (result == false) {
        return false;
      }
    }

    return true;
  }

  Future<bool?> _resolveSystemNotificationAvailability() async {
    try {
      final androidImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (androidImplementation != null) {
        return androidImplementation.areNotificationsEnabled();
      }

      final iOSImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (iOSImplementation != null) {
        final permissions = await iOSImplementation.checkPermissions();
        return permissions?.isEnabled;
      }

      final macOSImplementation = _plugin
          .resolvePlatformSpecificImplementation<
            MacOSFlutterLocalNotificationsPlugin
          >();
      if (macOSImplementation != null) {
        final permissions = await macOSImplementation.checkPermissions();
        return permissions?.isEnabled;
      }
    } catch (_) {
      return null;
    }

    return null;
  }

  @override
  Future<bool> showNotification({
    required int notificationId,
    required String title,
    required String body,
    required String payload,
  }) async {
    await initialize();

    final checkedAvailability = await _resolveSystemNotificationAvailability();
    if (checkedAvailability != null) {
      _systemNotificationsAvailable = checkedAvailability;
    }

    if (!_systemNotificationsAvailable) {
      return false;
    }

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'codex_mobile_companion_runtime',
        'Runtime activity',
        channelDescription:
            'Approval and live-activity notifications from the Codex bridge.',
        importance: Importance.max,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBadge: false,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentSound: true,
        presentBadge: false,
      ),
    );

    try {
      await _plugin.show(
        notificationId,
        title,
        body,
        details,
        payload: payload,
      );
      return true;
    } catch (_) {
      _systemNotificationsAvailable = false;
      return false;
    }
  }

  void _handleNotificationResponse(NotificationResponse response) {
    final payload = _normalizePayload(response.payload);
    if (payload == null || _openedPayloadController.isClosed) {
      return;
    }

    _openedPayloadController.add(payload);
  }

  @override
  Future<void> dispose() async {
    if (!_openedPayloadController.isClosed) {
      await _openedPayloadController.close();
    }
  }
}

String? _normalizePayload(String? payload) {
  if (payload == null) {
    return null;
  }

  final normalized = payload.trim();
  if (normalized.isEmpty) {
    return null;
  }

  return normalized;
}
