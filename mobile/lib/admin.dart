// Administrator workflows live outside member navigation so privileged evidence stays scoped.
import 'package:flutter/material.dart';
import 'api.dart';
import 'ui.dart';

/// Hosts regional moderation for administrator accounts on mobile and web.
///
/// Client role checks guide navigation; every privileged operation still requires
/// server authorization. No member workflow is exposed through this screen.
class AdminScreen extends StatefulWidget {
  final Api api;
  final Future<void> Function() onSignOut;
  const AdminScreen({super.key, required this.api, required this.onSignOut});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  List<Json> _countries = [];
  List<Json> _reports = [];
  Json? _summary;
  String? _error;
  bool _loading = true;
  bool _authorized = false;
  bool _denied = false;
  bool _showAll = false;
  bool _signingOut = false;

  // Load on entry rather than retaining moderation evidence between signed-in sessions.
  @override
  void initState() {
    super.initState();
    _load();
  }

  // Refresh clears previous evidence first, including after a country or role change.
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _reports = [];
      _summary = null;
    });
    try {
      if (!_authorized) {
        final profile = await widget.api.request('/me');
        if (profile['role'] != 'admin') {
          throw const ApiException(
            'Administrator access is required. Member accounts can use the mobile donation app.',
            statusCode: 403,
          );
        }
        // Resolve the account's active country before presenting its initial regional inbox.
        widget.api.country =
            profile['country']?.toString() ?? widget.api.country;
        _authorized = true;
      }
      final results = await Future.wait([
        widget.api.request('/countries'),
        widget.api.request('/admin/summary'),
        widget.api.request('/admin/reports'),
      ]);
      if (!mounted || _signingOut) return;
      setState(() {
        _countries = (results[0]['items'] as List)
            .map((item) => Json.from(item as Map))
            .toList();
        _summary = results[1];
        _reports = (results[2]['items'] as List)
            .map((item) => Json.from(item as Map))
            .toList();
        _denied = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _denied =
            error is ApiException &&
            (error.statusCode == 401 || error.statusCode == 403);
        if (_denied) _authorized = false;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Wait for sign-out so repeated taps cannot race session cleanup and navigation.
  Future<void> _signOut() async {
    setState(() {
      _signingOut = true;
      _reports = [];
      _summary = null;
    });
    try {
      await widget.onSignOut();
    } catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } finally {
      if (mounted) setState(() => _signingOut = false);
    }
  }

  // A dedicated route gives evidence a readable width and predictable native back navigation.
  Future<void> _openReport(Json report) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => _AdminReportScreen(api: widget.api, report: report),
      ),
    );
    if (mounted && !_signingOut) await _load();
  }

  // About explains the mission while showing the shared community signature once.
  void _about() => showAboutDialog(
    context: context,
    applicationName: 'Blood Connection',
    applicationVersion: 'Community care',
    applicationLegalese: attribution,
    children: [
      const SizedBox(height: 16),
      const Text('Connecting people through safe, voluntary blood donation.'),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final visible = _reports
        .where((report) => _showAll || report['status'] == 'pending')
        .toList();
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: const Padding(
          padding: EdgeInsets.all(12),
          child: BrandMark(size: 32),
        ),
        title: const Text('Admin'),
        actions: [
          IconButton(
            onPressed: _about,
            tooltip: 'About Blood Connection',
            icon: const Icon(Icons.info_outline),
          ),
          IconButton(
            onPressed: _signingOut ? null : _signOut,
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: PageBody(
          children: [
            if (widget.api.demo) ...[
              const Notice(
                'Local admin demo · Fictional accounts and reports',
                icon: Icons.science_outlined,
              ),
              const SizedBox(height: 24),
            ],
            Text(
              'COMMUNITY CARE',
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 10),
            Text(
              'A safer community.',
              style: Theme.of(context).textTheme.headlineLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Read with care. Protect every person who comes here to help.',
            ),
            const SizedBox(height: 24),
            if (_loading) ...[
              const LinearProgressIndicator(
                semanticsLabel: 'Loading admin reports',
              ),
              const SizedBox(height: 16),
              const Text('Loading your review inbox…'),
            ] else if (_error != null) ...[
              Semantics(liveRegion: true, child: ErrorPanel(_error!, _load)),
              if (_denied) ...[
                const SizedBox(height: 16),
                const Notice(
                  'Report evidence is available only to assigned administrators.',
                  icon: Icons.lock_outline,
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: _signingOut ? null : _signOut,
                  child: const Text('Sign out'),
                ),
              ],
            ] else if (_summary != null) ...[
              DropdownButtonFormField<String>(
                key: ValueKey(widget.api.country),
                initialValue:
                    _countries.any((item) => item['code'] == widget.api.country)
                    ? widget.api.country
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Review country'),
                items: _countries
                    .map(
                      (item) => DropdownMenuItem<String>(
                        value: item['code'] as String,
                        child: Text(
                          item['name'] as String,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (value) {
                  if (value == null || value == widget.api.country) return;
                  widget.api.country = value;
                  _load();
                },
              ),
              const SizedBox(height: 12),
              const Text(
                'Reports stay in their country. Confirmed money-request bans apply worldwide.',
              ),
              const SizedBox(height: 24),
              _AdminStats(summary: _summary!),
              const SizedBox(height: 28),
              Text(
                'Report inbox',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              const Text(
                'A report is a concern to review, not proof of misconduct.',
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilterChip(
                    label: const Text('Awaiting review'),
                    selected: !_showAll,
                    onSelected: (_) => setState(() => _showAll = false),
                  ),
                  FilterChip(
                    label: const Text('All reports'),
                    selected: _showAll,
                    onSelected: (_) => setState(() => _showAll = true),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              if (visible.isEmpty)
                const Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.task_alt_outlined, color: muted),
                      SizedBox(height: 12),
                      Text(
                        'A quieter inbox.',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'No reports in this view. Refresh to check for new concerns.',
                      ),
                    ],
                  ),
                ),
              for (final report in visible) ...[
                Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => _openReport(report),
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              Text(
                                _reason(report['reason']),
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              _StatusBadge(report['status'].toString()),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Text(
                            report['details']?.toString() ??
                                'No description provided.',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '${_date(report['created_at'])}  ·  Open report',
                            style: Theme.of(context).textTheme.labelLarge,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              OutlinedButton.icon(
                onPressed: _load,
                icon: const Icon(Icons.refresh),
                label: const Text('Refresh inbox'),
              ),
              const SizedBox(height: 20),
              const Notice(
                'Only report-scoped evidence is shown. Phone numbers are never collected.',
                icon: Icons.lock_outline,
              ),
            ],
            const SizedBox(height: 32),
            TextButton(
              onPressed: _about,
              child: const Text(attribution, textAlign: TextAlign.center),
            ),
          ],
        ),
      ),
    );
  }
}

// Stats stack on phones and with large text rather than compressing labels into unreadable rows.
class _AdminStats extends StatelessWidget {
  final Json summary;
  const _AdminStats({required this.summary});

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide =
          constraints.maxWidth >= 600 &&
          MediaQuery.textScalerOf(context).scale(14) <= 21;
      final width = wide
          ? (constraints.maxWidth - 24) / 3
          : constraints.maxWidth;
      final stats = [
        (
          'Awaiting review',
          summary['pending_reports'],
          'Reports in this country',
        ),
        (
          'Ready to help',
          summary['active_donors'],
          'Available donors in this country',
        ),
        (
          'Community protected',
          summary['banned_accounts'],
          'Lifetime bans worldwide',
        ),
      ];
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (var index = 0; index < stats.length; index++)
            SizedBox(
              width: width,
              child: Panel(
                color: index == 1 ? mint : null,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      stats[index].$1,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${stats[index].$2 ?? 0}',
                      style: Theme.of(context).textTheme.headlineLarge,
                    ),
                    const SizedBox(height: 4),
                    Text(stats[index].$3),
                  ],
                ),
              ),
            ),
        ],
      );
    },
  );
}

