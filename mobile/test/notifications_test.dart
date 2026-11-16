// External notification data may identify a request, never choose an arbitrary route or expose health data.
import 'dart:async';
import 'dart:convert';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/notifications.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';

// A held enrollment response reproduces sign-out while the server is saving the device.
class _DelayedDeviceApi extends Api {
  final postStarted = Completer<void>();
  final finishPost = Completer<void>();
  final calls = <String>[];
  Json? removed;

  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    calls.add('$method $path');
    if (method == 'POST') {
      postStarted.complete();
      await finishPost.future;
      calls.add('POST completed');
    } else if (method == 'DELETE') {
      removed = body;
    }
    return {'status': 'ok'};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'report notifications accept only an opaque identifier and strict country, with no visible payload content',
    () {
      final target = notificationTarget({
        'report_id': 'report-123',
        'report_country': 'BD',
        'country': 'AU',
        'title': 'PRIVATE NOTE',
        'body': 'Private evidence',
        'route': '/admin',
      });
      expect(target?.reportId, 'report-123');
      expect(target?.reportCountry, 'BD');
      expect(target?.payload, {
        'report_id': 'report-123',
        'report_country': 'BD',
      });
      expect(notificationRequest(target?.payload), isNull);
      for (final payload in [
        {'report_id': '../other', 'report_country': 'BD'},
        {'report_id': 'safe', 'report_country': 'BD\n'},
        {'report_id': 'safe', 'report_country': 'bd'},
        {'report_id': 'safe', 'report_country': 'BD?country=AU'},
        {'report_id': 'safe'},
        {
          'report_id': 'safe',
          'report_country': 'BD',
          'request_id': 'ambiguous',
        },
      ]) {
        expect(notificationTarget(payload), isNull);
      }
    },
  );

  test(
    'notification parsing accepts only a bounded opaque request identifier',
    () {
      expect(notificationRequest({'request_id': 'aB9_-'}), 'aB9_-');
      expect(
        notificationRequest('{"request_id":"request-123"}'),
        'request-123',
      );
      expect(notificationRequest({'request_id': 'a' * 80}), 'a' * 80);
      for (final payload in [
        null,
        true,
        123,
        [],
        '{}',
        'not-json',
        '{"request_id":',
        {'request_id': null},
        {'request_id': 123},
        {'request_id': ''},
        {'request_id': 'a' * 81},
        {'request_id': '../admin'},
        {'request_id': 'https://example.test/request'},
        {'request_id': 'request?token=secret'},
        {'request_id': 'request\n'},
        {'request_id': ' request'},
        {'request_id': 'রক্ত'},
        {
          'request_id': ['request-123'],
        },
      ]) {
        expect(
          notificationRequest(payload),
          isNull,
          reason: 'Reject ${payload.runtimeType}: $payload',
        );
      }
    },
  );

  test(
    'extra notification fields never become navigation or visible content',
    () {
      final hostile = jsonEncode({
        'request_id': 'request-123',
        'route': '/admin',
        'title': 'PRIVATE HEALTH DATA',
        'body': 'phone, precise location and blood group',
        'access_token': 'must-not-be-used',
      });
      expect(notificationRequest(hostile), 'request-123');
      expect(notificationRequest({'body': hostile}), isNull);
    },
  );

  test(
    'iOS registers a safe watch action without requesting permission at launch',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      // Widget tests do not execute the generated native plugin registrant.
      IOSFlutterLocalNotificationsPlugin.registerWith();
      const local = MethodChannel('dexterous.com/flutter/local_notifications');
      const apple = MethodChannel('bloodconnection/apns');
      final nativeCalls = <MethodCall>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(local, (call) async {
        nativeCalls.add(call);
        if (call.method == 'initialize') return true;
        if (call.method == 'getNotificationAppLaunchDetails') {
          return {'notificationLaunchedApp': false};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(apple, (call) async {
        nativeCalls.add(call);
        if (call.method == 'initialNotification') {
          return {'request_id': 'launch-request'};
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(local, null);
        messenger.setMockMethodCallHandler(apple, null);
        NotificationService.openedTarget.value = null;
      });

      await NotificationService.initialize([]);
      final initialization =
          nativeCalls
                  .singleWhere((call) => call.method == 'initialize')
                  .arguments
              as Map;
      expect(initialization['requestAlertPermission'], false);
      expect(initialization['requestBadgePermission'], false);
      expect(initialization['requestSoundPermission'], false);
      expect(
        nativeCalls.any(
          (call) =>
              call.method == 'register' || call.method == 'requestPermissions',
        ),
        false,
      );
      final category =
          (initialization['notificationCategories'] as List).single as Map;
      expect(category['identifier'], 'PRIVATE_UPDATE');
      final actions = category['actions'] as List;
      expect(actions.length, 1);
      expect((actions.first as Map)['identifier'], 'open_phone');
      expect((actions.first as Map)['options'], [
        DarwinNotificationActionOption.foreground.value,
      ]);
      expect(
        NotificationService.openedTarget.value?.requestId,
        'launch-request',
      );

      // Simulate APNs delivery into Flutter, checking the same sanitizer used by cold-start handling.
      await messenger.handlePlatformMessage(
        apple.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('opened', {'request_id': '../../admin'}),
        ),
        (_) {},
      );
      expect(NotificationService.openedTarget.value?.requestId, isNull);
      await messenger.handlePlatformMessage(
        apple.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('opened', {'request_id': 'safe-request'}),
        ),
        (_) {},
      );
      expect(NotificationService.openedTarget.value?.requestId, 'safe-request');
      await messenger.handlePlatformMessage(
        apple.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('opened', {
            'report_id': 'reviewed-report',
            'report_country': 'BD',
          }),
        ),
        (_) {},
      );
      expect(
        NotificationService.openedTarget.value?.reportId,
        'reviewed-report',
      );
      expect(NotificationService.openedTarget.value?.reportCountry, 'BD');
    },
  );
  test(
    'sign-out waits for pending enrollment before revoking the device',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      IOSFlutterLocalNotificationsPlugin.registerWith();
      const local = MethodChannel('dexterous.com/flutter/local_notifications');
      const apple = MethodChannel('bloodconnection/apns');
      const secure = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final stored = <String, String>{};
      final nativeCalls = <String>[];
      final api = _DelayedDeviceApi();
      final statuses = <String>[];
      void rememberStatus() => statuses.add(NotificationService.status.value);
      NotificationService.status.addListener(rememberStatus);
      messenger.setMockMethodCallHandler(local, (call) async {
        nativeCalls.add(call.method);
        if (call.method == 'initialize' ||
            call.method == 'requestPermissions') {
          return true;
        }
        if (call.method == 'getNotificationAppLaunchDetails') {
          return {'notificationLaunchedApp': false};
        }
        return null;
      });
      messenger.setMockMethodCallHandler(apple, (call) async {
        nativeCalls.add(call.method);
        return call.method == 'register' ? 'a' * 64 : null;
      });
      messenger.setMockMethodCallHandler(secure, (call) async {
        final arguments = call.arguments as Map;
        final key = arguments['key'] as String;
        switch (call.method) {
          case 'read':
            return stored[key];
          case 'write':
            stored[key] = arguments['value'] as String;
            return null;
          case 'delete':
            stored.remove(key);
            return null;
          default:
            throw StateError('Unexpected storage operation ${call.method}');
        }
      });
      addTearDown(() {
        NotificationService.status.removeListener(rememberStatus);
        messenger.setMockMethodCallHandler(local, null);
        messenger.setMockMethodCallHandler(apple, null);
        messenger.setMockMethodCallHandler(secure, null);
        debugDefaultTargetPlatformOverride = null;
        api.client.close();
      });

      await NotificationService.initialize([]);
      await NotificationService.attach(
        api,
        userId: 'member-race',
        role: 'member',
      );
      final enabling = NotificationService.enable();
      await api.postStarted.future.timeout(const Duration(seconds: 3));
      final detaching = NotificationService.detach();
      await Future<void>.delayed(Duration.zero);
      // DELETE before this POST commits would leave a registered device after sign-out.
      expect(api.calls, ['POST /devices']);
      api.finishPost.complete();
      await Future.wait([enabling, detaching]);

      expect(api.calls, ['POST /devices', 'POST completed', 'DELETE /devices']);
      expect(api.removed, {'token': 'a' * 64});
      expect(stored, isEmpty);
      expect(nativeCalls, containsAll(['unregister', 'cancelAll']));
      expect(statuses, isNot(contains('Notifications enabled')));
      expect(NotificationService.status.value, 'Notifications are off');
      // A stale caller cannot enroll again after the signed-in owner has been detached.
      await NotificationService.enable();
      expect(api.calls.length, 3);
    },
  );
}
