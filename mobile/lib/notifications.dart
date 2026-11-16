// Push contains only bounded opaque target IDs. Names, evidence and health details stay behind sign-in.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:unifiedpush_android/unifiedpush_android.dart';
import 'api.dart';

/// A validated request or report reference, never an arbitrary route from push data.
///
/// Report targets carry their original country so travel does not break review links.
class PrivateNotificationTarget {
  final String? requestId, reportId, reportCountry;
  const PrivateNotificationTarget.request(String id)
    : requestId = id,
      reportId = null,
      reportCountry = null;
  const PrivateNotificationTarget.report(String id, String country)
    : reportId = id,
      reportCountry = country,
      requestId = null;
  Json get payload => reportId == null
      ? {'request_id': requestId}
      : {'report_id': reportId, 'report_country': reportCountry};
  String get notificationKey => reportId == null
      ? 'request:$requestId'
      : 'report:$reportCountry:$reportId';
}

/// Parses external push data into a bounded target, returning null for malformed input.
///
/// The target selects navigation only; the API must authorize its content after sign-in.
PrivateNotificationTarget? notificationTarget(Object? payload) {
  try {
    final value = payload is String ? jsonDecode(payload) : payload;
    if (value is! Map) return null;
    bool validId(Object? id) =>
        id is String && RegExp(r'^[a-zA-Z0-9_-]{1,80}$').stringMatch(id) == id;
    if (value.containsKey('report_id')) {
      final id = value['report_id'];
      final country = value['report_country'];
      if (!validId(id) ||
          country is! String ||
          RegExp(r'^[A-Z]{2}$').stringMatch(country) != country ||
          value['request_id'] != null) {
        return null;
      }
      return PrivateNotificationTarget.report(id as String, country);
    }
    return validId(value['request_id'])
        ? PrivateNotificationTarget.request(value['request_id'] as String)
        : null;
  } catch (_) {
    return null;
  }
}

/// Returns only a request target for callers that cannot handle report navigation.
String? notificationRequest(Object? payload) =>
    notificationTarget(payload)?.requestId;

/// Coordinates opt-in device enrollment, private alerts and signed-in ownership.
///
/// Transport callbacks can outlive a session. The persisted owner filters headless
/// Android delivery; the epoch invalidates asynchronous work after detachment.
class NotificationService {
  static final status = ValueNotifier<String>('Notifications are off');
  static final openedTarget = ValueNotifier<PrivateNotificationTarget?>(null);
  // Use the Android SDK directly; the umbrella package adds unused Linux native crypto.
  static final _push = UnifiedPushAndroid();
  static final _local = FlutterLocalNotificationsPlugin();
  static const _storage = FlutterSecureStorage();
  static const _apple = MethodChannel('bloodconnection/apns');
  static const _android = MethodChannel('bloodconnection/notifications');
  static Api? _api;
  static String? _owner;
  static bool _ready = false;
  static bool _enabling = false;
  static Future<void>? _enrollment;
  static int _epoch = 0;
  static String get _key => 'notification_device_${_owner ?? ''}';

