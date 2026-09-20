import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../../shared/relay/identity_scoped_prefs.dart';
import '../../../shared/relay/nostr_models.dart';

/// Newest ~50 messages are kept per cached channel — enough to paint a
/// believable first frame, not a general-purpose offline history store.
const int maxCachedMessagesPerChannel = 50;

/// Only the most recently opened channels are worth painting instantly on
/// cold launch; anything older can wait for the real history load.
const int maxCachedChannels = 5;

/// `SharedPreferences` is a flat-file/plist-backed key-value store, not a
/// database — this caps the whole per-identity-per-relay blob so the cache
/// can never grow into something that store isn't built for. If real usage
/// wants to exceed this, that is a signal to build a real on-disk store, not
/// to raise the cap.
const int maxCachedBytes = 256 * 1024;

const _cacheKeyPrefix = 'buzz.channel-message-cache.v1';

String _cacheKey({required String baseUrl, required String pubkey}) =>
    '$_cacheKeyPrefix:$baseUrl:$pubkey';

/// The newest-known messages for one channel, plus enough bookkeeping to
/// support LRU eviction across channels.
class ChannelMessageCacheEntry {
  final String channelId;

  /// Epoch-millis of the last successful write, used to order channels
  /// oldest-first for eviction.
  final int updatedAt;

  /// Newest-first-trimmed messages in the same ascending chronological order
  /// the live provider uses.
  final List<NostrEvent> messages;

  const ChannelMessageCacheEntry({
    required this.channelId,
    required this.updatedAt,
    required this.messages,
  });

  Map<String, dynamic> toJson() => {
    'channelId': channelId,
    'updatedAt': updatedAt,
    'messages': messages.map((event) => event.toJson()).toList(),
  };

  static ChannelMessageCacheEntry? fromJson(dynamic json) {
    if (json is! Map<String, dynamic>) return null;
    final channelId = json['channelId'];
    final updatedAt = json['updatedAt'];
    final rawMessages = json['messages'];
    if (channelId is! String || updatedAt is! int || rawMessages is! List) {
      return null;
    }
    final messages = <NostrEvent>[];
    for (final rawMessage in rawMessages) {
      if (rawMessage is! Map<String, dynamic>) continue;
      try {
        messages.add(NostrEvent.fromJson(rawMessage));
      } catch (_) {
        // Skip a malformed message rather than discarding the whole cache.
      }
    }
    return ChannelMessageCacheEntry(
      channelId: channelId,
      updatedAt: updatedAt,
      messages: messages,
    );
  }
}

/// The full cached snapshot for one identity on one relay: up to
/// [maxCachedChannels] channels, most-recently-updated first.
class ChannelMessageCacheStore {
  final int version;
  final List<ChannelMessageCacheEntry> channels;

  const ChannelMessageCacheStore({this.version = 1, this.channels = const []});

  Map<String, dynamic> toJson() => {
    'version': version,
    'channels': channels.map((entry) => entry.toJson()).toList(),
  };

  static ChannelMessageCacheStore fromJson(dynamic json) {
    if (json is! Map<String, dynamic> || json['version'] != 1) {
      return const ChannelMessageCacheStore();
    }
    final rawChannels = json['channels'];
    if (rawChannels is! List) return const ChannelMessageCacheStore();
    final channels = <ChannelMessageCacheEntry>[];
    for (final rawChannel in rawChannels) {
      final entry = ChannelMessageCacheEntry.fromJson(rawChannel);
      if (entry != null) channels.add(entry);
    }
    return ChannelMessageCacheStore(channels: channels);
  }
}

/// Disk-backed cache of the newest messages per recently opened channel.
///
/// Scoped per identity **and** per relay using the same
/// `<prefix>:<relay-origin>:<pubkey>` key pattern as
/// [readMigratedPref]'s other callers (e.g. `recentSearchesProvider`,
/// `ComposeDraftsNotifier`) — a cache surviving an identity or community
/// switch would leak one account's messages into another's cold-launch
/// paint.
class ChannelMessageCacheStorage {
  final SharedPreferences _prefs;

  ChannelMessageCacheStorage(this._prefs);

