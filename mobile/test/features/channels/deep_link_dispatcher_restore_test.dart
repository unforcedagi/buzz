import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channels_provider.dart';
import 'package:buzz/features/channels/deep_link_dispatcher.dart';
import 'package:buzz/shared/deeplink/deep_link.dart';
import 'package:buzz/shared/deeplink/pending_deep_link_provider.dart';
import 'package:buzz/shared/last_conversation/last_conversation_storage.dart';
import 'package:buzz/shared/read_state/read_state_provider.dart';
import 'package:buzz/shared/theme/theme_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const pubkey = 'aa';

  Future<SharedPreferences> prefs({String? storedChannelId}) async {
    final seed = <String, String>{};
    if (storedChannelId != null) {
      seed[lastConversationKey(pubkey)] = storedChannelId;
    }
    SharedPreferences.setMockInitialValues(seed);
    return SharedPreferences.getInstance();
  }

  Future<(ProviderContainer, dynamic)> pumpRestoreApp(
    WidgetTester tester, {
    required SharedPreferences prefs,
    required ChannelsNotifier channelsNotifier,
    PendingDeepLinkNotifier? pending,
    _RecordingDestinationBuilder? builder,
    _InactiveReadStateNotifier? readState,
  }) async {
    final container = ProviderContainer(
      overrides: [
        savedPrefsProvider.overrideWithValue(prefs),
        readStateProvider.overrideWith(
          () => readState ?? _InactiveReadStateNotifier(pubkey),
        ),
        channelsProvider.overrideWith(() => channelsNotifier),
        if (pending != null)
          pendingDeepLinkProvider.overrideWith(() => pending),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: DeepLinkDispatcher(
            destinationBuilder: builder?.build,
            child: const Scaffold(body: Text('home')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, builder);
  }

  testWidgets(
    'restores the stored channel once after the first channels load',
    (tester) async {
      final builder = _RecordingDestinationBuilder();
      final notifier = _EmittingChannelsNotifier(Future.value([_channel]));
      await pumpRestoreApp(
        tester,
        prefs: await prefs(storedChannelId: 'channel-1'),
        channelsNotifier: notifier,
        builder: builder,
      );

      expect(find.text('opened:channel-1'), findsOneWidget);
      expect(builder.pushed.map((c) => c.id), ['channel-1']);
    },
  );

  testWidgets('does not restore when no channel was stored', (tester) async {
    final builder = _RecordingDestinationBuilder();
    final notifier = _EmittingChannelsNotifier(Future.value([_channel]));
    await pumpRestoreApp(
      tester,
      prefs: await prefs(),
      channelsNotifier: notifier,
      builder: builder,
    );

    expect(find.text('home'), findsOneWidget);
    expect(builder.pushed, isEmpty);
  });

  testWidgets('deeplink target wins; restore never adds a second push', (
    tester,
  ) async {
    final builder = _RecordingDestinationBuilder();
    final notifier = _EmittingChannelsNotifier(Future.value([_channel]));
    await pumpRestoreApp(
      tester,
      prefs: await prefs(storedChannelId: 'channel-1'),
      channelsNotifier: notifier,
      pending: _PendingDeepLinkNotifier(
        const ChannelDeepLink(channelId: 'channel-1'),
      ),
      builder: builder,
    );

    final destination = tester.widget<_CapturedDestination>(
      find.byType(_CapturedDestination),
    );
    expect(destination.channel.id, 'channel-1');
    // Exactly one push, made by the deep link dispatch.
    expect(builder.pushed.map((c) => c.id), ['channel-1']);
  });

  testWidgets(
    'a stored id that is absent from the loaded list is not restored and is cleared',
    (tester) async {
      final builder = _RecordingDestinationBuilder();
      final notifier = _EmittingChannelsNotifier(Future.value([_channel]));
      final prefsInstance = await prefs(storedChannelId: 'channel-gone');
      await pumpRestoreApp(
        tester,
        prefs: prefsInstance,
        channelsNotifier: notifier,
        builder: builder,
      );

      expect(find.text('home'), findsOneWidget);
      expect(builder.pushed, isEmpty);
      final storage = LastConversationStorage(prefsInstance);
      expect(storage.read(pubkey), isNull);
    },
  );

  testWidgets('a second channels emission does not push again', (tester) async {
    final builder = _RecordingDestinationBuilder();
    final notifier = _EmittingChannelsNotifier(Future.value([_channel]));
    await pumpRestoreApp(
      tester,
      prefs: await prefs(storedChannelId: 'channel-1'),
      channelsNotifier: notifier,
      builder: builder,
    );
    expect(builder.pushed.map((c) => c.id), ['channel-1']);

    notifier.emit([_channel, _secondChannel]);
    await tester.pumpAndSettle();

    expect(builder.pushed.map((c) => c.id), ['channel-1']);
    expect(find.byType(_CapturedDestination), findsOneWidget);
  });

  testWidgets(
    'identity ready after the first channels load still restores once',
    (tester) async {
      final builder = _RecordingDestinationBuilder();
      final notifier = _EmittingChannelsNotifier(Future.value([_channel]));
      final readState = _InactiveReadStateNotifier(null);
      await pumpRestoreApp(
        tester,
        prefs: await prefs(storedChannelId: 'channel-1'),
        channelsNotifier: notifier,
        builder: builder,
        readState: readState,
      );

      expect(builder.pushed, isEmpty, reason: 'identity not ready yet');

      readState.reveal();
      await tester.pumpAndSettle();

      expect(builder.pushed.map((c) => c.id), ['channel-1']);
      expect(find.text('opened:channel-1'), findsOneWidget);
    },
  );

  testWidgets(
    'a second channels emission after a pending deep link does not push again',
    (tester) async {
      final builder = _RecordingDestinationBuilder();
      final notifier = _EmittingChannelsNotifier(Future.value([_channel]));
      await pumpRestoreApp(
        tester,
        prefs: await prefs(storedChannelId: 'channel-1'),
        channelsNotifier: notifier,
        pending: _PendingDeepLinkNotifier(
          const ChannelDeepLink(channelId: 'channel-1'),
        ),
        builder: builder,
      );
      expect(builder.pushed.map((c) => c.id), ['channel-1']);

      notifier.emit([_channel, _secondChannel]);
      await tester.pumpAndSettle();

      expect(builder.pushed.map((c) => c.id), ['channel-1']);
      expect(find.byType(_CapturedDestination), findsOneWidget);
    },
  );
}

final _secondChannel = Channel(
  id: 'channel-2',
  name: 'random',
  channelType: 'stream',
  visibility: 'open',
  description: 'Other discussion',
  createdBy: 'creator',
  createdAt: DateTime(2026),
  memberCount: 2,
  isMember: true,
);

final _channel = Channel(
  id: 'channel-1',
  name: 'general',
  channelType: 'stream',
  visibility: 'open',
  description: 'General discussion',
  createdBy: 'creator',
  createdAt: DateTime(2026),
  memberCount: 2,
  isMember: true,
);

class _InactiveReadStateNotifier extends ReadStateNotifier {
  _InactiveReadStateNotifier(this.pubkey);

  String? pubkey;

  @override
  ReadStateState build() => _state();

  void reveal() {
    pubkey = 'aa';
    state = _state();
  }

  ReadStateState _state() => ReadStateState(
    isReady: false,
    pubkey: pubkey,
    contexts: const {},
    version: 0,
  );
}

class _PendingDeepLinkNotifier extends PendingDeepLinkNotifier {
  _PendingDeepLinkNotifier(this.link);

  final BuzzDeepLink link;

  @override
  BuzzDeepLink? build() => link;
}

class _EmittingChannelsNotifier extends ChannelsNotifier {
  _EmittingChannelsNotifier(this.channels);

  final Future<List<Channel>> channels;

  @override
  Future<List<Channel>> build() => channels;

  void emit(List<Channel> next) {
    state = AsyncValue.data(next);
  }
}

class _RecordingDestinationBuilder {
  final pushed = <Channel>[];

  Widget build(Channel channel, BuzzDeepLink link) {
    pushed.add(channel);
    return _CapturedDestination(channel: channel);
  }
}

class _CapturedDestination extends StatelessWidget {
  const _CapturedDestination({required this.channel});

  final Channel channel;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text('opened:${channel.id}'));
}
