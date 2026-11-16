// Reports remain available after a match closes; evidence stays authenticated and private.
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'api.dart';
import 'ui.dart';

/// Opens the shared reporting flow for exactly one request or conversation context.
///
/// The server derives the reported participant from that context rather than
/// trusting a caller-supplied account identity.
Future<void> showReport(
  BuildContext context,
  Api api, {
  String? conversationId,
  String? requestId,
  String? peerName,
}) => Navigator.push<void>(
  context,
  MaterialPageRoute(
    builder: (_) => ReportScreen(
      api: api,
      conversationId: conversationId,
      requestId: requestId,
      peerName: peerName,
    ),
  ),
);

// Track acknowledgements per image so a partial upload can resume within the same private draft.
class _DraftEvidence {
  final String name;
  final Uint8List bytes;
  final MemoryImage image;
  bool uploaded = false;
  _DraftEvidence(this.name, this.bytes) : image = MemoryImage(bytes);

  // Decoded screenshots must not remain in Flutter's shared image cache after this private view closes.
  void evict() => unawaited(image.evict().catchError((_) => false));
}

/// Collects a report and up to three private evidence images for an existing interaction.
///
/// Exactly one of [conversationId] and [requestId] identifies the interaction.
/// A saved report remains valid even if an evidence upload must be retried.
class ReportScreen extends StatefulWidget {
  final Api api;
  final String? conversationId, requestId, peerName;
  final Future<List<XFile>> Function()? pickImages;
  const ReportScreen({
    super.key,
    required this.api,
    this.conversationId,
    this.requestId,
    this.peerName,
    this.pickImages,
  }) : assert((conversationId == null) != (requestId == null));
  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen>
    with WidgetsBindingObserver {
  final form = GlobalKey<FormState>();
  final details = TextEditingController();
  // Reuse across retries when the server may have saved a report whose acknowledgement was lost.
  final idempotencyKey = newSubmissionKey();
  final evidence = <_DraftEvidence>[];
  String reason = 'money_request';
  String? reportId, reportCountry, error;
  bool busy = false,
      completed = false,
      active = true,
      allowExit = false,
      leaving = false;
  bool get dirty =>
      details.text.isNotEmpty || evidence.isNotEmpty || reportId != null;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    details.dispose();
    for (final item in evidence) {
      item.evict();
    }
    super.dispose();
  }