  /// Installs native callbacks once, without requesting notification permission.
  ///
  /// UnifiedPush also uses this in a headless Flutter engine, where displaying a
  /// generic alert requires no OAuth token or private profile fetch.
  static Future<void> initialize(List<String> args) async {
    if (kIsWeb || _ready) return;
    if (defaultTargetPlatform != TargetPlatform.android &&
        defaultTargetPlatform != TargetPlatform.iOS) {
      return;
    }
    await _local.initialize(
      settings: InitializationSettings(
        android: const AndroidInitializationSettings('ic_notification'),
        iOS: DarwinInitializationSettings(
          requestAlertPermission: false,
          requestBadgePermission: false,
          requestSoundPermission: false,
          notificationCategories: [
            DarwinNotificationCategory(
              'PRIVATE_UPDATE',
              actions: [
                DarwinNotificationAction.plain(
                  'open_phone',
                  'Open on phone',
                  options: {DarwinNotificationActionOption.foreground},
                ),
              ],
            ),
          ],
        ),
      ),
      onDidReceiveNotificationResponse: (response) {
        openedTarget.value = notificationTarget(response.payload);
      },
    );
    _ready = true;
    final launch = await _local.getNotificationAppLaunchDetails();
    if (launch?.didNotificationLaunchApp == true) {
      openedTarget.value = notificationTarget(
        launch?.notificationResponse?.payload,
      );
    }
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _push.initializeCallback(
        onNewEndpoint: (endpoint, instance) async {
          if (instance != await _storage.read(key: 'notification_owner')) {
            return;
          }
          final keys = endpoint.pubKeySet;
          if (keys == null) return;
          final device = <String, dynamic>{
            'provider': 'unifiedpush',
            'token': endpoint.url,
            'pub_key': keys.pubKey,
            'auth': keys.auth,
          };
          await _storage.write(
            key: 'notification_device_$instance',
            value: jsonEncode(device),
          );
          if (_owner == instance) await _register(device);
        },
        onMessage: (message, instance) async {
          if (!message.decrypted ||
              instance != await _storage.read(key: 'notification_owner')) {
            return;
          }
          await _show(message.content);
        },
        onRegistrationFailed: (_, _) =>
            status.value = 'Notification setup failed. Please try again.',
      );
      await _push.initializeOnTempUnavailable(
        (_) => status.value = 'Notification service is temporarily unavailable',
      );
    } else {
      _apple.setMethodCallHandler((call) async {
        if (call.method == 'opened') {
          openedTarget.value = notificationTarget(call.arguments);
        }
      });
      final initial = await _apple.invokeMethod<Object?>('initialNotification');
      openedTarget.value = notificationTarget(initial) ?? openedTarget.value;
    }
  }

  /// Attaches the current member and restores an existing notification opt-in.
  ///
  /// Existing opt-in restores enrollment for a new signed-in session without
  /// prompting again. Administrator sessions do not enroll member alerts.
  static Future<void> attach(
    Api api, {
    required String userId,
    required String role,
  }) async {
    if (kIsWeb || role == 'admin' || !_ready) return;
    if (_api == api && _owner == userId) return;
    if (_api != null && (_api != api || _owner != userId)) await detach();
    _api = api;
    _owner = userId;
    final enabled = await _storage.read(key: 'notification_owner');
    if (enabled != null && enabled != userId) {
      // A new login on a shared phone cannot keep receiving a previous account's alerts.
      await _storage.delete(key: 'notification_owner');
      if (defaultTargetPlatform == TargetPlatform.android) {
        await _push.unregister(enabled);
      }
      if (defaultTargetPlatform == TargetPlatform.iOS) {
        await _apple.invokeMethod<void>('unregister');
      }
      await _local.cancelAll();
    }
    status.value = enabled == userId
        ? 'Connecting notifications…'
        : 'Notifications are off';
    if (enabled != userId) return;
    final saved = await _storage.read(key: _key);
    if (saved != null) await _register(Json.from(jsonDecode(saved) as Map));
    if (defaultTargetPlatform == TargetPlatform.android) {
      await _push.register(userId, [], null, null);
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      // Apple can rotate a token; ask the OS on every signed-in launch without another permission prompt.
      try {
        final token = await _apple
            .invokeMethod<String>('register')
            .timeout(const Duration(seconds: 20));
        if (token != null) {
          final device = <String, dynamic>{'provider': 'apns', 'token': token};
          await _storage.write(key: _key, value: jsonEncode(device));
          await _register(device);
        }
      } catch (_) {
        status.value = 'Could not connect notifications. Tap to retry.';
      }
    }
  }

  static Future<void> _register(Json device) async {
    final api = _api;
    final epoch = _epoch;
    if (api == null) return;
    // Serialize enrollment so sign-out can wait for a pending POST before sending DELETE.
    while (_enrollment != null) {
      await _enrollment;
    }
    if (epoch != _epoch || api != _api) return;
    final pending = () async {
      try {
        await api.request('/devices', method: 'POST', body: device);
        if (epoch == _epoch) status.value = 'Notifications enabled';
      } catch (_) {
        if (epoch == _epoch) {
          status.value = 'Could not connect notifications. Tap to retry.';
        }
      }
    }();
    _enrollment = pending;
    await pending;
    if (identical(_enrollment, pending)) _enrollment = null;
  }

  /// Opens the selected Android push companion so its service can be configured.
  static Future<void> openDistributor() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    final package = await _push.getDistributor();
    if (package == null) {
      status.value =
          'Enable notifications first to choose a notification service.';
      return;
    }
    try {
      await _android.invokeMethod<void>('openDistributor', {
        'package': package,
      });
    } catch (_) {
      status.value =
          'Open your notification companion from your phone’s app list.';
    }
  }

  /// Requests permission after an explicit opt-in and enrolls this session's device.
  static Future<void> enable() async {
    if (_api == null || _owner == null || _enabling) return;
    _enabling = true;
    final epoch = _epoch;
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        final granted = await _local
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >()
            ?.requestNotificationsPermission();
        if (granted != true) {
          throw const ApiException(
            'Allow notifications in your phone settings to receive alerts.',
          );
        }
        if (epoch != _epoch) return;
        if (!await _push.tryUseCurrentOrDefaultDistributor()) {
          final distributors = await _push.getDistributors([]);
          if (distributors.isEmpty) {
            throw const ApiException(
              'Install the free ntfy app and set up your community’s notification server, then try again.',
            );
          }
          await _push.saveDistributor(distributors.first);
        }
        if (epoch != _epoch) return;
        await _storage.write(key: 'notification_owner', value: _owner);
        status.value = 'Connecting notifications…';
        await _push.register(_owner!, [], null, null);
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final granted = await _local
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >()
            ?.requestPermissions(alert: true, badge: true, sound: true);
        if (granted != true) {
          throw const ApiException(
            'Allow notifications in Settings to receive alerts.',
          );
        }
        if (epoch != _epoch) return;
        final token = await _apple
            .invokeMethod<String>('register')
            .timeout(const Duration(seconds: 20));
        if (epoch != _epoch) return;
        if (token == null) {
          throw const ApiException(
            'Notification registration is unavailable. Please try again.',
          );
        }
        final device = <String, dynamic>{'provider': 'apns', 'token': token};
        await _storage.write(key: 'notification_owner', value: _owner);
        await _storage.write(key: _key, value: jsonEncode(device));
        await _register(device);
      }
    } catch (e) {
      status.value = e is ApiException
          ? e.message
          : 'Notification setup is unavailable. Please try again.';
    } finally {
      _enabling = false;
    }
  }

  /// Turns alerts off while retaining the signed-in API for a later explicit opt-in.
  static Future<void> disable() async {
    final api = _api;
    final owner = _owner;
    await detach();
    // Turning off alerts is independent of sign-in and can be reversed from the same screen.
    _api = api;
    _owner = owner;
  }

  /// Revokes session ownership and clears local alerts during sign-out or replacement.
  ///
  /// Pending enrollment settles before deletion, preventing a late POST from
  /// recreating the device after the sign-out DELETE has completed.
  static Future<void> detach() async {
    openedTarget.value = null;
    if (!_ready || kIsWeb) return;
    final owner = _owner;
    final api = _api;
    _epoch++;
    _owner = null;
    _api = null;
    await _enrollment;
    final saved = owner == null
        ? null
        : await _storage.read(key: 'notification_device_$owner');
    if (saved != null && api != null) {
      try {
        await api.request(
          '/devices',
          method: 'DELETE',
          body: {'token': (jsonDecode(saved) as Map)['token']},
        );
      } catch (_) {
        /* Generic pushes contain no account details; local ownership below rejects stale delivery. */
      }
    }
    await _storage.delete(key: 'notification_owner');
    if (owner != null) await _storage.delete(key: 'notification_device_$owner');
    if (defaultTargetPlatform == TargetPlatform.android && owner != null) {
      await _push.unregister(owner);
    }
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _apple.invokeMethod<void>('unregister');
    }
    await _local.cancelAll();
    _owner = null;
    _api = null;
    openedTarget.value = null;
    status.value = 'Notifications are off';
  }

  // Use local fixed copy, never server-supplied message text, for lock-screen and watch previews.
  static Future<void> _show(List<int> content) async {
    final target = notificationTarget(
      utf8.decode(content, allowMalformed: true),
    );
    if (target == null) return;
    // System templates are readable on paired watches; no health facts appear in their preview.
    await _local.show(
      id: target.notificationKey.hashCode & 0x7fffffff,
      title: 'Blood Connection',
      body: 'You have a private update. Open the app to view it.',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          'private_updates',
          'Private updates',
          importance: Importance.high,
          priority: Priority.high,
          visibility: NotificationVisibility.private,
          // Native notifications bridge to paired watches by default.
          styleInformation: BigTextStyleInformation(
            'You have a private update. Open the app to view it.',
          ),
          actions: [
            AndroidNotificationAction(
              'open_phone',
              'Open on phone',
              showsUserInterface: true,
            ),
          ],
        ),
        iOS: DarwinNotificationDetails(categoryIdentifier: 'PRIVATE_UPDATE'),
      ),
      payload: jsonEncode(target.payload),
    );
  }
}
