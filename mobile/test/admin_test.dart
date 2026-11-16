// These checks protect privileged evidence and the irreversible review workflow on small phones.
import 'dart:async';
import 'dart:typed_data';
import 'package:blood_connection/admin.dart';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart' show TileProvider;

class _AdminApi extends Api {
  final String role;
  final bool denyReports;
  final bool attachments;
  final String reason;
  final List<String> calls = [];
  final List<String> evidenceCalls = [];
  Future<Uint8List> Function()? imageReply;
  Json? decision;
  _AdminApi({
    this.role = 'admin',
    this.denyReports = false,
    this.attachments = false,
    this.reason = 'money_request',
  });

  @override
  Future<Uint8List> adminReportEvidence(
    String reportId,
    String evidenceId,
  ) async {
    evidenceCalls.add('$country/$reportId/$evidenceId');
    return imageReply != null
        ? imageReply!()
        : Uint8List.fromList(TileProvider.transparentImage);
  }

  // Endpoint-shaped fixtures let the test verify authorization flow without real credentials.
  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    calls.add(path);
    if (path == '/me') return {'role': role, 'country': 'BD'};
    if (denyReports && path.startsWith('/admin/')) {
      throw const ApiException(
        'Administrator access required by server.',
        statusCode: 403,
      );
    }
    if (path == '/countries') {
      return {
        'items': [
          {'code': 'BD', 'name': 'Bangladesh'},
          {'code': 'AU', 'name': 'Australia'},
        ],
      };
    }
    if (path == '/admin/summary') {
      return {
        'pending_reports': 1,
        'banned_accounts': 0,
        'active_donors': 4,
        'country': country,
      };
    }
    if (path.endsWith('/resolve')) {
      decision = body;
      return {'status': body!['decision'] == 'ban' ? 'banned' : 'dismissed'};
    }
    if (path == '/admin/reports') {
      return {
        'items': [
          {
            'id': 'test-report',
            'reason': reason,
            'details': 'A fictional member requested money.',
            'status': 'pending',
            'reported_id': 'fictional-reported-account',
            'reporter_id': 'fictional-reporter',
            'created_at': '2026-11-15T00:00:00Z',
            'attachments': attachments
                ? [
                    {
                      'id': 'private-image',
                      'content_type': 'image/jpeg',
                      'created_at': '2026-11-15T00:00:00Z',
                    },
                  ]
                : [],
            'evidence': [
              {
                'sender_id': 'fictional-reported-account',
                'body': 'PRIVATE EVIDENCE: fictional payment request.',
                'created_at': '2026-11-15T00:00:00Z',
              },
            ],
          },
        ],
      };
    }
    throw StateError('Unexpected test route: $path');
  }
}

// Reuse the production theme so widget layout checks also cover real text/button sizing.
Widget _app(
  _AdminApi api, {
  Size size = const Size(375, 812),
  double scale = 1,
}) => MaterialApp(
  theme: appTheme(),
  home: MediaQuery(
    data: MediaQueryData(size: size, textScaler: TextScaler.linear(scale)),
    child: AdminScreen(api: api, onSignOut: () async {}),
  ),
);

