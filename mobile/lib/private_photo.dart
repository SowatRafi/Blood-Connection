// Photos are fetched only from authenticated endpoints and removed from Flutter's image cache on disposal.
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'api.dart';
import 'ui.dart';

/// Displays a photo only after the authenticated endpoint allows the read.
///
/// Backgrounding clears the displayed bytes; resuming fetches through the
/// server again so a previously accepted relationship is not assumed to persist.
class PrivatePhoto extends StatefulWidget {
  final Api api;
  final String userId;
  final double size;
  const PrivatePhoto({
    super.key,
    required this.api,
    required this.userId,
    this.size = 88,
  });
  @override
  State<PrivatePhoto> createState() => _PrivatePhotoState();
}

class _PrivatePhotoState extends State<PrivatePhoto>
    with WidgetsBindingObserver {
  Uint8List? bytes;
  int generation = 0;
  bool active = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  // A different account or participant must never inherit the previous person's decoded image.
  @override
  void didUpdateWidget(PrivatePhoto oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api || oldWidget.userId != widget.userId) {
      clear();
      load();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) {
      load();
    } else {
      clear();
    }
  }

  // Invalidating the generation also prevents an in-flight fetch from restoring
  // the cleared image after an account change or background transition.
  void clear() {
    generation++;
    final previous = bytes;
    if (previous != null) MemoryImage(previous).evict();
    if (mounted) setState(() => bytes = null);
  }

  // Requests are not cancelled; only the newest foreground result may be shown.
  Future<void> load() async {
    final current = ++generation;
    try {
      final result = await widget.api.photo(widget.userId);
      if (mounted && active && current == generation) {
        setState(() => bytes = result);
      }
    } catch (_) {
      /* Revoked or absent photos become a neutral placeholder, never a cached public fallback. */
    }
  }

  @override
  void dispose() {
    generation++;
    WidgetsBinding.instance.removeObserver(this);
    final image = bytes;
    if (image != null) MemoryImage(image).evict();
    bytes = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.size,
    height: widget.size,
    child: ClipOval(
      child: bytes == null
          ? const ColoredBox(
              color: mint,
              child: Icon(Icons.person_outline, color: ink, size: 40),
            )
          : Image.memory(
              bytes!,
              fit: BoxFit.cover,
              semanticLabel: 'Shared profile photo',
              errorBuilder: (_, _, _) => const ColoredBox(
                color: mint,
                child: Icon(Icons.person_outline),
              ),
            ),
    ),
  );
}