// Only explicit reason labels are interpreted; report bodies stay plain text.
String _reason(Object? value) => switch (value) {
  'money_request' => 'Request for money',
  'harassment' => 'Harassment',
  'misleading_information' => 'Misleading information',
  'no_show' => 'Missed meeting',
  _ => 'Other concern',
};

// Local calendar labels avoid exposing internal timestamp formats in moderation screens.
String _date(Object? value) {
  final date = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (date == null) return 'Date unavailable';
  return '${date.day}/${date.month}/${date.year}';
}

class _StatusBadge extends StatelessWidget {
  final String status;
  const _StatusBadge(this.status);

  // A written status accompanies its color so it remains clear with impaired color vision.
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
    decoration: BoxDecoration(
      color: status == 'pending' ? const Color(0xFFFFF1D2) : mint,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      switch (status) {
        'pending' => 'Pending',
        'banned' => 'Banned',
        _ => 'Reviewed',
      },
      style: const TextStyle(
        color: ink,
        fontSize: 12,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

// Keep a review's evidence and decision state scoped to one route, then reload the inbox on return.
class _AdminReportScreen extends StatefulWidget {
  final Api api;
  final Json report;
  const _AdminReportScreen({required this.api, required this.report});

  @override
  State<_AdminReportScreen> createState() => _AdminReportScreenState();
}

class _AdminReportScreenState extends State<_AdminReportScreen>
    with WidgetsBindingObserver {
  bool _busy = false;
  bool _denied = false;
  String? _error;
  String? _resolvedStatus;
  bool _foreground = true;

  // Backgrounding removes private image widgets, which evict their decoded bytes on disposal.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (mounted) {
      setState(() => _foreground = state == AppLifecycleState.resumed);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // A decision becomes actionable only after a concrete note and, for bans, evidence confirmation.
  Future<void> _review(bool ban) async {
    final note = await showDialog<String>(
      context: context,
      builder: (_) => _ReviewDialog(
        ban: ban,
        account: widget.report['reported_id'].toString(),
      ),
    );
    if (note == null || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.api.request(
        '/admin/reports/${Uri.encodeComponent(widget.report['id'].toString())}/resolve',
        method: 'POST',
        body: {'decision': ban ? 'ban' : 'dismiss', 'note': note},
      );
      if (!mounted) return;
      setState(
        () => _resolvedStatus =
            result['status']?.toString() ?? (ban ? 'banned' : 'dismissed'),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _denied =
            error is ApiException &&
            (error.statusCode == 401 || error.statusCode == 403);
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    final status = _resolvedStatus ?? report['status'].toString();
    final evidence = (report['evidence'] as List? ?? []).map(
      (entry) => Json.from(entry as Map),
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Review report')),
      body: SafeArea(
        child: PageBody(
          children: [
            if (!_foreground) ...[
              const Notice(
                'Report evidence is hidden while the app is in the background.',
                icon: Icons.lock_outline,
              ),
            ] else if (_denied) ...[
              Semantics(
                liveRegion: true,
                child: Notice(
                  _error ?? 'Administrator access is required.',
                  icon: Icons.lock_outline,
                ),
              ),
              const SizedBox(height: 16),
              OutlinedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Back to admin'),
              ),
            ] else ...[
              Align(
                alignment: Alignment.centerLeft,
                child: _StatusBadge(status),
              ),
              const SizedBox(height: 16),
              Text(
                _reason(report['reason']),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              Text('Received ${_date(report['created_at'])}'),
              const SizedBox(height: 24),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'The concern',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      report['details']?.toString() ??
                          'No description provided.',
                    ),
                    const Divider(height: 32),
                    const Text('Reported account'),
                    SelectableText(
                      report['reported_id']?.toString() ?? 'Unavailable',
                    ),
                    const SizedBox(height: 12),
                    const Text('Report reference'),
                    SelectableText(report['id'].toString()),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Conversation evidence',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (evidence.isEmpty)
                const Notice(
                  'No messages are attached. A report alone is not proof of misconduct.',
                  icon: Icons.info_outline,
                ),
              for (final message in evidence) ...[
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        message['sender_id'] == report['reported_id']
                            ? 'Reported account'
                            : 'Reporter',
                        style: Theme.of(context).textTheme.labelLarge,
                      ),
                      const SizedBox(height: 8),
                      SelectableText(message['body']?.toString() ?? ''),
                      const SizedBox(height: 12),
                      Text(_date(message['created_at'])),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if ((report['attachments'] as List? ?? []).isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(
                  'Submitted images',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Provided by the reporter. Review alongside the conversation; an image alone is not proof.',
                ),
                const SizedBox(height: 16),
                for (final entry in (report['attachments'] as List).take(
                  3,
                )) ...[
                  _PrivateReportImage(
                    key: ValueKey('admin-evidence-${entry['id']}'),
                    api: widget.api,
                    reportId: report['id'].toString(),
                    evidenceId: entry['id'].toString(),
                    onDenied: (error) {
                      if (mounted) {
                        setState(() {
                          _denied = true;
                          _error = error.toString();
                        });
                      }
                    },
                  ),
                  const SizedBox(height: 16),
                ],
              ],
              if (_error != null) ...[
                Semantics(
                  liveRegion: true,
                  child: Notice(_error!, icon: Icons.error_outline),
                ),
                const SizedBox(height: 16),
              ],
              if (_busy) ...[
                const LinearProgressIndicator(
                  semanticsLabel: 'Saving review decision',
                ),
                const SizedBox(height: 16),
              ],
              if (status == 'pending') ...[
                const Notice(
                  'Review the context carefully. A lifetime ban is available only for a confirmed request for money.',
                ),
                const SizedBox(height: 24),
                if (report['reason'] == 'money_request') ...[
                  FilledButton.icon(
                    onPressed: _busy ? null : () => _review(true),
                    icon: const Icon(Icons.gpp_bad_outlined),
                    label: const Text('Review lifetime ban'),
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton(
                  onPressed: _busy ? null : () => _review(false),
                  child: const Text('Dismiss report'),
                ),
              ] else
                Semantics(
                  liveRegion: true,
                  child: Notice(
                    status == 'banned'
                        ? 'Lifetime ban recorded. This account is blocked worldwide.'
                        : 'This report has been reviewed. The decision is recorded in the audit trail.',
                    icon: Icons.task_alt_outlined,
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

// Authenticated bytes stay in this route; there is no shared-file cache or token-bearing image URL.
class _PrivateReportImage extends StatefulWidget {
  final Api api;
  final String reportId, evidenceId;
  final ValueChanged<Object> onDenied;
  const _PrivateReportImage({
    super.key,
    required this.api,
    required this.reportId,
    required this.evidenceId,
    required this.onDenied,
  });

  @override
  State<_PrivateReportImage> createState() => _PrivateReportImageState();
}

class _PrivateReportImageState extends State<_PrivateReportImage>
    with WidgetsBindingObserver {
  MemoryImage? _image;
  String? _error;
  bool _loading = false;
  int _generation = 0;
  bool _active = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  // Invalidate pending fetches immediately; do not wait for the parent route's next layout frame.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    if (!_active) {
      _clear();
      if (mounted) setState(() => _loading = false);
    }
  }

  // Evict the exact provider, including live/pending decoded images, instead of flushing unrelated app images.
  void _clear() {
    ++_generation;
    final image = _image;
    _image = null;
    if (image != null) PaintingBinding.instance.imageCache.evict(image);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clear();
    super.dispose();
  }

  // Evidence opens only on demand; discard late results if its region or foreground lifetime changes.
  Future<void> _load() async {
    final generation = ++_generation;
    final country = widget.api.country;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final bytes = await widget.api.adminReportEvidence(
        widget.reportId,
        widget.evidenceId,
      );
      if (!mounted ||
          !_active ||
          generation != _generation ||
          widget.api.country != country) {
        return;
      }
      setState(() => _image = MemoryImage(bytes));
    } catch (error) {
      if (!mounted || generation != _generation) return;
      _clear();
      if (error is ApiException && [401, 403, 404].contains(error.statusCode)) {
        widget.onDenied(error);
      } else {
        setState(() => _error = error.toString());
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => Panel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_image != null) ...[
          SizedBox(
            height: 320,
            child: InteractiveViewer(
              minScale: 1,
              maxScale: 5,
              child: Image(
                key: ValueKey('admin-evidence-image-${widget.evidenceId}'),
                image: _image!,
                fit: BoxFit.contain,
                semanticLabel: 'Reporter-submitted evidence image',
                errorBuilder: (_, _, _) => const Notice(
                  'This image could not be decoded. Hide it and retry.',
                  icon: Icons.broken_image_outlined,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Pinch to inspect. This private preview is cleared when you leave or background the app.',
            style: TextStyle(fontSize: 12, color: muted),
          ),
          TextButton.icon(
            onPressed: () => setState(_clear),
            icon: const Icon(Icons.visibility_off_outlined),
            label: const Text('Hide image'),
          ),
        ] else ...[
          if (_error != null) Text(_error!, style: const TextStyle(color: red)),
          OutlinedButton.icon(
            onPressed: _loading ? null : _load,
            icon: _loading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.image_outlined),
            label: Text(
              _loading ? 'Loading private image…' : 'View attached image',
            ),
          ),
        ],
      ],
    ),
  );
}

class _ReviewDialog extends StatefulWidget {
  final bool ban;
  final String account;
  const _ReviewDialog({required this.ban, required this.account});

  @override
  State<_ReviewDialog> createState() => _ReviewDialogState();
}

class _ReviewDialogState extends State<_ReviewDialog> {
  final _form = GlobalKey<FormState>();
  final _note = TextEditingController();
  bool _confirmed = false;
  bool _missingConfirmation = false;

  // Clear the private review draft when the dialog closes rather than retaining it in UI state.
  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  // A lifetime ban requires both a review note and an explicit evidence acknowledgement.
  void _confirm() {
    final valid = _form.currentState!.validate();
    setState(() => _missingConfirmation = widget.ban && !_confirmed);
    if (valid && !_missingConfirmation) {
      Navigator.pop(context, _note.text.trim());
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    scrollable: true,
    title: Text(widget.ban ? 'Issue a lifetime ban?' : 'Dismiss this report?'),
    content: Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.ban
                ? 'Account ${widget.account} will permanently lose access in every country. This cannot be reversed in the app.'
                : 'Close this report without banning the account. Record the reason for your decision.',
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _note,
            autofocus: true,
            minLines: 3,
            maxLines: 6,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: 'Review note',
              hintText: 'Explain what the evidence shows.',
            ),
            validator: (value) => (value?.trim().length ?? 0) < 5
                ? 'Write at least 5 characters explaining your decision.'
                : null,
          ),
          if (widget.ban) ...[
            const SizedBox(height: 12),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _confirmed,
              onChanged: (value) => setState(() {
                _confirmed = value ?? false;
                _missingConfirmation = false;
              }),
              title: const Text(
                'I reviewed the evidence and confirmed a request for money.',
              ),
            ),
            if (_missingConfirmation)
              Semantics(
                liveRegion: true,
                child: Text(
                  'Confirm the evidence before issuing a lifetime ban.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ],
      ),
    ),
    actionsOverflowDirection: VerticalDirection.down,
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Keep reviewing'),
      ),
      FilledButton(
        onPressed: _confirm,
        child: Text(widget.ban ? 'Confirm lifetime ban' : 'Dismiss report'),
      ),
    ],
  );
}
