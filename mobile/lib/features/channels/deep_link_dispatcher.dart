import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/deeplink/deep_link.dart';
import '../../shared/deeplink/pending_deep_link_provider.dart';
import '../../shared/last_conversation/last_conversation_storage.dart';
import '../../shared/read_state/read_state_provider.dart';
import '../invites/invite_join_provider.dart';
import '../invites/invite_join_sheet.dart';
import 'channel.dart';
import 'channel_detail_page.dart';
import 'channels_provider.dart';

/// Routes pending `buzz://message` deep links into the channel view.
///
/// Wraps the authenticated home subtree. Whenever a parsed link is parked in
/// [pendingDeepLinkProvider] and the channel list is available, this pushes
/// the target [ChannelDetailPage] on the enclosing [Navigator]. Links are
/// held (not dropped) while channels are still loading, so cold-start links
/// dispatch as soon as the first channel fetch completes.
typedef DeepLinkDestinationBuilder =
    Widget Function(Channel channel, BuzzDeepLink link);

class DeepLinkDispatcher extends ConsumerStatefulWidget {
  final Widget child;
  final DeepLinkDestinationBuilder? destinationBuilder;
  final bool dispatchMessageLinks;

  const DeepLinkDispatcher({
    super.key,
    required this.child,
    this.destinationBuilder,
    this.dispatchMessageLinks = true,
  });

  @override
  ConsumerState<DeepLinkDispatcher> createState() => _DeepLinkDispatcherState();
}

