// Either matched participant may confirm what happened; the log and pause always belong to the donor.
import 'package:flutter/material.dart';
import 'api.dart';
import 'ui.dart';

/// Opens the shared recorder and returns the server-updated caller profile on save.
///
/// [confirmation] associates the record with a completed match; without it, the
/// member records their own donation. Cancellation returns null.
Future<Json?> showDonationRecorder(
  BuildContext context,
  Api api,
  Json me, {
  Json? confirmation,
}) async {
  final saved = await Navigator.push<Json>(
    context,
    MaterialPageRoute(
      builder: (_) =>
          DonationRecorderScreen(api: api, me: me, confirmation: confirmation),
    ),
  );
  if (saved != null && context.mounted) {
    feedback(
      context,
      confirmation?['is_donor'] == false
          ? 'Donation confirmed. The donor’s record and recovery pause are updated.'
          : 'Donation saved. Your private history and donation pause are updated.',
    );
  }
  return saved;
}

/// Asks either matched participant whether a donation occurred before recording it.
///
/// Later leaves the reminder pending; No dismisses only this caller's reminder.
/// A Yes still requires checking the date and place in the recorder.
Future<Json?> showDonationConfirmation(
  BuildContext context,
  Api api,
  Json me,
  Json pending,
) async {
  final record = await showDialog<bool>(
    context: context,
    builder: (_) => _DonationConfirmationDialog(api: api, pending: pending),
  );
  if (record != true || !context.mounted) return null;
  return showDonationRecorder(context, api, me, confirmation: pending);
}

class _DonationConfirmationDialog extends StatefulWidget {
  final Api api;
  final Json pending;
  const _DonationConfirmationDialog({required this.api, required this.pending});
  @override
  State<_DonationConfirmationDialog> createState() =>
      _DonationConfirmationDialogState();
}

class _DonationConfirmationDialogState
    extends State<_DonationConfirmationDialog> {
  bool busy = false;
  String? error;

  // Keep failures visible and the prompt recoverable instead of claiming a dismissal before it saves.
  Future<void> dismiss() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.request(
        '/donation-confirmations/${widget.pending['request_id']}/dismiss',
        method: 'POST',
        body: {},
      );
      if (mounted) Navigator.pop(context, false);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      scrollable: true,
      title: Text(
        widget.pending['is_donor'] == false
            ? 'Did the donor give blood?'
            : 'Did you donate blood?',
      ),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.pending['is_donor'] == false
                ? 'Your match was marked complete. You or the donor can confirm whether the donation happened.'
                : 'Your match was marked complete. You or the seeker can confirm whether your donation happened.',
          ),
          if (widget.pending['is_donor'] == false &&
              widget.pending['donor_name'] != null) ...[
            const SizedBox(height: 12),
            Text(
              'Donor: ${widget.pending['donor_name']}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
          if (widget.pending['facility_name'] != null) ...[
            const SizedBox(height: 12),
            Text(
              widget.pending['facility_name'].toString(),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            widget.pending['is_donor'] == false
                ? 'If yes, check the date and place. Saving updates the donor’s private record and pauses their donation availability for three calendar months. Your account is not paused.'
                : 'If yes, check the date and place before saving. This updates your private record and pauses donor requests for three calendar months.',
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: const TextStyle(color: red)),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('confirm-donation-later'),
          onPressed: busy ? null : () => Navigator.pop(context, false),
          child: const Text('Later'),
        ),
        TextButton(
          key: const Key('confirm-donation-no'),
          onPressed: busy ? null : dismiss,
          child: Text(busy ? 'Saving…' : 'No donation'),
        ),
        FilledButton(
          key: const Key('confirm-donation-yes'),
          onPressed: busy ? null : () => Navigator.pop(context, true),
          child: const Text('Yes, record'),
        ),
      ],
    ),
  );
}

/// Collects the date and facility for a personal or matched donation record.
///
/// The server resolves the donor from [confirmation], so a seeker can confirm
/// without accidentally pausing their own account.
class DonationRecorderScreen extends StatefulWidget {
  final Api api;
  final Json me;
  final Json? confirmation;
  const DonationRecorderScreen({
    super.key,
    required this.api,
    required this.me,
    this.confirmation,
  });
  @override
  State<DonationRecorderScreen> createState() => _DonationRecorderScreenState();
}

