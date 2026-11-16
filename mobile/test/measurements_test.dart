// Units are presentation: changing them must not silently change a saved measurement or BMI.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/measurements.dart';
import 'package:blood_connection/ui.dart';

void main() {
  test('metric and imperial forms produce the same canonical measurements', () {
    expect(metricMeasurement('ft_in', '5', '7'), closeTo(170.18, 1e-9));
    expect(metricMeasurement('in', '67'), closeTo(170.18, 1e-9));
    expect(metricMeasurement('m', '1,7018'), closeTo(170.18, 1e-9));
    expect(metricMeasurement('cm', '170.18'), 170.18);
    expect(metricMeasurement('lb', '140'), closeTo(63.5029318, 1e-9));
    expect(metricMeasurement('st_lb', '10', '0'), closeTo(63.5029318, 1e-9));
    expect(metricMeasurement('kg', '63.5029318'), 63.5029318);
    expect(metricMeasurement('ft_in', '5', ''), 152.4);
    expect(metricMeasurement('ft_in', '5.5', '0'), isNull);
    expect(metricMeasurement('ft_in', '5', '12'), isNull);
    expect(metricMeasurement('st_lb', '10', '14'), isNull);
    expect(metricMeasurement('lb', '-2'), isNull);
    expect(metricMeasurement('kg', 'NaN'), isNull);
    expect(metricMeasurement('kg', 'Infinity'), isNull);
    expect(metricMeasurement('m', '1e308'), isNull);
    expect(displayMeasurement('lb', 62), ('136.69', ''));
    expect(displayMeasurement('ft_in', 165), ('5', '4.96'));
    expect(displayMeasurement('ft_in', 182.8799), ('6', '0'));
    expect(displayMeasurement('st_lb', 140 * poundsToKg - .0001), ('10', '0'));
  });

  testWidgets(
    'repeated unit changes preserve exact value and validate boundary measurements',
    (tester) async {
      final form = GlobalKey<FormState>();
      var unit = 'cm';
      double? value = 250;
      late StateSetter change;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: Form(
              key: form,
              child: StatefulBuilder(
                builder: (context, setState) {
                  change = setState;
                  return MeasurementField(
                    height: true,
                    unit: unit,
                    metricValue: value,
                    onChanged: (v) => setState(() => value = v),
                    onUnitChanged: (v) => setState(() => unit = v),
                  );
                },
              ),
            ),
          ),
        ),
      );
      for (final next in ['ft_in', 'in', 'm', 'cm', 'ft_in', 'cm']) {
        change(() => unit = next);
        await tester.pump();
        expect(form.currentState!.validate(), isTrue);
        expect(value, 250);
      }
      change(() => unit = 'ft_in');
      await tester.pump();
      await tester.enterText(find.byKey(const ValueKey('height-ft')), '5');
      await tester.enterText(find.byKey(const ValueKey('height-in')), '7');
      await tester.pump();
      expect(value, closeTo(170.18, 1e-9));
      expect(form.currentState!.validate(), isTrue);
      await tester.enterText(find.byKey(const ValueKey('height-in')), '12');
      await tester.pump();
      expect(form.currentState!.validate(), isFalse);
    },
  );

  testWidgets(
    'all unit selectors and fields fit a narrow phone at doubled text size',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final unit in [...heightUnits.keys, ...weightUnits.keys]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Form(
                    child: MeasurementField(
                      key: ValueKey(unit),
                      height: heightUnits.containsKey(unit),
                      unit: unit,
                      metricValue: heightUnits.containsKey(unit) ? 170 : 70,
                      onChanged: (_) {},
                      onUnitChanged: (_) {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: unit);
        await tester.tap(find.byType(DropdownButtonFormField<String>));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$unit menu');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
    },
  );
}
