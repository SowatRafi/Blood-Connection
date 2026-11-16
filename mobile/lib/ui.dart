// Small shared visual primitives keep touch sizes, spacing and privacy language consistent.
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const ink = Color(0xFF203135);
const muted = Color(0xFF59686B);
const red = Color(0xFFB42346);
const canvas = Color(0xFFFAF8F5);
const mint = Color(0xFFE6F3EF);
const teal = Color(0xFF176B65);
const rose = Color(0xFFF8E8EC);

// Use shorter feedback for a tap than for spatial travel; callers can share the
// timing without overriding the platform's reduced-motion preference.
const motionPress = Duration(milliseconds: 120);
const motionState = Duration(milliseconds: 200);
const motionTravel = Duration(milliseconds: 280);
// Preserve normal-text contrast throughout a reveal, including its first frame.
const motionEntryOpacity = .96;

/// Removes optional movement when the system requests reduced animation.
Duration motionDuration(BuildContext context, Duration duration) =>
    MediaQuery.disableAnimationsOf(context) ? Duration.zero : duration;

/// Reveals the current content once, without delaying input or retaining old data.
///
/// This is an entrance treatment, not a crossfade: replacing [child] immediately
/// removes the previous subtree, including its private images and subscriptions.
class EntranceMotion extends StatefulWidget {
  final Widget child;
  const EntranceMotion({super.key, required this.child});

  @override
  State<EntranceMotion> createState() => _EntranceMotionState();
}

class _EntranceMotionState extends State<EntranceMotion>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final Animation<double> progress;
  bool started = false;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(vsync: this, duration: motionTravel);
    progress = controller.drive(CurveTween(curve: Curves.easeOutCubic));
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A covered route must not queue a decorative replay when it becomes active.
    if (MediaQuery.disableAnimationsOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      controller.value = 1;
      started = true;
    } else if (!started) {
      started = true;
      controller.forward();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: progress,
    // Cache painting of the content while the small composited transform changes.
    child: RepaintBoundary(child: widget.child),
    builder: (context, child) => Transform.translate(
      offset: Offset(0, 10 * (1 - progress.value)),
      child: Opacity(
        // Keep content legible and interactive from its first frame.
        opacity: motionEntryOpacity + (1 - motionEntryOpacity) * progress.value,
        alwaysIncludeSemantics: true,
        child: child,
      ),
    ),
  );
}

/// Registers the bundled font license for the app's offline license screen.
void registerBrandLicenses() => LicenseRegistry.addLicense(() async* {
  yield LicenseEntryWithLineBreaks([
    'Manrope',
  ], await rootBundle.loadString('assets/fonts/OFL.txt'));
});

/// Uses the shared brand master and launcher padding at any in-app display size.
class BrandMark extends StatelessWidget {
  final double size;
  const BrandMark({super.key, this.size = 48});
  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Blood Connection',
    image: true,
    child: Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 202 / 1024),
      decoration: BoxDecoration(
        color: canvas,
        borderRadius: BorderRadius.circular(size * .25),
      ),
      child: Image.asset(
        'assets/brand/mark.png',
        fit: BoxFit.contain,
        excludeFromSemantics: true,
        // Decode only the physical pixels needed; Flutter caches each requested asset size.
        cacheWidth: (size * 620 / 1024 * MediaQuery.devicePixelRatioOf(context))
            .ceil()
            .clamp(1, 1024),
      ),
    ),
  );
}