class _DonationRecorderScreenState extends State<DonationRecorderScreen> {
  final form = GlobalKey<FormState>();
  // Keep the key for this draft: a lost acknowledgement must not create another donation on retry.
  final idempotencyKey = newSubmissionKey();
  late final TextEditingController facility, area;
  DateTime date = DateUtils.dateOnly(DateTime.now());
  List<Json> countries = [];
  String? country, error, countryError;
  bool busy = false;

  @override
  void initState() {
    super.initState();
    facility = TextEditingController(
      text: widget.confirmation?['facility_name']?.toString() ?? '',
    );
    // The donor's current city is not evidence of where this donation took place.
    area = TextEditingController(
      text: widget.confirmation?['location_name']?.toString() ?? '',
    );
    country = (widget.confirmation?['country'] ?? widget.me['country'])
        ?.toString();
    if (country?.isEmpty == true) country = null;
    loadCountries();
  }

  @override
  void dispose() {
    facility.dispose();
    area.dispose();
    super.dispose();
  }

  // A saved profile country remains usable if the optional country-name lookup temporarily fails.
  Future<void> loadCountries() async {
    try {
      final result = await widget.api.list('/countries');
      if (mounted) {
        setState(() {
          countries = result;
          countryError = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => countryError = e.toString());
    }
  }

  String? requiredPlace(String? value) {
    final text = value?.trim() ?? '';
    return text.length < 2 || text.length > 160
        ? 'Enter 2–160 characters.'
        : null;
  }

  // Calendar dates are submitted with the device's offset so midnight near the date line is valid.
  Future<void> chooseDate() async {
    final now = DateUtils.dateOnly(DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: date.isAfter(now) ? now : date,
      firstDate: DateTime(1900),
      lastDate: now,
      helpText: 'When did you donate blood?',
    );
    if (picked != null && mounted) setState(() => date = picked);
  }

  // Server confirmation is the only success boundary; an error leaves every field intact for retry.
  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final saved = await widget.api.request(
        '/donations',
        method: 'POST',
        body: {
          'idempotency_key': idempotencyKey,
          'donated_at': shortDate(date.toIso8601String()),
          'utc_offset_minutes': DateTime.now().timeZoneOffset.inMinutes,
          'facility_name': facility.text.trim(),
          'location_name': area.text.trim(),
          'country': country,
          if (widget.confirmation != null)
            'request_id': widget.confirmation!['request_id'],
        },
      );
      if (mounted) Navigator.pop(context, saved);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final forDonor = widget.confirmation?['is_donor'] == false;
    final donorName =
        widget.confirmation?['donor_name']?.toString() ?? 'the donor';
    final choices = <Json>[
      ...countries,
      if (country != null && !countries.any((item) => item['code'] == country))
        {'code': country, 'name': country},
    ];
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        key: const Key('donation-recorder'),
        appBar: AppBar(
          title: Text(forDonor ? 'Confirm a donation' : 'Record a donation'),
        ),
        body: SafeArea(
          child: Form(
            key: form,
            child: PageBody(
              children: [
                Text(
                  forDonor
                      ? 'Confirm what happened.'
                      : 'A little care, remembered.',
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 12),
                Text(
                  forDonor
                      ? 'Confirm the date and place of $donorName’s donation. It goes into their private log, with a summary in your matched request.'
                      : 'This log is private. Record only blood you actually donated, with the date and place it happened.',
                ),
                const SizedBox(height: 24),
                OutlinedButton.icon(
                  key: const Key('donation-date'),
                  onPressed: busy ? null : chooseDate,
                  icon: const Icon(Icons.calendar_today_outlined),
                  label: Text(
                    'Donation date: ${MaterialLocalizations.of(context).formatMediumDate(date)}',
                  ),
                ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const Key('donation-facility'),
                  controller: facility,
                  enabled: !busy,
                  maxLength: 160,
                  textCapitalization: TextCapitalization.words,
                  validator: requiredPlace,
                  decoration: const InputDecoration(
                    labelText: 'Hospital or blood bank',
                    hintText: 'Where you donated',
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  key: const Key('donation-location'),
                  controller: area,
                  enabled: !busy,
                  maxLength: 160,
                  textCapitalization: TextCapitalization.words,
                  validator: requiredPlace,
                  decoration: const InputDecoration(
                    labelText: 'Area or city',
                    hintText: 'Where this donation took place',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  key: const Key('donation-country'),
                  initialValue: country,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Donation country',
                  ),
                  items: choices
                      .map(
                        (item) => DropdownMenuItem<String>(
                          value: item['code'].toString(),
                          child: Text(
                            item['name'].toString(),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(),
                  onChanged: busy
                      ? null
                      : (value) => setState(() => country = value),
                  validator: (value) => value == null
                      ? 'Choose the country where you donated.'
                      : null,
                ),
                const SizedBox(height: 8),
                const Text(
                  'This is the donation location. It does not change your current search area.',
                  style: TextStyle(fontSize: 12, color: muted),
                ),
                if (countryError != null)
                  TextButton(
                    onPressed: loadCountries,
                    child: const Text('Retry country list'),
                  ),
                const SizedBox(height: 24),
                Notice(
                  forDonor
                      ? 'Saving starts a three-calendar-month recovery pause for the donor from this date. It does not pause your account or add this donation to your own history. Confirm only a donation that actually happened.'
                      : 'Saving starts a three-calendar-month donation pause from this date. You will be hidden from donor searches and receive no blood-request alerts during that pause. Your willingness setting is kept. Your blood bank may require a longer wait.',
                  icon: Icons.event_available_outlined,
                ),
                if (error != null) ...[
                  const SizedBox(height: 16),
                  Text(error!, style: const TextStyle(color: red)),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  key: const Key('save-donation'),
                  onPressed: busy ? null : save,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check),
                  label: Text(
                    busy
                        ? 'Saving donation…'
                        : forDonor
                        ? 'Confirm donation'
                        : 'Save my donation',
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows the signed-in member's private donation history and unresolved reminders.
///
/// [onSaved] lets the parent refresh availability from the acknowledged profile.
class DonationHistoryScreen extends StatefulWidget {
  final Api api;
  final Json me;
  final ValueChanged<Json>? onSaved;
  const DonationHistoryScreen({
    super.key,
    required this.api,
    required this.me,
    this.onSaved,
  });
  @override
  State<DonationHistoryScreen> createState() => _DonationHistoryScreenState();
}

class _DonationHistoryScreenState extends State<DonationHistoryScreen> {
  late Json me;
  List<Json> records = [], pending = [];
  bool loading = true, acting = false;
  String? error;
  @override
  void initState() {
    super.initState();
    me = widget.me;
    load();
  }

  // Both collections are owner-only, including records made before the account changed country.
  Future<void> load() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final result = await Future.wait([
        widget.api.list('/donations'),
        widget.api.list('/donation-confirmations'),
      ]);
      if (mounted) {
        setState(() {
          records = result[0];
          pending = result[1];
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          records = [];
          pending = [];
          error = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  // A Later choice stays in this list; a successful record refreshes both the status and history.
  Future<void> record({Json? confirmation}) async {
    setState(() => acting = true);
    final saved = confirmation == null
        ? await showDonationRecorder(context, widget.api, me)
        : await showDonationConfirmation(context, widget.api, me, confirmation);
    if (!mounted) return;
    if (saved != null) {
      me = saved;
      widget.onSaved?.call(saved);
    }
    setState(() => acting = false);
    await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('My donation history'),
      actions: [
        IconButton(
          tooltip: 'Refresh donation history',
          onPressed: loading || acting ? null : load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: PageBody(
        children: [
          const Notice(
            'Only you can see these donation records. For matched requests, either participant can confirm what happened; only the actual donor receives the donation record.',
            icon: Icons.lock_outline,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: loading || acting ? null : () => record(),
            icon: const Icon(Icons.add),
            label: const Text('Record a donation'),
          ),
          const SizedBox(height: 24),
          if (loading) const Center(child: CircularProgressIndicator()),
          if (error != null) ErrorPanel(error!, load),
          if (!loading && error == null) ...[
            if (pending.isNotEmpty) ...[
              Text('To confirm', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              for (final item in pending) ...[
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        item['facility_name']?.toString() ??
                            'Completed request',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Did a donation happen? You can confirm it now or leave it for later.',
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton(
                        key: ValueKey(
                          'donation-confirmation-${item['request_id']}',
                        ),
                        onPressed: acting
                            ? null
                            : () => record(confirmation: item),
                        child: const Text('Review donation'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ],
            Text(
              'Your donations',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            if (records.isEmpty)
              const Text('Your recorded donations will appear here.'),
            for (final item in records) ...[
              Panel(
                key: ValueKey('donation-record-${item['id']}'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      shortDate(item['donated_at']),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      item['facility_name']?.toString() ??
                          'Facility not recorded',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item['location_name']?.toString() ??
                          'Location not recorded',
                    ),
                    if (item['country'] != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        item['country'].toString(),
                        style: const TextStyle(color: muted),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],
          ],
        ],
      ),
    ),
  );
}
