import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

class _Recorder extends NoOpNotificationPort
    implements ExactNotificationTiming, NotificationChannelDeclaration {
  final posted = <AppNotification>[];
  final declared = <String>[];
  bool exactAsked = false;

  @override
  Future<void> post(AppNotification n) async => posted.add(n);

  @override
  Future<bool> requestExactTiming() async {
    exactAsked = true;
    return false;
  }

  @override
  Future<void> declareChannels({
    required AppHandle source,
    required String appName,
    required List<AppNotificationChannel> channels,
  }) async =>
      declared.add('$source|$appName|${channels.map((c) => c.id).join(',')}');
}

AppNotification _n(String id, AppHandle app) =>
    AppNotification(id: id, title: 't', body: 'b', source: app);

void main() {
  const chat = AppHandle.bundle('chat');
  const dues = AppHandle.bundle('dues');
  late _Recorder inner;
  late DateTime now;
  late List<AppHandle> throttled;
  late Set<AppHandle> muted;
  late GatedNotificationPort port;

  setUp(() {
    inner = _Recorder();
    now = DateTime(2026, 10, 21, 12);
    throttled = [];
    muted = {};
    port = GatedNotificationPort(
      inner,
      isMuted: muted.contains,
      maxPerWindow: 3,
      window: const Duration(minutes: 1),
      onThrottled: throttled.add,
      clock: () => now,
    );
  });

  test('an app the person turned off is not shown', () async {
    muted.add(chat);
    await port.post(_n('1', chat));
    await port.post(_n('2', dues));
    expect(inner.posted.map((n) => n.id), ['2']);
  });

  test('an app over its limit is held to it and the host is told once',
      () async {
    for (var i = 0; i < 6; i++) {
      await port.post(_n('$i', chat));
    }
    expect(inner.posted, hasLength(3));
    expect(throttled, [chat]);
    // Another app has its own count.
    await port.post(_n('d', dues));
    expect(inner.posted, hasLength(4));
  });

  test('the limit lifts when the window has passed', () async {
    for (var i = 0; i < 4; i++) {
      await port.post(_n('$i', chat));
    }
    expect(inner.posted, hasLength(3));
    now = now.add(const Duration(minutes: 2));
    await port.post(_n('late', chat));
    expect(inner.posted, hasLength(4));
    // Over again in the next window: told again.
    for (var i = 0; i < 4; i++) {
      await port.post(_n('x$i', chat));
    }
    expect(throttled, [chat, chat]);
  });

  test('the native port keeps its capabilities through the wrapper', () async {
    await port.declareChannels(
      source: chat,
      appName: 'Chat',
      channels: const [
        AppNotificationChannel(id: 'messages', name: 'Messages'),
        AppNotificationChannel(
            id: 'calls',
            name: 'Calls',
            importance: NotificationImportance.high),
      ],
    );
    expect(inner.declared, ['bundle:chat|Chat|messages,calls']);
    expect(await port.requestExactTiming(), isFalse);
    expect(inner.exactAsked, isTrue);
  });

  test('a port without them is fine', () async {
    final bare = GatedNotificationPort(const NoOpNotificationPort(),
        isMuted: (_) => false);
    await bare.declareChannels(source: chat, appName: 'Chat', channels: const []);
    expect(await bare.requestExactTiming(), isTrue);
  });
}
