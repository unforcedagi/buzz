import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../theme/theme_provider.dart';

String lastConversationKey(String pubkey) =>
    'buzz.last-conversation.v1:$pubkey';

class LastConversationStorage {
  final SharedPreferences _prefs;

  LastConversationStorage(this._prefs);

  String? read(String pubkey) => _prefs.getString(lastConversationKey(pubkey));

  void write(String pubkey, String channelId) =>
      _prefs.setString(lastConversationKey(pubkey), channelId);

  void clear(String pubkey) => _prefs.remove(lastConversationKey(pubkey));
}

final lastConversationStorageProvider = Provider<LastConversationStorage>((
  ref,
) {
  return LastConversationStorage(ref.read(savedPrefsProvider));
});