void main() {
  testWidgets('ordinary members never request or display admin evidence', (
    tester,
  ) async {
    final api = _AdminApi(role: 'member');
    addTearDown(api.close);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Administrator access is required.'),
      findsOneWidget,
    );
    expect(find.textContaining('PRIVATE EVIDENCE'), findsNothing);
    expect(api.calls, ['/me']);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'server denial clears protected inbox even after an admin role response',
    (tester) async {
      final api = _AdminApi(denyReports: true);
      addTearDown(api.close);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      expect(
        find.text('Administrator access required by server.'),
        findsOneWidget,
      );
      expect(find.text('Request for money'), findsNothing);
      expect(find.textContaining('PRIVATE EVIDENCE'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('small phone and large text keep admin review usable', (
    tester,
  ) async {
    const size = Size(320, 640);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _AdminApi();
    addTearDown(api.close);
    await tester.pumpWidget(_app(api, size: size, scale: 2));
    await tester.pumpAndSettle();
    expect(api.country, 'BD');
    expect(find.text('A safer community.'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Request for money'), 300);
    await tester.tap(find.text('Request for money'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PRIVATE EVIDENCE'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'lifetime ban requires both a review note and evidence confirmation',
    (tester) async {
      final api = _AdminApi();
      addTearDown(api.close);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Request for money'), 300);
      await tester.tap(find.text('Request for money'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review lifetime ban'));
      await tester.tap(find.text('Review lifetime ban'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm lifetime ban'));
      await tester.pumpAndSettle();
      expect(api.decision, isNull);
      expect(
        find.textContaining('Write at least 5 characters'),
        findsOneWidget,
      );
      await tester.enterText(
        find.byType(TextFormField),
        'Confirmed the fictional payment request in context.',
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm lifetime ban'));
      await tester.pumpAndSettle();
      expect(api.decision?['decision'], 'ban');
      expect(
        api.decision?['note'],
        'Confirmed the fictional payment request in context.',
      );
      expect(find.textContaining('Lifetime ban recorded.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'private image previews clear decoded cache on background and leaving report',
    (tester) async {
      final api = _AdminApi(attachments: true);
      addTearDown(api.close);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Request for money'), 300);
      await tester.tap(find.text('Request for money'));
      await tester.pumpAndSettle();
      expect(
        api.evidenceCalls,
        isEmpty,
      ); // Reading the report does not silently download image evidence.
      await tester.scrollUntilVisible(
        find.text('View attached image'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('View attached image'));
      await tester.pumpAndSettle();
      final imageFinder = find.byKey(
        const ValueKey('admin-evidence-image-private-image'),
      );
      final provider = tester.widget<Image>(imageFinder).image;
      await tester.runAsync(
        () => precacheImage(provider, tester.element(imageFinder)),
      );
      await tester.pumpAndSettle();
      expect(api.evidenceCalls, ['BD/test-report/private-image']);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).live,
        isTrue,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(imageFinder, findsNothing);
      expect(find.textContaining('PRIVATE EVIDENCE'), findsNothing);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).live,
        isFalse,
      );
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).keepAlive,
        isFalse,
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(imageFinder, findsNothing);
      await tester.scrollUntilVisible(
        find.text('View attached image'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('View attached image'));
      await tester.pumpAndSettle();
      final reopened = tester.widget<Image>(imageFinder).image;
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(imageFinder, findsNothing);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(reopened).live,
        isFalse,
      );
      expect(
        PaintingBinding.instance.imageCache.statusForKey(reopened).keepAlive,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late image completion cannot restore a backgrounded report', (
    tester,
  ) async {
    final result = Completer<Uint8List>();
    final api = _AdminApi(attachments: true)..imageReply = () => result.future;
    addTearDown(api.close);
    await tester.pumpWidget(_app(api));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Request for money'), 300);
    await tester.tap(find.text('Request for money'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('View attached image'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('View attached image'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    result.complete(Uint8List.fromList(TileProvider.transparentImage));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('admin-evidence-image-private-image')),
      findsNothing,
    );
    expect(api.evidenceCalls, hasLength(1));
    expect(find.text('View attached image'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'image authorization denial clears all protected report evidence',
    (tester) async {
      final api = _AdminApi(attachments: true)
        ..imageReply = () async => throw const ApiException(
          'Evidence access denied.',
          statusCode: 403,
        );
      addTearDown(api.close);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Request for money'), 300);
      await tester.tap(find.text('Request for money'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('View attached image'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('View attached image'));
      await tester.pumpAndSettle();
      expect(find.text('Evidence access denied.'), findsOneWidget);
      expect(find.textContaining('PRIVATE EVIDENCE'), findsNothing);
      expect(find.text('Review lifetime ban'), findsNothing);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'generic violations can be reviewed without enabling money-only permanent bans',
    (tester) async {
      final api = _AdminApi(reason: 'no_show');
      addTearDown(api.close);
      await tester.pumpWidget(_app(api));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text('Missed meeting'), 300);
      await tester.tap(find.text('Missed meeting'));
      await tester.pumpAndSettle();
      expect(find.text('Dismiss report'), findsOneWidget);
      expect(find.text('Review lifetime ban'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
