// Saving, dismissing and delaying a donation have different privacy and cooldown consequences.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/donations.dart';
import 'package:blood_connection/requests.dart';
import 'package:blood_connection/ui.dart';

const me = <String, dynamic>{
  'id': 'donor',
  'country': 'AU',
  'city': 'Sydney',
  'available': true,
  'is_available': true,
};
const pending = <String, dynamic>{
  'request_id': 'request-one',
  'facility_name': 'City Blood Bank',
  'location_name': null,
  'country': 'BD',
  'created_at': '2026-11-15T01:00:00Z',
};

class DonationApi extends Api {
  final writes = <(String, Json?)>[];
  List<Json> history = [];
  List<Json> confirmations = [];
  Future<Json> Function(String, Json?)? respond;

  @override
  Future<List<Json>> list(String path, {Map<String, String>? query}) async =>
      switch (path) {
        '/countries' => [
          {'code': 'AU', 'name': 'Australia'},
          {'code': 'BD', 'name': 'Bangladesh'},
        ],
        '/donations' => history,
        '/donation-confirmations' => confirmations,
        _ => [],
      };

  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    if (method != 'GET') writes.add((path, body));
    if (respond != null) return respond!(path, body);
    if (path.endsWith('/dismiss')) {
      confirmations = [];
      return {'status': 'dismissed'};
    }
    if (path.startsWith('/requests/')) {
      return {
        'id': 'request-one',
        'status': path.endsWith('/complete') ? 'completed' : 'accepted',
        'is_requester': false,
        'accepted_donor_id': 'donor',
        'blood_type': 'O+',
        'requester_name': 'Requester',
      };
    }
    return {...me, 'eligible_after': '2027-02-15', 'is_available': false};
  }
}

