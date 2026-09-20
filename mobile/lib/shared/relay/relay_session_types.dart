import 'package:flutter/foundation.dart';

import 'relay_socket.dart';

enum SessionStatus { disconnected, connecting, connected, reconnecting }

typedef RelaySocketFactory =
    RelaySocket Function({
      required String wsUrl,
      required String? nsec,
      required void Function(List<dynamic> message) onMessage,
      required void Function() onConnected,
      required void Function(Object? error) onDisconnected,
    });

@immutable
class SessionState {
  final SessionStatus status;
  final int reconnectAttempt;

  const SessionState({required this.status, this.reconnectAttempt = 0});
}

/// Recovery lifecycle for a live relay subscription.
enum RelaySubscriptionStatus { ready, retrying }

/// Thrown when an operation needs a live relay socket and the session is
/// disconnected or has moved on to a newer connection generation.
///
/// Kept distinct from a bare [StateError] so callers can tell "you're
/// offline" apart from other `StateError`s (e.g. a community switch
/// cancelling an in-flight action) without matching on message text.
class RelayDisconnectedException implements Exception {
  const RelayDisconnectedException();

  @override
  String toString() =>
      'RelayDisconnectedException: Relay session is not connected';
}
