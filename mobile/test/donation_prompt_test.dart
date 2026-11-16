// A persisted reminder should appear on entry, without repeatedly nagging after Later.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/main.dart';
import 'package:blood_connection/ui.dart';

class PendingDonationApi extends Api {
  int dismissals = 0;
  DateTime? peerConfirmedUntil;
  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    if (path == '/me') {
      return {
        'id': 'donor',
        'display_name': 'Nadia',
        'role': 'member',
        'blood_type': 'O+',
        'height_cm': 170,
        'weight_kg': 60,
        'country': 'BD',
        'city': 'Dhaka',
        'location_mode': 'manual',
        'available': true,
        'is_available': true,
        'eligible_after_utc': peerConfirmedUntil?.toIso8601String(),
      };
    }
    if (path == '/donation-confirmations') {
      return {
        'items': [
          {
            'request_id': 'completed-1',
            'facility_name': 'Sample blood bank',
            'country': 'BD',
          },
        ],
      };
    }
    if (path.endsWith('/dismiss')) dismissals++;
    return {'items': []};
  }
}

void main() {
  testWidgets(
    'entry shows persisted donor confirmation and Later leaves it pending without repeated popups',
    (tester) async {
      final api = PendingDonationApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: MainScreen(api: api),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Did you donate blood?'), findsOneWidget);
      await tester.tap(find.byKey(const Key('confirm-donation-later')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('Did you donate blood?'), findsNothing);
      expect(api.dismissals, 0);
      // A seeker's confirmation on another device must refresh this donor's compact status.
      api.peerConfirmedUntil = DateTime.now().toUtc().add(
        const Duration(days: 7),
      );
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
      expect(find.text('In cooldown'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
