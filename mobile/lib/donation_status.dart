// One status card keeps Home and Profile consistent without storing a second availability state.
import 'dart:async';
import 'package:flutter/material.dart';
import 'api.dart';
import 'ui.dart';

/// Displays willingness and the server's recovery deadline as one donation status.
///
/// A cooldown temporarily overrides availability without changing the member's
/// preference. [compact] moves infrequent actions into a sheet on the home page.
class DonationStatusCard extends StatefulWidget {
  final Json me;
  final ValueChanged<bool>? onAvailability;
  final VoidCallback? onRecord, onHistory;
  final bool compact;
  const DonationStatusCard({
    super.key,
    required this.me,
    this.onAvailability,
    this.onRecord,
    this.onHistory,
    this.compact = false,
  });

  @override
  State<DonationStatusCard> createState() => _DonationStatusCardState();
}

class _DonationStatusCardState extends State<DonationStatusCard>
    with WidgetsBindingObserver {
  Timer? timer;
  bool foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    scheduleTick();
  }

  @override
  void didUpdateWidget(covariant DonationStatusCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    scheduleTick();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) setState(() {});
    scheduleTick();
  }

  // Minute updates save battery; the final tick uses the exact server deadline, even below a minute.
  void scheduleTick() {
    timer?.cancel();
    final end = donationPauseEnd(widget.me);
    final remaining = end?.difference(DateTime.now().toUtc());
    if (!foreground || remaining == null || remaining <= Duration.zero) return;
    timer = Timer(
      remaining < const Duration(minutes: 1)
          ? remaining
          : const Duration(minutes: 1),
      () {
        if (!mounted) return;
        setState(() {});
        scheduleTick();
      },
    );
  }

  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Home keeps a small status control; infrequent actions and policy details stay one tap away.
  Future<void> showOptions() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Donation settings',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 16),
            DonationStatusCard(me: widget.me),
            if (widget.onAvailability != null) ...[
              const SizedBox(height: 8),
              SwitchListTile.adaptive(
                title: Text(
                  (donationPauseEnd(
                            widget.me,
                          )?.isAfter(DateTime.now().toUtc()) ??
                          false)
                      ? 'Available after cooldown'
                      : 'Willing to donate',
                ),
                value: widget.me['available'] == true,
                onChanged: (value) {
                  // Return to the live Home control while the server saves, avoiding a stale modal switch.
                  Navigator.pop(sheetContext);
                  widget.onAvailability!(value);
                },
              ),
            ],
            if (widget.onRecord != null)
              ListTile(
                leading: const Icon(Icons.volunteer_activism_outlined),
                title: const Text('Record donation'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onRecord!();
                },
              ),
            if (widget.onHistory != null)
              ListTile(
                leading: const Icon(Icons.history_rounded),
                title: const Text('Donation history'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.pop(sheetContext);
                  widget.onHistory!();
                },
              ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final end = donationPauseEnd(widget.me);
    final remaining = end?.difference(DateTime.now().toUtc());
    final cooling = remaining != null && remaining > Duration.zero;
    final willing = widget.me['available'] == true;
    final title = cooling
        ? 'In cooldown'
        : willing
        ? 'Available to donate'
        : 'Offline';
    final color = cooling
        ? const Color(0xFF805000)
        : willing
        ? const Color(0xFF206340)
        : muted;
    final icon = cooling
        ? Icons.hourglass_bottom_rounded
        : willing
        ? Icons.check_circle_outline_rounded
        : Icons.pause_circle_outline_rounded;
    final localEnd = end?.toLocal();
    final locale = MaterialLocalizations.of(context);
    if (widget.compact) {
      return Card(
        key: const Key('compact-donation-status'),
        color: cooling
            ? const Color(0xFFFFF4DF)
            : willing
            ? mint
            : const Color(0xFFEEF0F3),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: showOptions,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 64),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Icon(icon, color: color, size: 22),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  title,
                                  style: Theme.of(context).textTheme.titleSmall
                                      ?.copyWith(
                                        color: color,
                                        fontWeight: FontWeight.w700,
                                      ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  cooling
                                      ? donationTimeRemaining(remaining)
                                      : willing
                                      ? 'Visible to nearby seekers'
                                      : 'Switch on when you’re ready',
                                  style: const TextStyle(
                                    fontSize: 12,
                                    color: muted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              if (!cooling)
                Semantics(
                  label: 'Available to donate',
                  child: Switch.adaptive(
                    value: willing,
                    onChanged: widget.onAvailability,
                  ),
                ),
              IconButton(
                tooltip: 'Donation settings and history',
                onPressed: showOptions,
                icon: const Icon(Icons.expand_more_rounded),
              ),
            ],
          ),
        ),
      );
    }
    return Panel(
      color: cooling
          ? const Color(0xFFFFF4DF)
          : willing
          ? mint
          : const Color(0xFFEEF0F3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'YOUR DONATION STATUS',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: muted,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 28, color: color),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(color: color),
                ),
              ),
              const SizedBox(width: 8),
              BloodBadge(
                displayBlood(widget.me['blood_type']).isEmpty
                    ? '?'
                    : displayBlood(widget.me['blood_type']),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (cooling) ...[
            Text(
              donationTimeRemaining(remaining),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              'Pause ends ${locale.formatFullDate(localEnd!)} at ${locale.formatTimeOfDay(TimeOfDay.fromDateTime(localEnd))}.',
            ),
            const SizedBox(height: 8),
            Text(
              willing
                  ? 'No blood-request alerts during this pause. You’ll become available automatically when it ends.'
                  : 'No blood-request alerts during this pause. You’ll stay offline afterwards until you switch on.',
            ),
          ] else
            Text(
              willing
                  ? 'Nearby seekers can find you. You can take a break whenever you need.'
                  : 'You’re hidden from donor searches and won’t receive new blood requests.',
            ),
          if (widget.onAvailability != null) ...[
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                cooling ? 'Available after cooldown' : 'Willing to donate',
              ),
              subtitle: cooling
                  ? const Text('Changing this won’t end your recovery pause.')
                  : null,
              value: willing,
              onChanged: widget.onAvailability,
            ),
          ],
          if (widget.onRecord != null || widget.onHistory != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                if (widget.onRecord != null)
                  TextButton.icon(
                    onPressed: widget.onRecord,
                    icon: const Icon(Icons.volunteer_activism_outlined),
                    label: const Text('Record donation'),
                  ),
                if (widget.onHistory != null)
                  TextButton.icon(
                    onPressed: widget.onHistory,
                    icon: const Icon(Icons.history_rounded),
                    label: const Text('Donation history'),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Formats the recovery countdown, rounding up so an active pause never reads zero.
String donationTimeRemaining(Duration remaining) {
  if (remaining <= Duration.zero) return 'Cooldown complete';
  final minutes =
      (remaining.inMicroseconds / (Duration.microsecondsPerSecond * 60)).ceil();
  final days = minutes ~/ (24 * 60);
  final hours = (minutes ~/ 60) % 24;
  final rest = minutes % 60;
  final parts = <String>[
    if (days > 0) '$days ${days == 1 ? 'day' : 'days'}',
    if (hours > 0) '$hours ${hours == 1 ? 'hour' : 'hours'}',
    if (rest > 0) '$rest ${rest == 1 ? 'minute' : 'minutes'}',
  ];
  return '${parts.join(', ')} remaining';
}
