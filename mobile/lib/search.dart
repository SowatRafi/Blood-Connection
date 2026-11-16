// Map discovery displays only server-supplied approximate areas, never reconstructed donor locations.
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
import 'api.dart';
import 'ui.dart';
import 'requests.dart';
import 'messaging.dart';

/// Groups returned donors under the backend's coarse area identifier and center.
///
/// The center describes the shared area; it is not a donor or meeting location.
class DonorArea {
  final String id;
  final LatLng center;
  final List<Json> donors;
  DonorArea(this.id, this.center, this.donors);
}

/// Groups valid server areas without deriving a point from individual donors.
///
/// Invalid or missing areas remain eligible for the list, but produce no marker.
List<DonorArea> groupDonorAreas(List<Json> donors) {
  final areas = <String, DonorArea>{};
  for (final donor in donors) {
    final area = donor['map_area'];
    if (area is! Map) continue;
    final id = area['id'];
    final latitude = area['latitude'];
    final longitude = area['longitude'];
    if (id is! String ||
        id.isEmpty ||
        latitude is! num ||
        longitude is! num ||
        !latitude.isFinite ||
        !longitude.isFinite ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      continue;
    }
    final center = LatLng(latitude.toDouble(), longitude.toDouble());
    (areas[id] ??= DonorArea(id, center, [])).donors.add(donor);
  }
  return areas.values.toList();
}

/// Shows exact blood-group results as coarse map areas and accessible donor cards.
///
/// Searches use the refreshed profile location. Panning explores those results
/// without silently replacing the saved search origin or expanding its radius.
class SearchScreen extends StatefulWidget {
  final Api api;
  final Json me;
  final VoidCallback onProfile;
  final Future<Json> Function() refreshLocation;
  final TileProvider? tileProvider;
  const SearchScreen({
    super.key,
    required this.api,
    required this.me,
    required this.onProfile,
    required this.refreshLocation,
    this.tileProvider,
  });
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen>
    with SingleTickerProviderStateMixin {
  final map = MapController();
  final sheet = DraggableScrollableController();
  final filterBounds = GlobalKey();
  ScrollController? donorScroll;
  double collapsedExtent = .14, initialExtent = .25;
  static const expandedExtent = .80;
  String group = 'O+';
  double radius = 10;
  List<Json>? donors;
  String? selectedArea, opening, error;
  bool busy = false, mapReady = false, tileError = false;
  // Separate revisions prevent unrelated resets: queries discard stale results,
  // tile retries recreate only the tile layer, and gestures cancel auto-framing.
  int generation = 0, tileRevision = 0, cameraInteractions = 0;
  late final AnimationController cameraMotion;
  VoidCallback? cameraTick;

  @override
  void initState() {
    super.initState();
    cameraMotion = AnimationController(vsync: this, duration: motionTravel);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) search();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A preference change applies to an in-flight camera action too; gesture
    // cancellations remain stopped at the user's chosen position.
    if (MediaQuery.disableAnimationsOf(context)) {
      if (cameraMotion.isAnimating) cameraMotion.value = 1;
      // Stop a sheet animation or fling at its current visible extent rather
      // than replaying an old target after a person has dragged the sheet.
      if (sheet.isAttached) sheet.jumpTo(sheet.size);
    }
  }

  @override
  void dispose() {
    generation++;
    cameraMotion.dispose();
    map.dispose();
    sheet.dispose();
    super.dispose();
  }

