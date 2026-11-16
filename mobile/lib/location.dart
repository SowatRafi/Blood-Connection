// Location routing uses native services and explicit consent; the app never tracks in the background.
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geocoding/geocoding.dart' as geo;
import 'package:geolocator/geolocator.dart';
import 'api.dart';
import 'ui.dart';

/// Native latitude/longitude used for private routing and nearby searches.
typedef Coordinates = ({double latitude, double longitude});

/// A resolved country, area and coordinates, with an optional address preview.
///
/// Detailed addresses are requested only for meeting-place previews and are
/// excluded from routing payloads; coordinates still accompany the private API.
class ResolvedPlace {
  final String country, city;
  final String? address;
  final double latitude, longitude;
  const ResolvedPlace({
    required this.country,
    required this.city,
    required this.latitude,
    required this.longitude,
    this.address,
  });
  /// Builds the location update without including the optional address preview.
  Json payload(String mode) => {
    'country': country,
    'city': city,
    'latitude': latitude,
    'longitude': longitude,
    'mode': mode,
  };
}

/// Resolves locations through injectable native GPS and geocoding operations.
///
/// Injection allows travel and lookup failures to be tested without live GPS.
class LocationService {
  final Future<Coordinates> Function() coordinates;
  final Future<List<geo.Placemark>> Function(double, double) reverse;
  final Future<List<geo.Location>> Function(String) geocode;
  LocationService({
    Future<Coordinates> Function()? coordinates,
    Future<List<geo.Placemark>> Function(double, double)? reverse,
    Future<List<geo.Location>> Function(String)? geocode,
  }) : coordinates = coordinates ?? _deviceCoordinates,
       reverse =
           reverse ??
           ((lat, lng) => geo.Geocoding().placemarkFromCoordinates(lat, lng)),
       geocode =
           geocode ??
           ((address) => geo.Geocoding().locationFromAddress(address));

  // Ask only when permission is undecided/denied, and leave a manual route for
  // disabled services or permanent denial instead of starting background tracking.
  static Future<Coordinates> _deviceCoordinates() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw const ApiException(
        'Location services are off. Turn them on or choose your area manually.',
      );
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      throw const ApiException(
        'Location permission is off. Allow it in your phone settings, or choose your area manually.',
      );
    }
    final result = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.medium,
        timeLimit: Duration(seconds: 20),
      ),
    );
    return (latitude: result.latitude, longitude: result.longitude);
  }

  // A point is usable for country routing only when both an ISO code and area
  // label resolve; a coordinate alone must not silently choose a country.
  Future<ResolvedPlace> _resolve(
    Coordinates point, {
    bool includeAddress = false,
  }) async {
    final placemarks = await reverse(
      point.latitude,
      point.longitude,
    ).timeout(const Duration(seconds: 20));
    for (final placemark in placemarks) {
      final country = placemark.isoCountryCode?.trim().toUpperCase() ?? '';
      final areas = [
        placemark.locality,
        placemark.subAdministrativeArea,
        placemark.administrativeArea,
        placemark.subLocality,
      ];
      final city = areas
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .firstOrNull;
      if (RegExp(r'^[A-Z]{2}$').hasMatch(country) && city != null) {
        return ResolvedPlace(
          country: country,
          city: city,
          latitude: point.latitude,
          longitude: point.longitude,
          // Detailed native address stays out of routing payloads; only a requester choosing a meeting place asks for this preview.
          address: includeAddress
              ? [
                      placemark.name,
                      placemark.street,
                      city,
                      placemark.postalCode,
                      placemark.country,
                    ]
                    .whereType<String>()
                    .map((s) => s.trim())
                    .where((s) => s.isNotEmpty)
                    .toSet()
                    .join(', ')
              : null,
        );
      }
    }
    throw const ApiException(
      'Your country and area could not be identified. Try again or choose an area manually.',
    );
  }

  /// Resolves a one-time device position before discovery location can change.
  Future<ResolvedPlace> automatic() async {
    try {
      return await _resolve(await coordinates());
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Your location could not be updated. Retry or choose your area manually.',
      );
    }
  }

  /// Accepts a geocoded area only when its resolved country matches the selection.
  Future<ResolvedPlace> manual({
    required String country,
    required String countryName,
    required String area,
    bool includeAddress = false,
  }) async {
    try {
      final points = await geocode(
        '${area.trim()}, $countryName',
      ).timeout(const Duration(seconds: 20));
      for (final point in points.take(3)) {
        final place = await _resolve((
          latitude: point.latitude,
          longitude: point.longitude,
        ), includeAddress: includeAddress);
        if (place.country == country) return place;
      }
      throw const ApiException(
        'We could not verify that area in the selected country. Try a more specific city or suburb.',
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Area lookup is unavailable. Check your connection and try again.',
      );
    }
  }
}

