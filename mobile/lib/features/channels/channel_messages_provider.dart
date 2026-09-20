import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';
import '../../shared/theme/theme_provider.dart' show savedPrefsProvider;
import 'channel_event_order.dart';
import 'channel_message_cache/channel_message_cache_storage.dart';
import 'pending_local_messages_provider.dart';
import 'channel_window.dart';
import 'thread_replies_provider.dart';

const _channelLiveEventKinds = [
  ...EventKind.channelEventKinds,
  EventKind.channelThreadSummary,
];

/// Provides the message list for a specific channel. Registers a live
/// subscription first, then syncs history via the server-assembled channel
/// window fast path, falling back to the legacy websocket history path when the
/// relay does not return a valid NIP-CW bounds overlay.
class ChannelMessagesNotifier extends Notifier<AsyncValue<List<NostrEvent>>> {
  final String channelId;
  void Function()? _unsubscribe;
  bool _reachedOldest = false;
  bool _initInFlight = false;
  bool _usingChannelWindow = false;
  bool _initialWindowQueryInFlight = false;
  int _initVersion = 0;
  ChannelWindowStore _windowStore = const ChannelWindowStore.empty();
  final Set<String> _liveSummaryRootsDuringInitialWindowQuery = {};
  final Map<String, NostrEvent> _deepLinkEvents = {};
  final Set<String> _retainedDeepLinkEventIds = {};

  /// The identity/relay this instance's in-memory state was populated under.
  /// `null` before the first `build()`, so the very first build never counts
  /// as a "switch" (there is nothing to leak yet).
  ({String? pubkey, String baseUrl})? _populatedFor;

  ChannelMessagesNotifier(this.channelId);

  /// Last successfully loaded messages, preserved across reconnections so the
  /// UI can show stale data instead of a blank loading spinner.
  List<NostrEvent>? _lastKnownMessages;

  /// Whether this channel has a last-known truth to show — not whether a
  /// network load happened.
  ///
  /// This distinguishes a channel we know about from the synthetic empty
  /// value returned while the relay is not yet connected. A disk snapshot
  /// sets it too, which is why it is phrased as last-known rather than
  /// loaded: `_readCachedSnapshot` returns null for an empty snapshot and
  /// writes skip empty lists, so `hasLoadedMessages && messages.isEmpty`
  /// still means a network load came back empty. That invariant lives in
  /// those two places, not here — if either changes, this getter's meaning
  /// changes with it and the empty-state branch in `_MessageList` will need
  /// splitting.
  bool get hasLoadedMessages => _lastKnownMessages != null;

  Map<String, ChannelWindowThreadSummary> get threadSummaries =>
      channelWindowThreadSummaries(_windowStore);

  @override
  AsyncValue<List<NostrEvent>> build() {
    // This provider is a `NotifierProvider.family` keyed only by `channelId`,
    // and it is not autoDispose: the same notifier instance survives an
    // identity switch (same-relay identities share NIP-29 channel ids), so
    // every in-memory field below is a potential cross-identity leak unless
    // it's explicitly reset here. Watching identity + relay origin makes this
    // build() re-run on a switch even while connected, which the previous
    // relaySessionProvider-only watch did not guarantee.
    final identityPubkey = ref.watch(myPubkeyProvider);
    final identityBaseUrl = ref.watch(
      relayConfigProvider.select((config) => config.baseUrl),
    );
    final identity = (pubkey: identityPubkey, baseUrl: identityBaseUrl);
    if (_populatedFor != null && _populatedFor != identity) {
      _resetForIdentitySwitch();
    }
    _populatedFor = identity;

    final sessionState = ref.watch(relaySessionProvider);
    ref.onDispose(() {
      _initVersion++;
      _clearSubscription();
    });

    if (sessionState.status != SessionStatus.connected) {
      _initVersion++;
      _initInFlight = false;
      _initialWindowQueryInFlight = false;
      _liveSummaryRootsDuringInitialWindowQuery.clear();
      // A cold launch has no in-memory `_lastKnownMessages` yet, but a prior
      // session may have left a disk snapshot for this exact channel. Reading
      // it here (SharedPreferences is preloaded before `runApp`, so this is
      // synchronous) lets the first frame paint real content instead of the
      // disconnected placeholder. `_resetForIdentitySwitch` above clears
      // `_lastKnownMessages` on an identity/relay change, so this re-reads
      // for the new identity instead of keeping the old one's `??=` value.
      _lastKnownMessages ??= _readCachedSnapshot();
      return AsyncData(_lastKnownMessages ?? const []);
    }

    _reachedOldest = false;
    _windowStore = const ChannelWindowStore.empty();
    _usingChannelWindow = false;
    _initialWindowQueryInFlight = false;
    _liveSummaryRootsDuringInitialWindowQuery.clear();
    _init();
    if (_lastKnownMessages case final cached? when cached.isNotEmpty) {
      return AsyncData(cached);
    }
    return const AsyncLoading();
  }

