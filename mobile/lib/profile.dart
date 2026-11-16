// Owner-only health measurements stay separate from discovery and country-routing updates.
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'api.dart';
import 'ui.dart';
import 'private_photo.dart';
import 'package:image_picker/image_picker.dart';
import 'notifications.dart';
import 'donations.dart';
import 'donation_status.dart';
import 'measurements.dart';
import 'reports.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

// Only owner-editable fields are submitted; location values must match the latest server profile.
Json profileBody(Json me) => {
  for (final key in [
    'display_name',
    'blood_type',
    'height_cm',
    'weight_kg',
    'city',
    'latitude',
    'longitude',
    'available',
  ])
    key: me[key],
};

class ProfileScreen extends StatefulWidget {
  final Api api;
  final Json me;
  final ValueChanged<Json> onSaved;
  final Future<void> Function() onSignOut, onLocation;
  const ProfileScreen({
    super.key,
    required this.api,
    required this.me,
    required this.onSaved,
    required this.onSignOut,
    required this.onLocation,
  });
  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final form = GlobalKey<FormState>();
  late final TextEditingController name;
  double? heightCm, weightKg;
  String heightUnit = 'cm', weightUnit = 'kg';
  bool loadingUnits = true;
  static const unitStorage = FlutterSecureStorage();
  String? blood, error;
  bool busy = false;
  int photoVersion = 0;
  @override
  void initState() {
    super.initState();
    name = TextEditingController(
      text: widget.me['display_name']?.toString() ?? '',
    );
    heightCm = (widget.me['height_cm'] as num?)?.toDouble();
    weightKg = (widget.me['weight_kg'] as num?)?.toDouble();
    loadUnits();
    blood = displayBlood(widget.me['blood_type']);
    if (!bloodGroups.contains(blood)) blood = null;
  }

  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  // Remember display choices per account on this device; the server continues storing cm and kg.
  Future<void> loadUnits() async {
    try {
      final saved = await unitStorage.read(
        key: 'measurement_units_${widget.me['id']}',
      );
      if (saved != null && mounted) {
        final units = jsonDecode(saved) as Map;
        if (heightUnits.containsKey(units['height'])) {
          heightUnit = units['height'];
        }
        if (weightUnits.containsKey(units['weight'])) {
          weightUnit = units['weight'];
        }
      }
    } catch (_) {
      /* A missing preference never prevents registration or profile editing. */
    }
    if (mounted) setState(() => loadingUnits = false);
  }

  Future<void> rememberUnits() async {
    try {
      await unitStorage.write(
        key: 'measurement_units_${widget.me['id']}',
        value: jsonEncode({'height': heightUnit, 'weight': weightUnit}),
      );
    } catch (_) {
      /* Measurements still save even if this device cannot retain display preferences. */
    }
  }

