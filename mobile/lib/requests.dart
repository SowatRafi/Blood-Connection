// Donation requests make acceptance explicit before sharing a meeting point or private profile photo.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';
import 'ui.dart';
import 'location.dart';
import 'private_photo.dart';
import 'messaging.dart';
import 'reports.dart';

/// Build-time tile endpoint shared by the donor and accepted-meeting maps.
const mapTileUrl = String.fromEnvironment(
  'MAP_TILE_URL',
  defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
);
/// Attribution displayed with tiles; deployments must match it to their provider.
const mapAttribution = String.fromEnvironment(
  'MAP_ATTRIBUTION',
  defaultValue: '© OpenStreetMap contributors',
);

/// Offers navigation providers and explains that the chosen service receives the destination.
///
/// The sheet scrolls so large text does not hide options on a short phone screen.
Future<String?> chooseDirectionsApp(
  BuildContext context,
) => showModalBottomSheet<String>(
  context: context,
  builder: (ctx) => SafeArea(
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(20),
            child: Text(
              'Open directions in your map app. The meeting destination is shared with the chosen service.',
            ),
          ),
          for (final app in ['Google Maps', 'Apple Maps', 'Waze'])
            ListTile(
              title: Text(app),
              leading: const Icon(Icons.directions_outlined),
              onTap: () => Navigator.pop(ctx, app),
            ),
        ],
      ),
    ),
  ),
);

/// Lists requests and private event updates while the app is in the foreground.
class RequestsScreen extends StatefulWidget {
  final Api api;
  final Json me;
  final VoidCallback onFind;
  const RequestsScreen({
    super.key,
    required this.api,
    required this.me,
    required this.onFind,
  });
  @override
  State<RequestsScreen> createState() => _RequestsScreenState();
}

class _RequestsScreenState extends State<RequestsScreen>
    with WidgetsBindingObserver {
  List<Json>? requests;
  List<Json> events = [];
  Timer? timer;
  String? error;
  bool loading = false, active = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 8), (_) => load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) load();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Refresh both collections together so failure does not leave an apparently current inbox.
  Future<void> load() async {
    if (loading || !active) return;
    loading = true;
    try {
      final result = await Future.wait([
        widget.api.list('/requests'),
        widget.api.list('/events'),
      ]);
      if (mounted) {
        setState(() {
          requests = result[0];
          events = result[1];
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          requests = null;
          events = [];
        });
      }
    } finally {
      loading = false;
    }
  }

  Future<void> open(String id) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) =>
            RequestDetailScreen(api: widget.api, me: widget.me, requestId: id),
      ),
    );
    load();
  }

  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      Text(
        'A request. A connection.',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      const Text('See who needs help, and keep track of your requests.'),
      const SizedBox(height: 12),
      TextButton.icon(
        key: const Key('my-reports'),
        onPressed: () => Navigator.push<void>(
          context,
          MaterialPageRoute(builder: (_) => MyReportsScreen(api: widget.api)),
        ),
        icon: const Icon(Icons.fact_check_outlined),
        label: const Text('My reports'),
      ),
      const SizedBox(height: 24),
      if (events.any((event) => event['read'] != true)) ...[
        Text('Updates', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 12),
        for (final event in events.where((e) => e['read'] != true).take(5)) ...[
          Card(
            child: ListTile(
              contentPadding: const EdgeInsets.all(16),
              leading: const Icon(
                Icons.notifications_active_outlined,
                color: red,
              ),
              title: Text(event['title'].toString()),
              subtitle: Text(event['body'].toString()),
              onTap: () async {
                try {
                  await widget.api.request(
                    '/events/${event['id']}/read',
                    method: 'POST',
                    query: event['country'] is String
                        ? {'country': event['country']}
                        : null,
                  );
                  if (event['report_id'] != null &&
                      event['report_country'] != null &&
                      context.mounted) {
                    await Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => ReportDetailScreen(
                          api: widget.api,
                          reportId: event['report_id'].toString(),
                          reportCountry: event['report_country'].toString(),
                        ),
                      ),
                    );
                    if (mounted) await load();
                  } else if (event['request_id'] != null && mounted) {
                    await open(event['request_id'].toString());
                  } else {
                    load();
                  }
                } catch (e) {
                  if (context.mounted) feedback(context, e.toString());
                }
              },
            ),
          ),
          const SizedBox(height: 8),
        ],
        const SizedBox(height: 20),
      ],
      if (error != null) ErrorPanel(error!, load),
      if (requests == null && error == null)
        const Center(child: CircularProgressIndicator()),
      if (requests?.isEmpty ?? false) ...[
        const Notice(
          'No requests yet. Find nearby donors, choose who to invite, and share a hospital meeting point after someone accepts.',
          icon: Icons.volunteer_activism_outlined,
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: widget.onFind,
          icon: const Icon(Icons.search),
          label: const Text('Find donors'),
        ),
      ],
      for (final request in requests ?? <Json>[]) ...[
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  BloodBadge(displayBlood(request['blood_type'])),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          request['is_requester'] == true
                              ? 'Your blood request'
                              : '${request['requester_name']} needs a donor',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        Text(requestStatus(request)),
                        Text(
                          shortDate(request['created_at']),
                          style: const TextStyle(fontSize: 12, color: muted),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => open(request['id'].toString()),
                child: const Text('View request'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
      ],
    ],
  );
}