  /// Clears every in-memory field that is scoped to the previous identity or
  /// relay before this build() serves the new one.
  ///
  /// - `_lastKnownMessages`: the actual leak — must be cleared so the
  ///   disconnected branch's `??=` re-reads the new identity's disk cache
  ///   (or shows nothing) instead of keeping the old identity's messages.
  /// - `_windowStore`, `_usingChannelWindow`, `_reachedOldest`,
  ///   `_initialWindowQueryInFlight`,
  ///   `_liveSummaryRootsDuringInitialWindowQuery`: server-assembled window
  ///   state for this channel on the *old* relay/identity. The `connected`
  ///   branch below already zeros it on every build, so the reconnect path
  ///   is not the reason to clear it here. The reasons are that
  ///   `threadSummaries` is read straight off `_windowStore` on every
  ///   `ChannelDetailPage` build — including while the new identity is still
  ///   disconnected, which would show the old identity's reply counts — and
  ///   that an in-flight writer can land after that zeroing (see the
  ///   `_isCurrentInit` fences in `_fetchNewestHistory` and `fetchOlder`).
  /// - `_deepLinkEvents` / `_retainedDeepLinkEventIds`: pinned events fetched
  ///   for a deep link belong to whichever relay/identity fetched them.
  /// - Subscription (`_clearSubscription`) and `_initInFlight`: an in-flight
  ///   `_init()` or live subscription callback from the old identity's
  ///   session must not be allowed to land and repopulate
  ///   `_lastKnownMessages`/`state` after the switch; `_initVersion++` makes
  ///   any such in-flight callback a no-op via `_isCurrentInit`.
  void _resetForIdentitySwitch() {
    _initVersion++;
    _clearSubscription();
    _initInFlight = false;
    _lastKnownMessages = null;
    _windowStore = const ChannelWindowStore.empty();
    _usingChannelWindow = false;
    _reachedOldest = false;
    _initialWindowQueryInFlight = false;
    _liveSummaryRootsDuringInitialWindowQuery.clear();
    _deepLinkEvents.clear();
    _retainedDeepLinkEventIds.clear();
  }

  Future<void> _init() async {
    final initVersion = ++_initVersion;
    _initInFlight = true;
    _clearSubscription();
    try {
      final session = ref.read(relaySessionProvider.notifier);

      try {
        final unsubscribe = await session.subscribe(
          NostrFilter(
            kinds: _channelLiveEventKinds,
            tags: {
              '#h': [channelId],
            },
            since: _currentUnixSeconds(),
            limit: 200,
          ),
          // Fenced to the init that opened it: `_clearSubscription()` stops
          // future delivery on an identity switch, but a callback already
          // dispatched for the previous identity can still be in flight, and
          // `_handleLiveEvent` writes `_lastKnownMessages` and `_windowStore`
          // directly.
          (event, {bool authoritative = true}) {
            if (!_isCurrentInit(initVersion)) return;
            _handleLiveEvent(event, authoritative: authoritative);
          },
        );
        if (!_isCurrentInit(initVersion)) {
          unsubscribe();
          return;
        }
        _unsubscribe = unsubscribe;
      } catch (error) {
        if (!_isCurrentInit(initVersion)) return;
        debugPrint(
          '[ChannelMessagesNotifier] live subscription failed for $channelId: $error',
        );
      }

      final history = await _fetchNewestHistory(session, initVersion);
      if (!_isCurrentInit(initVersion)) return;
      _confirmLocalMessages(history.map((event) => event.id));

      final existing = state.value ?? const <NostrEvent>[];
      final existingIds = existing.map((event) => event.id).toSet();
      final merged = _withDeepLinkEvents([
        ...existing,
        ...history.where((event) => existingIds.add(event.id)),
      ]);
      _lastKnownMessages = merged;
      state = AsyncData(merged);
      // Snapshot on a successful load only — not on every live event, which
      // would turn a busy channel into a write on every message.
      if (merged.isNotEmpty) _writeCachedSnapshot(merged);
    } catch (e, st) {
      if (!_isCurrentInit(initVersion)) return;
      final fallbackMessages = state.value ?? _lastKnownMessages;
      if (fallbackMessages != null) {
        debugPrint(
          '[ChannelMessagesNotifier] history sync failed for $channelId: $e',
        );
        state = AsyncData(fallbackMessages);
        return;
      }
      state = AsyncError(e, st);
    } finally {
      if (_isCurrentInit(initVersion)) {
        _initInFlight = false;
      }
    }
  }

