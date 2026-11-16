// An initiative by Bindubashini Boys’ 2015 & Friends.
// Startup, signed-in routing and foreground coordination share one current
// profile so travel, donation pauses and account changes reach each screen.
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'api.dart';
import 'ui.dart';
import 'profile.dart';
import 'messaging.dart';
import 'location.dart';
import 'admin.dart';
import 'requests.dart';
import 'notifications.dart';
import 'search.dart';
import 'donation_status.dart';
import 'donations.dart';
import 'reports.dart';
export 'search.dart' show SearchScreen;

/// Stores mobile auth sessions in platform-backed secure storage.
///
/// The web initialization uses empty storage instead of persisting this session.
class SecureSessionStorage extends LocalStorage {
  const SecureSessionStorage();
  static const storage = FlutterSecureStorage();
  static const key = 'blood_connection_session';
  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => await storage.containsKey(key: key);
  @override
  Future<String?> accessToken() => storage.read(key: key);
  @override
  Future<void> removePersistedSession() => storage.delete(key: key);
  @override
  Future<void> persistSession(String persistSessionString) =>
      storage.write(key: key, value: persistSessionString);
}

/// Initializes optional services, then starts the app unless this is a push task.
///
/// Missing auth configuration leaves the welcome screen available for local work.
Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  registerBrandLicenses();
  await NotificationService.initialize(args);
  if (args.contains('--unifiedpush-bg')) return;
  if (hasAuth) {
    await Supabase.initialize(
      url: supabaseUrl,
      publishableKey: supabaseKey,
      authOptions: FlutterAuthClientOptions(
        localStorage: kIsWeb
            ? const EmptyLocalStorage()
            : const SecureSessionStorage(),
      ),
    );
  }
  runApp(const BloodConnectionApp());
}

/// Applies the shared brand theme before authentication and role-based routing.
class BloodConnectionApp extends StatelessWidget {
  const BloodConnectionApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Blood Connection',
    debugShowCheckedModeBanner: false,
    theme: appTheme(),
    home: const WelcomeScreen(),
  );
}