  /// Returns the cached messages for [channelId] under this identity and
  /// relay, or null if nothing is cached.
  List<NostrEvent>? readChannel({
    required String baseUrl,
    required String storedOrigin,
    required String pubkey,
    required String channelId,
  }) {
    final store = _readStore(
      baseUrl: baseUrl,
      storedOrigin: storedOrigin,
      pubkey: pubkey,
    );
    for (final entry in store.channels) {
      if (entry.channelId == channelId) return entry.messages;
    }
    return null;
  }

  /// Persists the newest messages for [channelId], moving it to the front of
  /// the LRU order and evicting older channels to stay within both the
  /// entry-count and serialized-byte caps.
  void writeChannel({
    required String baseUrl,
    required String storedOrigin,
    required String pubkey,
    required String channelId,
    required List<NostrEvent> messages,
    int Function() now = _nowMillis,
  }) {
    final store = _readStore(
      baseUrl: baseUrl,
      storedOrigin: storedOrigin,
      pubkey: pubkey,
    );
    final trimmedMessages = messages.length > maxCachedMessagesPerChannel
        ? messages.sublist(messages.length - maxCachedMessagesPerChannel)
        : messages;
    final nextEntry = ChannelMessageCacheEntry(
      channelId: channelId,
      updatedAt: now(),
      messages: trimmedMessages,
    );
    final remaining = store.channels
        .where((entry) => entry.channelId != channelId)
        .toList();
    // Most-recently-updated first, so both eviction passes below can simply
    // drop from the tail.
    var channels = [nextEntry, ...remaining]
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    if (channels.length > maxCachedChannels) {
      channels = channels.sublist(0, maxCachedChannels);
    }
    channels = _capToByteBudget(channels);

    final key = _cacheKey(baseUrl: baseUrl, pubkey: pubkey);
    _prefs.setString(
      key,
      jsonEncode(ChannelMessageCacheStore(channels: channels).toJson()),
    );
  }

  List<ChannelMessageCacheEntry> _capToByteBudget(
    List<ChannelMessageCacheEntry> channels,
  ) {
    var current = channels;
    // Oldest-first eviction: [channels] is sorted most-recently-updated
    // first, so dropping the tail always removes the least-recently-used
    // channel.
    while (current.length > 1 && _encodedByteLength(current) > maxCachedBytes) {
      current = current.sublist(0, current.length - 1);
    }

    // A single surviving channel can still exceed the budget on its own —
    // channel messages routinely run 2-4KB, so 50 of them is not
    // automatically safe. Trim its oldest messages next, oldest-first, same
    // eviction order as the pass above, instead of silently storing an
    // oversized blob.
    while (current.length == 1 &&
        current.first.messages.isNotEmpty &&
        _encodedByteLength(current) > maxCachedBytes) {
      final entry = current.first;
      current = [
        ChannelMessageCacheEntry(
          channelId: entry.channelId,
          updatedAt: entry.updatedAt,
          messages: entry.messages.sublist(1),
        ),
      ];
    }

    // Even a channel with zero messages left can't fit (pathological, but be
    // honest about it): store nothing rather than an oversized blob.
    if (current.length == 1 && _encodedByteLength(current) > maxCachedBytes) {
      return const [];
    }
    return current;
  }

  int _encodedByteLength(List<ChannelMessageCacheEntry> channels) {
    final encoded = jsonEncode(
      ChannelMessageCacheStore(channels: channels).toJson(),
    );
    return utf8.encode(encoded).length;
  }

  ChannelMessageCacheStore _readStore({
    required String baseUrl,
    required String storedOrigin,
    required String pubkey,
  }) {
    final canonicalKey = _cacheKey(baseUrl: baseUrl, pubkey: pubkey);
    final legacyKey = _cacheKey(baseUrl: storedOrigin, pubkey: pubkey);
    final raw = readMigratedPref<String>(
      _prefs,
      canonicalKey: canonicalKey,
      legacyKey: legacyKey,
      read: _prefs.getString,
      write: _prefs.setString,
    );
    if (raw == null || raw.isEmpty) return const ChannelMessageCacheStore();
    try {
      return ChannelMessageCacheStore.fromJson(jsonDecode(raw));
    } catch (_) {
      return const ChannelMessageCacheStore();
    }
  }
}

int _nowMillis() => DateTime.now().millisecondsSinceEpoch;