  Future<List<NostrEvent>> _fetchNewestHistory(
    RelaySessionNotifier session,
    int initVersion,
  ) async {
    try {
      _initialWindowQueryInFlight = true;
      final page = await _fetchWindowPage(session, null);
      // An identity or relay switch during the await already reset this
      // notifier's state. Installing this page would write the previous
      // identity's window — including the live summaries retained below —
      // back over it. The caller's own `_isCurrentInit` check happens after
      // we return, which is too late for these fields.
      if (!_isCurrentInit(initVersion)) return const [];
      _initialWindowQueryInFlight = false;
      _windowStore = replaceNewestChannelWindow(
        _windowStore,
        page,
        retainLiveSummaryRootIds: _liveSummaryRootsDuringInitialWindowQuery,
      );
      _liveSummaryRootsDuringInitialWindowQuery.clear();
      _usingChannelWindow = true;
      _reachedOldest = !channelWindowHasMore(_windowStore);
      return flattenChannelWindowEvents(_windowStore);
    } catch (error) {
      if (!_isCurrentInit(initVersion)) return const [];
      _initialWindowQueryInFlight = false;
      _liveSummaryRootsDuringInitialWindowQuery.clear();
      debugPrint(
        '[ChannelMessagesNotifier] channel window unavailable for $channelId, falling back to WS history: $error',
      );
      _usingChannelWindow = false;
      final history = await session.fetchHistory(
        NostrFilters.messages(channelId),
      );
      history.sort(compareChannelTimelineEventsChronologically);
      return history;
    }
  }

  Future<ChannelWindowPage> _fetchWindowPage(
    RelaySessionNotifier session,
    ChannelPageCursor? cursor,
  ) async {
    final events = await session.queryRelay([_channelWindowFilter(cursor)]);
    return parseChannelWindowResponse(events, channelId, cursor);
  }

  NostrFilter _channelWindowFilter(ChannelPageCursor? cursor) => NostrFilter(
    kinds: EventKind.channelTimelineContentKinds,
    tags: {
      '#h': [channelId],
    },
    limit: 50,
    until: cursor?.createdAt,
    extensions: {
      'top_level': true,
      'include_summaries': true,
      'include_aux': true,
      if (cursor != null) 'before_id': cursor.eventId,
    },
  );

  void _handleLiveEvent(NostrEvent event, {bool authoritative = true}) {
    // Invalidate the thread query independently of the selected channel-history
    // path. The websocket fallback does not merge through the window store.
    _invalidateThreadReplies(event);
    // A live summary can race the initial channel-window query. Buffer it in
    // the window store even before that query installs its first page, rather
    // than treating metadata as an ordinary websocket timeline event.
    if (event.kind == EventKind.channelThreadSummary && !_usingChannelWindow) {
      final rootId = _initialWindowQueryInFlight
          ? event.getTagValue('e')
          : null;
      if (_mergeWindowEventIntoStore(event)) {
        if (rootId != null) {
          _liveSummaryRootsDuringInitialWindowQuery.add(rootId);
        }
        if (_initInFlight) return;
        final current =
            state.value ?? _lastKnownMessages ?? const <NostrEvent>[];
        _lastKnownMessages = current;
        state = AsyncData(current);
      }
      return;
    }

    // Reply ownership and its thread-local overlay must transition together.
    // The authoritative thread query performs both confirmations after it
    // contains the reply; a live echo only triggers that query below.
    if (authoritative && event.threadReference.parentId == null) {
      _confirmLocalMessages([event.id]);
    }
    if (_usingChannelWindow) {
      _handleWindowLiveEvent(event);
    } else {
      final current = state.value ?? _lastKnownMessages ?? const <NostrEvent>[];
      final merged = _mergeEvent(current, event);
      _lastKnownMessages = merged;
      state = AsyncData(merged);
    }
  }

