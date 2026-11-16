// Discovery tests cover location privacy and real map/filter interactions without downloading tiles.
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/api.dart';
import 'package:blood_connection/search.dart';
import 'package:blood_connection/ui.dart';

class SearchTiles extends TileProvider {
  final requested = <TileCoordinates>[];
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    requested.add(coordinates);
    return MemoryImage(TileProvider.transparentImage);
  }
}

const profile = <String, dynamic>{
  'id': 'me',
  'country': 'BD',
  'city': 'Dhaka',
  'latitude': 23.8,
  'longitude': 90.4,
};

Json donor(
  String id, {
  String group = 'O+',
  String area = 'coarse-one',
  double latitude = 23.825,
  double longitude = 90.425,
}) => {
  'id': id,
  'display_name': 'Donor $id',
  'blood_type': group,
  'city': 'Dhaka',
  'distance_band': 'Within 5 km',
  'map_area': {'id': area, 'latitude': latitude, 'longitude': longitude},
};

class SearchApi extends Api {
  final queries = <Map<String, String>>[];
  List<Json> items = [donor('one'), donor('two')];
  Future<List<Json>> Function(Map<String, String>)? answer;
  @override
  Future<List<Json>> list(String path, {Map<String, String>? query}) async {
    queries.add(Map.of(query!));
    return answer != null ? answer!(query) : items;
  }
}

