// Reports are acknowledged before success; partial evidence retries must never create another report.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:image_picker/image_picker.dart';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/reports.dart';
import 'package:blood_connection/requests.dart';
import 'package:blood_connection/messaging.dart';
import 'package:blood_connection/ui.dart';

class ReportApi extends Api {
  final posts = <Json>[];
  final uploads = <String>[];
  bool failCreate = false, failSecondImage = false;
  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    if (path == '/reports') {
      posts.add({...body!});
      if (failCreate) {
        throw const ApiException('Report could not be acknowledged.');
      }
      return {'id': 'report-one', 'status': 'pending'};
    }
    if (path.startsWith('/requests/')) {
      return {
        'id': 'request-one',
        'status': 'completed',
        'is_requester': true,
        'can_report': true,
        'accepted_donor_id': 'donor',
        'blood_type': 'O+',
        'donation_recorded': true,
        'donation_summary': {
          'donated_at': '2026-11-15',
          'facility_name': 'City Hospital',
          'location_name': 'Dhaka',
          'country': 'BD',
          'confirmed_by_role': 'seeker',
        },
      };
    }
    return {};
  }

  @override
  Future<List<Json>> list(String path, {Map<String, String>? query}) async =>
      [];
  @override
  Future<Json> uploadReportEvidence(String reportId, Uint8List bytes) async {
    uploads.add(reportId);
    if (failSecondImage && uploads.length == 2) {
      throw const ApiException('Second image upload failed.');
    }
    return {'id': 'image-${uploads.length}', 'content_type': 'image/jpeg'};
  }
}

// In-memory picker results keep tests independent from a device gallery and real personal images.
XFile photo(String name) => XFile.fromData(
  TileProvider.transparentImage,
  name: name,
  mimeType: 'image/png',
);

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
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Widget reportHost(ReportApi api, {Future<List<XFile>> Function()? picker}) =>
    Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => ReportScreen(
                api: api,
                requestId: 'request-one',
                pickImages: picker,
              ),
            ),
          ),
          child: const Text('Open report'),
        ),
      ),
    );

void main() {
  testWidgets(
    'create failure retains draft and stable retry key without claiming success',
    (tester) async {
      final api = ReportApi()..failCreate = true;
      addTearDown(api.close);
      await host(tester, reportHost(api));
      await tester.tap(find.text('Open report'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('report-details')),
        'They asked me for money.',
      );
      await tapVisible(tester, find.byKey(const Key('submit-report')));
      expect(find.text('They asked me for money.'), findsOneWidget);
      expect(find.textContaining('Report received.'), findsNothing);
      api.failCreate = false;
      await tapVisible(tester, find.byKey(const Key('submit-report')));
      expect(api.posts, hasLength(2));
      expect(
        api.posts.first['idempotency_key'],
        matches(RegExp(r'^[a-f0-9]{32}$')),
      );
      expect(
        api.posts.last['idempotency_key'],
        api.posts.first['idempotency_key'],
      );
      expect(api.posts.last['request_id'], 'request-one');
      expect(api.posts.last.containsKey('conversation_id'), isFalse);
      expect(find.textContaining('Report received.'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('finish-report')));
      expect(find.byType(ReportScreen), findsNothing);
      expect(find.text('Open report'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'partial evidence save retries only remaining images on the acknowledged report',
    (tester) async {
      final api = ReportApi()..failSecondImage = true;
      addTearDown(api.close);
      await host(
        tester,
        reportHost(
          api,
          picker: () async => [photo('first.png'), photo('second.png')],
        ),
      );
      await tester.tap(find.text('Open report'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('report-details')),
        'These screenshots show the request.',
      );
      await tapVisible(tester, find.byKey(const Key('add-report-evidence')));
      await tapVisible(tester, find.byKey(const Key('submit-report')));
      expect(
        find.textContaining('Report saved. 1 of 2 images attached.'),
        findsOneWidget,
      );
      expect(find.text('Second image upload failed.'), findsOneWidget);
      expect(find.textContaining('Report received.'), findsNothing);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('report-details')))
            .enabled,
        isFalse,
      );
      await tapVisible(tester, find.byKey(const Key('submit-report')));
      expect(api.posts, hasLength(1));
      expect(api.uploads, ['report-one', 'report-one', 'report-one']);
      expect(find.textContaining('All 2 images attached.'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('finish-report')));
      expect(find.text('Open report'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Back requires an explicit discard and Keep editing preserves the draft',
    (tester) async {
      final api = ReportApi();
      addTearDown(api.close);
      await host(tester, reportHost(api), size: const Size(320, 640), scale: 2);
      await tester.tap(find.text('Open report'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('report-details')),
        'An unsent private draft.',
      );
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Discard this draft?'), findsOneWidget);
      await tester.tap(find.text('Keep editing'));
      await tester.pumpAndSettle();
      expect(find.text('An unsent private draft.'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Discard draft'));
      await tester.pumpAndSettle();
      expect(find.byType(ReportScreen), findsNothing);
      expect(api.posts, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('picker rejects excess images without dropping existing text', (
    tester,
  ) async {
    final api = ReportApi();
    addTearDown(api.close);
    await host(
      tester,
      ReportScreen(
        api: api,
        conversationId: 'chat-one',
        pickImages: () async => List.generate(4, (i) => photo('$i.png')),
      ),
      size: const Size(320, 640),
      scale: 2,
    );
    await tester.enterText(
      find.byKey(const Key('report-details')),
      'This is my explanation.',
    );
    await tapVisible(tester, find.byKey(const Key('add-report-evidence')));
    expect(find.text('Choose no more than three images.'), findsOneWidget);
    expect(find.text('Images · 0/3'), findsOneWidget);
    expect(find.text('This is my explanation.'), findsOneWidget);
    expect(api.posts, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'evidence validation rejects unsupported formats and oversized payloads',
    () {
      expect(
        () => privateImageType(Uint8List.fromList([1, 2, 3])),
        throwsA(isA<ApiException>()),
      );
      expect(
        () => privateImageType(Uint8List(5 * 1024 * 1024 + 1)),
        throwsA(isA<ApiException>()),
      );
      expect(privateImageType(TileProvider.transparentImage), 'image/png');
    },
  );

  testWidgets(
    'closed matched request shows donation result and can still open a report',
    (tester) async {
      final api = ReportApi();
      addTearDown(api.close);
      await host(
        tester,
        RequestDetailScreen(
          api: api,
          me: const {'id': 'seeker'},
          requestId: 'request-one',
        ),
      );
      expect(find.text('Donation confirmed'), findsOneWidget);
      expect(find.textContaining('Confirmed by the seeker.'), findsOneWidget);
      await tapVisible(tester, find.byKey(const Key('report-match')));
      expect(
        tester.widget<ReportScreen>(find.byType(ReportScreen)).requestId,
        'request-one',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'blocked conversation disables communication but keeps report entry',
    (tester) async {
      final api = ReportApi();
      addTearDown(api.close);
      await host(
        tester,
        ChatScreen(
          api: api,
          me: const {'id': 'me'},
          conversation: const {
            'id': 'chat-one',
            'peer_id': 'peer',
            'peer_name': 'Partner',
            'is_blocked': true,
          },
        ),
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Private voice call',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton && widget.tooltip == 'Send message',
              ),
            )
            .onPressed,
        isNull,
      );
      await tester.tap(find.byTooltip('Conversation safety'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Report conversation'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ReportScreen>(find.byType(ReportScreen)).conversationId,
        'chat-one',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
}