  // Hide previews while backgrounded, but retain unsent bytes in this draft so a picker round-trip loses nothing.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    setState(() => active = state == AppLifecycleState.resumed);
    if (!active) {
      for (final item in evidence) {
        item.evict();
      }
    }
  }

  // Back navigation requires an explicit decision before discarding unsent text or remaining evidence.
  Future<void> leave() async {
    if (busy || leaving) return;
    leaving = true;
    var approved = completed || !dirty;
    if (!approved) {
      approved =
          await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              scrollable: true,
              title: Text(
                reportId == null
                    ? 'Discard this draft?'
                    : 'Leave without remaining images?',
              ),
              content: Text(
                reportId == null
                    ? 'Your report has not been acknowledged. Keep this screen open to finish or retry it.'
                    : 'Your report is saved, but some images are not attached. You can stay and retry the upload.',
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Keep editing'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(
                    reportId == null ? 'Discard draft' : 'Leave report saved',
                  ),
                ),
              ],
            ),
          ) ??
          false;
    }
    leaving = false;
    if (approved && mounted) {
      setState(() => allowExit = true);
      Navigator.pop(context);
    }
  }

  // The system picker grants access only to selected images; originals are kept unchanged across upload retries.
  Future<void> attach() async {
    if (busy || completed || evidence.length >= 3) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final picked = widget.pickImages != null
          ? await widget.pickImages!()
          : await ImagePicker().pickMultiImage(
              limit: 3 - evidence.length,
              maxWidth: 2048,
              maxHeight: 2048,
              imageQuality: 85,
              requestFullMetadata: false,
            );
      if (picked.length + evidence.length > 3) {
        throw const ApiException('Choose no more than three images.');
      }
      final additions = <_DraftEvidence>[];
      for (final file in picked) {
        if (await file.length() > 5 * 1024 * 1024) {
          throw const ApiException('Choose images no larger than 5 MB.');
        }
        final bytes = await file.readAsBytes();
        privateImageType(bytes);
        additions.add(_DraftEvidence(file.name, bytes));
      }
      if (mounted) setState(() => evidence.addAll(additions));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // Once the report is acknowledged, retries upload only unfinished evidence to that same report.
  Future<void> submit() async {
    if (busy || completed || !form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (reportId == null) {
        final submissionCountry = widget.api.country;
        final created = await widget.api.request(
          '/reports',
          method: 'POST',
          body: {
            if (widget.requestId != null) 'request_id': widget.requestId,
            if (widget.conversationId != null)
              'conversation_id': widget.conversationId,
            'reason': reason,
            'details': details.text.trim(),
            'idempotency_key': idempotencyKey,
          },
        );
        final id = created['id'];
        if (id is! String || id.isEmpty) {
          throw const ApiException(
            'The report acknowledgement was incomplete. Retry to check the same submission.',
          );
        }
        if (!mounted) return;
        setState(() {
          reportId = id;
          reportCountry = submissionCountry;
        });
      }
      for (final item in evidence.where((item) => !item.uploaded)) {
        final uploaded = await widget.api.uploadReportEvidence(
          reportId!,
          item.bytes,
        );
        if (uploaded['id'] == null) {
          throw const ApiException(
            'An image upload was not acknowledged. Please retry.',
          );
        }
        if (!mounted) return;
        setState(() => item.uploaded = true);
      }
      if (mounted) setState(() => completed = true);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: allowExit || (!busy && (completed || !dirty)),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) unawaited(leave());
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Report a concern'),
        leading: IconButton(
          tooltip: 'Back',
          onPressed: busy ? null : leave,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Form(
          key: form,
          child: PageBody(
            children: [
              Text(
                widget.peerName == null
                    ? 'Tell us what happened.'
                    : 'Report ${widget.peerName}',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Reports and attached images are private to you and authorized moderators. Confirmed requests for money lead to a lifetime ban after review.',
              ),
              const SizedBox(height: 24),
              if (reportId != null) ...[
                Notice(
                  completed
                      ? 'Report received. ${evidence.isEmpty ? 'An administrator will review it.' : 'All ${evidence.length} image${evidence.length == 1 ? '' : 's'} attached.'}'
                      : 'Report saved. ${evidence.where((item) => item.uploaded).length} of ${evidence.length} images attached. You can retry the remaining uploads.',
                  icon: completed
                      ? Icons.check_circle_outline
                      : Icons.cloud_done_outlined,
                ),
                const SizedBox(height: 20),
              ],
              DropdownButtonFormField<String>(
                key: const Key('report-reason'),
                initialValue: reason,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Reason'),
                items: const [
                  DropdownMenuItem(
                    value: 'money_request',
                    child: Text(
                      'Asked for money',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'harassment',
                    child: Text('Harassment', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem(
                    value: 'misleading_information',
                    child: Text(
                      'Misleading information',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'no_show',
                    child: Text(
                      'Did not show up',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem(
                    value: 'other',
                    child: Text(
                      'Something else',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: busy || reportId != null
                    ? null
                    : (value) => setState(() => reason = value!),
              ),
              const SizedBox(height: 20),
              TextFormField(
                key: const Key('report-details'),
                controller: details,
                enabled: !busy && reportId == null,
                minLines: 3,
                maxLines: 6,
                maxLength: 2000,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(
                  labelText: 'What happened?',
                  hintText: 'Add details that help a moderator review this',
                ),
                onChanged: (_) => setState(() {}),
                validator: (value) => (value?.trim().length ?? 0) < 5
                    ? 'Add at least five characters.'
                    : null,
              ),
              const SizedBox(height: 16),
              Text(
                'Images · ${evidence.length}/3',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'Optional photos or screenshots, JPEG or PNG up to 5 MB each. Include only what helps this report.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              const SizedBox(height: 12),
              for (var index = 0; index < evidence.length; index++) ...[
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (active)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image(
                            image: evidence[index].image,
                            height: 140,
                            fit: BoxFit.contain,
                            errorBuilder: (_, _, _) => const SizedBox(
                              height: 80,
                              child: Center(
                                child: Icon(Icons.image_not_supported_outlined),
                              ),
                            ),
                          ),
                        )
                      else
                        const SizedBox(
                          height: 80,
                          child: Center(child: Icon(Icons.lock_outline)),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        evidence[index].name,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (evidence[index].uploaded)
                        const Text(
                          'Attached',
                          style: TextStyle(color: Color(0xFF285B45)),
                        )
                      else
                        TextButton.icon(
                          key: ValueKey('remove-evidence-$index'),
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  evidence.removeAt(index).evict();
                                }),
                          icon: const Icon(Icons.close),
                          label: const Text('Remove image'),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              if (!completed && evidence.length < 3)
                OutlinedButton.icon(
                  key: const Key('add-report-evidence'),
                  onPressed: busy ? null : attach,
                  icon: const Icon(Icons.add_photo_alternate_outlined),
                  label: const Text('Add photos or screenshots'),
                ),
              if (error != null) ...[
                const SizedBox(height: 16),
                Text(
                  error!,
                  key: const Key('report-error'),
                  style: const TextStyle(color: red),
                ),
              ],
              const SizedBox(height: 24),
              if (!completed)
                FilledButton.icon(
                  key: const Key('submit-report'),
                  onPressed: busy ? null : submit,
                  icon: busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.flag_outlined),
                  label: Text(
                    busy
                        ? 'Saving…'
                        : reportId == null
                        ? 'Submit report'
                        : 'Retry remaining uploads',
                  ),
                ),
              if (reportId != null) ...[
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  key: const Key('view-report-status'),
                  onPressed: busy
                      ? null
                      : () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ReportDetailScreen(
                              api: widget.api,
                              reportId: reportId!,
                              reportCountry: reportCountry!,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.fact_check_outlined),
                  label: const Text('View status'),
                ),
                TextButton(
                  key: const Key('finish-report'),
                  onPressed: busy ? null : leave,
                  child: Text(completed ? 'Done' : 'Leave report saved'),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// Labels the reporter-visible outcome without reading internal moderator notes.
String reportStatusLabel(Json report) => report['status'] != 'reviewed'
    ? 'Awaiting review'
    : report['outcome'] == 'banned'
    ? 'Reviewed · action taken'
    : 'Reviewed · closed';

/// Maps known reason codes to member-facing copy, with a safe label for other values.
String reportReasonLabel(Object? reason) => switch (reason) {
  'money_request' => 'Asked for money',
  'harassment' => 'Harassment',
  'misleading_information' => 'Misleading information',
  'no_show' => 'Did not show up',
  _ => 'Other concern',
};

/// Formats a review timestamp in device-local time with an explicit calendar date.
String reportTime(BuildContext context, Object? value) {
  final parsed = DateTime.tryParse(value?.toString() ?? '')?.toLocal();
  if (parsed == null) return 'Not yet available';
  return '${shortDate(parsed.toIso8601String())} · ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(parsed))}';
}

/// Shows only the signed-in reporter's submissions, including reports from prior countries.
class MyReportsScreen extends StatefulWidget {
  final Api api;
  const MyReportsScreen({super.key, required this.api});
  @override
  State<MyReportsScreen> createState() => _MyReportsScreenState();
}

class _MyReportsScreenState extends State<MyReportsScreen>
    with WidgetsBindingObserver {
  List<Json>? reports;
  String? error;
  Timer? timer;
  bool active = true, loading = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 20), (_) => load());
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Clear private descriptions while backgrounded and reject any response started before that boundary.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (!active) {
      generation++;
      loading = false;
      setState(() => reports = null);
    } else {
      load();
    }
  }

  // The server collects only this reporter's records across regions; the active search country is untouched.
  Future<void> load() async {
    if (loading || !active) return;
    loading = true;
    final epoch = ++generation;
    try {
      final result = await widget.api.list('/reports');
      if (mounted && epoch == generation) {
        setState(() {
          reports = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && epoch == generation) {
        setState(() {
          reports = null;
          error = e.toString();
        });
      }
    } finally {
      if (epoch == generation) loading = false;
    }
  }

  Future<void> open(Json report) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => ReportDetailScreen(
          api: widget.api,
          reportId: report['id'].toString(),
          reportCountry: report['country'].toString(),
        ),
      ),
    );
    if (mounted) await load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('My reports'),
      actions: [
        IconButton(
          tooltip: 'Refresh reports',
          onPressed: load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: SafeArea(
      child: PageBody(
        children: [
          const Notice(
            'These are the reports you submitted. Your descriptions, evidence and review updates stay private to you and authorized moderators.',
            icon: Icons.lock_outline,
          ),
          const SizedBox(height: 24),
          if (error != null) ErrorPanel(error!, load),
          if (reports == null && error == null)
            const Center(child: CircularProgressIndicator()),
          if (reports?.isEmpty == true)
            const Text(
              'You have not submitted a report yet. You can report a concern from a matched request or conversation.',
            ),
          for (final report in reports ?? <Json>[]) ...[
            Panel(
              key: ValueKey('report-card-${report['country']}-${report['id']}'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    reportReasonLabel(report['reason']),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    reportStatusLabel(report),
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      color: red,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Submitted ${reportTime(context, report['submitted_at'])}',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: () => open(report),
                    child: const Text('View report'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    ),
  );
}

/// Displays one owned report using its original country independently of search location.
///
/// Protected descriptions and evidence are removed on backgrounding and fetched
/// again on resume so stale results cannot restore content across that boundary.
class ReportDetailScreen extends StatefulWidget {
  final Api api;
  final String reportId, reportCountry;
  const ReportDetailScreen({
    super.key,
    required this.api,
    required this.reportId,
    required this.reportCountry,
  });
  @override
  State<ReportDetailScreen> createState() => _ReportDetailScreenState();
}

class _ReportDetailScreenState extends State<ReportDetailScreen>
    with WidgetsBindingObserver {
  Json? report;
  String? error;
  Timer? timer;
  bool active = true, loading = false;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 10), (_) => load());
  }

  @override
  void dispose() {
    generation++;
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(ReportDetailScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.reportId != widget.reportId ||
        oldWidget.reportCountry != widget.reportCountry) {
      generation++;
      loading = false;
      report = null;
      load();
    }
  }

  // Backgrounding removes protected content; resume fetches it through the authenticated API again.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (!active) {
      generation++;
      loading = false;
      setState(() => report = null);
    } else {
      load();
    }
  }

  // Carry the report's country as a query rather than mutating the user's current search region.
  Future<void> load() async {
    if (loading || !active) return;
    loading = true;
    final epoch = ++generation;
    try {
      final result = await widget.api.request(
        '/reports/${Uri.encodeComponent(widget.reportId)}',
        query: {'country': widget.reportCountry},
      );
      if (mounted && epoch == generation) {
        setState(() {
          report = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted && epoch == generation) {
        setState(() {
          report = null;
          error = e.toString();
        });
      }
    } finally {
      if (epoch == generation) loading = false;
    }
  }

  // This timeline uses submitted/reviewed timestamps and the explicitly public explanation only.
  Widget timelineRow(IconData icon, String title, String detail) => Padding(
    padding: const EdgeInsets.only(bottom: 20),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: red),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 4),
              Text(detail),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final item = report;
    final attachments = item?['attachments'] as List? ?? [];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report status'),
        actions: [
          IconButton(
            tooltip: 'Refresh report status',
            onPressed: load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: PageBody(
          children: [
            if (error != null) ErrorPanel(error!, load),
            if (item == null && error == null)
              const Center(child: CircularProgressIndicator()),
            if (item != null) ...[
              Text(
                reportStatusLabel(item),
                key: const Key('owner-report-status'),
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              const Text(
                'Only you and authorized moderators can view this report. Review updates contain a public outcome, never private moderator notes.',
              ),
              const SizedBox(height: 24),
              Panel(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Timeline',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 20),
                    timelineRow(
                      Icons.flag_outlined,
                      'Submitted',
                      reportTime(context, item['submitted_at']),
                    ),
                    timelineRow(
                      item['status'] == 'reviewed'
                          ? Icons.fact_check_outlined
                          : Icons.hourglass_top,
                      item['status'] == 'reviewed'
                          ? 'Reviewed'
                          : 'Awaiting review',
                      item['status'] == 'reviewed'
                          ? reportTime(context, item['reviewed_at'])
                          : 'An authorized moderator will review the information you supplied.',
                    ),
                    if (item['outcome_explanation'] is String &&
                        (item['outcome_explanation'] as String).isNotEmpty)
                      Text(
                        item['outcome_explanation'],
                        key: const Key('report-public-explanation'),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              Text(
                'Your report',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(
                reportReasonLabel(item['reason']),
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              SelectableText(item['details']?.toString() ?? ''),
              const SizedBox(height: 24),
              Text(
                'Your evidence',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (attachments.isEmpty) const Text('No images were attached.'),
              for (final attachment in attachments.take(3)) ...[
                Panel(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _PrivateReportImage(
                        api: widget.api,
                        reportId: widget.reportId,
                        reportCountry: widget.reportCountry,
                        evidenceId: attachment['id'].toString(),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push<void>(
                          context,
                          MaterialPageRoute(
                            builder: (_) => Scaffold(
                              appBar: AppBar(
                                title: const Text('Private evidence'),
                              ),
                              body: SafeArea(
                                child: _PrivateReportImage(
                                  api: widget.api,
                                  reportId: widget.reportId,
                                  reportCountry: widget.reportCountry,
                                  evidenceId: attachment['id'].toString(),
                                  fullScreen: true,
                                ),
                              ),
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.zoom_in),
                        label: const Text('View image'),
                      ),
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
}

// Each evidence view rechecks owner authorization and keeps decoded image data out of persistent storage.
class _PrivateReportImage extends StatefulWidget {
  final Api api;
  final String reportId, reportCountry, evidenceId;
  final bool fullScreen;
  const _PrivateReportImage({
    required this.api,
    required this.reportId,
    required this.reportCountry,
    required this.evidenceId,
    this.fullScreen = false,
  });
  @override
  State<_PrivateReportImage> createState() => _PrivateReportImageState();
}

class _PrivateReportImageState extends State<_PrivateReportImage>
    with WidgetsBindingObserver {
  MemoryImage? image;
  String? error;
  bool active = true;
  int generation = 0;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
  }

  @override
  void dispose() {
    generation++;
    clear();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didUpdateWidget(_PrivateReportImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.api != widget.api ||
        oldWidget.reportId != widget.reportId ||
        oldWidget.evidenceId != widget.evidenceId ||
        oldWidget.reportCountry != widget.reportCountry) {
      generation++;
      clear();
      load();
    }
  }

  // Remove both the widget reference and Flutter's decoded-image cache entry on every privacy boundary.
  void clear() {
    if (image != null) unawaited(image!.evict().catchError((_) => false));
    image = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (!active) {
      generation++;
      clear();
      setState(() {});
    } else {
      load();
    }
  }

  // A later route, account or lifecycle change invalidates these bytes even if the fetch succeeds.
  Future<void> load() async {
    final epoch = ++generation;
    clear();
    if (!active) return;
    try {
      final bytes = await widget.api.reportEvidence(
        widget.reportId,
        widget.evidenceId,
        country: widget.reportCountry,
      );
      if (mounted && active && epoch == generation) {
        setState(() {
          image = MemoryImage(bytes);
          error = null;
        });
      }
    } catch (e) {
      if (mounted && epoch == generation) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!active) {
      return const SizedBox(
        height: 80,
        child: Center(child: Icon(Icons.lock_outline)),
      );
    }
    if (error != null) return ErrorPanel(error!, load);
    if (image == null) {
      return const SizedBox(
        height: 120,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final content = Image(
      image: image!,
      fit: BoxFit.contain,
      errorBuilder: (_, _, _) =>
          const Center(child: Text('This image cannot be displayed.')),
    );
    return widget.fullScreen
        ? InteractiveViewer(
            minScale: .5,
            maxScale: 6,
            child: Center(child: content),
          )
        : SizedBox(height: 220, child: content);
  }
}