/// Describes coordination state from this participant's perspective, not clinical completion.
String requestStatus(Json request) => switch (request['status']) {
  'accepted' => 'Accepted · ready to coordinate',
  'completed' => 'Coordination completed',
  'cancelled' => 'Cancelled',
  'expired' => 'Expired',
  _ =>
    request['invitation_status'] == 'declined'
        ? 'You declined this invitation'
        : request['is_requester'] == true
        ? 'Waiting for a donor'
        : 'Your help is requested',
};

/// Turns selected nearby donors into an invitation with an explicitly confirmed meeting point.
class CreateRequestScreen extends StatefulWidget {
  final Api api;
  final Json me;
  final String bloodType;
  final double radius;
  final List<String> donorIds;
  final Future<Json> Function() refreshLocation;
  final LocationService? locationService;
  const CreateRequestScreen({
    super.key,
    required this.api,
    required this.me,
    required this.bloodType,
    required this.radius,
    required this.donorIds,
    required this.refreshLocation,
    this.locationService,
  });
  @override
  State<CreateRequestScreen> createState() => _CreateRequestScreenState();
}

class _CreateRequestScreenState extends State<CreateRequestScreen> {
  final destination = TextEditingController();
  bool consent = false, busy = false;
  String? error;
  @override
  void dispose() {
    destination.dispose();
    super.dispose();
  }

