import 'package:buzz/shared/last_conversation/last_conversation_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('write, read, and clear round trip scoped per pubkey', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = LastConversationStorage(
      await SharedPreferences.getInstance(),
    );

    expect(storage.read('aa'), isNull);

    storage.write('aa', 'channel-1');
    expect(storage.read('aa'), 'channel-1');

    // Keys are identity-scoped: another pubkey reads nothing.
    expect(storage.read('bb'), isNull);
    storage.write('bb', 'channel-2');
    expect(storage.read('aa'), 'channel-1');
    expect(storage.read('bb'), 'channel-2');

    storage.clear('aa');
    expect(storage.read('aa'), isNull);
    expect(storage.read('bb'), 'channel-2');
    expect(
      SharedPreferences.getInstance().then(
        (prefs) => prefs.getString(lastConversationKey('aa')),
      ),
      completion(isNull),
    );
  });
}
