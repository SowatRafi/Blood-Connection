// Exercise the real profile form so unit preferences, conversion and travel-safe saving work together.
import 'dart:convert';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/profile.dart';
import 'package:blood_connection/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _ProfileApi extends Api {
  Json? savedBody;
  String? savedCountry;

  // Reject unexpected traffic so this test cannot silently substitute for location or photo requests.
  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    if (path != '/me' || method != 'PUT') {
      throw StateError('Unexpected request: $method $path');
    }
    savedBody = Map.of(body!);
    savedCountry = country;
    return {'id': 'member-one', 'country': country, ...body};
  }
}

void main() {
  testWidgets(
    'remembered imperial units save canonical values without overwriting a new location',
    (tester) async {
      FlutterSecureStorage.setMockInitialValues({
        'measurement_units_member-one': jsonEncode({
          'height': 'ft_in',
          'weight': 'lb',
        }),
        'measurement_units_other-member': jsonEncode({
          'height': 'm',
          'weight': 'kg',
        }),
      });
      final api = _ProfileApi()..country = 'BD';
      addTearDown(api.close);
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Json me = {
        'id': 'member-one',
        'display_name': 'Fictional member',
        'blood_type': 'O+',
        'height_cm': 170,
        'weight_kg': 65,
        'available': true,
        'is_available': true,
        'country': 'BD',
        'city': 'Dhaka',
        'latitude': 23.8,
        'longitude': 90.4,
        'location_mode': 'automatic',
      };
      Json? savedProfile;
      late StateSetter updateHost;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updateHost = setState;
                return ProfileScreen(
                  api: api,
                  me: me,
                  onSaved: (value) => savedProfile = value,
                  onSignOut: () async {},
                  onLocation: () async {},
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('height-unit-ft_in')), findsOneWidget);
      expect(find.byKey(const ValueKey('weight-unit-lb')), findsOneWidget);

      for (final entry in {
        'height-ft': '5',
        'height-in': '6',
        'weight-lb': '150',
      }.entries) {
        final field = find.byKey(ValueKey(entry.key));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.enterText(field, entry.value);
        await tester.pump();
      }
      expect(find.text('Body mass index (BMI)  24.2'), findsOneWidget);
      tester.testTextInput.hide();
      await tester.pumpAndSettle();

      // Simulate an automatic travel update after typing: the form must use the new server location.
      api.country = 'AU';
      updateHost(
        () => me = {
          ...me,
          'country': 'AU',
          'city': 'Sydney',
          'latitude': -33.86,
          'longitude': 151.2,
        },
      );
      await tester.pump();
      final save = find.text('Save my details');
      await tester.ensureVisible(save);
      await tester.pumpAndSettle();
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(api.savedBody?['height_cm'], closeTo(167.64, 1e-9));
      expect(api.savedBody?['weight_kg'], closeTo(68.0388555, 1e-9));
      expect(api.savedCountry, 'AU');
      expect(api.savedBody?['city'], 'Sydney');
      expect(api.savedBody?['latitude'], -33.86);
      expect(api.savedBody?['longitude'], 151.2);
      expect(savedProfile?['id'], 'member-one');
      const storage = FlutterSecureStorage();
      expect(
        jsonDecode((await storage.read(key: 'measurement_units_member-one'))!),
        {'height': 'ft_in', 'weight': 'lb'},
      );
      expect(
        jsonDecode(
          (await storage.read(key: 'measurement_units_other-member'))!,
        ),
        {'height': 'm', 'weight': 'kg'},
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