  // Refresh country before geocoding: a traveller's old profile must not determine the meeting region.
  Future<void> create() async {
    if (!consent || destination.text.trim().length < 3) {
      setState(
        () => error =
            'Enter a hospital or meeting place and agree to share it after acceptance.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final current = await widget.refreshLocation();
      final countries = await widget.api.list('/countries');
      final country = current['country'].toString();
      final countryName = countries
          .firstWhere((c) => c['code'] == country)['name']
          .toString();
      final place = await (widget.locationService ?? LocationService()).manual(
        country: country,
        countryName: countryName,
        area: '${destination.text.trim()}, ${current['city']}',
        includeAddress: true,
      );
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          scrollable: true,
          title: const Text('Confirm the meeting place'),
          content: Text(
            '${destination.text.trim()}\n${place.address ?? '${place.city}, ${place.country}'}\n\nThis point will be shared only after a donor accepts. Check the resolved address carefully.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Edit place'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Send request'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final result = await widget.api.request(
        '/requests',
        method: 'POST',
        body: {
          'blood_type': wireBlood(widget.bloodType),
          'radius_km': widget.radius.round(),
          'destination_name': destination.text.trim(),
          'destination_latitude': place.latitude,
          'destination_longitude': place.longitude,
          'donor_ids': widget.donorIds,
        },
      );
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute<void>(
            builder: (_) => RequestDetailScreen(
              api: widget.api,
              me: current,
              requestId: result['id'].toString(),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Request a donation')),
    body: SafeArea(
      child: PageBody(
        children: [
          Text(
            'Ask for a helping hand.',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 20),
          Panel(
            child: Row(
              children: [
                BloodBadge(displayBlood(widget.bloodType)),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    '${widget.donorIds.length} nearby donor${widget.donorIds.length == 1 ? '' : 's'} will receive your request.',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          const Notice(
            'Choose a hospital or agreed public meeting place. Never enter a donor’s home address. Photos and destination details remain private until a donor accepts.',
          ),
          const SizedBox(height: 20),
          TextField(
            controller: destination,
            maxLength: 160,
            textCapitalization: TextCapitalization.words,
            decoration: const InputDecoration(
              labelText: 'Hospital or meeting place',
              hintText: 'Name and street address',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            value: consent,
            onChanged: busy
                ? null
                : (value) => setState(() => consent = value!),
            title: const Text(
              'Share this meeting point and my optional profile photo with the donor who accepts.',
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 16),
            Text(error!, style: const TextStyle(color: red)),
          ],
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: busy ? null : create,
            icon: const Icon(Icons.send_outlined),
            label: Text(
              busy ? 'Finding the meeting place…' : 'Review & send request',
            ),
          ),
        ],
      ),
    ),
  );
}

/// Presents server-authorized request details and confirmed coordination transitions.
///
/// Acceptance controls access to private photos and the meeting point; completing
/// coordination only schedules donation confirmation, not a donation record.
class RequestDetailScreen extends StatefulWidget {
  final Api api;
  final Json me;
  final String requestId;
  const RequestDetailScreen({
    super.key,
    required this.api,
    required this.me,
    required this.requestId,
  });
  @override
  State<RequestDetailScreen> createState() => _RequestDetailScreenState();
}

class _RequestDetailScreenState extends State<RequestDetailScreen>
    with WidgetsBindingObserver {
  Json? request;
  String? error;
  Timer? timer;
  bool loading = false, acting = false, active = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 6), (_) => load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) load();
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Do not start polling during a mutation, and clear details if access can no longer be verified.
  Future<void> load() async {
    if (loading || acting || !active) return;
    loading = true;
    try {
      final result = await widget.api.request('/requests/${widget.requestId}');
      if (mounted) {
        setState(() {
          request = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          request = null;
          error = e.toString();
        });
      }
    } finally {
      loading = false;
    }
  }

  // Explain each sharing consequence before submission; the server arbitrates competing acceptances.
  Future<void> act(String action) async {
    final text = switch (action) {
      'accept' =>
        'Accepting shares your optional photo with the requester and reveals the agreed meeting place. Confirm clinical eligibility with the hospital.',
      'complete' =>
        'Mark coordination complete? Both matched participants will be asked whether a donation happened. Either can confirm it; the donation record and recovery pause belong to the donor.',
      'cancel' =>
        'Cancel this request? Access to shared photos and the meeting point will close.',
      _ => 'Decline this invitation?',
    };
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        scrollable: true,
        title: Text(
          '${action[0].toUpperCase()}${action.substring(1)} request?',
        ),
        content: Text(text),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Back'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() {
      acting = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        '/requests/${widget.requestId}/$action',
        method: 'POST',
        body: {},
      );
      if (mounted) {
        setState(() => request = result);
        // Returning to the root requests list lets its foreground prompt coordinator
        // ask the donor without stacking a second dialog over this detail screen.
        if (action == 'complete') Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => acting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = request;
    final accepted = item?['status'] == 'accepted';
    final summary = item?['donation_summary'];
    return Scaffold(
      appBar: AppBar(title: const Text('Donation request')),
      body: SafeArea(
        child: PageBody(
          children: [
            if (error != null) ...[
              ErrorPanel(error!, load),
              const SizedBox(height: 16),
            ],
            if (item == null && error == null)
              const Center(child: CircularProgressIndicator()),
            if (item != null) ...[
              Row(
                children: [
                  BloodBadge(displayBlood(item['blood_type'])),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item['is_requester'] == true
                              ? 'Your request'
                              : '${item['requester_name']} needs blood',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(requestStatus(item)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              if (item['donation_recorded'] == true && summary is Map) ...[
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Donation confirmed',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      Text(shortDate(summary['donated_at'])),
                      Text(summary['facility_name']?.toString() ?? ''),
                      Text(
                        '${summary['location_name'] ?? ''} · ${summary['country'] ?? ''}',
                      ),
                      const SizedBox(height: 8),
                      Text(
                        summary['confirmed_by_role'] == 'seeker'
                            ? 'Confirmed by the seeker. The donor’s recovery pause has been updated.'
                            : 'Confirmed by the donor. The donor’s recovery pause has been updated.',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
              ],
              if (item['can_report'] == true) ...[
                OutlinedButton.icon(
                  key: const Key('report-match'),
                  onPressed: () => showReport(
                    context,
                    widget.api,
                    requestId: widget.requestId,
                    peerName: item['peer_name']?.toString(),
                  ),
                  icon: const Icon(Icons.flag_outlined),
                  label: const Text('Report this match'),
                ),
                const SizedBox(height: 20),
              ],
              if (accepted && item['peer_id'] != null) ...[
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (item['peer_has_photo'] == true)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: PrivatePhoto(
                            key: ValueKey(item['peer_id']),
                            api: widget.api,
                            userId: item['peer_id'].toString(),
                          ),
                        ),
                      const SizedBox(height: 12),
                      Text(
                        item['peer_name'].toString(),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'You are connected. Coordinate here without sharing your phone number.',
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: item['conversation_id'] == null
                            ? null
                            : () => Navigator.push(
                                context,
                                MaterialPageRoute<void>(
                                  builder: (_) => ChatScreen(
                                    api: widget.api,
                                    me: widget.me,
                                    conversation: {
                                      'id': item['conversation_id'],
                                      'peer_id': item['peer_id'],
                                      'peer_name': item['peer_name'],
                                      'blood_type': item['blood_type'],
                                    },
                                  ),
                                ),
                              ),
                        icon: const Icon(Icons.chat_bubble_outline),
                        label: const Text('Message or call'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
              ],
              if (accepted &&
                  item['destination_latitude'] != null &&
                  item['destination_longitude'] != null)
                MeetingMap(request: item, me: widget.me),
              if (!accepted)
                const Notice(
                  'The meeting point and partner’s photo are shared only after acceptance. You can always decline a request.',
                ),
              const SizedBox(height: 24),
              if (item['is_requester'] != true &&
                  item['status'] == 'open' &&
                  item['invitation_status'] == 'invited') ...[
                FilledButton.icon(
                  onPressed: acting ? null : () => act('accept'),
                  icon: const Icon(Icons.volunteer_activism_outlined),
                  label: const Text('I can help · accept request'),
                ),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: acting ? null : () => act('decline'),
                  child: const Text('Decline'),
                ),
              ],
              if ((item['is_requester'] == true &&
                      ['open', 'accepted'].contains(item['status'])) ||
                  (accepted &&
                      item['accepted_donor_id'] == widget.me['id'])) ...[
                if (accepted) ...[
                  FilledButton(
                    onPressed: acting ? null : () => act('complete'),
                    child: const Text('Mark coordination complete'),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton(
                  onPressed: acting ? null : () => act('cancel'),
                  child: Text(
                    item['is_requester'] == true
                        ? 'Cancel request'
                        : 'Withdraw from this request',
                  ),
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// Maps only an accepted match's shared meeting point, never the other member's exact position.
///
/// The displayed distance is straight-line from the caller's saved location;
/// the external navigation provider calculates its own route after consent.
class MeetingMap extends StatefulWidget {
  final Json request, me;
  final TileProvider? tileProvider;
  const MeetingMap({
    super.key,
    required this.request,
    required this.me,
    this.tileProvider,
  });
  @override
  State<MeetingMap> createState() => _MeetingMapState();
}

class _MeetingMapState extends State<MeetingMap> {
  final controller = MapController();
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  // Fixed provider URLs carry only the meeting coordinates, without app credentials or member IDs.
  Future<void> go() async {
    final choice = await chooseDirectionsApp(context);
    if (choice == null) return;
    final point =
        '${widget.request['destination_latitude']},${widget.request['destination_longitude']}';
    final uri = switch (choice) {
      'Apple Maps' => Uri.https('maps.apple.com', '/', {
        'daddr': point,
        'dirflg': 'd',
      }),
      'Waze' => Uri.https('waze.com', '/ul', {'ll': point, 'navigate': 'yes'}),
      _ => Uri.https('www.google.com', '/maps/dir/', {
        'api': '1',
        'destination': point,
        'travelmode': 'driving',
      }),
    };
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
        throw const ApiException('No map application could be opened.');
      }
    } catch (_) {
      if (mounted) {
        feedback(
          context,
          'Could not open directions. Please try another map application.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final latitude = (widget.request['destination_latitude'] as num).toDouble();
    final longitude = (widget.request['destination_longitude'] as num)
        .toDouble();
    final point = LatLng(latitude, longitude);
    final ownLatitude = widget.me['latitude'] as num?;
    final ownLongitude = widget.me['longitude'] as num?;
    final distance = ownLatitude != null && ownLongitude != null
        ? Geolocator.distanceBetween(
                ownLatitude.toDouble(),
                ownLongitude.toDouble(),
                latitude,
                longitude,
              ) /
              1000
        : null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Meet here', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        Text(widget.request['destination_name'].toString()),
        if (distance != null)
          Text(
            '${distance.toStringAsFixed(1)} km straight-line from your saved location · road distance will differ.',
          ),
        const SizedBox(height: 16),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: SizedBox(
            height: 300,
            child: FlutterMap(
              mapController: controller,
              options: MapOptions(
                initialCenter: point,
                initialZoom: 14,
                maxZoom: 18,
                interactionOptions: const InteractionOptions(
                  // This is a single meeting-point preview: one-finger swipes belong to the surrounding page.
                  flags:
                      InteractiveFlag.pinchZoom | InteractiveFlag.doubleTapZoom,
                ),
              ),
              children: [
                TileLayer(
                  tileProvider: widget.tileProvider,
                  urlTemplate: mapTileUrl,
                  userAgentPackageName: 'org.bindubashini.bloodconnection',
                ),
                MarkerLayer(
                  markers: [
                    Marker(
                      point: point,
                      width: 48,
                      height: 48,
                      child: Semantics(
                        label: 'Shared meeting point',
                        child: Icon(Icons.location_on, color: red, size: 44),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        // Credit remains adjacent to the map and can wrap with large text instead of clipping an overlay.
        TextButton(
          onPressed: () => launchUrl(
            Uri.https('www.openstreetmap.org', '/copyright'),
            mode: LaunchMode.externalApplication,
          ),
          style: TextButton.styleFrom(
            alignment: Alignment.centerLeft,
            textStyle: const TextStyle(fontSize: 12, height: 1.4),
          ),
          child: const Text(mapAttribution, softWrap: true),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            IconButton(
              tooltip: 'Zoom in',
              onPressed: () => controller.move(
                controller.camera.center,
                (controller.camera.zoom + 1).clamp(1, 18),
              ),
              icon: const Icon(Icons.add),
            ),
            IconButton(
              tooltip: 'Zoom out',
              onPressed: () => controller.move(
                controller.camera.center,
                (controller.camera.zoom - 1).clamp(1, 18),
              ),
              icon: const Icon(Icons.remove),
            ),
            TextButton.icon(
              onPressed: () => controller.move(point, 14),
              icon: const Icon(Icons.center_focus_strong),
              label: const Text('Show meeting point'),
            ),
          ],
        ),
        const Text(
          'Map tiles are loaded from the configured map provider. Only the agreed destination is marked.',
          style: TextStyle(fontSize: 12, color: muted),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: go,
          icon: const Icon(Icons.directions),
          label: const Text('Go · open directions'),
        ),
      ],
    );
  }
}
