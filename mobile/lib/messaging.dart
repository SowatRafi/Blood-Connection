// Conversations use app identities only: no phone number or external dialer is involved.
import 'dart:async';
import 'package:flutter/material.dart' hide ConnectionState;
import 'package:livekit_client/livekit_client.dart';
import 'api.dart';
import 'ui.dart';
import 'reports.dart';

/// Settles media teardown and invitation cancellation before closing the call UI.
///
/// Both operations run even if one fails synchronously. Cleanup errors must not
/// trap navigation; failed invitation cancellation is bounded by server expiry.
Future<void> finishCallCleanup({
  required Future<void> Function() disconnect,
  required Future<void> Function() cancelInvitation,
  required void Function() close,
}) async {
  try {
    await Future.wait<void>([
      Future<void>.sync(disconnect),
      Future<void>.sync(cancelInvitation),
    ]);
  } catch (_) {
    // Both operations have settled; failed signalling is also bounded by server-side expiry.
  } finally {
    close();
  }
}

/// Lists the member's server-authorized conversations using foreground polling.
class ConversationsScreen extends StatefulWidget {
  final Api api;
  final Json me;
  const ConversationsScreen({super.key, required this.api, required this.me});
  @override
  State<ConversationsScreen> createState() => _ConversationsScreenState();
}

