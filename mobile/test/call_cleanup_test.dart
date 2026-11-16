// Regression for Pixel cancellation: a LiveKit disconnect timeout must not leave a ringing invitation or trap the route.
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:blood_connection/messaging.dart';

void main() {
  test(
    'media timeout still cancels the invitation and closes exactly once',
    () async {
      var cancelled = false;
      var closes = 0;
      await finishCallCleanup(
        disconnect: () async => throw TimeoutException('No disconnected event'),
        cancelInvitation: () async => cancelled = true,
        close: () => closes++,
      );
      expect(cancelled, isTrue);
      expect(closes, 1);
    },
  );

  test(
    'server cancellation begins without waiting for media teardown',
    () async {
      final media = Completer<void>();
      var cancelled = false;
      var closed = false;
      final cleanup = finishCallCleanup(
        disconnect: () => media.future,
        cancelInvitation: () async => cancelled = true,
        close: () => closed = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(cancelled, isTrue);
      expect(closed, isFalse);
      media.completeError(TimeoutException('Teardown failed'));
      await cleanup;
      expect(closed, isTrue);
    },
  );
}