  void _handleWindowLiveEvent(NostrEvent event) {
    if (!_mergeWindowEventIntoStore(event)) return;
    final windowEvents = flattenChannelWindowEvents(_windowStore);
    // Flattening already orders the window. Only merge and sort again when
    // there are retained deep-link events to include.
    final flattened = _deepLinkEvents.isEmpty
        ? windowEvents
        : _withDeepLinkEvents(windowEvents);
    _lastKnownMessages = flattened;
    state = AsyncData(flattened);
  }

  void _invalidateThreadReplies(NostrEvent event) {
    if (!EventKind.channelTimelineContentKinds.contains(event.kind)) return;
    final thread = event.threadReference;
    if (thread.parentId == null) return;

    final rootId = thread.rootId;
    if (rootId != null) {
      ref.invalidate(
        threadRepliesProvider(
          ThreadRepliesArgs(channelId: channelId, rootId: rootId),
        ),
      );
    }
    final parentId = thread.parentId;
    if (parentId != null && parentId != rootId) {
      ref.invalidate(
        threadRepliesProvider(
          ThreadRepliesArgs(channelId: channelId, rootId: parentId),
        ),
      );
    }
  }

  bool _mergeWindowEventIntoStore(NostrEvent event) {
    final isTimelineRow = EventKind.channelTimelineContentKinds.contains(
      event.kind,
    );
    final thread = isTimelineRow ? event.threadReference : null;
    if (thread?.parentId != null) {
      // Replies are kept in the store rather than dropped here, matching
      // desktop: the main timeline filters them out at render
      // (`buildMainTimelineEntries`), and their parent's "N replies" row needs
      // them as the local half of the summary merge when the relay's
      // best-effort recount is delayed, lost, or older than this reply.
    }
    // Thread summaries are neither a timeline row nor an aux event, but they are
    // how the root's "N replies" row learns a reply landed — a reply itself
    // never reaches the main timeline. Dropping them here meant the count only
    // appeared after leaving the channel and coming back, which refetched.
    if (!isTimelineRow &&
        event.kind != EventKind.channelThreadSummary &&
        !EventKind.channelAuxEventKinds.contains(event.kind)) {
      return false;
    }

    final next = mergeLiveChannelWindowEvent(
      _windowStore,
      event,
      isTimelineRow: isTimelineRow,
    );
    if (identical(next, _windowStore)) return false;
    _windowStore = next;
    return true;
  }

  void _confirmLocalMessages(Iterable<String> eventIds) {
    ref
        .read(pendingLocalMessagesProvider(channelId).notifier)
        .confirm(eventIds);
  }

  /// Adds a just-signed outgoing message before the relay acknowledges it.
  /// The live relay echo is deduplicated by event id.
  void addLocalMessage(NostrEvent event) {
    ref.read(pendingLocalMessagesProvider(channelId).notifier).add(event);
    final thread = event.threadReference;
    if (thread.parentId != null) {
      final rootId = thread.rootId;
      if (rootId == null) {
        throw StateError('Reply ${event.id} has a parent but no thread root.');
      }
      ref
          .read(
            threadLocalRepliesProvider(
              ThreadRepliesArgs(channelId: channelId, rootId: rootId),
            ).notifier,
          )
          .add(event);
      return;
    }

    final isTimelineRow = EventKind.channelTimelineContentKinds.contains(
      event.kind,
    );
    if (!_usingChannelWindow && isTimelineRow) {
      _windowStore = mergeLiveChannelWindowEvent(
        _windowStore,
        event,
        isTimelineRow: true,
      );
    }
    _handleLiveEvent(event, authoritative: false);
  }