class _ConversationsScreenState extends State<ConversationsScreen>
    with WidgetsBindingObserver {
  List<Json>? conversations;
  String? error;
  Timer? timer;
  bool busy = false, active = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 8), (_) => load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      active = state == AppLifecycleState.resumed;
  @override
  void dispose() {
    timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Sequential foreground polling is sufficient for the local build and cannot overlap itself.
  Future<void> load() async {
    if (busy || !active) return;
    busy = true;
    try {
      final result = await widget.api.list('/conversations');
      if (mounted) {
        setState(() {
          conversations = result;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      busy = false;
    }
  }

  @override
  Widget build(BuildContext context) => PageBody(
    children: [
      Text(
        'Your connections',
        style: Theme.of(context).textTheme.headlineMedium,
      ),
      const SizedBox(height: 8),
      const Text('A conversation can make all the difference.'),
      const SizedBox(height: 24),
      const Notice(
        'Keep your conversation here. You never need to share your number or pay anyone for blood.',
      ),
      const SizedBox(height: 24),
      if (error != null) ErrorPanel(error!, load),
      if (conversations == null && error == null)
        const Center(child: CircularProgressIndicator()),
      if (conversations?.isEmpty ?? false)
        const Panel(
          child: Column(
            children: [
              Icon(Icons.chat_bubble_outline, size: 40, color: muted),
              SizedBox(height: 16),
              Text(
                'Your first connection starts here',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 8),
              Text(
                'Find a nearby donor and send a private message.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      for (final conversation in conversations ?? <Json>[]) ...[
        Card(
          child: ListTile(
            contentPadding: const EdgeInsets.all(16),
            leading: BloodBadge(displayBlood(conversation['blood_type'])),
            title: Text(
              conversation['peer_name'].toString(),
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: Text(
              conversation['last_message']?.toString().isNotEmpty == true
                  ? conversation['last_message'].toString()
                  : 'Start a private conversation',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              await Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ChatScreen(
                    api: widget.api,
                    me: widget.me,
                    conversation: conversation,
                  ),
                ),
              );
              load();
            },
          ),
        ),
        const SizedBox(height: 12),
      ],
      const SizedBox(height: 20),
      const Text(
        'Messages refresh while the app is open. Background push notifications are not connected in this local build.',
        style: TextStyle(fontSize: 12, color: muted),
      ),
    ],
  );
}

/// Keeps messages, voice-call invitations and safety actions within app identities.
class ChatScreen extends StatefulWidget {
  final Api api;
  final Json me, conversation;
  const ChatScreen({
    super.key,
    required this.api,
    required this.me,
    required this.conversation,
  });
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> with WidgetsBindingObserver {
  final compose = TextEditingController();
  final scroll = ScrollController();
  List<Json> messages = [];
  String? error;
  bool loading = true,
      polling = false,
      sending = false,
      active = true,
      calling = false,
      blocked = false;
  Timer? timer;
  String get id => widget.conversation['id'].toString();
  @override
  void initState() {
    super.initState();
    blocked = widget.conversation['is_blocked'] == true;
    WidgetsBinding.instance.addObserver(this);
    load();
    timer = Timer.periodic(const Duration(seconds: 4), (_) => load());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      active = state == AppLifecycleState.resumed;
  @override
  void dispose() {
    timer?.cancel();
    compose.dispose();
    scroll.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // A single foreground request avoids overlapping polls; scroll only when the message count changes.
  Future<void> load() async {
    if (polling || !active) return;
    polling = true;
    try {
      final result = await widget.api.list('/conversations/$id/messages');
      final changed = messages.length != result.length;
      if (mounted) {
        setState(() {
          messages = result;
          error = null;
          loading = false;
        });
      }
      if (changed) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (scroll.hasClients) scroll.jumpTo(scroll.position.maxScrollExtent);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          error = e.toString();
          loading = false;
        });
      }
    } finally {
      polling = false;
    }
  }

  // The draft clears only after acknowledgement, preventing message loss on a failed network request.
  Future<void> send() async {
    final body = compose.text.trim();
    if (body.isEmpty || sending || blocked) return;
    setState(() => sending = true);
    try {
      await widget.api.request(
        '/conversations/$id/messages',
        method: 'POST',
        body: {'body': body},
      );
      compose.clear();
      await load();
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    } finally {
      if (mounted) setState(() => sending = false);
    }
  }

  // Creating an invitation does not join media; CallScreen waits for server-issued room credentials.
  Future<void> call() async {
    if (blocked) return;
    setState(() => calling = true);
    try {
      final result = await widget.api.request(
        '/conversations/$id/calls',
        method: 'POST',
      );
      if (mounted) {
        await Navigator.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => CallScreen(
              api: widget.api,
              callId: result['id'].toString(),
              peerName: widget.conversation['peer_name'].toString(),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) feedback(context, e.toString());
    } finally {
      if (mounted) setState(() => calling = false);
    }
  }

  // Reports stay accessible even when this conversation can no longer send messages.
  Future<void> report() => showReport(
    context,
    widget.api,
    conversationId: id,
    peerName: widget.conversation['peer_name']?.toString(),
  );

  Future<void> block() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Block this person?'),
        content: const Text(
          'They will no longer be able to message or call you through this app.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Block'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.api.request(
        '/blocks',
        method: 'POST',
        body: {'user_id': widget.conversation['peer_id']},
      );
      if (mounted) {
        setState(() => blocked = true);
        feedback(
          context,
          'Person blocked. You can still report this conversation.',
        );
      }
    } catch (e) {
      if (mounted) feedback(context, e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.conversation['peer_name'].toString()),
      actions: [
        IconButton(
          tooltip: 'Private voice call',
          onPressed: calling || blocked ? null : call,
          icon: const Icon(Icons.call_outlined),
        ),
        PopupMenuButton<String>(
          tooltip: 'Conversation safety',
          onSelected: (value) => value == 'report' ? report() : block(),
          itemBuilder: (_) => [
            const PopupMenuItem(
              value: 'report',
              child: Text('Report conversation'),
            ),
            PopupMenuItem(
              value: 'block',
              enabled: !blocked,
              child: Text(blocked ? 'Person blocked' : 'Block person'),
            ),
          ],
        ),
      ],
    ),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: Notice(
              'Private in-app chat · never pay for blood.',
              icon: Icons.lock_outline,
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: ErrorPanel(error!, load),
            ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator())
                : messages.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'Say hello. Share the hospital and blood group needed. Avoid posting phone numbers or sensitive medical records.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView.builder(
                    controller: scroll,
                    padding: const EdgeInsets.all(16),
                    itemCount: messages.length,
                    itemBuilder: (context, index) {
                      final message = messages[index];
                      final mine = message['sender_id'] == widget.me['id'];
                      return Align(
                        alignment: mine
                            ? Alignment.centerRight
                            : Alignment.centerLeft,
                        child: Container(
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.sizeOf(context).width * .82,
                          ),
                          margin: const EdgeInsets.only(bottom: 12),
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: mine ? mint : Colors.white,
                            border: Border.all(color: const Color(0xFFE6E3DE)),
                            borderRadius: BorderRadius.circular(18),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                message['body'].toString(),
                                style: const TextStyle(
                                  fontSize: 16,
                                  color: ink,
                                  height: 1.5,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '${mine ? 'You' : widget.conversation['peer_name']} · ${shortDate(message['created_at'])}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: muted,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: compose,
                    enabled: !blocked,
                    minLines: 1,
                    maxLines: 4,
                    maxLength: 2000,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      labelText: 'Message',
                      counterText: '',
                    ),
                    onSubmitted: (_) => send(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.filled(
                  tooltip: 'Send message',
                  onPressed: sending || blocked ? null : send,
                  style: IconButton.styleFrom(minimumSize: const Size(52, 52)),
                  icon: sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.arrow_upward),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// Owns one voice invitation and its LiveKit room until the route closes.
///
/// Accepted incoming calls may supply [credentials]; outgoing calls poll until
/// the server authorizes joining the room. Neither path uses a phone number.
class CallScreen extends StatefulWidget {
  final Api api;
  final String callId, peerName;
  final Json? credentials;
  const CallScreen({
    super.key,
    required this.api,
    required this.callId,
    required this.peerName,
    this.credentials,
  });
  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final room = Room();
  Timer? timer;
  String status = 'Ringing…';
  bool connecting = false,
      connected = false,
      mutedMic = false,
      ended = false,
      checking = false;
  @override
  void initState() {
    super.initState();
    room.addListener(roomChanged);
    if (widget.credentials != null) connect(widget.credentials!);
    timer = Timer.periodic(const Duration(seconds: 2), (_) => check());
  }

  // Connection labels reflect media-room state, not just the creation of a call invitation.
  void roomChanged() {
    if (!mounted || ended) return;
    if (room.connectionState == ConnectionState.connected) {
      setState(
        () => status = room.remoteParticipants.isEmpty
            ? 'Connected · waiting for your contact'
            : 'Private voice call',
      );
    }
    if (room.connectionState == ConnectionState.disconnected && connected) {
      end();
    }
  }

  // Check route lifetime after each await so a late connection cannot reopen a cancelled microphone.
  Future<void> connect(Json credentials) async {
    if (connecting || connected || ended) return;
    connecting = true;
    if (mounted) setState(() => status = 'Connecting securely…');
    try {
      await room.connect(
        credentials['url'].toString(),
        credentials['token'].toString(),
      );
      // A user may end while signalling is in flight; never enable audio after that decision.
      if (ended || !mounted) {
        await disconnectMedia();
        return;
      }
      await room.localParticipant?.setMicrophoneEnabled(true);
      if (ended || !mounted) {
        await disconnectMedia();
        return;
      }
      connected = true;
      roomChanged();
    } catch (_) {
      if (mounted) {
        feedback(
          context,
          'Could not connect. Check your network and microphone permission.',
        );
      }
      await end();
    } finally {
      connecting = false;
    }
  }

  // Server state governs continued access, including expiry, decline and revocation while connected.
  Future<void> check() async {
    if (checking || ended) return;
    checking = true;
    try {
      final result = await widget.api.request('/calls/${widget.callId}');
      if (result['status'] == 'ended' ||
          result['status'] == 'missed' ||
          result['status'] == 'declined' ||
          result['status'] == 'expired') {
        await end(notifyServer: false);
        return;
      }
      if (result['token'] != null) await connect(result);
    } catch (e) {
      // Revoked access and network loss must stop media, not leave an unmonitored call running.
      await end(notifyServer: false);
    } finally {
      checking = false;
    }
  }

  Future<void> toggleMute() async {
    try {
      await room.localParticipant?.setMicrophoneEnabled(mutedMic);
      if (mounted) setState(() => mutedMic = !mutedMic);
    } catch (_) {
      if (mounted) feedback(context, 'Microphone could not be changed.');
    }
  }

  // Ending always tears down local audio, even if the server cannot be reached.
  Future<void> end({bool notifyServer = true}) async {
    if (ended) return;
    // Keep the exact route: a system-back action may already remove it while async cleanup is running.
    final route = mounted ? ModalRoute.of(context) : null;
    if (mounted) {
      setState(() => ended = true);
    } else {
      ended = true;
    }
    timer?.cancel();
    await finishCallCleanup(
      disconnect: disconnectMedia,
      cancelInvitation: () async {
        if (notifyServer) {
          await widget.api.request(
            '/calls/${widget.callId}/end',
            method: 'POST',
          );
        }
      },
      close: () {
        if (mounted && route?.isCurrent == true) Navigator.pop(context);
      },
    );
  }

  // A ringing call has no media connection. Disconnecting an unopened LiveKit room waits for an event that never arrives.
  Future<void> disconnectMedia() async {
    if (room.connectionState != ConnectionState.disconnected) {
      await room.disconnect();
    }
  }

  @override
  void dispose() {
    // Route removal must revoke a pending invitation as well as release local microphone resources.
    if (!ended) {
      ended = true;
      unawaited(
        widget.api
            .request('/calls/${widget.callId}/end', method: 'POST')
            .catchError((_) => <String, dynamic>{}),
      );
    }
    timer?.cancel();
    room.removeListener(roomChanged);
    // SDK disposal is asynchronous; explicitly observe failure so it cannot become an uncaught platform error.
    unawaited(
      room.dispose().then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: ended,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) end();
    },
    child: Scaffold(
      appBar: AppBar(
        title: const Text('Private voice call'),
        leading: IconButton(
          tooltip: 'End call and go back',
          onPressed: end,
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: PageBody(
          children: [
            const SizedBox(height: 64),
            const Center(
              child: CircleAvatar(
                radius: 52,
                backgroundColor: mint,
                child: Icon(Icons.person_outline, size: 56, color: ink),
              ),
            ),
            const SizedBox(height: 28),
            Text(
              widget.peerName,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineMedium,
            ),
            const SizedBox(height: 12),
            Text(status, textAlign: TextAlign.center),
            const SizedBox(height: 48),
            OutlinedButton.icon(
              onPressed: connected ? toggleMute : null,
              icon: Icon(mutedMic ? Icons.mic_off : Icons.mic),
              label: Text(mutedMic ? 'Unmute microphone' : 'Mute microphone'),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: end,
              icon: const Icon(Icons.call_end),
              label: const Text('End call'),
            ),
            const SizedBox(height: 32),
            const Notice(
              'Your phone number is never shared. Calls are not recorded by this app.',
              icon: Icons.lock_outline,
            ),
          ],
        ),
      ),
    ),
  );
}
