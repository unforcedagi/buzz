import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:buzz/features/channels/channel_message_cache/channel_message_cache_storage.dart';
import 'package:buzz/shared/relay/relay.dart';

/// Tests for [ChannelMessageCacheStorage]'s identity/relay scoping and its
/// LRU eviction by both entry count and serialized byte size.
void main() {
  const baseUrl = 'https://relay.example';
  const pubkey = 'pk-a';

  NostrEvent event({
    required String id,
    required String channelId,
    int createdAt = 1,
    String content = 'hi',
  }) {
    return NostrEvent(
      id: id,
      pubkey: pubkey,
      createdAt: createdAt,
      kind: 40002,
      tags: [
        ['h', channelId],
      ],
      content: content,
      sig: 'sig',
    );
  }

  late SharedPreferences prefs;
  late ChannelMessageCacheStorage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    storage = ChannelMessageCacheStorage(prefs);
  });

  test('readChannel returns null when nothing is cached', () {
    expect(
      storage.readChannel(
        baseUrl: baseUrl,
        storedOrigin: baseUrl,
        pubkey: pubkey,
        channelId: 'chan-1',
      ),
      isNull,
    );
  });

  test('writeChannel then readChannel round-trips the newest messages', () {
    final messages = [
      event(id: 'a', channelId: 'chan-1', createdAt: 1),
      event(id: 'b', channelId: 'chan-1', createdAt: 2),
    ];
    storage.writeChannel(
      baseUrl: baseUrl,
      storedOrigin: baseUrl,
      pubkey: pubkey,
      channelId: 'chan-1',
      messages: messages,
    );

    final read = storage.readChannel(
      baseUrl: baseUrl,
      storedOrigin: baseUrl,
      pubkey: pubkey,
      channelId: 'chan-1',
    );
    expect(read?.map((e) => e.id).toList(), ['a', 'b']);
  });

  test('caps stored messages per channel at maxCachedMessagesPerChannel', () {
    final messages = List.generate(
      maxCachedMessagesPerChannel + 20,
      (i) => event(id: 'm$i', channelId: 'chan-1', createdAt: i),
    );
    storage.writeChannel(
      baseUrl: baseUrl,
      storedOrigin: baseUrl,
      pubkey: pubkey,
      channelId: 'chan-1',
      messages: messages,
    );

    final read = storage.readChannel(
      baseUrl: baseUrl,
      storedOrigin: baseUrl,
      pubkey: pubkey,
      channelId: 'chan-1',
    );
    expect(read!.length, maxCachedMessagesPerChannel);
    // Newest ~N kept, oldest dropped.
    expect(read.first.id, 'm20');
    expect(read.last.id, 'm${maxCachedMessagesPerChannel + 19}');
  });

  test('evicts the least-recently-updated channel first once the channel-count '
      'cap is exceeded', () {
    var tick = 0;
    for (var i = 0; i < maxCachedChannels + 3; i++) {
      storage.writeChannel(
        baseUrl: baseUrl,
        storedOrigin: baseUrl,
        pubkey: pubkey,
        channelId: 'chan-$i',
        messages: [event(id: 'm$i', channelId: 'chan-$i')],
        now: () => tick++,
      );
    }

    // Only the most recently written maxCachedChannels channels survive.
    for (var i = 0; i < 3; i++) {
      expect(
        storage.readChannel(
          baseUrl: baseUrl,
          storedOrigin: baseUrl,
          pubkey: pubkey,
          channelId: 'chan-$i',
        ),
        isNull,
        reason: 'chan-$i is oldest and should have been evicted first',
      );
    }
    for (var i = 3; i < maxCachedChannels + 3; i++) {
      expect(
        storage.readChannel(
          baseUrl: baseUrl,
          storedOrigin: baseUrl,
          pubkey: pubkey,
          channelId: 'chan-$i',
        ),
        isNotNull,
      );
    }
  });

  test('evicts oldest-first to stay under the serialized byte cap, even within '
      'the channel-count cap', () {
    // Each full channel (maxCachedMessagesPerChannel messages at this
    // content size) is ~103KB encoded, so 5 of them (528KB, never
    // exceeding the channel-count cap) still forces byte-budget eviction:
    // 2 channels (~211KB) fit under the 256KB cap, 3 (~317KB) do not.
    final bigContent = 'x' * 2000;
    var tick = 0;
    for (var i = 0; i < maxCachedChannels; i++) {
      storage.writeChannel(
        baseUrl: baseUrl,
        storedOrigin: baseUrl,
        pubkey: pubkey,
        channelId: 'chan-$i',
        messages: List.generate(
          maxCachedMessagesPerChannel,
          (m) => event(
            id: 'chan$i-m$m',
            channelId: 'chan-$i',
            content: bigContent,
          ),
        ),
        now: () => tick++,
      );
    }

    final raw = prefs.getString(
      'buzz.channel-message-cache.v1:$baseUrl:$pubkey',
    )!;
    expect(utf8.encode(raw).length, lessThanOrEqualTo(maxCachedBytes));

    // Only the two most recently written channels fit under the byte
    // budget; the three oldest must be evicted first, oldest first.
    for (final survivor in ['chan-3', 'chan-4']) {
      expect(
        storage.readChannel(
          baseUrl: baseUrl,
          storedOrigin: baseUrl,
          pubkey: pubkey,
          channelId: survivor,
        ),
        isNotNull,
        reason: '$survivor is among the most recently written channels',
      );
    }
    for (final evicted in ['chan-0', 'chan-1', 'chan-2']) {
      expect(
        storage.readChannel(
          baseUrl: baseUrl,
          storedOrigin: baseUrl,
          pubkey: pubkey,
          channelId: evicted,
        ),
        isNull,
        reason: '$evicted is older and should be evicted before survivors',
      );
    }
  });

  test('trims a single channel oldest-first when its own messages alone '
      'exceed the byte cap', () {
    // 50 messages at this content length encode to well over maxCachedBytes
    // by themselves (channel content routinely runs 2-4KB in real usage),
    // so this must trim messages rather than store an oversized blob or
    // silently give up once only one channel remains.
    final bigContent = 'x' * 6000;
    final messages = List.generate(
      maxCachedMessagesPerChannel,
      (i) => event(id: 'm$i', channelId: 'chan-solo', content: bigContent),
    );
    storage.writeChannel(
      baseUrl: baseUrl,
      storedOrigin: baseUrl,
      pubkey: pubkey,
      channelId: 'chan-solo',
      messages: messages,
    );

    final raw = prefs.getString(
      'buzz.channel-message-cache.v1:$baseUrl:$pubkey',
    )!;
    expect(utf8.encode(raw).length, lessThanOrEqualTo(maxCachedBytes));

    final read = storage.readChannel(
      baseUrl: baseUrl,
      storedOrigin: baseUrl,
      pubkey: pubkey,
      channelId: 'chan-solo',
    );
    expect(read, isNotNull);
    expect(
      read!.length,
      lessThan(maxCachedMessagesPerChannel),
      reason:
          'the channel alone exceeds the cap, so some messages must '
          'be trimmed',
    );
    // Newest kept, oldest dropped.
    expect(read.last.id, 'm${maxCachedMessagesPerChannel - 1}');
    expect(read.first.id, isNot('m0'));
  });

  test('isolates cached channels by identity and relay', () {
    storage.writeChannel(
      baseUrl: baseUrl,
      storedOrigin: baseUrl,
      pubkey: 'pk-a',
      channelId: 'chan-1',
      messages: [event(id: 'a-msg', channelId: 'chan-1')],
    );

    expect(
      storage.readChannel(
        baseUrl: baseUrl,
        storedOrigin: baseUrl,
        pubkey: 'pk-b',
        channelId: 'chan-1',
      ),
      isNull,
    );
    expect(
      storage.readChannel(
        baseUrl: 'https://relay-b.example',
        storedOrigin: 'https://relay-b.example',
        pubkey: 'pk-a',
        channelId: 'chan-1',
      ),
      isNull,
    );
    expect(
      storage.readChannel(
        baseUrl: baseUrl,
        storedOrigin: baseUrl,
        pubkey: 'pk-a',
        channelId: 'chan-1',
      ),
      isNotNull,
    );
  });
}