  /// Releases rollback ownership after the publish future succeeds. The
  /// optimistic row (and any thread overlay) remains visible until relay data
  /// replaces it, because OK and EVENT delivery are unordered.
  void completeLocalMessage(String eventId) {
    _confirmLocalMessages([eventId]);
  }

  /// Rolls back a local message when its publish is rejected or times out.
  void removeLocalMessage(String eventId) {
    final pending = ref
        .read(pendingLocalMessagesProvider(channelId).notifier)
        .take(eventId);
    if (pending == null) return;

    final thread = pending.threadReference;
    if (thread.parentId != null) {
      final rootId = thread.rootId;
      if (rootId == null) {
        throw StateError('Reply $eventId has a parent but no thread root.');
      }
      ref
          .read(
            threadLocalRepliesProvider(
              ThreadRepliesArgs(channelId: channelId, rootId: rootId),
            ).notifier,
          )
          .remove(eventId);
      return;
    }

    final nextOverlay = _windowStore.liveOverlay
        .where((event) => event.id != eventId)
        .toList();
    if (nextOverlay.length != _windowStore.liveOverlay.length) {
      _windowStore = ChannelWindowStore(
        pages: _windowStore.pages,
        liveOverlay: nextOverlay,
        liveAux: _windowStore.liveAux,
        liveThreadSummaries: _windowStore.liveThreadSummaries,
      );
    }

    final current = state.value ?? _lastKnownMessages ?? const <NostrEvent>[];
    final next = current.where((event) => event.id != eventId).toList();
    _lastKnownMessages = next;
    state = AsyncData(next);
  }

  static List<NostrEvent> _mergeEvent(
    List<NostrEvent> current,
    NostrEvent incoming,
  ) {
    if (current.any((e) => e.id == incoming.id)) return current;
    final updated = [...current, incoming];
    updated.sort(compareChannelTimelineEventsChronologically);
    return updated;
  }

  /// Reads this channel's cached newest-message snapshot from disk, scoped to
  /// the active identity and relay so a switch between them can never surface
  /// another identity's messages.
  ///
  /// Returns null (and touches no storage) when there is no resolved
  /// identity yet. There is no shared "no identity" bucket to fall back to:
  /// that would let two different signed-out states, or a transient gap
  /// before the real pubkey resolves, share one identity's cache. A null
  /// result here just means this build sees no cache; `_lastKnownMessages
  /// ??= ...` retries on the next build once a real pubkey is available.
  List<NostrEvent>? _readCachedSnapshot() {
    final pubkey = ref.read(myPubkeyProvider);
    if (pubkey == null || pubkey.isEmpty) return null;
    final config = ref.read(relayConfigProvider);
    final cached = ChannelMessageCacheStorage(ref.read(savedPrefsProvider))
        .readChannel(
          baseUrl: config.baseUrl,
          storedOrigin: config.storedOrigin,
          pubkey: pubkey,
          channelId: channelId,
        );
    return cached == null || cached.isEmpty ? null : cached;
  }

  /// Persists [messages] as this channel's newest-message snapshot, scoped to
  /// the active identity and relay. Caller-side LRU across channels (entry
  /// count and serialized bytes) is handled by [ChannelMessageCacheStorage].
  ///
  /// A no-op when there is no resolved identity — see [_readCachedSnapshot].
  void _writeCachedSnapshot(List<NostrEvent> messages) {
    final pubkey = ref.read(myPubkeyProvider);
    if (pubkey == null || pubkey.isEmpty) return;
    final config = ref.read(relayConfigProvider);
    ChannelMessageCacheStorage(ref.read(savedPrefsProvider)).writeChannel(
      baseUrl: config.baseUrl,
      storedOrigin: config.storedOrigin,
      pubkey: pubkey,
      channelId: channelId,
      messages: messages,
    );
  }

  bool _isCurrentInit(int initVersion) => initVersion == _initVersion;

  void _clearSubscription() {
    _unsubscribe?.call();
    _unsubscribe = null;
  }

  bool get reachedOldest => _reachedOldest;

