// These checks cover entry points and layouts that strand users on small phones.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/main.dart';
import 'package:blood_connection/ui.dart';
import 'package:blood_connection/api.dart';

void main() {
  testWidgets(
    'welcome exposes social providers without a production demo bypass',
    (tester) async {
      await tester.pumpWidget(const BloodConnectionApp());
      expect(find.text('Continue with Google'), findsOneWidget);
      expect(find.text('Continue with Apple'), findsOneWidget);
      expect(find.text('Continue with Facebook'), findsOneWidget);
      if (!demoEnabled) expect(find.text('Explore local demo'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [
    const Size(375, 812),
    const Size(812, 375),
    const Size(320, 640),
  ]) {
    testWidgets('home fits ${size.width} x ${size.height} with large text', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: MediaQuery(
            data: MediaQueryData(
              size: size,
              textScaler: const TextScaler.linear(2),
            ),
            child: Scaffold(
              body: HomeScreen(
                me: {
                  'display_name': 'Rafi',
                  'city': 'Dhaka',
                  'country': 'BD',
                  'blood_type': 'B+',
                  'available': true,
                  'is_available': true,
                },
                demo: true,
                onSearch: () {},
                onProfile: () {},
                onAvailability: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('Find a blood donor'), findsOneWidget);
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('blood badge remains bounded inside conversation tiles', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: const Scaffold(
          body: ListTile(
            leading: BloodBadge('AB−'),
            title: Text('Fictional donor'),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
