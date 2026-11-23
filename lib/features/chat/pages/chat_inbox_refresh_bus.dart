import 'dart:async';

/// Sinyal lokal ketika inbox Reverb menerima perubahan.
///
/// Shell dan ChatListPage berbagi notifikasi ini tanpa membuka
/// WebSocket Reverb tambahan. Payload pesan tidak disimpan di sini.
class ChatInboxRefreshBus {
  ChatInboxRefreshBus._();

  static final StreamController<void> _changes =
      StreamController<void>.broadcast();

  static Stream<void> get changes => _changes.stream;

  static void notify() {
    if (!_changes.isClosed) _changes.add(null);
  }
}
