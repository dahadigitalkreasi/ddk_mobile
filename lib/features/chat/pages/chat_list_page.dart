import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../core/network/api_client.dart';
import '../../../core/constants/api_config.dart';
import 'chat_inbox_reverb_service.dart';
import 'chat_inbox_refresh_bus.dart';
import 'chat_detail_page.dart';

/// Halaman daftar klarifikasi Packing <-> CS.
///
/// Bisa dibuka dari navigasi CS maupun Packing:
/// Navigator.push(context, MaterialPageRoute(
///   builder: (_) => const ChatListPage(),
/// ));
///
/// Membuat chat baru oleh Packing akan dihubungkan pada tahap berikutnya.
class ChatListPage extends StatefulWidget {
  const ChatListPage({super.key});

  @override
  State<ChatListPage> createState() => _ChatListPageState();
}

class _ChatListPageState extends State<ChatListPage>
    with WidgetsBindingObserver {
  static const _storage = FlutterSecureStorage();

  final _searchController = TextEditingController();
  final List<Map<String, dynamic>> _chats = [];

  static const _appKey = String.fromEnvironment('REVERB_APP_KEY');
  static const _wsOverride = String.fromEnvironment('REVERB_WS_URL');
  ChatInboxReverbService? _inboxReverb;
  StreamSubscription<Map<String, dynamic>>? _inboxSubscription;
  StreamSubscription<String>? _inboxStatusSubscription;
  Timer? _inboxDebounce;
  Timer? _inboxReconnect;
  Timer? _refreshTimer;

  String get _apiRoot {
    final base = ApiConfig.baseUrl.replaceAll(RegExp(r'/$'), '');
    return base.endsWith('/api') ? base.substring(0, base.length - 4) : base;
  }

  String get _wsUrl {
    if (_wsOverride.isNotEmpty) return _wsOverride;
    final api = Uri.parse(_apiRoot);
    return Uri(
      scheme: api.scheme == 'https' ? 'wss' : 'ws',
      host: api.host,
      port: 8080,
    ).toString().replaceAll(RegExp(r'/$'), '');
  }

  String? _role;
  String? _token;
  String? _error;
  String _status = 'semua';
  bool _unreadOnly = false;
  int _totalUnread = 0;
  String _search = '';
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  int _requestNumber = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
    _refreshTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      // Jangan membebani jaringan saat aplikasi tidak sedang menampilkan halaman.
      if (!mounted || _token == null || _loading || _loadingMore) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? true)) return;
      _loadChats(silent: true);
    });
  }

  static Map<String, dynamic> _asMap(Object? raw) {
    if (raw is Map) return Map<String, dynamic>.from(raw);
    return <String, dynamic>{};
  }

  static int _asInt(Object? raw) => int.tryParse('$raw') ?? 0;

  static String _errorText(Object error) {
    if (error is DioException) {
      final body = _asMap(error.response?.data);
      return body['message']?.toString() ??
          'Gagal mengambil chat (HTTP ${error.response?.statusCode ?? '-'}).';
    }
    return error.toString().replaceFirst('Exception: ', '');
  }

  Options get _authOptions => Options(
    headers: {'Authorization': 'Bearer $_token', 'Accept': 'application/json'},
  );

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _token != null && !_loading) {
      _loadChats(silent: true);
    }
  }

  Future<void> _initialize() async {
    try {
      final token = await _storage.read(key: 'auth_token');
      final role = await _storage.read(key: 'user_role');
      final userIdRaw = await _storage.read(key: 'user_id');
      if (token == null || token.isEmpty) {
        throw Exception('Sesi login tidak ditemukan. Silakan login kembali.');
      }
      if (!mounted) return;
      _token = token;
      _role = role?.trim().toLowerCase();
      await _loadChats();
      final userId = int.tryParse(userIdRaw ?? '');
      if (_appKey.isNotEmpty && userId != null && userId > 0 && mounted) {
        await _connectInbox(userId, token);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = _errorText(error);
        _loading = false;
      });
    }
  }

  Future<void> _connectInbox(int userId, String token) async {
    await _inboxSubscription?.cancel();
    await _inboxStatusSubscription?.cancel();
    await _inboxReverb?.dispose();
    final service = ChatInboxReverbService(
      apiBaseUrl: _apiRoot,
      wsBaseUrl: _wsUrl,
      appKey: _appKey,
      authToken: token,
      userId: userId,
    );
    _inboxReverb = service;
    _inboxSubscription = service.messages.listen((_) {
      if (!mounted) return;
      ChatInboxRefreshBus.notify();
      _inboxDebounce?.cancel();
      _inboxDebounce = Timer(const Duration(milliseconds: 350), () {
        if (mounted) _loadChats(silent: true);
      });
    });
    _inboxStatusSubscription = service.statuses.listen((status) {
      if (!mounted) return;
      if (status == 'terhubung') {
        ChatInboxRefreshBus.notify();
        _loadChats(silent: true);
      }
      if (status == 'terputus' ||
          status.startsWith('error') ||
          status.startsWith('gagal')) {
        _inboxReconnect?.cancel();
        _inboxReconnect = Timer(const Duration(seconds: 8), () {
          if (mounted) _connectInbox(userId, token);
        });
      }
    });
    try {
      await service.connect();
    } catch (_) {
      // Polling 20 detik tetap berjalan sebagai fallback.
      _inboxReconnect?.cancel();
      _inboxReconnect = Timer(const Duration(seconds: 8), () {
        if (mounted) _connectInbox(userId, token);
      });
    }
  }

  Future<void> _loadChats({bool loadMore = false, bool silent = false}) async {
    if (_token == null) return;
    if (loadMore) {
      if (_loadingMore || !_hasMore) return;
      setState(() => _loadingMore = true);
    } else if (!silent) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    final requestNumber = ++_requestNumber;
    final requestedPage = loadMore ? _page + 1 : 1;

    try {
      final response = await ApiClient.dio.get<dynamic>(
        '/chat-klarifikasi-packing',
        queryParameters: {
          'page': requestedPage,
          'per_page': 20,
          if (_status != 'semua') 'status': _status,
          if (_search.isNotEmpty) 'search': _search,
          if (_unreadOnly) 'belum_dibaca_saja': 1,
        },
        options: _authOptions,
      );
      if (!mounted || requestNumber != _requestNumber) return;

      final responseBody = _asMap(response.data);
      final paginator = _asMap(responseBody['data']);
      final rawItems = paginator['data'];
      final incoming = rawItems is List
          ? rawItems.map(_asMap).toList()
          : <Map<String, dynamic>>[];
      final currentPage = _asInt(paginator['current_page']);
      final lastPage = _asInt(paginator['last_page']);
      // Total dari server mencakup seluruh chat, bukan hanya halaman ini.
      final totalUnread = responseBody.containsKey('jumlah_belum_dibaca_total')
          ? _asInt(responseBody['jumlah_belum_dibaca_total'])
          : _totalUnread;

      setState(() {
        _totalUnread = totalUnread;
        if (loadMore) {
          final existingIds = _chats.map((chat) => _asInt(chat['id'])).toSet();
          for (final chat in incoming) {
            if (!existingIds.contains(_asInt(chat['id']))) {
              _chats.add(chat);
            }
          }
        } else {
          _chats
            ..clear()
            ..addAll(incoming);
        }
        _page = currentPage > 0 ? currentPage : requestedPage;
        _hasMore = lastPage > 0 && _page < lastPage;
        _error = null;
      });
    } catch (error) {
      if (!mounted || requestNumber != _requestNumber) return;
      setState(() => _error = _errorText(error));
    } finally {
      if (mounted && requestNumber == _requestNumber) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _changeStatus(String status) {
    if (_status == status) return;
    setState(() => _status = status);
    _loadChats();
  }

  void _toggleUnreadOnly() {
    setState(() => _unreadOnly = !_unreadOnly);
    _loadChats();
  }

  void _applySearch() {
    final search = _searchController.text.trim();
    if (_search == search) return;
    setState(() => _search = search);
    _loadChats();
  }

  Future<void> _openChat(int chatId) async {
    if (chatId <= 0) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChatDetailPage(chatId: chatId)),
    );
    if (mounted) await _loadChats();
  }

  // Database menyimpan status historis berdasarkan pihak terakhir yang mengirim:
  // dibalas = terakhir CS, menunggu_jawaban = terakhir Packing.
  // Tulisan berikut menunjukkan tindak lanjut yang relevan bagi pengguna login.
  String _statusLabel(String status) {
    if (status == 'selesai') return 'Selesai';
    if (_role == 'cs') {
      if (status == 'dibalas') return 'Menunggu Packing';
      if (status == 'menunggu_jawaban') return 'Perlu dibalas';
    } else if (_role == 'packing') {
      if (status == 'dibalas') return 'Perlu dibalas';
      if (status == 'menunggu_jawaban') return 'Menunggu CS';
    }
    if (status == 'dibalas') return 'Dibalas';
    if (status == 'menunggu_jawaban') return 'Menunggu jawaban';
    return status;
  }

  Color _statusColor(BuildContext context, String status) {
    switch (status) {
      case 'menunggu_jawaban':
        return Colors.orange.shade800;
      case 'dibalas':
        return Colors.blue.shade700;
      case 'selesai':
        return Colors.green.shade700;
      default:
        return Theme.of(context).colorScheme.onSurfaceVariant;
    }
  }

  Widget _buildChatCard(Map<String, dynamic> chat) {
    final id = _asInt(chat['id']);
    final order = (chat['no_pesanan'] ?? '-').toString();
    final topic = (chat['topik'] ?? 'Klarifikasi pesanan').toString();
    final isUnassigned = _role == 'packing' && chat['packing_user_id'] == null;
    final status = (chat['status'] ?? '').toString();
    final unread = _asInt(chat['jumlah_belum_dibaca']);
    final cs = _asMap(chat['cs']);
    final packing = _asMap(chat['packing']);
    final participantNames = [
      if (packing['name'] != null) 'Packing: ${packing['name']}',
      if (cs['name'] != null) 'CS: ${cs['name']}',
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openChat(id),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.forum_outlined, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      order,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (unread > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.red.shade700,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        unread > 99 ? '99+' : '$unread',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (isUnassigned) ...[
                const Text(
                  'Belum ditangani Packing · Buka untuk menangani',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 6),
              ],
              if (topic.trim().isNotEmpty && topic != 'Klarifikasi Pesanan')
                Text(topic, maxLines: 2, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.circle,
                    size: 9,
                    color: _statusColor(context, status),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _statusLabel(status),
                      style: TextStyle(
                        color: _statusColor(context, status),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (chat['id_per_produk'] != null)
                    Text(
                      'Produk #${chat['id_per_produk']}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                ],
              ),
              if (participantNames.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  participantNames,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _requestNumber++;
    WidgetsBinding.instance.removeObserver(this);
    _refreshTimer?.cancel();
    _inboxDebounce?.cancel();
    _inboxReconnect?.cancel();
    _inboxSubscription?.cancel();
    _inboxStatusSubscription?.cancel();
    _inboxReverb?.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chat Klarifikasi'),
        actions: [
          IconButton(
            tooltip: 'Muat ulang chat',
            onPressed: _loading ? null : () => _loadChats(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
              child: TextField(
                controller: _searchController,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _applySearch(),
                decoration: InputDecoration(
                  labelText: 'Cari nomor pesanan atau topik',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: 'Cari',
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _applySearch,
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
              child: Row(
                children: [
                  const Icon(Icons.mark_chat_unread_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Total pesan belum dibaca: $_totalUnread',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 46,
              child: ListView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                scrollDirection: Axis.horizontal,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: const Text('Belum Dibaca'),
                      avatar: const Icon(
                        Icons.mark_chat_unread_outlined,
                        size: 18,
                      ),
                      selected: _unreadOnly,
                      onSelected: (_) => _toggleUnreadOnly(),
                    ),
                  ),
                  for (final filter in const [
                    ('semua', 'Semua'),
                    ('menunggu_jawaban', 'Packing terakhir'),
                    ('dibalas', 'CS terakhir'),
                    ('selesai', 'Selesai'),
                  ])
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ChoiceChip(
                        label: Text(filter.$2),
                        selected: _status == filter.$1,
                        onSelected: (_) => _changeStatus(filter.$1),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: () => _loadChats(),
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.all(12),
                        children: [
                          if (_error != null)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                _error!,
                                style: const TextStyle(color: Colors.red),
                              ),
                            ),
                          if (_chats.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 60),
                              child: Center(
                                child: Text(
                                  _unreadOnly
                                      ? 'Tidak ada chat yang belum dibaca.'
                                      : 'Belum ada percakapan klarifikasi.',
                                ),
                              ),
                            ),
                          for (final chat in _chats) _buildChatCard(chat),
                          if (_hasMore)
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: OutlinedButton(
                                  onPressed: _loadingMore
                                      ? null
                                      : () => _loadChats(loadMore: true),
                                  child: Text(
                                    _loadingMore
                                        ? 'Memuat...'
                                        : 'Muat chat lainnya',
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