  // Country is part of identity even if coordinates are unchanged at a border.
  String locationKey(Json profile) =>
      '${profile['country']}:${profile['latitude']}:${profile['longitude']}';
  @override
  void didUpdateWidget(SearchScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (locationKey(oldWidget.me) != locationKey(widget.me)) {
      donors = null;
      selectedArea = null;
      // A location refresh initiated by search is already in flight; its returned coordinates are checked below.
      if (!busy) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) search();
        });
      }
    }
  }

  // Each filter snapshot owns its response: slower old searches cannot repaint a newly selected blood group.
  Future<void> search() async {
    resetDonorScroll();
    final request = ++generation;
    final requestedGroup = group;
    final requestedRadius = radius.round();
    final interactionsAtStart = cameraInteractions;
    setState(() {
      busy = true;
      error = null;
      donors = null;
      selectedArea = null;
    });
    try {
      final current = await widget.refreshLocation();
      if (!mounted || request != generation) return;
      final result = await widget.api.list(
        '/donors',
        query: {
          'blood_type': wireBlood(requestedGroup),
          'radius_km': '$requestedRadius',
          'latitude': '${current['latitude']}',
          'longitude': '${current['longitude']}',
        },
      );
      if (!mounted || request != generation) return;
      if (locationKey(current) != locationKey(widget.me)) {
        throw const ApiException(
          'Your area changed during the search. Refresh to see donors near your current location.',
        );
      }
      setState(() => donors = result);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // A late result must not recenter after the person has started exploring.
        if (interactionsAtStart == cameraInteractions) frameAreas();
      });
    } catch (e) {
      if (mounted && request == generation) {
        setState(() => error = e.toString());
      }
    } finally {
      if (mounted && request == generation) setState(() => busy = false);
    }
  }

  // Web Mercator cannot draw the poles; projection clipping does not alter the server's coarse-area data.
  LatLng projected(LatLng point) =>
      LatLng(point.latitude.clamp(-85.05, 85.05), point.longitude);
  LatLng get searchCenter => projected(
    LatLng(
      (widget.me['latitude'] as num?)?.toDouble() ?? 0,
      (widget.me['longitude'] as num?)?.toDouble() ?? 0,
    ),
  );
  // Fit both the requested radius and returned coarse areas, allowing controls
  // and the initial sheet to occupy space without hiding the useful map center.
  void frameAreas({bool animate = false}) {
    if (!mounted || !mapReady) return;
    // Frame the requested radius around the search origin. Unwrapping longitude keeps
    // nearby areas across the date line together instead of zooming out to the world.
    final center = searchCenter;
    LatLng nearby(LatLng point) {
      final longitude =
          center.longitude +
          ((point.longitude - center.longitude + 180) % 360) -
          180;
      return LatLng(projected(point).latitude, longitude);
    }

    final distance = const Distance();
    final points = <LatLng>[
      center,
      for (final bearing in [0.0, 90.0, 180.0, 270.0])
        nearby(distance.offset(center, radius * 1000, bearing)),
      for (final area in groupDonorAreas(donors ?? [])) nearby(area.center),
    ];
    // Fit into the unobscured map at its initial sheet position. Reframing is
    // deliberately not tied to sheet movement, so dragging never moves the map.
    final height = map.camera.nonRotatedSize.height;
    final headerBox =
        filterBounds.currentContext?.findRenderObject() as RenderBox?;
    final top =
        ((headerBox?.hasSize == true ? headerBox!.size.height : 140) +
                MediaQuery.paddingOf(context).top +
                24)
            .clamp(24.0, height * .4);
    final bottom = (height * initialExtent + 60).clamp(24.0, height * .4);
    final target = CameraFit.coordinates(
      coordinates: points,
      padding: EdgeInsets.fromLTRB(40, top, 40, bottom),
      maxZoom: 13,
      minZoom: 2,
    ).fit(map.camera);
    if (animate) {
      moveCamera(target.center, target.zoom);
    } else {
      cameraMotion.stop();
      map.move(target.center, target.zoom);
    }
  }

  // One short native tween connects explicit camera actions. A new action replaces
  // the old one, and date-line interpolation takes the nearby route around Earth.
  void moveCamera(LatLng center, double zoom) {
    cameraInteractions++;
    cameraMotion.stop();
    if (cameraTick != null) cameraMotion.removeListener(cameraTick!);
    if (MediaQuery.disableAnimationsOf(context)) {
      map.move(center, zoom);
      return;
    }
    final start = map.camera;
    final longitudeDelta =
        (center.longitude - start.center.longitude + 180) % 360 - 180;
    cameraTick = () {
      final t = Curves.easeOutCubic.transform(cameraMotion.value);
      map.move(
        LatLng(
          start.center.latitude + (center.latitude - start.center.latitude) * t,
          start.center.longitude + longitudeDelta * t,
        ),
        start.zoom + (zoom - start.zoom) * t,
      );
    };
    cameraMotion.addListener(cameraTick!);
    cameraMotion.forward(from: 0);
  }

  // Slider edits stay local to the sheet; only Apply triggers another API query.
  Future<void> changeRadius() async {
    var draft = radius;
    final value = await showModalBottomSheet<double>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'How far should we look?',
                  style: Theme.of(ctx).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  '${draft.round()} km around your area',
                  style: Theme.of(ctx).textTheme.titleMedium,
                ),
                Slider(
                  value: draft,
                  min: 1,
                  max: 39,
                  divisions: 38,
                  label: '${draft.round()} km',
                  semanticFormatterCallback: (value) =>
                      '${value.round()} kilometres',
                  onChanged: (value) => update(() => draft = value),
                ),
                const Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [Text('1 km'), Text('39 km maximum')],
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, draft),
                  child: const Text('Apply radius'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    if (value != null && mounted) {
      setState(() => radius = value);
      await search();
    }
  }

  // Carry the current filter and a bounded recipient snapshot into the form.
  // That screen rechecks location before submitting the actual request.
  Future<void> requestDonation(List<Json> selected) async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => CreateRequestScreen(
          api: widget.api,
          me: widget.me,
          bloodType: group,
          radius: radius,
          donorIds: selected.map((d) => d['id'].toString()).take(50).toList(),
          refreshLocation: widget.refreshLocation,
        ),
      ),
    );
  }

  // Ask the server to create or return an authorized conversation; a search card
  // does not itself grant access to messages, private photos or call credentials.
  Future<void> contact(Json donor) async {
    setState(() => opening = donor['id'].toString());
    try {
      final conversation = await widget.api.request(
        '/conversations',
        method: 'POST',
        body: {'donor_id': donor['id']},
      );
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => ChatScreen(
              api: widget.api,
              me: widget.me,
              conversation: conversation,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) feedback(context, e.toString());
    } finally {
      if (mounted) setState(() => opening = null);
    }
  }

  // The sheet's scroll controller belongs to Flutter; resetting it keeps changed filters
  // and newly selected areas from opening halfway through an unrelated donor list.
  void resetDonorScroll() {
    if (donorScroll?.hasClients ?? false) donorScroll!.jumpTo(0);
  }

  // Explicit controls provide the same action as dragging for keyboard and screen-reader users.
  void showDonors({bool expanded = true}) {
    if (!sheet.isAttached) return;
    if (!expanded) resetDonorScroll();
    final extent = expanded ? expandedExtent : collapsedExtent;
    if (MediaQuery.disableAnimationsOf(context)) {
      sheet.jumpTo(extent);
      return;
    }
    sheet.animateTo(extent, duration: motionTravel, curve: Curves.easeOutCubic);
  }

  // Selecting an area reveals its real donor cards without re-querying from the map's camera position.
  void selectArea(String? area) {
    resetDonorScroll();
    setState(() => selectedArea = area);
    showDonors();
  }

  // A horizontal row keeps all eight choices available without consuming the map on small screens.
  Widget filters() => Material(
    key: const Key('search-filters'),
    color: Colors.white,
    elevation: 4,
    shadowColor: Colors.black.withValues(alpha: .12),
    borderRadius: BorderRadius.circular(22),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: widget.onProfile,
                  icon: const Icon(Icons.my_location, size: 18),
                  label: Text(
                    '${widget.api.demo ? 'DEMO · ' : ''}Near ${widget.me['city'] ?? 'your area'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: TextButton.styleFrom(
                    alignment: Alignment.centerLeft,
                    minimumSize: const Size(48, 48),
                  ),
                ),
              ),
              OutlinedButton.icon(
                key: const Key('search-radius'),
                onPressed: changeRadius,
                icon: const Icon(Icons.tune, size: 18),
                label: Text('${radius.round()} km'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final value in [
                  'O+',
                  ...bloodGroups.where((value) => value != 'O+'),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      key: ValueKey('blood-group-$value'),
                      tooltip: 'Search for $value donors',
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      label: Text(
                        value,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: group == value ? Colors.white : ink,
                        ),
                      ),
                      selectedColor: red,
                      backgroundColor: Colors.white,
                      side: BorderSide(
                        color: group == value ? red : const Color(0xFFE2E6E9),
                      ),
                      selected: group == value,
                      showCheckmark: false,
                      visualDensity: VisualDensity.standard,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 9,
                      ),
                      onSelected: (_) {
                        if (value != group) {
                          setState(() => group = value);
                          search();
                        }
                      },
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  // Every map gesture changes only the camera. The API always receives saved, consented coordinates.
  Widget donorMap() {
    final areas = groupDonorAreas(donors ?? []);
    final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
    return FlutterMap(
      key: const Key('search-map'),
      mapController: map,
      options: MapOptions(
        initialCenter: searchCenter,
        initialZoom: 11.5,
        minZoom: 2,
        maxZoom: 16,
        onPositionChanged: (_, hasGesture) {
          if (hasGesture) {
            cameraInteractions++;
            cameraMotion.stop();
          }
        },
        onMapReady: () {
          mapReady = true;
          // TileLayer must subscribe before the first move or physical devices can stay grey.
          // https://docs.fleaflet.dev/usage/programmatic-interaction
          WidgetsBinding.instance.addPostFrameCallback((_) => frameAreas());
          WidgetsBinding.instance.scheduleFrame();
        },
        interactionOptions: const InteractionOptions(
          flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
        ),
      ),
      children: [
        TileLayer(
          key: ValueKey(tileRevision),
          tileProvider: widget.tileProvider,
          urlTemplate: mapTileUrl,
          userAgentPackageName: 'org.bindubashini.bloodconnection',
          errorTileCallback: (_, _, _) {
            if (!tileError) {
              tileError = true;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) setState(() {});
              });
              WidgetsBinding.instance.scheduleFrame();
            }
          },
        ),
        CircleLayer(
          circles: areas
              .map(
                (area) => CircleMarker(
                  point: projected(area.center),
                  radius: 2800,
                  useRadiusInMeter: true,
                  color: red.withValues(alpha: .07),
                  borderColor: red.withValues(alpha: .20),
                  borderStrokeWidth: 1,
                ),
              )
              .toList(),
        ),
        MarkerLayer(
          markers: areas
              .map(
                (area) => Marker(
                  point: projected(area.center),
                  width: (74 + 24 * scale).clamp(98, 172),
                  height: (42 + 12 * scale).clamp(54, 82),
                  // A small selection emphasis preserves marker geometry and honors reduced motion.
                  child: AnimatedScale(
                    // Reused map slots must not inherit another area's selection
                    // animation when offscreen markers are culled or reordered.
                    key: ValueKey(
                      'area-motion-${area.id}-${MediaQuery.disableAnimationsOf(context)}',
                    ),
                    scale: selectedArea == area.id ? 1.04 : 1,
                    duration: motionDuration(context, motionPress),
                    curve: Curves.easeOutCubic,
                    child: Semantics(
                      button: true,
                      selected: selectedArea == area.id,
                      label:
                          '${area.donors.length} $group donors in an approximate area',
                      child: FilledButton(
                        key: ValueKey('donor-area-${area.id}'),
                        onPressed: () => selectArea(area.id),
                        style: FilledButton.styleFrom(
                          backgroundColor: selectedArea == area.id ? teal : red,
                          minimumSize: const Size(48, 48),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 8,
                          ),
                          shape: const StadiumBorder(),
                          elevation: 3,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                group,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w800,
                                  fontSize: 16,
                                ),
                              ),
                              const SizedBox(width: 8),
                              DecoratedBox(
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: .20),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  child: Text(
                                    '${area.donors.length}',
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ],
    );
  }

  // The attribution tracks the sheet edge so the map's required credit is never hidden behind results.
  Widget mapControls(double height) => AnimatedBuilder(
    animation: sheet,
    builder: (context, child) {
      final extent = sheet.isAttached ? sheet.size : initialExtent;
      if (extent >= .6) return const SizedBox.shrink();
      final header =
          filterBounds.currentContext?.findRenderObject() as RenderBox?;
      final vertical =
          height * (1 - extent) -
              (header?.hasSize == true ? header!.size.height : 140) >
          180;
      final controls = <Widget>[
        if (extent < .6) ...[
          mapButton('Zoom in', Icons.add, () => zoomMap(1)),
          SizedBox(width: vertical ? 0 : 4, height: vertical ? 4 : 0),
          mapButton('Zoom out', Icons.remove, () => zoomMap(-1)),
          SizedBox(width: vertical ? 0 : 4, height: vertical ? 4 : 0),
        ],
        mapButton(
          'Show nearby areas',
          Icons.my_location,
          () => frameAreas(animate: true),
        ),
      ];
      return Positioned(
        left: 12,
        right: 12,
        bottom: height * extent + 6,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.bottomLeft,
                child: Material(
                  color: Colors.white.withValues(alpha: .94),
                  borderRadius: BorderRadius.circular(10),
                  child: mapCredit(),
                ),
              ),
            ),
            const SizedBox(width: 12),
            if (vertical)
              Column(mainAxisSize: MainAxisSize.min, children: controls)
            else
              Row(mainAxisSize: MainAxisSize.min, children: controls),
          ],
        ),
      );
    },
  );

  // The same required credit moves into the pinned sheet when the map footprint is small.
  Widget mapCredit() => TextButton(
    key: const Key('map-attribution'),
    onPressed: () => launchUrl(
      Uri.https('www.openstreetmap.org', '/copyright'),
      mode: LaunchMode.externalApplication,
    ),
    style: TextButton.styleFrom(
      minimumSize: const Size(48, 48),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: const TextStyle(fontSize: 10),
    ),
    child: const Text(mapAttribution, softWrap: true),
  );

  // Native 48 dp controls let users zoom without a multi-finger gesture.
  Widget mapButton(String label, IconData icon, VoidCallback action) =>
      IconButton.filled(
        tooltip: label,
        onPressed: action,
        style: IconButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: ink,
          minimumSize: const Size(48, 48),
        ),
        icon: Icon(icon),
      );

  // Zoom is a camera-only action; it never changes the saved search origin or radius.
  void zoomMap(double delta) {
    if (mapReady) {
      moveCamera(map.camera.center, (map.camera.zoom + delta).clamp(2, 16));
    }
  }

  // Flutter's sheet owns gesture arbitration: only its visible footprint consumes vertical drags.
  Widget donorSheet(double headerHeight) => DraggableScrollableSheet(
    key: const Key('donor-sheet'),
    controller: sheet,
    expand: false,
    initialChildSize: initialExtent,
    minChildSize: collapsedExtent,
    maxChildSize: expandedExtent,
    snap: true,
    snapSizes: [initialExtent],
    builder: (context, scrollController) {
      donorScroll = scrollController;
      return Material(
        color: canvas,
        elevation: 12,
        shadowColor: Colors.black.withValues(alpha: .18),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        clipBehavior: Clip.antiAlias,
        child: CustomScrollView(
          key: const Key('donor-results-scroll'),
          controller: scrollController,
          slivers: [
            SliverPersistentHeader(
              pinned: true,
              delegate: _DonorHeader(
                height: headerHeight,
                child: Material(
                  color: canvas,
                  child: Column(
                    key: const Key('donor-sheet-handle'),
                    children: [
                      const SizedBox(height: 8),
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: const Color(0xFFCCD2D6),
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      // Reserve the progress slot so loading never shifts the
                      // header controls. Reduced motion keeps a static accent.
                      SizedBox(
                        key: const Key('search-progress-slot'),
                        height: 2,
                        width: double.infinity,
                        child: !busy
                            ? null
                            : MediaQuery.disableAnimationsOf(context)
                            ? const ColoredBox(color: red)
                            : const LinearProgressIndicator(minHeight: 2),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16),
                          child: Row(
                            children: [
                              Expanded(
                                child: Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    busy
                                        ? 'Finding donors…'
                                        : error != null
                                        ? 'Search needs attention'
                                        : '${visibleDonors.length} $group donor${visibleDonors.length == 1 ? '' : 's'} ${selectedArea == null ? 'nearby' : 'in this area'}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleMedium,
                                  ),
                                ),
                              ),
                              IconButton(
                                key: const Key('expand-donors'),
                                tooltip: 'Expand donors',
                                onPressed: () => showDonors(),
                                icon: const Icon(Icons.keyboard_arrow_up),
                              ),
                              IconButton(
                                key: const Key('collapse-donors'),
                                tooltip: 'Collapse donors',
                                onPressed: () => showDonors(expanded: false),
                                icon: const Icon(Icons.keyboard_arrow_down),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Keep map attribution visible without covering the floating blood filters.
            AnimatedBuilder(
              animation: sheet,
              builder: (context, child) {
                if (!sheet.isAttached || sheet.size < .6) {
                  return const SliverToBoxAdapter(child: SizedBox.shrink());
                }
                final scale = MediaQuery.textScalerOf(context).scale(10) / 10;
                return SliverPersistentHeader(
                  pinned: true,
                  delegate: _DonorHeader(
                    height: 48 + (scale - 1).clamp(0.0, 3.0) * 24,
                    child: Material(
                      color: canvas,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: mapCredit(),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 28),
              // Replace old results immediately, then reveal only the current
              // sliver. An outgoing crossfade would keep stale donor actions alive.
              sliver: TweenAnimationBuilder<double>(
                key: ValueKey(
                  'results-$generation-$selectedArea-$busy-${MediaQuery.disableAnimationsOf(context)}',
                ),
                tween: Tween(
                  begin: MediaQuery.disableAnimationsOf(context)
                      ? 1
                      : motionEntryOpacity,
                  end: 1,
                ),
                duration: motionDuration(context, motionState),
                curve: Curves.easeOutCubic,
                builder: (context, opacity, child) =>
                    SliverOpacity(opacity: opacity, sliver: child!),
                child: SliverList.list(
                  children: [
                    if (selectedArea != null)
                      Align(
                        alignment: Alignment.centerLeft,
                        child: TextButton.icon(
                          key: const Key('all-donor-areas'),
                          onPressed: () => selectArea(null),
                          icon: const Icon(Icons.layers_outlined, size: 18),
                          label: const Text('All areas'),
                        ),
                      ),
                    if (tileError) ...[
                      const Notice(
                        'Map tiles unavailable. Your donor list still works.',
                        icon: Icons.map_outlined,
                      ),
                      TextButton(
                        onPressed: () => setState(() {
                          tileError = false;
                          tileRevision++;
                        }),
                        child: const Text('Retry map'),
                      ),
                    ],
                    ...resultWidgets(),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  // Marker selection filters the current result set without another network
  // request. Clearing the selection also restores list-only donors.
  List<Json> get visibleDonors => selectedArea == null
      ? (donors ?? <Json>[])
      : (donors ?? <Json>[])
            .where(
              (donor) =>
                  donor['map_area'] is Map &&
                  donor['map_area']['id'] == selectedArea,
            )
            .toList();

  // The list remains useful when tiles fail and shows only discovery fields;
  // profile photos and precise locations are not part of these donor cards.
  List<Widget> resultWidgets() {
    final visible = visibleDonors;
    return [
      if (error != null) ...[
        ErrorPanel(error!, search),
        const SizedBox(height: 12),
        TextButton.icon(
          onPressed: widget.onProfile,
          icon: const Icon(Icons.edit_location_alt_outlined),
          label: const Text('Review my location'),
        ),
      ],
      if (busy)
        Padding(
          key: const Key('donor-search-loading'),
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: Column(
            children: [
              SizedBox(
                width: 48,
                height: 48,
                child: MediaQuery.disableAnimationsOf(context)
                    ? const Icon(Icons.travel_explore, color: teal, size: 32)
                    : const Padding(
                        padding: EdgeInsets.all(8),
                        child: CircularProgressIndicator(strokeWidth: 3),
                      ),
              ),
              const SizedBox(height: 12),
              Text(
                'Looking within ${radius.round()} km',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              const Text('Checking who is available to help.'),
            ],
          ),
        ),
      if (donors != null) ...[
        if (visible.isEmpty) ...[
          const Notice(
            'No willing donors match this search yet. Try a wider radius or ask your hospital for support.',
            icon: Icons.search_off,
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: changeRadius,
            child: const Text('Change radius'),
          ),
        ],
        for (final donor in visible) ...[
          Card(
            key: ValueKey('donor-card-${donor['id']}'),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      BloodBadge(displayBlood(donor['blood_type'])),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              donor['display_name'].toString(),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '${donor['city']} · ${donor['distance_band']}',
                            ),
                            const SizedBox(height: 4),
                            const Row(
                              children: [
                                Icon(
                                  Icons.volunteer_activism_outlined,
                                  size: 14,
                                  color: teal,
                                ),
                                SizedBox(width: 4),
                                Flexible(
                                  child: Text(
                                    'Willing to donate',
                                    style: TextStyle(fontSize: 12, color: teal),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton(
                          onPressed: () => requestDonation([donor]),
                          child: const Text('Request donor'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.outlined(
                        onPressed: opening != null
                            ? null
                            : () => contact(donor),
                        tooltip: 'Message ${donor['display_name']}',
                        style: IconButton.styleFrom(
                          minimumSize: const Size(52, 52),
                        ),
                        icon: opening == donor['id'].toString()
                            ? SizedBox(
                                width: 20,
                                height: 20,
                                child: MediaQuery.disableAnimationsOf(context)
                                    ? const Icon(Icons.hourglass_top, size: 20)
                                    : const CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                              )
                            : const Icon(Icons.chat_bubble_outline),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (visible.length > 1) ...[
          TextButton.icon(
            onPressed: () => requestDonation(visible),
            icon: const Icon(Icons.volunteer_activism_outlined, size: 18),
            label: const Text('Request help from these donors'),
          ),
          const SizedBox(height: 8),
        ],
        Align(
          alignment: Alignment.centerRight,
          child: IconButton(
            tooltip: 'Refresh donors',
            onPressed: search,
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (donors!.any((donor) => donor['map_area'] is! Map))
          const Text(
            'Some donors are listed without an approximate map area.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
      ],
      const SizedBox(height: 12),
      const Text(
        'Approximate areas · exact locations stay private',
        style: TextStyle(fontSize: 12, color: muted),
      ),
      const SizedBox(height: 8),
      const Text(
        'Exact blood-group search. Your hospital confirms compatibility and donation eligibility.',
        style: TextStyle(fontSize: 12, color: muted, height: 1.5),
      ),
    ];
  }

  // A stack leaves the entire map interactive except where floating controls or the sheet are painted.
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
      final headerHeight = (72.0 + (scale - 1).clamp(0.0, 3.0) * 48).clamp(
        72.0,
        180.0,
      );
      collapsedExtent = (headerHeight / constraints.maxHeight).clamp(.14, .65);
      initialExtent = collapsedExtent > .25 ? collapsedExtent : .25;
      return Stack(
        children: [
          Positioned.fill(
            // Pointer-down cancels before the map recognizer starts panning; an
            // interrupted recenter must never pull against the person's finger.
            child: Listener(
              onPointerDown: (_) {
                cameraInteractions++;
                cameraMotion.stop();
              },
              onPointerSignal: (_) {
                cameraInteractions++;
                cameraMotion.stop();
              },
              // Overlay loading and sheet motion should not repaint map tiles.
              child: RepaintBoundary(child: donorMap()),
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 12,
            left: 12,
            right: 12,
            child: Align(
              alignment: Alignment.topCenter,
              child: ConstrainedBox(
                key: filterBounds,
                constraints: const BoxConstraints(maxWidth: 720),
                child: filters(),
              ),
            ),
          ),
          mapControls(constraints.maxHeight),
          Align(
            alignment: Alignment.bottomCenter,
            child: donorSheet(headerHeight),
          ),
        ],
      );
    },
  );
}

// A pinned native sliver keeps Expand/Collapse reachable while the donor list scrolls.
class _DonorHeader extends SliverPersistentHeaderDelegate {
  final double height;
  final Widget child;
  _DonorHeader({required this.height, required this.child});
  @override
  double get minExtent => height;
  @override
  double get maxExtent => height;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => child;
  @override
  bool shouldRebuild(_DonorHeader oldDelegate) =>
      oldDelegate.height != height || oldDelegate.child != child;
}
