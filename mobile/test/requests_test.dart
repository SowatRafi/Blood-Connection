// Request privacy is checked at the UI boundary as well as in the server tests.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/main.dart';
import 'package:blood_connection/requests.dart';
import 'package:blood_connection/private_photo.dart';
import 'package:blood_connection/ui.dart';
import 'package:blood_connection/location.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:flutter_map/flutter_map.dart';

// Real map gestures are exercised with an in-memory tile so the test never downloads map data.
class PreviewTiles extends TileProvider {
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      MemoryImage(TileProvider.transparentImage);
}

class RequestApi extends Api {
  Json item = {
    'id': 'request-1',
    'status': 'open',
    'requester_id': 'seeker',
    'requester_name': 'Fictional requester',
    'blood_type': 'O+',
    'is_requester': false,
    'invitation_status': 'invited',
    'peer_id': 'seeker',
    'peer_name': 'Fictional requester',
    'peer_has_photo': true,
  };
  int photoReads = 0;
  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    if (path == '/countries') {
      return {
        'items': [
          {'code': 'BD', 'name': 'Bangladesh'},
        ],
      };
    }
    if (path == '/me') {
      return {
        'id': 'donor',
        'role': 'member',
        'country': 'BD',
        'city': 'Dhaka',
        'display_name': 'Fictional donor',
        'blood_type': 'O+',
        'height_cm': 170,
        'weight_kg': 60,
        'latitude': 23.8,
        'longitude': 90.4,
        'location_mode': 'manual',
        'available': true,
        'is_available': true,
      };
    }
    if (path.endsWith('/cancel')) {
      item = {...item, 'status': 'cancelled'};
    }
    return Json.from(item);
  }

  @override
  Future<Uint8List> photo(String userId) async {
    photoReads++;
    throw const ApiException('No photo', statusCode: 404);
  }
}

void main() {
  testWidgets(
    'one-finger swipe over map scrolls page to Go and attribution wraps',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              controller: scroll,
              padding: const EdgeInsets.all(24),
              child: MeetingMap(
                tileProvider: PreviewTiles(),
                request: const {
                  'destination_name': 'Community Hospital',
                  'destination_latitude': 23.8,
                  'destination_longitude': 90.4,
                },
                me: const {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final map = find.byType(FlutterMap);
      final before = scroll.offset;
      await tester.drag(map, const Offset(0, -460));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(before + 100));
      expect(find.text(mapAttribution), findsOneWidget);
      expect(find.textContaining('flutter_map |'), findsNothing);
      // At 200% text the explanatory content needs further ordinary swipes; no programmatic jump may reveal Go.
      for (
        var swipe = 0;
        swipe < 4 &&
            find.text('Go · open directions').hitTestable().evaluate().isEmpty;
        swipe++
      ) {
        await tester.dragFrom(const Offset(160, 500), const Offset(0, -300));
        await tester.pumpAndSettle();
      }
      expect(find.text('Go · open directions').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('map picker remains scrollable at 320px with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                selected = await chooseDirectionsApp(context);
              },
              child: const Text('Directions'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Directions'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Waze'));
    await tester.tap(find.text('Waze'));
    await tester.pumpAndSettle();
    expect(selected, 'Waze');
    expect(tester.takeException(), isNull);
  });

  testWidgets('hospital confirmation scrolls at 320px with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = RequestApi();
    addTearDown(api.close);
    final service = LocationService(
      geocode: (_) async => [
        const geo.Location(latitude: 23.8, longitude: 90.4),
      ],
      reverse: (_, _) async => [
        const geo.Placemark(
          isoCountryCode: 'BD',
          locality: 'Dhaka',
          name: 'Community Hospital',
          street: 'Main Street',
        ),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: CreateRequestScreen(
          api: api,
          me: const {'country': 'BD', 'city': 'Dhaka'},
          bloodType: 'O+',
          radius: 10,
          donorIds: const ['donor'],
          locationService: service,
          refreshLocation: () async => {'country': 'BD', 'city': 'Dhaka'},
        ),
      ),
    );
    await tester.enterText(
      find.byType(TextField),
      'Community Hospital Main Street',
    );
    await tester.ensureVisible(find.byType(Checkbox));
    await tester.tap(find.byType(Checkbox));
    await tester.ensureVisible(find.text('Review & send request'));
    await tester.tap(find.text('Review & send request'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm the meeting place'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Edit place'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unaccepted requests never display photo or destination even if supplied',
    (tester) async {
      final api = RequestApi()
        ..item.addAll({
          'destination_name': 'Private point',
          'destination_latitude': 23.8,
          'destination_longitude': 90.4,
        });
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: RequestDetailScreen(
            api: api,
            me: const {'id': 'donor'},
            requestId: 'request-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(MeetingMap), findsNothing);
      expect(find.byType(PrivatePhoto), findsNothing);
      expect(find.text('Private point'), findsNothing);
      expect(api.photoReads, 0);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'accepted donor can withdraw and revoked state clears private photo',
    (tester) async {
      final api = RequestApi()
        ..item.addAll({
          'status': 'accepted',
          'accepted_donor_id': 'donor',
          'invitation_status': 'accepted',
        });
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: RequestDetailScreen(
            api: api,
            me: const {'id': 'donor'},
            requestId: 'request-1',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PrivatePhoto), findsOneWidget);
      expect(api.photoReads, 1);
      await tester.ensureVisible(find.text('Withdraw from this request'));
      await tester.tap(find.text('Withdraw from this request'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();
      expect(find.byType(PrivatePhoto), findsNothing);
      expect(find.text('Cancelled'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'tablet member shell uses a rail and keeps all five destinations',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final api = RequestApi();
      addTearDown(api.close);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(),
          home: MainScreen(api: api),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byType(NavigationBar), findsNothing);
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('Profile'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