/// Coalesces foreground location refreshes and briefly caches successful updates.
///
/// Failures clear the five-minute cache so a retry cannot accept an older success.
class LocationCoordinator {
  final Api api;
  final LocationService service;
  final DateTime Function() now;
  DateTime? lastSuccess;
  Future<Json>? _pending;
  LocationCoordinator(
    this.api, {
    LocationService? service,
    DateTime Function()? now,
  }) : service = service ?? LocationService(),
       now = now ?? DateTime.now;
  /// Preserves manual locations and shares an in-flight automatic refresh.
  ///
  /// [force] bypasses the success cache, but still joins an existing request.
  Future<Json> refresh(Json profile, {bool force = false}) {
    if (profile['location_mode'] != 'automatic') return Future.value(profile);
    if (!force &&
        lastSuccess != null &&
        now().difference(lastSuccess!) < const Duration(minutes: 5)) {
      return Future.value(profile);
    }
    return _pending ??= _update().whenComplete(() => _pending = null);
  }

  // The old country header routes the move; only the acknowledged destination
  // becomes the shared API country used by subsequent requests.
  Future<Json> _update() async {
    try {
      final place = await service.automatic();
      final result = await api.request(
        '/location',
        method: 'POST',
        body: place.payload('automatic'),
      );
      api.country = result['country'].toString();
      lastSuccess = now();
      return result;
    } catch (_) {
      lastSuccess = null;
      rethrow;
    }
  }
}

/// Remembers app-level consent per account on this device, separate from OS GPS permission.
class LocationConsent {
  static const _storage = FlutterSecureStorage();
  /// Checks whether this account agreed to automatic foreground updates here.
  static Future<bool> allowed(String id) async =>
      await _storage.read(key: 'automatic_location_$id') == 'yes';
  /// Records consent only after an automatic location has been saved.
  static Future<void> remember(String id) =>
      _storage.write(key: 'automatic_location_$id', value: 'yes');
}

/// Collects automatic-location consent or a verified manual area before saving.
class LocationScreen extends StatefulWidget {
  final Api api;
  final Json? current;
  const LocationScreen({super.key, required this.api, this.current});
  @override
  State<LocationScreen> createState() => _LocationScreenState();
}

class _LocationScreenState extends State<LocationScreen> {
  final service = LocationService();
  final area = TextEditingController();
  List<Json> countries = [];
  String? country, error;
  bool manual = false, busy = false, committing = false;
  @override
  void initState() {
    super.initState();
    manual = widget.current?['location_mode'] == 'manual' && !widget.api.demo;
    loadCountries();
  }

  @override
  void dispose() {
    area.dispose();
    super.dispose();
  }