/// Starts social authentication and explicitly enabled local demo sessions.
class WelcomeScreen extends StatefulWidget {
  const WelcomeScreen({super.key});
  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen> {
  StreamSubscription<AuthState>? subscription;
  bool entered = false;
  bool busy = false;
  String? error;

  // Both a restored session and the OAuth deep link enter through the same route exactly once.
  @override
  void initState() {
    super.initState();
    if (hasAuth) {
      subscription = Supabase.instance.client.auth.onAuthStateChange.listen((
        state,
      ) {
        if (state.session != null && mounted && !entered) enter(false);
      });
    }
  }

  @override
  void dispose() {
    subscription?.cancel();
    super.dispose();
  }

  // Demo entry exists only in explicitly enabled local builds and is never an OAuth shortcut.
  Future<void> enter(bool demo, {String demoIdentity = 'seeker'}) async {
    if (entered || !mounted) return;
    entered = true;
    final api = Api()
      ..demo = demo
      ..demoIdentity = demoIdentity
      ..country = demo ? 'BD' : '';
    try {
      // Existing accounts resolve their own country; new members choose automatic or manual location before profile creation.
      if (mounted) {
        await Navigator.of(
          context,
        ).push(MaterialPageRoute<void>(builder: (_) => MainScreen(api: api)));
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      api.close();
    }
    entered = false;
    if (mounted) setState(() => busy = false);
  }

  // Provider completion returns through the auth subscription; starting OAuth
  // does not itself authorize navigation into the signed-in app.
  Future<void> signIn(OAuthProvider provider) async {
    if (!hasAuth) {
      setState(
        () => error =
            'Social sign-in will be available when the project’s Google, Apple and Facebook accounts are connected.',
      );
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await Supabase.instance.client.auth.signInWithOAuth(
        provider,
        redirectTo: kIsWeb
            ? Uri.base.origin
            : 'bloodconnection://login-callback',
      );
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Sign-in could not start. Please try again.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: PageBody(
        children: [
          const SizedBox(height: 32),
          const Align(
            alignment: Alignment.centerLeft,
            child: BrandMark(size: 68),
          ),
          const SizedBox(height: 28),
          Text(
            kIsWeb
                ? 'A safer community.\nIn your care.'
                : 'A little of you.\nA lifeline for someone.',
            style: Theme.of(context).textTheme.headlineLarge,
          ),
          const SizedBox(height: 16),
          const Text(
            kIsWeb
                ? 'Blood Connection administration. Member accounts use the Android or iOS app.'
                : 'Find blood donors nearby. Connect privately. Be there when it matters.',
            style: TextStyle(fontSize: 17, height: 1.6, color: muted),
          ),
          const SizedBox(height: 28),
          const Notice(
            'Your number stays yours. Messages and voice calls happen inside the app.',
          ),
          const SizedBox(height: 28),
          Text(
            kIsWeb ? 'Admin sign-in' : 'Welcome to Blood Connection',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          for (final provider in [
            (OAuthProvider.google, 'Google'),
            (OAuthProvider.apple, 'Apple'),
            (OAuthProvider.facebook, 'Facebook'),
          ]) ...[
            OutlinedButton(
              onPressed: busy ? null : () => signIn(provider.$1),
              child: Text('Continue with ${provider.$2}'),
            ),
            const SizedBox(height: 12),
          ],
          if (error != null) ...[
            Text(error!, style: const TextStyle(color: red)),
            const SizedBox(height: 16),
          ],
          if (demoEnabled && !kIsWeb) ...[
            FilledButton.icon(
              onPressed: busy ? null : () => enter(true),
              icon: const Icon(Icons.science_outlined),
              label: const Text('Explore local demo'),
            ),
            const SizedBox(height: 8),
            const Text(
              'Fictional people · local test data only',
              textAlign: TextAlign.center,
            ),
            TextButton(
              onPressed: busy ? null : () => enter(true, demoIdentity: 'donor'),
              child: const Text('Try donor demo'),
            ),
          ],
          if (demoEnabled)
            TextButton.icon(
              onPressed: busy ? null : () => enter(true, demoIdentity: 'admin'),
              icon: const Icon(Icons.admin_panel_settings_outlined),
              label: const Text('Open admin demo'),
            ),
          const SizedBox(height: 32),
          const Text(
            attribution,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, height: 1.7, color: muted),
          ),
        ],
      ),
    ),
  );
}

/// Owns the active profile, member navigation and the separate admin surface.
///
/// Screens receive this profile after server updates rather than maintaining
/// independent copies of location, availability and donation pause state.
class MainScreen extends StatefulWidget {
  final Api api;
  const MainScreen({super.key, required this.api});
  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  Json? me;
  String? error;
  int tab = 0;
  Timer? incomingTimer;
  Timer? locationTimer;
  bool checkingCall = false;
  bool callOpen = false;
  bool active = true;
  bool loading = false;
  bool signingOut = false;
  bool updatingLocation = false;
  bool checkingDonation = false;
  bool savingAvailability = false;
  bool routingNotification = false;
  // 'Later' leaves the server reminder intact without repeatedly interrupting this session.
  final Set<String> seenDonationPrompts = {};
  String? locationError;
  late final LocationCoordinator locations;

  // Only foreground polling is used locally; no background notification delivery is implied.
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    locations = LocationCoordinator(widget.api);
    NotificationService.openedTarget.addListener(openNotification);
    load();
    incomingTimer = Timer.periodic(const Duration(seconds: 6), (_) async {
      openNotification();
      await checkCalls();
      await checkDonationConfirmations();
    });
    // Foreground refresh also covers someone travelling while leaving the app open.
    locationTimer = Timer.periodic(const Duration(minutes: 5), (_) async {
      if (!active ||
          loading ||
          updatingLocation ||
          me == null ||
          me?['role'] == 'admin' ||
          kIsWeb ||
          me?['location_mode'] != 'automatic') {
        return;
      }
      try {
        await refreshLocation();
      } catch (_) {
        /* The visible location warning blocks stale searches. */
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    active = state == AppLifecycleState.resumed;
    if (active) load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    incomingTimer?.cancel();
    locationTimer?.cancel();
    NotificationService.openedTarget.removeListener(openNotification);
    super.dispose();
  }

  // Cold-start targets wait for a signed-in profile and onboarding; routing never changes country.
  void openNotification() {
    if (!mounted ||
        !active ||
        me == null ||
        me?['role'] == 'admin' ||
        loading ||
        updatingLocation ||
        signingOut ||
        checkingDonation ||
        callOpen ||
        routingNotification) {
      return;
    }
    final target = NotificationService.openedTarget.value;
    if (target == null) return;
    routingNotification = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || !active || signingOut) {
        routingNotification = false;
        return;
      }
      final selected = NotificationService.openedTarget.value;
      if (selected == null) {
        routingNotification = false;
        return;
      }
      NotificationService.openedTarget.value = null;
      setState(() => tab = 2);
      try {
        if (selected.reportId != null) {
          await Navigator.push<void>(
            context,
            MaterialPageRoute(
              builder: (_) => ReportDetailScreen(
                api: widget.api,
                reportId: selected.reportId!,
                reportCountry: selected.reportCountry!,
              ),
            ),
          );
        }
      } finally {
        routingNotification = false;
        if (mounted) openNotification();
      }
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  // Update routing from the server profile. Notification attachment is best
  // effort and must not prevent the profile from becoming usable.
  void acceptProfile(Json profile) {
    unawaited(
      NotificationService.attach(
        widget.api,
        userId: profile['id'].toString(),
        role: profile['role']?.toString() ?? 'member',
      ).catchError((_) {}),
    );
    widget.api.country = profile['country'].toString();
    if (mounted) {
      setState(() {
        me = profile;
        error = null;
      });
      openNotification();
    }
  }

  // Resolve the account before asking for local location consent. A 409 with no
  // profile represents location onboarding, not a generic signed-in failure.
  Future<void> load() async {
    if (loading) return;
    loading = true;
    try {
      final result = await widget.api.request('/me');
      acceptProfile(result);
      if (result['role'] != 'admin' && !kIsWeb) {
        if (result['height_cm'] == null || result['blood_type'] == null) {
          if (mounted) setState(() => tab = 4);
        }
        if (result['location_mode'] == 'automatic') {
          if (await LocationConsent.allowed(result['id'].toString())) {
            await refreshLocation();
          } else if (!widget.api.demo) {
            await chooseLocation();
          }
        }
      }
    } on ApiException catch (e) {
      if (e.statusCode == 409 && me == null && !kIsWeb) {
        await chooseLocation();
        if (me == null && mounted) {
          setState(
            () => error =
                'Choose automatic location or select your area to continue.',
          );
        }
      } else if (mounted) {
        setState(() => error = e.toString());
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      loading = false;
    }
    openNotification();
    unawaited(checkDonationConfirmations());
  }

  // Either matched participant can confirm; refreshing the owner profile also picks up a peer's confirmation.
  Future<void> checkDonationConfirmations() async {
    bool canPrompt() =>
        mounted &&
        active &&
        !signingOut &&
        !loading &&
        !updatingLocation &&
        !savingAvailability &&
        !checkingCall &&
        !routingNotification &&
        NotificationService.openedTarget.value == null &&
        !callOpen &&
        me != null &&
        me?['role'] != 'admin' &&
        !kIsWeb &&
        (tab == 0 || tab == 2) &&
        ModalRoute.of(context)?.isCurrent == true;
    if (checkingDonation || !canPrompt()) return;
    checkingDonation = true;
    try {
      final latest = await widget.api.request('/me');
      if (!mounted || !canPrompt()) return;
      acceptProfile(latest);
      final pending = await widget.api.list('/donation-confirmations');
      if (!mounted || !canPrompt()) return;
      for (final item in pending) {
        final id = item['request_id'].toString();
        if (seenDonationPrompts.contains(id)) continue;
        seenDonationPrompts.add(id);
        final updated = await showDonationConfirmation(
          context,
          widget.api,
          me!,
          item,
        );
        if (updated != null && mounted) acceptProfile(updated);
        break; // One respectful reminder at a time; the private history keeps all pending items reachable.
      }
    } catch (_) {
      // History exposes retry feedback; a background check must not displace the active screen on failure.
    } finally {
      checkingDonation = false;
    }
  }

  // Feed the returned server profile back into all tabs immediately so a newly
  // recorded donation updates availability without waiting for another poll.
  Future<void> recordDonation() async {
    if (me == null) return;
    final updated = await showDonationRecorder(context, widget.api, me!);
    if (updated != null && mounted) acceptProfile(updated);
  }

  // History may resolve pending confirmations, so it shares the profile callback.
  Future<void> showDonationHistory() async {
    if (me == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DonationHistoryScreen(
          api: widget.api,
          me: me!,
          onSaved: acceptProfile,
        ),
      ),
    );
  }

  // Keep manual selection out of an active automatic update; its saved result
  // also primes the refresh cache to avoid an immediate redundant GPS lookup.
  Future<void> chooseLocation() async {
    if (!mounted || kIsWeb) return;
    if (updatingLocation) {
      feedback(
        context,
        'Your location is updating. Please try again in a moment.',
      );
      return;
    }
    final result = await Navigator.push<Json>(
      context,
      MaterialPageRoute(
        builder: (_) => LocationScreen(api: widget.api, current: me),
      ),
    );
    if (result != null) {
      acceptProfile(result);
      locations.lastSuccess = DateTime.now();
      if (mounted) {
        setState(() {
          locationError = null;
          if (result['height_cm'] == null || result['blood_type'] == null) {
            tab = 4;
          }
        });
      }
    } else if (mounted && me?['location_mode'] == 'automatic') {
      setState(
        () => locationError =
            'Automatic location needs your consent. Choose a location before searching.',
      );
    }
  }

  // Search awaits this method, so a failed country lookup never silently searches the previous destination.
  Future<Json> refreshLocation() async {
    final current = me;
    if (current == null) throw const ApiException('Set your location first.');
    if (current['location_mode'] != 'automatic') return current;
    if (widget.api.demo &&
        !await LocationConsent.allowed(current['id'].toString())) {
      return current;
    }
    if (!await LocationConsent.allowed(current['id'].toString())) {
      throw const ApiException(
        'Agree to automatic location or choose your area manually in Profile.',
      );
    }
    if (mounted) setState(() => updatingLocation = true);
    try {
      final result = await locations.refresh(current);
      acceptProfile(result);
      if (mounted) setState(() => locationError = null);
      return result;
    } catch (e) {
      if (mounted) setState(() => locationError = e.toString());
      rethrow;
    } finally {
      if (mounted) setState(() => updatingLocation = false);
    }
  }

  // The callee explicitly accepts before the server releases any media-room credentials.
  Future<void> checkCalls() async {
    if (!active ||
        me == null ||
        me?['role'] == 'admin' ||
        kIsWeb ||
        checkingCall ||
        callOpen ||
        checkingDonation ||
        routingNotification) {
      return;
    }
    final eligibleAfter = donationPauseEnd(me!);
    if (eligibleAfter != null &&
        eligibleAfter.isAfter(DateTime.now().toUtc())) {
      return;
    }
    checkingCall = true;
    try {
      final calls = await widget.api.list('/calls');
      if (calls.isEmpty || !mounted) return;
      callOpen = true;
      final call = calls.first;
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Text('Incoming private call'),
          content: Text(
            '${call['caller_name']} is calling. Your phone number is never shared.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Decline'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Accept'),
            ),
          ],
        ),
      );
      if (accepted == true && mounted) {
        final credentials = await widget.api.request(
          '/calls/${call['id']}/accept',
          method: 'POST',
        );
        if (mounted) {
          await Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => CallScreen(
                api: widget.api,
                callId: call['id'].toString(),
                peerName: call['caller_name'].toString(),
                credentials: credentials,
              ),
            ),
          );
        }
      } else {
        await widget.api.request('/calls/${call['id']}/end', method: 'POST');
      }
    } catch (_) {
      /* The persistent screens handle network failures; background polling never interrupts typing. */
    } finally {
      checkingCall = false;
      callOpen = false;
    }
  }

  // Publish only the acknowledged profile. The switch does not locally override
  // server-enforced donation pauses or safety restrictions.
  Future<void> saveAvailability(bool value) async {
    if (me == null || savingAvailability) return;
    setState(() => savingAvailability = true);
    try {
      final result = await widget.api.request(
        '/me',
        method: 'PUT',
        body: profileBody(me!)..['available'] = value,
      );
      if (mounted) setState(() => me = result);
    } catch (e) {
      if (mounted) feedback(context, e.toString());
    } finally {
      if (mounted) setState(() => savingAvailability = false);
    }
  }

  // Detach this device's notification binding while credentials still exist,
  // then dispose the signed-in route and its shared HTTP client.
  Future<void> signOut() async {
    await NotificationService.detach();
    if (!widget.api.demo && hasAuth) {
      await Supabase.instance.client.auth.signOut();
    }
    if (mounted) {
      setState(() => signingOut = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    }
  }

  // Android Back exits the app instead of silently closing the API client under an attached notification session.
  Widget appRoot(Widget child) => PopScope(
    canPop: signingOut || kIsWeb,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && defaultTargetPlatform == TargetPlatform.android) {
        SystemNavigator.pop();
      }
    },
    child: child,
  );

  @override
  Widget build(BuildContext context) {
    final profile = me;
    if (profile?['role'] == 'admin') {
      return appRoot(AdminScreen(api: widget.api, onSignOut: signOut));
    }
    // The browser is an admin surface only, including while role verification is pending or fails.
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('Blood Connection Admin')),
        body: SafeArea(
          child: PageBody(
            children: [
              if (profile == null && error == null)
                const Center(child: CircularProgressIndicator())
              else
                const Notice(
                  'This account cannot access the admin application. Member accounts use the Android or iOS app.',
                  icon: Icons.admin_panel_settings_outlined,
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Text(error!),
                ),
              const SizedBox(height: 20),
              OutlinedButton(
                onPressed: signOut,
                child: const Text('Return to sign-in'),
              ),
            ],
          ),
        ),
      );
    }
    final wide = MediaQuery.sizeOf(context).width >= 720;
    final content = profile == null
        ? (error != null
              ? PageBody(children: [ErrorPanel(error!, load)])
              : const Center(child: CircularProgressIndicator()))
        : switch (tab) {
            0 => HomeScreen(
              me: profile,
              demo: widget.api.demo,
              locationWarning: locationError,
              onLocation: chooseLocation,
              onSearch: () => setState(() => tab = 1),
              onProfile: () => setState(() => tab = 4),
              onAvailability: savingAvailability ? null : saveAvailability,
              onRecordDonation: recordDonation,
              onDonationHistory: showDonationHistory,
            ),
            1 => SearchScreen(
              api: widget.api,
              me: profile,
              refreshLocation: refreshLocation,
              onProfile: () => setState(() => tab = 4),
            ),
            2 => RequestsScreen(
              api: widget.api,
              me: profile,
              onFind: () => setState(() => tab = 1),
            ),
            3 => ConversationsScreen(api: widget.api, me: profile),
            _ => ProfileScreen(
              api: widget.api,
              me: profile,
              onSaved: acceptProfile,
              onSignOut: signOut,
              onLocation: chooseLocation,
            ),
          };
    const destinations = [
      (Icons.home_outlined, 'Home'),
      (Icons.search, 'Find donors'),
      (Icons.volunteer_activism_outlined, 'Requests'),
      (Icons.chat_bubble_outline, 'Messages'),
      (Icons.person_outline, 'Profile'),
    ];
    return appRoot(
      Scaffold(
        // Search owns its floating controls so the map can use the entire content area.
        appBar: tab == 1
            ? null
            : AppBar(
                automaticallyImplyLeading: false,
                title: const Row(
                  children: [
                    BrandMark(size: 32),
                    SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        'Blood Connection',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 19,
                        ),
                      ),
                    ),
                  ],
                ),
                actions: [
                  if (widget.api.demo)
                    const Padding(
                      padding: EdgeInsets.only(right: 20),
                      child: Chip(
                        label: Text(
                          'DEMO',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
        body: SafeArea(
          top: tab != 1,
          bottom: tab != 1,
          child: wide
              ? Row(
                  children: [
                    NavigationRail(
                      selectedIndex: tab,
                      labelType: NavigationRailLabelType.all,
                      onDestinationSelected: (value) =>
                          setState(() => tab = value),
                      destinations: destinations
                          .map(
                            (d) => NavigationRailDestination(
                              icon: Icon(d.$1),
                              label: Text(d.$2),
                            ),
                          )
                          .toList(),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(child: content),
                  ],
                )
              : content,
        ),
        bottomNavigationBar: wide
            ? null
            : NavigationBar(
                selectedIndex: tab,
                onDestinationSelected: (value) => setState(() => tab = value),
                destinations: destinations
                    .map(
                      (d) =>
                          NavigationDestination(icon: Icon(d.$1), label: d.$2),
                    )
                    .toList(),
              ),
      ),
    );
  }
}

/// Shows donation status and entry points using the current server profile.
class HomeScreen extends StatelessWidget {
  final Json me;
  final bool demo;
  final VoidCallback onSearch, onProfile;
  final VoidCallback? onRecordDonation, onDonationHistory;
  final ValueChanged<bool>? onAvailability;
  final String? locationWarning;
  final Future<void> Function()? onLocation;
  const HomeScreen({
    super.key,
    required this.me,
    required this.demo,
    required this.onSearch,
    required this.onProfile,
    required this.onAvailability,
    this.onRecordDonation,
    this.onDonationHistory,
    this.locationWarning,
    this.onLocation,
  });
  @override
  Widget build(BuildContext context) {
    return PageBody(
      children: [
        if (locationWarning != null) ...[
          Notice(
            locationWarning!,
            icon: Icons.location_off_outlined,
            color: const Color(0xFFFBE9EC),
          ),
          TextButton(
            onPressed: onLocation,
            child: const Text('Review my location'),
          ),
          const SizedBox(height: 16),
        ],
        Row(
          children: [
            const Icon(Icons.location_on_outlined, size: 17, color: muted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '${me['city'] ?? 'Set your location'} · ${me['country'] ?? ''}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'Hello, ${me['display_name']?.toString().split(' ').first ?? 'friend'}.',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 6),
        const Text('Someone nearby may need your kindness.'),
        const SizedBox(height: 24),
        DonationStatusCard(
          me: me,
          compact: true,
          onAvailability: onAvailability,
          onRecord: onRecordDonation ?? onProfile,
          onHistory: onDonationHistory ?? onProfile,
        ),
        const SizedBox(height: 20),
        Panel(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Icon(
                  Icons.favorite_border_rounded,
                  size: 32,
                  color: red,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'The right connection.\nWhen it matters.',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 12),
              const Text(
                'Find willing donors within 39 km.\nA small distance. A meaningful difference.',
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: onSearch,
                icon: const Icon(Icons.search),
                label: const Text('Find a blood donor'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Notice(
          'Always free. Always private. Never pay for blood. Report requests for money directly from a conversation.',
        ),
        const SizedBox(height: 24),
        const Text(
          'For urgent medical care, contact your local emergency service or hospital. Matching here does not replace blood-bank screening.',
          style: TextStyle(fontSize: 12, color: muted, height: 1.6),
        ),
        if (demo) ...[
          const SizedBox(height: 12),
          const Text(
            'Local demo · all people and conversations are fictional.',
            style: TextStyle(fontSize: 12, color: red),
          ),
        ],
        const SizedBox(height: 28),
        const Text(
          attribution,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 12, color: muted, height: 1.7),
        ),
      ],
    );
  }
}
