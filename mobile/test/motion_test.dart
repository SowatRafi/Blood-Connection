// Motion must remain optional, finite and unable to retain outgoing private UI.
import 'package:blood_connection/ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mounts motion under explicit accessibility and ticker settings.
Widget scene(Widget child, {bool reduced = false, bool ticking = true}) =>
    MaterialApp(
      theme: appTheme(),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: TickerMode(
          enabled: ticking,
          child: Scaffold(body: EntranceMotion(child: child)),
        ),
      ),
    );

void main() {
  for (final surface in [canvas, mint]) {
    testWidgets(
      'first reveal frame keeps readable text on ${surface == canvas ? 'canvas' : 'mint'}',
      (tester) async {
        await tester.pumpWidget(
          scene(
            ColoredBox(
              color: surface,
              child: const Text(
                'Private by design',
                style: TextStyle(color: muted),
              ),
            ),
          ),
        );
        final opacity = tester
            .widget<Opacity>(
              find.descendant(
                of: find.byType(EntranceMotion),
                matching: find.byType(Opacity),
              ),
            )
            .opacity;
        final text = tester.widget<Text>(find.text('Private by design'));
        // A group-opacity layer composites both the text and its card background
        // against the scaffold. Check that real first-frame blend, not a token.
        final foreground = Color.alphaBlend(
          text.style!.color!.withValues(alpha: opacity),
          appTheme().scaffoldBackgroundColor,
        );
        final background = Color.alphaBlend(
          surface.withValues(alpha: opacity),
          appTheme().scaffoldBackgroundColor,
        );
        final ratio =
            (background.computeLuminance() + .05) /
            (foreground.computeLuminance() + .05);
        expect(ratio, greaterThanOrEqualTo(4.5));
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'entrance is interactive immediately and stops scheduling frames',
    (tester) async {
      var pressed = 0;
      await tester.pumpWidget(
        scene(
          FilledButton(
            onPressed: () => pressed++,
            child: const Text('Find a blood donor'),
          ),
        ),
      );
      await tester.tap(find.text('Find a blood donor'));
      expect(pressed, 1);
      await tester.pumpAndSettle();
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reduced motion shows final content on the first frame', (
    tester,
  ) async {
    await tester.pumpWidget(
      scene(const Text('Current content'), reduced: true),
    );
    final opacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(EntranceMotion),
        matching: find.byType(Opacity),
      ),
    );
    final transform = tester.widget<Transform>(
      find.descendant(
        of: find.byType(EntranceMotion),
        matching: find.byType(Transform),
      ),
    );
    expect(opacity.opacity, 1);
    expect(transform.transform.getTranslation().y, 0);
    expect(tester.hasRunningAnimations, isFalse);
    final context = tester.element(find.byType(EntranceMotion));
    expect(motionDuration(context, motionTravel), Duration.zero);
  });

  for (final preference in ['reduced motion', 'covered route']) {
    testWidgets('$preference completes an in-flight reveal without a replay', (
      tester,
    ) async {
      await tester.pumpWidget(scene(const Text('Current content')));
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pumpWidget(
        scene(
          const Text('Current content'),
          reduced: preference == 'reduced motion',
          ticking: preference != 'covered route',
        ),
      );
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(scene(const Text('Current content')));
      expect(tester.hasRunningAnimations, isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('replacing private content disposes it in the same frame', (
    tester,
  ) async {
    var disposed = false;
    await tester.pumpWidget(
      scene(_PrivateContent(onDispose: () => disposed = true)),
    );
    await tester.pump(const Duration(milliseconds: 40));
    await tester.pumpWidget(scene(const Text('Signed out')));
    expect(disposed, isTrue);
    expect(find.text('Private account content'), findsNothing);
    expect(find.text('Signed out'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.hasRunningAnimations, isFalse);
    expect(tester.takeException(), isNull);
  });
}

/// Records disposal where a real private widget would release image/subscription state.
class _PrivateContent extends StatefulWidget {
  final VoidCallback onDispose;
  const _PrivateContent({required this.onDispose});

  @override
  State<_PrivateContent> createState() => _PrivateContentState();
}

class _PrivateContentState extends State<_PrivateContent> {
  @override
  Widget build(BuildContext context) => const Text('Private account content');

  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }
}