class _DeepLinkDispatcherState extends ConsumerState<DeepLinkDispatcher> {
  bool _preparingInvite = false;
  bool _lastConversationRestored = false;
  bool _listeningIdentityPubkey = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Snapshot before dispatch: a channel deep link is consumed
      // synchronously, so restore afterwards would see pending == null and
      // push a second navigation on cold start. When a link was pending, it
      // owns this launch — spend the one-shot on it.
      final hadPendingLink = ref.read(pendingDeepLinkProvider) != null;
      _maybeDispatch(ref.read(pendingDeepLinkProvider));
      if (hadPendingLink) {
        _lastConversationRestored = true;
        return;
      }
      _maybeRestoreLastConversation();
    });
  }

  @override
  Widget build(BuildContext context) {
    // Re-evaluate dispatch when either a new link arrives or channels load.
    ref.listen<BuzzDeepLink?>(pendingDeepLinkProvider, (_, link) {
      _maybeDispatch(link);
    });
    // Identity can become ready after the first channels load; when a restore
    // attempt hits that case, _maybeRestoreLastConversation subscribes to the
    // pubkey so the restore retries on its own instead of waiting for a
    // channels refresh.
    if (widget.dispatchMessageLinks) {
      ref.listen<AsyncValue<List<Channel>>>(channelsProvider, (_, _) {
        // Dispatch runs first and may consume a pending link synchronously;
        // when a link was pending on this pass it owns the launch — spend the
        // one-shot on it so resume refreshes never restore on top of it.
        final hadPendingLink = ref.read(pendingDeepLinkProvider) != null;
        _maybeDispatch(ref.read(pendingDeepLinkProvider));
        if (hadPendingLink) {
          _lastConversationRestored = true;
          return;
        }
        _maybeRestoreLastConversation();
      });
    }

    return widget.child;
  }

  /// On the first successful channels load of the process, reopen the
  /// conversation the user was last in. A pending deep link always wins; a
  /// stored id that no longer resolves to a channel is cleared and ignored.
  /// The one-shot flag is spent only when the launch has been claimed — by the
  /// deep link, or by a restore — so "identity not ready yet" keeps retrying.
  void _maybeRestoreLastConversation() {
    if (_lastConversationRestored || !mounted) return;
    final channels = ref.read(channelsProvider).asData?.value;
    if (channels == null) return;
    if (ref.read(pendingDeepLinkProvider) != null) {
      _lastConversationRestored = true;
      return;
    }
    final pubkey = ref.read(readStateProvider).pubkey;
    if (pubkey == null) {
      _listenForIdentityPubkey();
      return; // identity not ready yet — keep retrying
    }
    _lastConversationRestored = true;
    final storage = ref.read(lastConversationStorageProvider);
    final storedChannelId = storage.read(pubkey);
    if (storedChannelId == null) return;

    final channel = channels
        .where((candidate) => candidate.id == storedChannelId)
        .cast<Channel?>()
        .firstOrNull;
    if (channel == null) {
      storage.clear(pubkey);
      return;
    }
    final link = ChannelDeepLink(channelId: channel.id);
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            widget.destinationBuilder?.call(channel, link) ??
            ChannelDetailPage(channel: channel),
      ),
    );
  }

  /// Subscribe once to the identity pubkey so a later non-null value retries
  /// the restore. Reading the pubkey state rises to identity initialization;
  /// subscribing lazily avoids that cost on launches that never reach the
  /// identity-ready retry.
  void _listenForIdentityPubkey() {
    if (_listeningIdentityPubkey) return;
    _listeningIdentityPubkey = true;
    ref.listenManual<String?>(
      readStateProvider.select((state) => state.pubkey),
      (_, _) => _maybeRestoreLastConversation(),
    );
  }

  void _maybeDispatch(BuzzDeepLink? link) {
    if (link == null || _preparingInvite) return;
    if (link is InviteDeepLink) {
      _maybeDispatchInvite(link);
      return;
    }
    if ((link is! MessageDeepLink && link is! ChannelDeepLink) ||
        !widget.dispatchMessageLinks) {
      return;
    }
    if (link is MessageDeepLink) {
      unawaited(_dispatchNotificationLink(link));
      return;
    }

    _dispatchNavigableLink(link);
  }

  Future<void> _dispatchNotificationLink(MessageDeepLink link) async {
    final preparation = await ref
        .read(pendingDeepLinkProvider.notifier)
        .prepareCommunity(link);
    if (!mounted || ref.read(pendingDeepLinkProvider) != link) return;
    switch (preparation) {
      case DeepLinkCommunityPreparation.ready:
        _dispatchNavigableLink(link);
      case DeepLinkCommunityPreparation.switched:
        // The community-scoped app subtree remounts and consumes the parked
        // target after its channels load.
        return;
      case DeepLinkCommunityPreparation.unavailable:
        ref.read(pendingDeepLinkProvider.notifier).consume();
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Notification community is no longer available'),
          ),
        );
      case DeepLinkCommunityPreparation.failed:
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text('Could not open the notification community'),
          ),
        );
    }
  }

  void _dispatchNavigableLink(BuzzDeepLink link) {
    final channelId = switch (link) {
      MessageDeepLink(:final channelId) => channelId,
      ChannelDeepLink(:final channelId) => channelId,
      _ => throw StateError('unsupported navigable deep link: $link'),
    };
    final channels = ref.read(channelsProvider).asData?.value;
    // Channels not loaded yet — keep the link parked; the channelsProvider
    // listener re-attempts once data arrives.
    if (channels == null) return;

    final channel = channels
        .where((c) => c.id == channelId)
        .cast<Channel?>()
        .firstOrNull;
    if (channel == null) {
      ref.read(pendingDeepLinkProvider.notifier).consume();
      debugPrint(
        'deep-link: channel $channelId not found in workspace; dropping link',
      );
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('Channel not found in this workspace')),
      );
      return;
    }
    if (!context.mounted) return;

    _pushChannel(channel, link);
    ref.read(pendingDeepLinkProvider.notifier).consume();
  }

  void _pushChannel(Channel channel, BuzzDeepLink link) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            widget.destinationBuilder?.call(channel, link) ??
            ChannelDetailPage(
              channel: channel,
              initialMessageId: link is MessageDeepLink ? link.messageId : null,
              initialThreadRootId: link is MessageDeepLink
                  ? link.threadRootId
                  : null,
            ),
      ),
    );
  }

  void _maybeDispatchInvite(InviteDeepLink link) {
    if (_preparingInvite) return;
    _preparingInvite = true;
    final navigatorContext = context;
    final messenger = ScaffoldMessenger.maybeOf(context);
    Future.microtask(() async {
      var consumed = false;
      try {
        await ref.read(inviteJoinProvider.notifier).prepare(link);
        ref.read(pendingDeepLinkProvider.notifier).consume();
        consumed = true;
        if (!navigatorContext.mounted) return;
        final inviteState = ref.read(inviteJoinProvider);
        final status = inviteState.status;
        if (status == InviteJoinStatus.confirming ||
            inviteState.isStarterSetupRecovery) {
          final sheet = showInviteJoinSheet(navigatorContext);
          if (status == InviteJoinStatus.claiming &&
              inviteState.isStarterSetupRecovery) {
            unawaited(
              ref.read(inviteJoinProvider.notifier).startStarterSetupRecovery(),
            );
          }
          final shouldFocusStarter = await sheet;
          final focusChannelId = ref.read(inviteJoinProvider).focusChannelId;
          if (shouldFocusStarter == true &&
              focusChannelId != null &&
              ref.read(pendingDeepLinkProvider) == null &&
              navigatorContext.mounted) {
            final channels = ref.read(channelsProvider).asData?.value;
            final channel = channels
                ?.where((candidate) => candidate.id == focusChannelId)
                .firstOrNull;
            if (channel != null) {
              _pushChannel(channel, ChannelDeepLink(channelId: focusChannelId));
            }
          }
        } else if (status == InviteJoinStatus.switchedExisting) {
          messenger?.showSnackBar(
            const SnackBar(content: Text('Switched to this community')),
          );
        }
      } catch (error) {
        debugPrint('deep-link: failed to prepare invite: $error');
        if (navigatorContext.mounted) {
          messenger?.showSnackBar(
            const SnackBar(
              content: Text(
                'Could not open this invite. Re-open the invite link to try again.',
              ),
            ),
          );
        }
      } finally {
        _preparingInvite = false;
        if (mounted && consumed) {
          _maybeDispatch(ref.read(pendingDeepLinkProvider));
        }
      }
    });
  }
}
