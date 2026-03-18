import 'package:codex_mobile_companion/features/settings/data/runtime_platform_notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('dexterous.com/flutter/local_notifications');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'initialize reports system notifications unavailable when permission request is denied',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'initialize':
                return true;
              case 'requestNotificationsPermission':
                return false;
              case 'areNotificationsEnabled':
                return false;
              case 'getNotificationAppLaunchDetails':
                return <String, dynamic>{'notificationLaunchedApp': false};
            }

            return null;
          });

      final notifications = FlutterLocalRuntimePlatformNotifications();
      addTearDown(notifications.dispose);

      final bootstrap = await notifications.initialize();
      expect(bootstrap.systemNotificationsAvailable, isFalse);
    },
  );

  test(
    'initialize honors runtime availability checks when permission request succeeds',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'initialize':
                return true;
              case 'requestNotificationsPermission':
                return true;
              case 'areNotificationsEnabled':
                return false;
              case 'getNotificationAppLaunchDetails':
                return <String, dynamic>{'notificationLaunchedApp': false};
            }

            return null;
          });

      final notifications = FlutterLocalRuntimePlatformNotifications();
      addTearDown(notifications.dispose);

      final bootstrap = await notifications.initialize();
      expect(bootstrap.systemNotificationsAvailable, isFalse);
    },
  );

  test(
    'showNotification keeps fallback active and skips platform show when availability is denied',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidFlutterLocalNotificationsPlugin.registerWith();

      var showInvocations = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'initialize':
                return true;
              case 'requestNotificationsPermission':
                return false;
              case 'areNotificationsEnabled':
                return false;
              case 'getNotificationAppLaunchDetails':
                return <String, dynamic>{'notificationLaunchedApp': false};
              case 'show':
                showInvocations++;
                return null;
            }

            return null;
          });

      final notifications = FlutterLocalRuntimePlatformNotifications();
      addTearDown(notifications.dispose);

      final didShow = await notifications.showNotification(
        notificationId: 1,
        title: 'Approval requested',
        body: 'Permission denied fallback',
        payload: '{"event_id":"evt-1"}',
      );

      expect(didShow, isFalse);
      expect(showInvocations, 0);
    },
  );
}
