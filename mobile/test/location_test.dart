// Mock only native location boundaries; exercise real country routing, manual verification and stale-data rejection.
import 'package:flutter_test/flutter_test.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:blood_connection/api.dart';
import 'package:blood_connection/location.dart';

class RecordingApi extends Api {
  final List<Json> updates = [];
  bool reject = false;
  @override
  Future<Json> request(
    String path, {
    String method = 'GET',
    Json? body,
    Map<String, String>? query,
  }) async {
    expect(path, '/location');
    expect(method, 'POST');
    if (reject) {
      throw const ApiException('Country is not enabled', statusCode: 400);
    }
    updates.add(body!);
    return {
      'id': 'test',
      ...body,
      'location_mode': body['mode'],
      'eligible_after': '2027-02-28',
      'available': false,
    };
  }
}

void main() {
  test(
    'automatic travel resolves country and area without sharing street labels',
    () async {
      final api = RecordingApi()..country = 'BD';
      addTearDown(api.close);
      final service = LocationService(
        coordinates: () async => (latitude: -33.86, longitude: 151.20),
        reverse: (_, _) async => [
          const geo.Placemark(
            isoCountryCode: 'au',
            locality: 'Sydney',
            street: 'Private street',
            name: 'Private building',
          ),
        ],
      );
      final coordinator = LocationCoordinator(api, service: service);
      final profile = await coordinator.refresh({
        'location_mode': 'automatic',
        'country': 'BD',
      });
      expect(api.country, 'AU');
      expect(profile['city'], 'Sydney');
      expect(profile['eligible_after'], '2027-02-28');
      expect(profile['available'], isFalse);
      expect(
        api.updates.single.keys,
        unorderedEquals(['country', 'city', 'latitude', 'longitude', 'mode']),
      );
      expect(api.updates.single.values, isNot(contains('Private street')));
    },
  );

  test(
    'manual override does not read GPS or move on automatic refresh',
    () async {
      final api = RecordingApi();
      addTearDown(api.close);
      final service = LocationService(
        coordinates: () async => throw StateError('GPS must not run'),
      );
      final current = {'country': 'BD', 'location_mode': 'manual'};
      expect(
        await LocationCoordinator(
          api,
          service: service,
        ).refresh(current, force: true),
        same(current),
      );
      expect(api.updates, isEmpty);
    },
  );

  test(
    'manual area geocoding rejects a country mismatch instead of reusing old coordinates',
    () async {
      String? query;
      final service = LocationService(
        geocode: (address) async {
          query = address;
          return [geo.Location(latitude: 23.8, longitude: 90.4)];
        },
        reverse: (_, _) async => [
          const geo.Placemark(isoCountryCode: 'BD', locality: 'Dhaka'),
        ],
      );
      await expectLater(
        service.manual(country: 'AU', countryName: 'Australia', area: 'Sydney'),
        throwsA(isA<ApiException>()),
      );
      expect(query, 'Sydney, Australia');
    },
  );

  test(
    'failed travel update rejects stale search and does not change the active country',
    () async {
      final api = RecordingApi()
        ..country = 'BD'
        ..reject = true;
      addTearDown(api.close);
      var reads = 0;
      final service = LocationService(
        coordinates: () async {
          reads++;
          return (latitude: -33.86, longitude: 151.20);
        },
        reverse: (_, _) async => [
          const geo.Placemark(isoCountryCode: 'AU', locality: 'Sydney'),
        ],
      );
      final coordinator = LocationCoordinator(api, service: service);
      final current = {'country': 'BD', 'location_mode': 'automatic'};
      await expectLater(
        coordinator.refresh(current),
        throwsA(isA<ApiException>()),
      );
      expect(api.country, 'BD');
      expect(coordinator.lastSuccess, isNull);
      api.reject = false;
      expect((await coordinator.refresh(current))['country'], 'AU');
      expect(reads, 2);
    },
  );

  test(
    'foreground refresh is throttled for five minutes and then detects travel',
    () async {
      final api = RecordingApi();
      addTearDown(api.close);
      var clock = DateTime.utc(2026, 11, 15);
      var reads = 0;
      final service = LocationService(
        coordinates: () async {
          reads++;
          return (latitude: 23.8, longitude: 90.4);
        },
        reverse: (_, _) async => [
          const geo.Placemark(
            isoCountryCode: 'BD',
            subAdministrativeArea: 'Tangail',
          ),
        ],
      );
      final coordinator = LocationCoordinator(
        api,
        service: service,
        now: () => clock,
      );
      var current = await coordinator.refresh({'location_mode': 'automatic'});
      current = await coordinator.refresh(current);
      expect(reads, 1);
      clock = clock.add(const Duration(minutes: 5));
      await coordinator.refresh(current);
      expect(reads, 2);
      expect(current['city'], 'Tangail');
    },
  );
}