// Shared host controls viewport and text scaling while retaining the real Material/map widgets.
Future<void> mount(
  WidgetTester tester,
  SearchApi api, {
  Size size = const Size(1024, 900),
  double scale = 1,
  bool reduceMotion = false,
  ValueNotifier<bool>? motionSetting,
  Json me = profile,
  Future<Json> Function()? refresh,
  SearchTiles? tiles,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(api.close);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(),
      builder: (context, child) {
        Widget media(bool reduced) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            disableAnimations: reduced,
          ),
          child: child!,
        );
        return motionSetting == null
            ? media(reduceMotion)
            : ValueListenableBuilder<bool>(
                valueListenable: motionSetting,
                builder: (context, reduced, child) => media(reduced),
              );
      },
      home: Scaffold(
        body: SearchScreen(
          api: api,
          me: me,
          onProfile: () {},
          refreshLocation: refresh ?? () async => me,
          tileProvider: tiles ?? SearchTiles(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'reduced-motion searching stays readable without an animated spinner',
    (tester) async {
      final api = SearchApi();
      await mount(tester, api, reduceMotion: true);
      final pending = Completer<List<Json>>();
      api.answer = (_) => pending.future;
      final expandBefore = tester.getRect(
        find.byKey(const Key('expand-donors')),
      );
      await tester.tap(find.byKey(const ValueKey('blood-group-A+')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('donor-search-loading')), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.text('Finding donors…'), findsOneWidget);
      expect(
        tester.getRect(find.byKey(const Key('expand-donors'))),
        expandBefore,
      );
      expect(tester.hasRunningAnimations, isFalse);
      pending.complete([donor('new', group: 'A+')]);
      await tester.pumpAndSettle();
      expect(find.text('Donor new'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'rapid filters discard old actions while preserving the map and pinned controls',
    (tester) async {
      final api = SearchApi();
      await mount(tester, api);
      final originalMap = tester.element(find.byType(FlutterMap));
      final expandBefore = tester.getRect(
        find.byKey(const Key('expand-donors')),
      );
      final aReply = Completer<List<Json>>();
      final bReply = Completer<List<Json>>();
      api.answer = (query) =>
          query['blood_type'] == 'A+' ? aReply.future : bReply.future;
      await tester.tap(find.byKey(const ValueKey('blood-group-A+')));
      await tester.pump();
      expect(find.text('Donor one'), findsNothing);
      expect(find.text('Request donor'), findsNothing);
      expect(tester.element(find.byType(FlutterMap)), same(originalMap));
      expect(
        tester.getRect(find.byKey(const Key('expand-donors'))),
        expandBefore,
      );
      aReply.complete([donor('first reply', group: 'A+')]);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('Donor first reply'), findsOneWidget);
      // Replace the result while its finite reveal is still running: no outgoing
      // card or request callback may remain mounted during the next query.
      await tester.tap(find.byKey(const ValueKey('blood-group-B+')));
      await tester.pump();
      expect(find.text('Donor first reply'), findsNothing);
      expect(find.text('Request donor'), findsNothing);
      bReply.complete([donor('latest reply', group: 'B+')]);
      await tester.pumpAndSettle();
      expect(find.text('Donor latest reply'), findsOneWidget);
      expect(tester.element(find.byType(FlutterMap)), same(originalMap));
      expect(
        tester.getRect(find.byKey(const Key('expand-donors'))),
        expandBefore,
      );
      expect(api.queries, hasLength(3));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('turning reduced motion on settles camera and sheet actions', (
    tester,
  ) async {
    final setting = ValueNotifier(false);
    addTearDown(setting.dispose);
    await mount(tester, SearchApi(), motionSetting: setting);
    final map = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    final before = map.camera.zoom;
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.tap(find.byKey(const Key('expand-donors')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(map.camera.zoom, lessThan(before + 1));
    setting.value = true;
    await tester.pump();
    expect(map.camera.zoom, closeTo(before + 1, .000001));
    final sheet = tester
        .widget<DraggableScrollableSheet>(find.byKey(const Key('donor-sheet')))
        .controller!;
    final stoppedExtent = sheet.size;
    await tester.pump(const Duration(milliseconds: 400));
    expect(map.camera.zoom, closeTo(before + 1, .000001));
    expect(sheet.size, stoppedExtent);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('zoom eases briefly and touching the map cancels camera motion', (
    tester,
  ) async {
    await mount(tester, SearchApi(), size: const Size(390, 844));
    final controller = tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!;
    final before = controller.camera.zoom;
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    final intermediate = controller.camera.zoom;
    expect(intermediate, greaterThan(before));
    expect(intermediate, lessThan(before + 1));
    // Hold a real pointer over the exposed map: no drag/inertia is needed to cancel.
    final pointer = await tester.startGesture(const Offset(40, 340));
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.camera.zoom, closeTo(intermediate, .000001));
    await pointer.up();
    // Let flutter_map's single/double-tap arbitration timer finish before disposing it.
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    // Disposal while another zoom is running must not leave a ticker behind.
    await tester.tap(find.byTooltip('Zoom in'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reduced-motion camera controls apply the final zoom in one frame',
    (tester) async {
      await mount(tester, SearchApi(), reduceMotion: true);
      final controller = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!;
      final before = controller.camera.zoom;
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump();
      expect(controller.camera.zoom, closeTo(before + 1, .000001));
      await tester.pump(const Duration(milliseconds: 400));
      expect(controller.camera.zoom, closeTo(before + 1, .000001));
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'late search results preserve a camera that the person has panned',
    (tester) async {
      final api = SearchApi();
      await mount(tester, api, size: const Size(390, 844));
      final reply = Completer<List<Json>>();
      api.answer = (_) => reply.future;
      await tester.tap(find.byKey(const ValueKey('blood-group-A+')));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      final controller = tester
          .widget<FlutterMap>(find.byType(FlutterMap))
          .mapController!;
      await tester.dragFrom(const Offset(45, 320), const Offset(100, 90));
      await tester.pump(const Duration(seconds: 1));
      final explored = controller.camera.center;
      reply.complete([donor('new', group: 'A+')]);
      await tester.pumpAndSettle();
      expect(
        controller.camera.center.latitude,
        closeTo(explored.latitude, .000001),
      );
      expect(
        controller.camera.center.longitude,
        closeTo(explored.longitude, .000001),
      );
      expect(api.queries.last['latitude'], '${profile['latitude']}');
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('initial fitted map requests and decodes tiles without a gesture', (
    tester,
  ) async {
    final tiles = SearchTiles();
    await mount(tester, SearchApi(), tiles: tiles, size: const Size(390, 844));
    // Decode outside the fake clock; the map must render the fitted viewport without input.
    await tester.runAsync(
      () => precacheImage(
        MemoryImage(TileProvider.transparentImage),
        tester.element(find.byType(SearchScreen)),
      ),
    );
    await tester.pumpAndSettle();
    final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
    final fittedZoom = map.mapController!.camera.zoom.round();
    expect(tiles.requested.where((tile) => tile.z == fittedZoom), isNotEmpty);
    expect(
      tester
          .widgetList<RawImage>(find.byType(RawImage))
          .where((image) => image.image != null),
      isNotEmpty,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  test(
    'areas group only explicit coarse server locations, never raw coordinates',
    () {
      final areas = groupDonorAreas([
        donor('one'),
        donor('two'),
        donor('three', area: 'coarse-two'),
        {'id': 'legacy', 'latitude': 23.801234, 'longitude': 90.401234},
        donor('invalid', latitude: 91),
      ]);
      expect(areas, hasLength(2));
      expect(areas.first.donors, hasLength(2));
      expect(areas.first.center.latitude, 23.825);
    },
  );

  testWidgets(
    'peek shows the first donor and zoom controls while expanded credits clear filters',
    (tester) async {
      final api = SearchApi();
      await mount(tester, api, size: const Size(390, 844));
      final firstName = tester.getRect(find.text('Donor one'));
      final sheetHeader = tester.getRect(
        find.byKey(const Key('donor-sheet-handle')),
      );
      expect(firstName.top, greaterThanOrEqualTo(sheetHeader.bottom));
      expect(firstName.bottom, lessThanOrEqualTo(844));
      final map = tester
          .widget<FlutterMap>(find.byKey(const Key('search-map')))
          .mapController!;
      final center = map.camera.center;
      final zoom = map.camera.zoom;
      expect(find.byTooltip('Zoom in').hitTestable(), findsOneWidget);
      expect(find.byTooltip('Zoom out').hitTestable(), findsOneWidget);
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pumpAndSettle();
      expect(map.camera.zoom, closeTo(zoom + 1, .001));
      await tester.tap(find.byTooltip('Zoom out'));
      await tester.pumpAndSettle();
      expect(map.camera.zoom, closeTo(zoom, .001));
      expect(map.camera.center, center);
      expect(api.queries, hasLength(1));
      await tester.tap(find.byKey(const Key('expand-donors')));
      await tester.pumpAndSettle();
      final credit = find.byKey(const Key('map-attribution'));
      expect(credit, findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const Key('donor-sheet')),
          matching: credit,
        ),
        findsOneWidget,
      );
      expect(
        tester
            .getRect(credit)
            .overlaps(tester.getRect(find.byKey(const Key('search-filters')))),
        isFalse,
      );
      expect(credit.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'map groups donors and a selected area filters actual donor actions',
    (tester) async {
      final api = SearchApi()
        ..items.add(donor('three', area: 'coarse-two', latitude: 23.85));
      await mount(tester, api);
      expect(api.queries.single['blood_type'], 'O+');
      expect(
        tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers,
        hasLength(2),
      );
      final sheet = tester.widget<DraggableScrollableSheet>(
        find.byKey(const Key('donor-sheet')),
      );
      final before = sheet.controller!.size;
      await tester.tap(find.byKey(const ValueKey('donor-area-coarse-one')));
      await tester.pumpAndSettle();
      expect(sheet.controller!.size, greaterThan(before));
      expect(find.text('Donor one'), findsOneWidget);
      expect(find.text('Donor two'), findsOneWidget);
      expect(find.text('Donor three'), findsNothing);
      expect(find.text('Request donor'), findsNWidgets(2));
      expect(find.byTooltip('Message Donor one'), findsOneWidget);
      await tester.tap(find.byKey(const Key('all-donor-areas')));
      await tester.pumpAndSettle();
      expect(find.text('Donor three'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reduced motion selects an area and opens donors without animation',
    (tester) async {
      await mount(tester, SearchApi(), reduceMotion: true);
      final marker = find.byKey(const ValueKey('donor-area-coarse-one'));
      final animation = find.ancestor(
        of: marker,
        matching: find.byType(AnimatedScale),
      );
      expect(tester.widget<AnimatedScale>(animation).duration, Duration.zero);
      await tester.tap(marker);
      // A single frame is enough: the sheet must jump instead of interpolating its extent.
      await tester.pump();
      final sheet = tester.widget<DraggableScrollableSheet>(
        find.byKey(const Key('donor-sheet')),
      );
      expect(sheet.controller!.size, sheet.maxChildSize);
      expect(tester.widget<AnimatedScale>(animation).duration, Duration.zero);
      expect(tester.widget<AnimatedScale>(animation).scale, greaterThan(1));
      expect(find.text('Donor one'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'date-line areas stay local and only coarse centers become markers',
    (tester) async {
      final api = SearchApi()
        ..items = [
          donor('east', longitude: 179.97, latitude: 0),
          donor('west', area: 'west', longitude: -179.97, latitude: 0),
        ];
      await mount(
        tester,
        api,
        me: {...profile, 'latitude': 0, 'longitude': 179.99},
      );
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      expect(
        map.mapController!.camera.center.longitude.abs(),
        greaterThan(179),
      );
      expect(map.mapController!.camera.zoom, greaterThan(8));
      final markers = tester
          .widget<MarkerLayer>(find.byType(MarkerLayer))
          .markers;
      expect(markers.map((marker) => marker.point.longitude), [
        179.97,
        -179.97,
      ]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  for (final size in [
    const Size(320, 640),
    const Size(812, 375),
    const Size(1024, 900),
  ]) {
    testWidgets('floating filters and donor sheet fit $size with doubled text', (
      tester,
    ) async {
      await mount(tester, SearchApi(), size: size, scale: 2);
      expect(tester.takeException(), isNull);
      expect(find.byType(ChoiceChip), findsNWidgets(8));
      expect(tester.getSize(find.byKey(const Key('search-map'))), size);
      expect(find.byKey(const Key('search-filters')), findsOneWidget);
      final sheet = tester.widget<DraggableScrollableSheet>(
        find.byKey(const Key('donor-sheet')),
      );
      expect(sheet.controller!.isAttached, isTrue);
      expect(
        tester
            .widget<CustomScrollView>(
              find.byKey(const Key('donor-results-scroll')),
            )
            .controller!
            .hasClients,
        isTrue,
      );
      // The list must use the sheet's attached scrolling position, otherwise dragging cannot resize it.
      final sheetScrollables = tester.stateList<ScrollableState>(
        find.descendant(
          of: find.byKey(const Key('donor-sheet')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(
        sheetScrollables.where((state) => state.position.hasContentDimensions),
        isNotEmpty,
      );
      final before = sheet.controller!.size;
      final semantics = tester.ensureSemantics();
      try {
        final expand = find.byKey(const Key('expand-donors'));
        expect(
          tester
              .getSemantics(expand)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        final expandData = tester.getSemantics(expand).getSemanticsData();
        expect(
          '${expandData.label} ${expandData.tooltip}',
          contains('Expand donors'),
        );
        await tester.tap(expand);
        await tester.pumpAndSettle();
        expect(sheet.controller!.size, greaterThan(before));
        expect(tester.takeException(), isNull);
        final credit = find.byKey(const Key('map-attribution'));
        expect(credit, findsOneWidget);
        expect(
          tester
              .getRect(credit)
              .overlaps(
                tester.getRect(find.byKey(const Key('search-filters'))),
              ),
          isFalse,
        );
        final collapse = find.byKey(const Key('collapse-donors'));
        expect(
          tester
              .getSemantics(collapse)
              .getSemanticsData()
              .hasAction(SemanticsAction.tap),
          isTrue,
        );
        final collapseData = tester.getSemantics(collapse).getSemanticsData();
        expect(
          '${collapseData.label} ${collapseData.tooltip}',
          contains('Collapse donors'),
        );
        await tester.tap(collapse);
        await tester.pumpAndSettle();
        expect(sheet.controller!.size, lessThan(.5));
        expect(find.byType(FlutterMap), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('offline map keeps donor actions available in the sheet', (
    tester,
  ) async {
    await mount(tester, SearchApi(), size: const Size(320, 640), scale: 2);
    final layer = tester.widget<TileLayer>(find.byType(TileLayer));
    final tile = TileImage(
      vsync: tester,
      coordinates: const TileCoordinates(0, 0, 1),
      imageProvider: MemoryImage(TileProvider.transparentImage),
      onLoadComplete: (_) {},
      onLoadError: (_, _, _) {},
      tileDisplay: const TileDisplay.instantaneous(),
      errorImage: null,
      cancelLoading: Completer<void>(),
    );
    layer.errorTileCallback!(
      tile,
      Exception('Network unavailable'),
      StackTrace.current,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('expand-donors')));
    await tester.pumpAndSettle();
    expect(find.byType(FlutterMap), findsOneWidget);
    // Offline guidance may fill the first screen at large text; the actual sheet still scrolls to donor actions.
    await tester.scrollUntilVisible(
      find.text('Donor one'),
      150,
      scrollable: find.descendant(
        of: find.byKey(const Key('donor-results-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Donor one'), findsOneWidget);
    expect(tester.takeException(), isNull);
    tile.dispose();
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one-finger map pan moves camera without moving filters or sheet', (
    tester,
  ) async {
    await mount(tester, SearchApi(), size: const Size(390, 844));
    final map = tester
        .widget<FlutterMap>(find.byKey(const Key('search-map')))
        .mapController!;
    final filters = find.byKey(const Key('search-filters'));
    final handle = find.byKey(const Key('donor-sheet-handle'));
    final filtersBefore = tester.getRect(filters);
    final handleBefore = tester.getRect(handle);
    final centerBefore = map.camera.center;
    final sheet = tester.widget<DraggableScrollableSheet>(
      find.byKey(const Key('donor-sheet')),
    );
    final extentBefore = sheet.controller!.size;
    // Start in exposed map space: the gesture must not hit either floating control layer.
    final gapY = (filtersBefore.bottom + handleBefore.top) / 2;
    expect(gapY, greaterThan(filtersBefore.bottom));
    expect(gapY, lessThan(handleBefore.top));
    await tester.dragFrom(Offset(40, gapY), const Offset(140, 0));
    await tester.pumpAndSettle();
    expect(map.camera.center, isNot(centerBefore));
    expect(tester.getRect(filters), filtersBefore);
    expect(tester.getRect(handle), handleBefore);
    expect(sheet.controller!.size, extentBefore);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'dragging donor sheet expands and collapses without panning map',
    (tester) async {
      await mount(tester, SearchApi(), size: const Size(390, 844));
      final map = tester
          .widget<FlutterMap>(find.byKey(const Key('search-map')))
          .mapController!;
      final centerBefore = map.camera.center;
      final zoomBefore = map.camera.zoom;
      final sheet = tester.widget<DraggableScrollableSheet>(
        find.byKey(const Key('donor-sheet')),
      );
      final extentBefore = sheet.controller!.size;
      await tester.drag(
        find.byKey(const Key('donor-sheet-handle')),
        const Offset(0, -320),
      );
      await tester.pumpAndSettle();
      final expanded = sheet.controller!.size;
      expect(expanded, greaterThan(extentBefore));
      expect(map.camera.center, centerBefore);
      expect(map.camera.zoom, zoomBefore);
      await tester.drag(
        find.byKey(const Key('donor-sheet-handle')),
        const Offset(0, 400),
      );
      await tester.pumpAndSettle();
      expect(sheet.controller!.size, lessThan(expanded));
      expect(map.camera.center, centerBefore);
      expect(map.camera.zoom, zoomBefore);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('new group wins even when previous search finishes later', (
    tester,
  ) async {
    final old = Completer<List<Json>>();
    final api = SearchApi()
      ..answer = (query) => query['blood_type'] == 'O+'
          ? old.future
          : Future.value([donor('A match', group: 'A+')]);
    // An outstanding request has an intentional spinner, so do not pumpAndSettle until it is superseded.
    tester.view.physicalSize = const Size(1024, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(api.close);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(),
        home: Scaffold(
          body: SearchScreen(
            api: api,
            me: profile,
            onProfile: () {},
            refreshLocation: () async => profile,
            tileProvider: SearchTiles(),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('blood-group-A+')));
    await tester.pumpAndSettle();
    old.complete([donor('stale')]);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('expand-donors')));
    await tester.pumpAndSettle();
    expect(find.text('Donor A match'), findsOneWidget);
    expect(find.text('Donor stale'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('radius stays unchanged until Apply and never exceeds 39 km', (
    tester,
  ) async {
    final api = SearchApi();
    await mount(tester, api);
    await tester.tap(find.text('10 km'));
    await tester.pumpAndSettle();
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, 39);
    slider.onChanged!(39);
    await tester.pump();
    expect(api.queries, hasLength(1));
    await tester.tap(find.text('Apply radius'));
    await tester.pumpAndSettle();
    expect(api.queries.last['radius_km'], '39');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('location failure never sends a search with old coordinates', (
    tester,
  ) async {
    final api = SearchApi();
    await mount(
      tester,
      api,
      refresh: () async => throw const ApiException('Current area unavailable'),
    );
    expect(api.queries, isEmpty);
    await tester.tap(find.byKey(const Key('expand-donors')));
    await tester.pumpAndSettle();
    expect(find.text('Current area unavailable'), findsOneWidget);
    expect(find.text('Review my location'), findsOneWidget);
    expect(
      tester.widget<MarkerLayer>(find.byType(MarkerLayer)).markers,
      isEmpty,
    );
    await tester.pumpWidget(const SizedBox());
  });
}