  // Use backend-supported country codes rather than maintaining a second list.
  Future<void> loadCountries() async {
    try {
      final result = await widget.api.list('/countries');
      if (mounted) setState(() => countries = result);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  // Save routing first, then remember consent. Existing accounts retain their
  // original country header until the server acknowledges the regional move.
  Future<void> save(bool automatic) async {
    if (!automatic && (country == null || area.text.trim().isEmpty)) {
      setState(() => error = 'Choose a country and enter a city or suburb.');
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    final previousCountry = widget.api.country;
    var committed = false;
    try {
      final place = automatic
          ? await service.automatic()
          : await service.manual(
              country: country!,
              countryName: countries
                  .firstWhere((c) => c['code'] == country)['name']
                  .toString(),
              area: area.text,
            );
      if (!mounted) return;
      if (!automatic && mounted) {
        final accepted = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Use this area?'),
            content: Text(
              '${place.city}, ${place.country}\n\nYour location stays here until you change it or enable automatic location.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Try another area'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Use this area'),
              ),
            ],
          ),
        );
        if (accepted != true || !mounted) return;
      }
      // New users have no regional profile; the resolved destination safely bootstraps their first one.
      if (widget.current == null) widget.api.country = place.country;
      // PopScope blocks leaving during the mutation so its result can update the
      // parent's profile and the shared API country together.
      setState(() => committing = true);
      final result = await widget.api.request(
        '/location',
        method: 'POST',
        body: place.payload(automatic ? 'automatic' : 'manual'),
      );
      widget.api.country = result['country'].toString();
      committed = true;
      if (automatic) {
        try {
          await LocationConsent.remember(result['id'].toString());
        } catch (_) {
          if (mounted) {
            feedback(
              context,
              'Location saved. Your phone could not remember automatic-location consent; you may be asked again.',
            );
          }
        }
      }
      if (mounted) Navigator.pop(context, result);
    } catch (e) {
      if (!committed) widget.api.country = previousCountry;
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) {
        setState(() {
          busy = false;
          committing = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !committing,
    child: Scaffold(
      appBar: AppBar(title: const Text('Your location')),
      body: SafeArea(
        child: PageBody(
          children: [
            Text(
              'Nearby, wherever life takes you.',
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 16),
            const Notice(
              'Automatic location detects your country and area when you open the app or search. When you travel, your donor profile moves to that country’s database. Donation pauses and safety restrictions stay with you. No background tracking or precise public location.',
            ),
            const SizedBox(height: 24),
            if (widget.api.demo) ...[
              const Text(
                'This changes the fictional demo account to your real area. Sample donors may no longer appear nearby.',
              ),
              const SizedBox(height: 16),
            ],
            FilledButton.icon(
              onPressed: busy ? null : () => save(true),
              icon: const Icon(Icons.my_location),
              label: Text(
                busy ? 'Updating location…' : 'Agree & use automatic location',
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: busy ? null : () => setState(() => manual = !manual),
              child: Text(
                manual ? 'Hide manual options' : 'Choose an area manually',
              ),
            ),
            if (manual) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                isExpanded: true,
                initialValue: country,
                decoration: const InputDecoration(labelText: 'Country'),
                items: countries
                    .map(
                      (c) => DropdownMenuItem(
                        value: c['code'].toString(),
                        child: Text(
                          c['name'].toString(),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: busy
                    ? null
                    : (value) => setState(() => country = value),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: area,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'City or suburb',
                  hintText: 'For example, Sydney or Tangail',
                ),
                maxLength: 100,
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy || countries.isEmpty ? null : () => save(false),
                icon: const Icon(Icons.place_outlined),
                label: const Text('Find and confirm this area'),
              ),
            ],
            if (error != null) ...[
              const SizedBox(height: 20),
              Notice(
                error!,
                icon: Icons.info_outline,
                color: const Color(0xFFFBE9EC),
              ),
              if (countries.isEmpty)
                TextButton(
                  onPressed: loadCountries,
                  child: const Text('Retry country list'),
                ),
            ],
            const SizedBox(height: 24),
            const Text(
              'Your phone’s location permission is always under your control. If automatic location cannot update, we will ask you to retry or choose a location before searching.',
            ),
          ],
        ),
      ),
    ),
  );
}