  /// Loads specific deep-link targets that may fall outside the newest window.
  Future<void> loadEventsById(Iterable<String> eventIds) async {
    final ids = eventIds.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    _retainedDeepLinkEventIds.addAll(ids);

    final existing = state.value ?? const <NostrEvent>[];
    for (final event in existing) {
      if (ids.contains(event.id)) _deepLinkEvents[event.id] = event;
    }
    ids.removeAll(_deepLinkEvents.keys);
    if (ids.isEmpty) return;

    final events = await ref
        .read(relaySessionProvider.notifier)
        .fetchHistory(
          NostrFilter(
            kinds: EventKind.channelTimelineContentKinds,
            ids: ids.toList(),
            limit: ids.length,
          ),
        );
    for (final event in events) {
      if (event.channelId == channelId &&
          _retainedDeepLinkEventIds.contains(event.id)) {
        _deepLinkEvents[event.id] = event;
      }
    }

    // Let the initial history load publish the complete timeline once it
    // finishes. Publishing a target-only list here would make the UI consume
    // its one-shot jump against a provisional ordering.
    if (_initInFlight) return;
    final merged = _withDeepLinkEvents(
      state.value ?? _lastKnownMessages ?? const [],
    );
    _lastKnownMessages = merged;
    state = AsyncData(merged);
  }

  /// Stops pinning deep-link-only events into subsequent window rebuilds.
  void releaseDeepLinkEvents(Iterable<String> eventIds) {
    for (final id in eventIds) {
      _retainedDeepLinkEventIds.remove(id);
      _deepLinkEvents.remove(id);
    }
  }

  List<NostrEvent> _withDeepLinkEvents(List<NostrEvent> events) {
    final ids = events.map((event) => event.id).toSet();
    return [
      ...events,
      ..._deepLinkEvents.values.where((event) => ids.add(event.id)),
    ]..sort(compareChannelTimelineEventsChronologically);
  }

  Future<bool> fetchOlder() async {
    if (_reachedOldest || _initInFlight) return false;

    // Pagination outlives its own awaits, so an identity or relay switch can
    // land mid-fetch. Everything below writes instance state; none of it may
    // run against a notifier that has since been reset for another identity.
    final initVersion = _initVersion;
    final session = ref.read(relaySessionProvider.notifier);
    if (_usingChannelWindow) {
      final cursor = channelWindowNextCursor(_windowStore);
      if (cursor == null) {
        _reachedOldest = true;
        return false;
      }
      try {
        final page = await _fetchWindowPage(session, cursor);
        if (!_isCurrentInit(initVersion)) return false;
        _windowStore = appendOlderChannelWindow(_windowStore, page);
        _reachedOldest = !channelWindowHasMore(_windowStore);
        final flattened = _withDeepLinkEvents(
          flattenChannelWindowEvents(_windowStore),
        );
        _lastKnownMessages = flattened;
        state = AsyncData(flattened);
        return page.rows.isNotEmpty || page.aux.isNotEmpty;
      } catch (error) {
        debugPrint(
          '[ChannelMessagesNotifier] failed to fetch older channel window page for $channelId: $error',
        );
        return false;
      }
    }

    final currentEvents = state.value;
    if (currentEvents == null || currentEvents.isEmpty) return false;
    final oldest = currentEvents.first.createdAt;
    final older = await session.fetchHistory(
      NostrFilters.messages(channelId, limit: 100, until: oldest),
    );
    if (!_isCurrentInit(initVersion)) return false;
    if (older.isEmpty) {
      _reachedOldest = true;
      return false;
    }
    final currentIds = state.value?.map((e) => e.id).toSet() ?? {};
    final deduped = older.where((e) => !currentIds.contains(e.id)).toList();
    if (deduped.isEmpty) {
      _reachedOldest = true;
      return false;
    }
    state = state.whenData((events) {
      final merged = [...deduped, ...events];
      merged.sort(compareChannelTimelineEventsChronologically);
      _lastKnownMessages = merged;
      return merged;
    });
    return true;
  }
}

int _currentUnixSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

final channelMessagesProvider =
    NotifierProvider.family<
      ChannelMessagesNotifier,
      AsyncValue<List<NostrEvent>>,
      String
    >(ChannelMessagesNotifier.new);