// Real routes and Material controls exercise errors and large text without platform integrations.
Future<void> host(
  WidgetTester tester,
  Widget child, {
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets(
    'seeker confirms the actual donor without receiving a personal donation pause',
    (tester) async {
      final api = DonationApi();
      addTearDown(api.close);
      const seeker = <String, dynamic>{
        'id': 'seeker',
        'country': 'AU',
        'city': 'Sydney',
        'available': true,
        'is_available': true,
      };
      api.respond = (_, _) async => seeker;
      Json? result;
      await host(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDonationConfirmation(context, api, seeker, {
                  ...pending,
                  'is_donor': false,
                  'donor_name': 'Donor Partner',
                });
              },
              child: const Text('Prompt'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();
      expect(find.text('Did the donor give blood?'), findsOneWidget);
      expect(
        find.textContaining('Your account is not paused.'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('confirm-donation-yes')));
      await tester.pumpAndSettle();
      expect(find.text('Confirm what happened.'), findsOneWidget);
      expect(
        find.textContaining('It does not pause your account'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const Key('donation-location')),
        'Dhaka',
      );
      await tapVisible(tester, find.byKey(const Key('save-donation')));
      await tester.pumpAndSettle();
      expect(api.writes.single.$2!['request_id'], 'request-one');
      expect(result?['id'], 'seeker');
      expect(result?['is_available'], isTrue);
      expect(result?.containsKey('eligible_after'), isFalse);
      expect(
        find.textContaining(
          'The donor’s record and recovery pause are updated.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Your private history and donation pause are updated.',
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'recorder validates place and returns success only after the server saves',
    (tester) async {
      final api = DonationApi();
      addTearDown(api.close);
      final save = Completer<Json>();
      api.respond = (_, _) => save.future;
      Json? result;
      await host(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDonationRecorder(context, api, me);
              },
              child: const Text('Record'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Record'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.byKey(const Key('save-donation')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(find.text('Enter 2–160 characters.'), findsNWidgets(2));
      await tester.enterText(
        find.byKey(const Key('donation-facility')),
        '  City Blood Bank  ',
      );
      await tester.enterText(
        find.byKey(const Key('donation-location')),
        '  Parramatta  ',
      );
      await tapVisible(tester, find.byKey(const Key('save-donation')));
      expect(result, isNull);
      expect(find.byKey(const Key('donation-recorder')), findsOneWidget);
      expect(api.writes.single.$2!['facility_name'], 'City Blood Bank');
      expect(api.writes.single.$2!['location_name'], 'Parramatta');
      expect(api.writes.single.$2!['country'], 'AU');
      expect(
        api.writes.single.$2!['utc_offset_minutes'],
        DateTime.now().timeZoneOffset.inMinutes,
      );
      expect(api.writes.single.$2!.containsKey('request_id'), isFalse);
      save.complete({
        ...me,
        'eligible_after': '2027-02-15',
        'is_available': false,
      });
      await tester.pumpAndSettle();
      expect(result?['is_available'], isFalse);
      expect(find.byKey(const Key('donation-recorder')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('save failure preserves entered details for retry', (
    tester,
  ) async {
    final api = DonationApi()
      ..respond = (_, _) async =>
          throw const ApiException('Could not save. Try again.');
    addTearDown(api.close);
    await host(tester, DonationRecorderScreen(api: api, me: me));
    await tester.enterText(
      find.byKey(const Key('donation-facility')),
      'Hospital One',
    );
    await tester.enterText(find.byKey(const Key('donation-location')), 'Dhaka');
    await tapVisible(tester, find.byKey(const Key('save-donation')));
    await tester.pumpAndSettle();
    expect(find.text('Could not save. Try again.'), findsOneWidget);
    expect(find.text('Hospital One'), findsOneWidget);
    expect(find.text('Dhaka'), findsOneWidget);
    expect(find.textContaining('Donation saved.'), findsNothing);
    await tapVisible(tester, find.byKey(const Key('save-donation')));
    await tester.pumpAndSettle();
    expect(api.writes, hasLength(2));
    expect(
      api.writes.first.$2!['idempotency_key'],
      matches(RegExp(r'^[a-f0-9]{32}$')),
    );
    expect(
      api.writes.last.$2!['idempotency_key'],
      api.writes.first.$2!['idempotency_key'],
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Later is non-mutating and Yes requires missing donation location',
    (tester) async {
      final api = DonationApi();
      addTearDown(api.close);
      await host(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDonationConfirmation(context, api, me, pending),
              child: const Text('Prompt'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-donation-later')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-donation-yes')));
      await tester.pumpAndSettle();
      expect(find.text('City Blood Bank'), findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('donation-location')))
            .controller!
            .text,
        isEmpty,
      );
      await tapVisible(tester, find.byKey(const Key('save-donation')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      await tester.enterText(
        find.byKey(const Key('donation-location')),
        'Dhaka',
      );
      await tapVisible(tester, find.byKey(const Key('save-donation')));
      await tester.pumpAndSettle();
      expect(api.writes.single.$2!['request_id'], 'request-one');
      expect(api.writes.single.$2!['country'], 'BD');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'No donation dismisses only after server confirmation and never records blood',
    (tester) async {
      final api = DonationApi();
      addTearDown(api.close);
      var fail = true;
      api.respond = (_, _) async {
        if (fail) throw const ApiException('Dismissal unavailable');
        return {'status': 'dismissed'};
      };
      await host(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showDonationConfirmation(context, api, me, pending),
              child: const Text('Prompt'),
            ),
          ),
        ),
        size: const Size(320, 640),
        scale: 2,
      );
      await tester.tap(find.text('Prompt'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-donation-no')));
      await tester.pumpAndSettle();
      expect(find.text('Dismissal unavailable'), findsOneWidget);
      expect(find.text('Did you donate blood?'), findsOneWidget);
      expect(tester.takeException(), isNull);
      fail = false;
      await tester.tap(find.byKey(const Key('confirm-donation-no')));
      await tester.pumpAndSettle();
      expect(find.text('Did you donate blood?'), findsNothing);
      expect(
        api.writes.every(
          (item) => item.$1 == '/donation-confirmations/request-one/dismiss',
        ),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'history preserves legacy unknown details and exposes Later confirmations',
    (tester) async {
      final api = DonationApi()
        ..confirmations = [pending]
        ..history = [
          {
            'id': 'old-one',
            'donated_at': '2026-08-10',
            'facility_name': null,
            'location_name': null,
            'country': 'BD',
          },
        ];
      addTearDown(api.close);
      await host(
        tester,
        DonationHistoryScreen(api: api, me: me),
        size: const Size(1024, 900),
        scale: 2,
      );
      expect(find.text('Review donation'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const Key('donation-confirmation-request-one')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-donation-later')));
      await tester.pumpAndSettle();
      expect(find.text('Review donation'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const Key('donation-record-old-one')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Facility not recorded'), findsOneWidget);
      expect(find.text('Location not recorded'), findsOneWidget);
      expect(find.text('Sydney'), findsNothing);
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'manual form remains scrollable and usable at narrow doubled text',
    (tester) async {
      final api = DonationApi();
      addTearDown(api.close);
      await host(
        tester,
        DonationRecorderScreen(api: api, me: me),
        size: const Size(320, 640),
        scale: 2,
      );
      await tapVisible(tester, find.byKey(const Key('save-donation')));
      await tester.pumpAndSettle();
      expect(api.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'completing coordination returns to list without recording a donation',
    (tester) async {
      final api = DonationApi();
      addTearDown(api.close);
      await host(
        tester,
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => RequestDetailScreen(
                    api: api,
                    me: me,
                    requestId: 'request-one',
                  ),
                ),
              ),
              child: const Text('Requests list'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Requests list'));
      await tester.pumpAndSettle();
      await tapVisible(tester, find.text('Mark coordination complete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.text('Requests list'), findsOneWidget);
      expect(find.byType(RequestDetailScreen), findsNothing);
      expect(api.writes.single.$1, '/requests/request-one/complete');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