  // Do not overwrite location with form-era coordinates after an automatic travel update.
  Future<void> save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request(
        '/me',
        method: 'PUT',
        body: profileBody(widget.me)
          ..addAll({
            'display_name': name.text.trim(),
            'blood_type': wireBlood(blood!),
            'height_cm': heightCm,
            'weight_kg': weightKg,
          }),
      );
      widget.onSaved(result);
      await rememberUnits();
      if (mounted) feedback(context, 'Your profile details are saved.');
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // Photos are optional after onboarding and shared only with an accepted request partner.
  Future<void> pickPhoto() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final image = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
        requestFullMetadata: false,
      );
      if (image == null || !mounted) return;
      if (await image.length() > 5 * 1024 * 1024) {
        throw const ApiException('Choose a photo smaller than 5 MB.');
      }
      await widget.api.uploadPhoto(await image.readAsBytes());
      final result = await widget.api.request('/me');
      widget.onSaved(result);
      if (mounted) setState(() => photoVersion++);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> removePhoto() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.request('/me/photo', method: 'DELETE');
      widget.onSaved(await widget.api.request('/me'));
      if (mounted) setState(() => photoVersion++);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  // Shared recording keeps manual entries and completed-request confirmations consistent.
  Future<void> donation() async {
    final result = await showDonationRecorder(context, widget.api, widget.me);
    if (result != null && mounted) widget.onSaved(result);
  }

  // The history remains private and carries unresolved Later confirmations back to the donor.
  Future<void> history() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => DonationHistoryScreen(
          api: widget.api,
          me: widget.me,
          onSaved: widget.onSaved,
        ),
      ),
    );
  }

  // Export remains on the user's screen; it is not copied to a shared clipboard automatically.
  Future<void> export() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await widget.api.request('/me/export');
      if (mounted) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Your account data'),
            content: SizedBox(
              width: 600,
              child: SingleChildScrollView(
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(result),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close'),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'Your profile and personal content will be removed. Minimal moderation evidence and any lifetime ban may be retained to prevent abuse. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep account'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.api.request('/me', method: 'DELETE');
      await widget.onSignOut();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final h = heightCm ?? 0;
    final w = weightKg ?? 0;
    final bmi = h >= 100 && h <= 250 && w >= 30 && w <= 300
        ? (w / ((h / 100) * (h / 100))).toStringAsFixed(1)
        : '—';
    final automatic = widget.me['location_mode'] == 'automatic';
    return PageBody(
      children: [
        Text('Your profile', style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        // State sharing limits precisely: some profile fields appear in donor search.
        const Text('Manage your details, privacy and donation preferences.'),
        const SizedBox(height: 24),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (widget.me['has_photo'] == true)
                PrivatePhoto(
                  key: ValueKey(photoVersion),
                  api: widget.api,
                  userId: widget.me['id'].toString(),
                )
              else
                const CircleAvatar(
                  radius: 40,
                  backgroundColor: mint,
                  child: Icon(Icons.person_outline, size: 40),
                ),
              const SizedBox(height: 16),
              Text(
                'Profile photo · optional',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 6),
              const Text(
                'Hidden from donor searches. Only you and your matched donor or seeker can see it while your accepted request is active.',
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: busy ? null : pickPhoto,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(
                      widget.me['has_photo'] == true
                          ? 'Change photo'
                          : 'Add a photo',
                    ),
                  ),
                  if (widget.me['has_photo'] == true)
                    TextButton(
                      onPressed: busy ? null : removePhoto,
                      child: const Text('Remove photo'),
                    ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        const Notice(
          'Donor searches show your display name, blood group, city, approximate distance and map area. Your exact location, height, weight and BMI stay private.',
        ),
        const SizedBox(height: 24),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your search location',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Icon(
                    automatic ? Icons.my_location : Icons.place_outlined,
                    color: red,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '${widget.me['city'] ?? 'Choose an area'}, ${widget.me['country'] ?? ''}',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                widget.api.demo
                    ? 'Demo location · the people nearby are fictional sample accounts.'
                    : automatic
                    ? 'Automatic · updates when you open the app or search, including when you travel.'
                    : 'Manual · stays here until you change it. Automatic travel updates are off.',
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: busy ? null : widget.onLocation,
                icon: const Icon(Icons.edit_location_alt_outlined),
                label: const Text('Location & travel settings'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Your details',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: name,
                textCapitalization: TextCapitalization.words,
                maxLength: 60,
                decoration: const InputDecoration(
                  labelText: 'Display name',
                  helperText: 'Shown to other members. A nickname is fine.',
                  helperMaxLines: 3,
                ),
                validator: (v) => (v?.trim().length ?? 0) < 2
                    ? 'Enter at least two characters'
                    : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: blood,
                decoration: const InputDecoration(
                  labelText: 'Blood group',
                  helperText: 'Use your confirmed blood group. Do not guess.',
                  helperMaxLines: 3,
                ),
                items: bloodGroups
                    .map((g) => DropdownMenuItem(value: g, child: Text(g)))
                    .toList(),
                validator: (v) =>
                    v == null ? 'Choose your known blood group' : null,
                onChanged: (v) => setState(() => blood = v),
              ),
              const SizedBox(height: 16),
              if (loadingUnits)
                const Center(child: CircularProgressIndicator())
              else ...[
                MeasurementField(
                  height: true,
                  unit: heightUnit,
                  metricValue: heightCm,
                  enabled: !busy,
                  onChanged: (value) => setState(() => heightCm = value),
                  onUnitChanged: (value) => setState(() => heightUnit = value),
                ),
                const SizedBox(height: 20),
                MeasurementField(
                  height: false,
                  unit: weightUnit,
                  metricValue: weightKg,
                  enabled: !busy,
                  onChanged: (value) => setState(() => weightKg = value),
                  onUnitChanged: (value) => setState(() => weightUnit = value),
                ),
                const SizedBox(height: 16),
              ],
              Panel(
                color: mint,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Body mass index (BMI)  $bmi',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Calculated from your height and weight. These measurements stay private. Your blood bank decides whether you can donate; BMI alone cannot tell you.',
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              if (error != null) ...[
                Text(error!, style: const TextStyle(color: red)),
                const SizedBox(height: 16),
              ],
              FilledButton(
                onPressed: busy || loadingUnits ? null : save,
                child: Text(busy ? 'Please wait…' : 'Save my details'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 28),
        Text(
          'Donation availability',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        // Availability lives on Home; explain that existing control rather than duplicate it.
        const Text(
          'Use “Willing to donate” on Home to appear in donor searches or take a break. After giving blood, record the date and place below so requests pause while you recover.',
        ),
        const SizedBox(height: 16),
        DonationStatusCard(me: widget.me),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: busy ? null : donation,
          icon: const Icon(Icons.volunteer_activism_outlined),
          label: const Text('Record a blood donation'),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: busy ? null : history,
          icon: const Icon(Icons.history),
          label: const Text('My donation history'),
        ),
        const SizedBox(height: 28),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.fact_check_outlined),
          title: const Text('My reports'),
          subtitle: const Text('Track submitted concerns and review updates'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => MyReportsScreen(api: widget.api),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          'Privacy & account',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        const Text(
          'We do not collect or publish your phone number. Messages are protected in transit; they are not end-to-end encrypted. Authorized moderators can review reported conversation evidence. Voice calls use private rooms; only connect with people you trust.',
        ),
        const SizedBox(height: 12),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Notifications on this device',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              // Explain notification privacy separately from the live registration status.
              const Text(
                'Alerts say you have a private update. Open the app to read the details.',
              ),
              const SizedBox(height: 8),
              ValueListenableBuilder<String>(
                valueListenable: NotificationService.status,
                builder: (_, value, _) => Text(value),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await NotificationService.enable();
                        } catch (e) {
                          if (context.mounted) feedback(context, e.toString());
                        }
                      },
                icon: const Icon(Icons.notifications_outlined),
                label: const Text('Enable notifications'),
              ),
              // Android's companion must be opened by the user once so the OS permits its background notification service.
              if (!kIsWeb &&
                  defaultTargetPlatform == TargetPlatform.android) ...[
                const SizedBox(height: 12),
                const Text(
                  'Android needs a notification companion app, such as ntfy, set up for this service. Enable notifications above, then open the companion once so alerts can arrive while Blood Connection is closed.',
                ),
                TextButton.icon(
                  onPressed: busy
                      ? null
                      : () async {
                          try {
                            await NotificationService.openDistributor();
                          } catch (e) {
                            if (context.mounted) {
                              feedback(context, e.toString());
                            }
                          }
                        },
                  icon: const Icon(Icons.open_in_new),
                  label: const Text('Open notification companion'),
                ),
              ],
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () async {
                        try {
                          await NotificationService.disable();
                        } catch (e) {
                          if (context.mounted) feedback(context, e.toString());
                        }
                      },
                icon: const Icon(Icons.notifications_off_outlined),
                label: const Text('Turn off on this device'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Export currently opens selectable data; do not imply that a file is downloaded.
        TextButton.icon(
          onPressed: busy ? null : export,
          icon: const Icon(Icons.description_outlined),
          label: const Text('View my account data'),
        ),
        TextButton.icon(
          onPressed: busy ? null : widget.onSignOut,
          icon: const Icon(Icons.logout),
          label: const Text('Sign out'),
        ),
        TextButton.icon(
          onPressed: busy ? null : delete,
          icon: const Icon(Icons.delete_outline),
          label: const Text('Delete my account'),
        ),
        TextButton(
          onPressed: () => showLicensePage(
            context: context,
            applicationName: 'Blood Connection',
            applicationLegalese: attribution,
          ),
          child: const Text('Open-source licenses'),
        ),
        const SizedBox(height: 24),
        const Text(
          attribution,
          style: TextStyle(fontSize: 12, height: 1.7),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