/// Applies the brand to Material controls while retaining their native semantics.
ThemeData appTheme() => ThemeData(
  useMaterial3: true,
  fontFamily: 'Manrope',
  colorScheme: ColorScheme.fromSeed(seedColor: red).copyWith(
    primary: red,
    surface: canvas,
    onSurface: ink,
    secondary: teal,
    onSecondary: Colors.white,
    secondaryContainer: mint,
    onSecondaryContainer: teal,
    primaryContainer: rose,
    onPrimaryContainer: red,
    surfaceContainerHigh: Colors.white,
    surfaceContainerHighest: const Color(0xFFF0EDEA),
    onSurfaceVariant: muted,
    outline: const Color(0xFF748080),
    outlineVariant: const Color(0xFFE5E2DD),
  ),
  scaffoldBackgroundColor: canvas,
  appBarTheme: const AppBarTheme(
    backgroundColor: canvas,
    foregroundColor: ink,
    centerTitle: false,
    elevation: 0,
  ),
  textTheme: const TextTheme(
    headlineLarge: TextStyle(
      fontSize: 36,
      fontWeight: FontWeight.w800,
      letterSpacing: -1.2,
      height: 1.15,
      color: ink,
    ),
    headlineMedium: TextStyle(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -.7,
      color: ink,
    ),
    titleLarge: TextStyle(
      fontSize: 21,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    titleMedium: TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w700,
      color: ink,
    ),
    bodyLarge: TextStyle(fontSize: 16, height: 1.5, color: ink),
    bodyMedium: TextStyle(fontSize: 14, height: 1.5, color: muted),
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    margin: EdgeInsets.zero,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(20),
      side: const BorderSide(color: Color(0xFFE6E3DE)),
    ),
  ),
  filledButtonTheme: FilledButtonThemeData(
    style: FilledButton.styleFrom(
      minimumSize: const Size(48, 52),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
  outlinedButtonTheme: OutlinedButtonThemeData(
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(48, 52),
      foregroundColor: ink,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  ),
  iconButtonTheme: IconButtonThemeData(
    style: IconButton.styleFrom(minimumSize: const Size(48, 48), iconSize: 24),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: Colors.white,
    contentPadding: const EdgeInsets.all(16),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
  ),
  snackBarTheme: const SnackBarThemeData(
    backgroundColor: ink,
    contentTextStyle: TextStyle(color: Colors.white),
    behavior: SnackBarBehavior.floating,
  ),
  navigationRailTheme: const NavigationRailThemeData(
    backgroundColor: canvas,
    indicatorColor: mint,
  ),
  navigationBarTheme: const NavigationBarThemeData(
    backgroundColor: Colors.white,
    indicatorColor: mint,
  ),
);

/// Constrains reading width while allowing scrolling on phones and large text.
class PageBody extends StatelessWidget {
  final List<Widget> children;
  const PageBody({super.key, required this.children});
  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
    child: Center(
      widthFactor: 1,
      heightFactor: 1,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      ),
    ),
  );
}

/// Gives grouped content the common card treatment and internal spacing.
class Panel extends StatelessWidget {
  final Widget child;
  final Color? color;
  const Panel({super.key, required this.child, this.color});
  @override
  Widget build(BuildContext context) => Card(
    color: color,
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

/// Identifies the blood group with text, so color is never the only indication.
class BloodBadge extends StatelessWidget {
  final String group;
  const BloodBadge(this.group, {super.key});
  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 56, minHeight: 56),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: rose,
      borderRadius: BorderRadius.circular(18),
    ),
    child: Center(
      widthFactor: 1,
      heightFactor: 1,
      child: Text(
        group,
        style: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w800,
          color: red,
        ),
      ),
    ),
  );
}

/// Presents explanatory text with a wrapping layout and a supporting icon.
class Notice extends StatelessWidget {
  final String text;
  final IconData icon;
  final Color color;
  const Notice(
    this.text, {
    super.key,
    this.icon = Icons.shield_outlined,
    this.color = mint,
  });
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: color,
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, height: 1.5, color: ink),
          ),
        ),
      ],
    ),
  );
}

/// Keeps a recoverable failure and its retry action visible in the page.
class ErrorPanel extends StatelessWidget {
  final String message;
  final VoidCallback retry;
  const ErrorPanel(this.message, this.retry, {super.key});
  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(message),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: retry,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      ],
    ),
  );
}

/// Shows transient action feedback through the screen's existing messenger.
void feedback(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
