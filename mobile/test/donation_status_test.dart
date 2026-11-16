// Exercise the policy boundary, user preference and readable layout rather than matching widget internals.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/donation_status.dart';
import 'package:blood_connection/ui.dart';

void main() {
  testWidgets(
    'compact status leaves Home space and keeps settings one tap away',
    (tester) async {
      tester.view.physicalSize = const Size(375, 812);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool? saved;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: DonationStatusCard(
                compact: true,
                me: const {'blood_type': 'O+', 'available': true},
                onAvailability: (value) => saved = value,
                onRecord: () {},
                onHistory: () {},
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const Key('compact-donation-status'))).height,
        lessThan(130),
      );
      expect(find.text('Donation history'), findsNothing);
      await tester.tap(find.byType(Switch));
      expect(saved, false);
      await tester.tap(find.byTooltip('Donation settings and history'));
      await tester.pumpAndSettle();
      expect(find.text('Donation history'), findsOneWidget);
      expect(find.text('Record donation'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('remaining time rounds up and never claims zero while paused', () {
    expect(
      donationTimeRemaining(const Duration(days: 2, hours: 3, minutes: 4)),
      '2 days, 3 hours, 4 minutes remaining',
    );
    expect(
      donationTimeRemaining(const Duration(milliseconds: 1)),
      '1 minute remaining',
    );
    expect(donationTimeRemaining(Duration.zero), 'Cooldown complete');
  });

  testWidgets(
    'cooldown overrides willingness and preserves the return preference',
    (tester) async {
      final end = DateTime.now().toUtc().add(const Duration(days: 7, hours: 2));
      Future<void> show(bool willing, DateTime deadline) => tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: DonationStatusCard(
                me: {
                  'blood_type': 'O+',
                  'available': willing,
                  'is_available': false,
                  'eligible_after_utc': deadline.toIso8601String(),
                },
                onAvailability: (_) {},
              ),
            ),
          ),
        ),
      );
      await show(true, end);
      expect(find.text('In cooldown'), findsOneWidget);
      expect(find.textContaining('7 days'), findsOneWidget);
      expect(
        find.textContaining('become available automatically'),
        findsOneWidget,
      );
      await show(false, end);
      expect(find.text('In cooldown'), findsOneWidget);
      expect(find.textContaining('stay offline afterwards'), findsOneWidget);
      final past = DateTime.now().toUtc().subtract(const Duration(seconds: 1));
      await show(false, past);
      expect(find.text('Offline'), findsOneWidget);
      await show(true, past);
      expect(find.text('Available to donate'), findsOneWidget);
      expect(find.textContaining('remaining'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('long countdown and controls fit a small phone with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: DonationStatusCard(
                me: {
                  'blood_type': 'AB-',
                  'available': true,
                  'eligible_after_utc': DateTime.now()
                      .toUtc()
                      .add(const Duration(days: 92, hours: 23, minutes: 58))
                      .toIso8601String(),
                },
                onAvailability: (_) {},
                onRecord: () {},
                onHistory: () {},
              ),
            ),
          ),
        ),
      ),
    );
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    expect(find.text('Donation history'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
