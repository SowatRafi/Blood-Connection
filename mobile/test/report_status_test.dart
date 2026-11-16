// Owner status and notification targets must survive travel without changing the active search region.
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/main.dart';
import 'package:blood_connection/notifications.dart';
import 'package:blood_connection/reports.dart';
import 'package:blood_connection/requests.dart';
import 'package:blood_connection/ui.dart';

class OwnerReportApi extends Api {
  final reads = <(String, Map<String, String>?)>[];
  final evidenceCountries = <String?>[];
  Completer<Json>? profileGate;
  Completer<Uint8List>? evidenceGate;
  bool denied = false;
  Json item = {
    'id': 'report-one',
    'country': 'BD',
    'reason': 'money_request',
    'details': 'My original account of the incident.',
    'status': 'reviewed',
    'outcome': 'dismissed',
    'submitted_at': '2026-11-15T01:00:00Z',
    'reviewed_at': '2026-11-15T03:00:00Z',
    'outcome_explanation': 'The review did not establish a violation.',
    'notes': 'INTERNAL MODERATOR SECRET',
    'attachments': [
      {
        'id': 'evidence-one',
        'content_type': 'image/jpeg',
        'created_at': '2026-11-15T01:01:00Z',
      },
    ],
  };
  List<Json> events = [];
  static const me = <String, dynamic>{
    'id': 'owner',
    'role': 'member',
    'display_name': 'Owner',
    'country': 'AU',
    'city': 'Sydney',
    'latitude': -33.8,
    'longitude': 151.2,
    'location_mode': 'manual',
    'height_cm': 170,
    'weight_kg': 60,
    'blood_type': 'O+',
    'available': true,
    'is_available': true,
  };
  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    reads.add((path, query));
    if (path == '/me') return profileGate == null ? me : profileGate!.future;
    if (path == '/reports/report-one') {
      if (denied) {
        throw const ApiException('Report is unavailable.', statusCode: 404);
      }
      return Map.of(item);
    }
    return {'items': []};
  }

  @override
  Future<List<Json>> list(String path, {Map<String, String>? query}) async {
    reads.add((path, query));
    if (path == '/reports') return [Map.of(item)];
    if (path == '/events') return events;
    return [];
  }

  @override
  Future<Uint8List> reportEvidence(
    String reportId,
    String evidenceId, {
    String? country,
  }) async {
    evidenceCountries.add(country);
    if (denied) {
      throw const ApiException('Evidence is unavailable.', statusCode: 404);
    }
    return evidenceGate == null
        ? TileProvider.transparentImage
        : evidenceGate!.future;
  }
}

Future<void> mount(
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

void main() {
  testWidgets(
    'owner history opens original-region details and evidence without exposing internal notes',
    (tester) async {
      final api = OwnerReportApi()..country = 'AU';
      addTearDown(api.close);
      await mount(tester, MyReportsScreen(api: api));
      expect(find.text('Reviewed · closed'), findsOneWidget);
      await tester.tap(find.text('View report'));
      await tester.pumpAndSettle();
      expect(find.text('My original account of the incident.'), findsOneWidget);
      expect(
        find.text('The review did not establish a violation.'),
        findsOneWidget,
      );
      expect(find.text('INTERNAL MODERATOR SECRET'), findsNothing);
      expect(
        api.reads.where((entry) => entry.$1 == '/reports/report-one').single.$2,
        {'country': 'BD'},
      );
      expect(api.evidenceCountries, ['BD']);
      expect(api.country, 'AU');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'detail clears old evidence when authorization fails on refresh',
    (tester) async {
      final api = OwnerReportApi()..country = 'AU';
      addTearDown(api.close);
      await mount(
        tester,
        ReportDetailScreen(
          api: api,
          reportId: 'report-one',
          reportCountry: 'BD',
        ),
      );
      expect(find.byType(Image), findsOneWidget);
      api.denied = true;
      await tester.tap(find.byTooltip('Refresh report status'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
      expect(find.text('My original account of the incident.'), findsNothing);
      expect(find.text('Report is unavailable.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'a late evidence response cannot restore a backgrounded private report',
    (tester) async {
      final api = OwnerReportApi()..evidenceGate = Completer<Uint8List>();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: ReportDetailScreen(
            api: api,
            reportId: 'report-one',
            reportCountry: 'BD',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      api.evidenceGate!.complete(TileProvider.transparentImage);
      await tester.pump();
      expect(find.byType(Image), findsNothing);
      expect(find.text('My original account of the incident.'), findsNothing);
      api.denied = true;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Report is unavailable.'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('large-text owner timeline and image controls remain reachable', (
    tester,
  ) async {
    final api = OwnerReportApi()..country = 'AU';
    addTearDown(api.close);
    await mount(
      tester,
      ReportDetailScreen(api: api, reportId: 'report-one', reportCountry: 'BD'),
      size: const Size(320, 640),
      scale: 2,
    );
    await tester.ensureVisible(find.text('View image'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View image'));
    await tester.pumpAndSettle();
    expect(find.text('Private evidence'), findsOneWidget);
    expect(api.evidenceCountries, ['BD', 'BD']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'report notification waits for sign-in profile then opens its region without travel',
    (tester) async {
      final api = OwnerReportApi()
        ..country = 'AU'
        ..profileGate = Completer<Json>();
      addTearDown(api.close);
      addTearDown(() => NotificationService.openedTarget.value = null);
      NotificationService.openedTarget.value =
          const PrivateNotificationTarget.report('report-one', 'BD');
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: MainScreen(api: api),
        ),
      );
      await tester.pump();
      expect(find.byType(ReportDetailScreen), findsNothing);
      expect(NotificationService.openedTarget.value?.reportId, 'report-one');
      api.profileGate!.complete(OwnerReportApi.me);
      await tester.pumpAndSettle();
      expect(find.byType(ReportDetailScreen), findsOneWidget);
      expect(NotificationService.openedTarget.value, isNull);
      expect(api.country, 'AU');
      expect(
        api.reads.where((entry) => entry.$1 == '/reports/report-one').single.$2,
        {'country': 'BD'},
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'donation notification still opens Requests instead of a report',
    (tester) async {
      final api = OwnerReportApi()..country = 'AU';
      addTearDown(api.close);
      addTearDown(() => NotificationService.openedTarget.value = null);
      NotificationService.openedTarget.value =
          const PrivateNotificationTarget.request('request-one');
      await mount(tester, MainScreen(api: api));
      expect(find.byType(RequestsScreen), findsOneWidget);
      expect(find.byType(ReportDetailScreen), findsNothing);
      expect(api.country, 'AU');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'review inbox uses event region for read acknowledgement and report navigation',
    (tester) async {
      final api = OwnerReportApi()
        ..country = 'AU'
        ..events = [
          {
            'id': '7',
            'country': 'BD',
            'report_id': 'report-one',
            'report_country': 'BD',
            'request_id': null,
            'title': 'Your report was reviewed',
            'body': 'Open to see the result.',
            'read': false,
          },
        ];
      addTearDown(api.close);
      await mount(
        tester,
        Scaffold(
          body: RequestsScreen(api: api, me: OwnerReportApi.me, onFind: () {}),
        ),
      );
      await tester.tap(find.text('Your report was reviewed'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportDetailScreen), findsOneWidget);
      expect(
        api.reads.where((entry) => entry.$1 == '/events/7/read').single.$2,
        {'country': 'BD'},
      );
      expect(api.country, 'AU');
      await tester.pumpWidget(const SizedBox());
    },
  );
}
