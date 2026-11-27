import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:image_picker/image_picker.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';

class CsManageOrderPage extends StatefulWidget {
  final String noPesanan;
  const CsManageOrderPage({super.key, required this.noPesanan});

  @override
  State<CsManageOrderPage> createState() => _CsManageOrderPageState();
}

class _Region {
  final String id;
  final String name;
  const _Region(this.id, this.name);
}

class _CsManageOrderPageState extends State<CsManageOrderPage> {
  final _storage = const FlutterSecureStorage();
  final _form = GlobalKey<FormState>();
  final _nama = TextEditingController();
  final _phone = TextEditingController();
  final _alamat = TextEditingController();
  final _notes = TextEditingController();
  final _tanggal = TextEditingController();
  final _chatMasuk = TextEditingController();
  final _alasanHapus = TextEditingController();
  final _provinsi = TextEditingController();
  final _kabupaten = TextEditingController();
  final _kecamatan = TextEditingController();
  final _desa = TextEditingController();

  Map<String, dynamic>? _raw;
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _dateNotice;
  XFile? _proof;

  List<_Region> _provinces = [];
  List<_Region> _cities = [];
  List<_Region> _districts = [];
  List<_Region> _villages = [];
  final bool _loadingProvince = false;
  bool _loadingCity = false;
  bool _loadingDistrict = false;
  bool _loadingVillage = false;
  String? _provinceError;
  String? _cityError;
  String? _districtError;
  String? _villageError;
  int _regionGeneration = 0;

  Map<String, dynamic> _map(dynamic v) =>
      v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
  String _str(dynamic v) => v == null ? '' : '$v';
  bool _yes(dynamic v) => v == true || v == 1 || v == '1';
  Map<String, dynamic> get _order => _map(_raw?['pesanan']);
  Map<String, dynamic> get _payment {
    final list = _raw?['pembayaran'];
    return list is List && list.isNotEmpty
        ? _map(list.first)
        : <String, dynamic>{};
  }

  bool get _approval => _yes(_order['pengajuan_resi_meta']);
  String get _resi => _str(_order['noResi'] ?? _order['no_resi']).trim();

  // API memproses edit berdasarkan pengajuan_resi_meta. Nomor resi harus
  // konsisten dengan status ini agar edit tidak tersimpan langsung.
  bool get _statusTidakSinkron =>
      !_order.containsKey('pengajuan_resi_meta') ||
      !(_order.containsKey('noResi') || _order.containsKey('no_resi')) ||
      (_resi.isNotEmpty != _approval);

  String get _pesanStatusTidakSinkron =>
      'Pesanan ini memiliki status pengiriman yang perlu diperiksa. '
      'Hubungi Admin Logistik sebelum mengubah atau menghapus pesanan.';
  bool get _deleteDirect => !_approval && _resi.isEmpty;
  bool get _deleteRequest => _approval && _resi.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _nama,
      _phone,
      _alamat,
      _notes,
      _tanggal,
      _chatMasuk,
      _alasanHapus,
      _provinsi,
      _kabupaten,
      _kecamatan,
      _desa,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<String> _token() async {
    final token = await _storage.read(key: 'auth_token');
    if (token == null || token.isEmpty) {
      throw StateError('Sesi login tidak ditemukan. Silakan login kembali.');
    }
    return token;
  }

  Options _options(String token) => Options(
    headers: {'Authorization': 'Bearer $token', 'Accept': 'application/json'},
  );

  // Ubah pesan teknis dari server menjadi bahasa yang mudah dipahami CS.
  String _pesanPengguna(String raw) {
    final pesan = raw.trim();
    final lower = pesan.toLowerCase();
    if (pesan.isEmpty) return 'Terjadi kendala. Silakan coba lagi.';
    if (lower.contains('file tidak ditemukan') ||
        lower.contains('file not found') ||
        lower.contains('no such file')) {
      return 'Berkas pesanan tidak ditemukan di penyimpanan. '
          'Hubungi Admin Logistik untuk memeriksa berkas pesanan.';
    }
    if (lower.contains('total_hpp') ||
        lower.contains('total hpp') ||
        lower.contains('total_harga') ||
        lower.contains('total harga') ||
        lower.contains('total_admin') ||
        lower.contains('total admin')) {
      return 'Data biaya pesanan belum sesuai. Hubungi Admin Logistik.';
    }
    if (lower.contains('tanggal_order') || lower.contains('tanggal order')) {
      return 'Periksa kembali tanggal dan waktu pesanan.';
    }
    if (lower.contains('chat_masuk_at') || lower.contains('chat masuk')) {
      return 'Periksa kembali tanggal dan waktu chat masuk.';
    }
    if (lower.contains('phone') || lower.contains('nomor telepon')) {
      return 'Nomor WhatsApp belum sesuai. Gunakan format 628xxxxxxxxxx.';
    }
    if (lower.contains('nama_pembeli') || lower.contains('nama pembeli')) {
      return 'Nama pembeli wajib diisi dengan benar.';
    }
    if (lower.contains('alamat') ||
        lower.contains('provinsi') ||
        lower.contains('kabupaten') ||
        lower.contains('kecamatan') ||
        lower.contains('desa')) {
      return 'Periksa kembali alamat dan wilayah pengiriman.';
    }
    if (lower.contains('bukti_bayar') || lower.contains('bukti bayar')) {
      return 'Bukti pembayaran tidak dapat diproses. Periksa berkas yang dipilih.';
    }
    if (lower.contains('required') || lower.contains('wajib')) {
      return 'Ada informasi wajib yang belum lengkap. Periksa kembali formulir.';
    }
    if (lower.contains('permission') ||
        lower.contains('forbidden') ||
        lower.contains('unauthorized') ||
        lower.contains('akses ditolak')) {
      return 'Akun ini belum memiliki izin untuk melakukan tindakan tersebut.';
    }
    if (lower.contains('not found') || lower.contains('tidak ditemukan')) {
      return 'Data pesanan tidak ditemukan. Muat ulang daftar pesanan.';
    }
    // Jangan meneruskan nama field, kode server, atau pesan internal.
    return 'Permintaan belum berhasil diproses. Silakan coba lagi atau '
        'hubungi Admin Logistik jika masalah berlanjut.';
  }

  String _apiError(Object e) {
    if (e is DioException) {
      final status = e.response?.statusCode;
      if (status == 401) {
        return 'Sesi login sudah berakhir. Silakan masuk kembali.';
      }
      if (status == 403) {
        return 'Akun ini tidak memiliki izin untuk mengubah pesanan.';
      }
      if (status == 404) {
        return 'Pesanan atau berkas terkait tidak ditemukan. Coba muat ulang.';
      }
      final data = e.response?.data;
      if (data is Map) {
        final errors = data['errors'];
        if (errors is Map && errors.isNotEmpty) {
          final key = errors.keys.first.toString();
          final val = errors.values.first;
          final value = val is List && val.isNotEmpty
              ? val.first.toString()
              : val.toString();
          return _pesanPengguna('$key $value');
        }
        if (data['message'] != null) {
          return _pesanPengguna(data['message'].toString());
        }
      }
      if (status == 422) {
        return 'Ada informasi yang belum sesuai. Periksa kembali formulir.';
      }
      if (status != null && status >= 500) {
        return 'Layanan sedang mengalami kendala. Silakan coba lagi nanti.';
      }
      return 'Koneksi ke layanan terganggu. Periksa internet lalu coba lagi.';
    }
    if (e is FormatException) return _pesanPengguna(e.message);
    if (e is StateError) return _pesanPengguna(e.message);
    return 'Terjadi kendala. Silakan coba lagi.';
  }

  String _firstText(Map<String, dynamic> m, List<String> keys) {
    for (final key in keys) {
      final value = _str(m[key]).trim();
      if (value.isNotEmpty && value != 'null') return value;
    }
    return '';
  }

  String _dateText(String raw) {
    if (raw.isEmpty) return '';
    final dt = DateTime.tryParse(raw.replaceFirst(' ', 'T'));
    if (dt == null) return raw;
    String two(int n) => n.toString().padLeft(2, '0');
    // Timestamp API bisa UTC. Untuk tanggal dengan suffix Z konversi ke WIB
    // sesuai timezone perangkat; tanpa suffix, jangan lakukan konversi.
    final local = raw.endsWith('Z') || RegExp(r'[+-]\d\d:\d\d$').hasMatch(raw)
        ? dt.toLocal()
        : dt;
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  }

  Future<List<_Region>> _fetchRegions(String path, String token) async {
    final res = await ApiClient.dio.get<dynamic>(
      path,
      options: _options(token),
    );
    final body = _map(res.data);
    if (body['success'] != true || body['data'] is! List) {
      throw const FormatException('Data wilayah tidak dapat dimuat.');
    }
    return (body['data'] as List)
        .whereType<Map>()
        .map((e) => _Region(_str(e['id']).trim(), _str(e['name']).trim()))
        .where((e) => e.id.isNotEmpty && e.name.isNotEmpty)
        .toList();
  }

  // Muat semua level wilayah awal secara berurutan sehingga ID lama
  // langsung muncul sebagai nama wilayah yang benar.
  Future<void> _loadInitialRegions(String token) async {
    final generation = ++_regionGeneration;
    try {
      final p = await _fetchRegions('/wilayah/provinsi', token);
      if (!mounted || generation != _regionGeneration) return;
      setState(() {
        _provinces = p;
        _provinceError = null;
      });
    } catch (e) {
      if (!mounted || generation != _regionGeneration) return;
      setState(() => _provinceError = _apiError(e));
    }
    Future<void> next(
      String value,
      String endpoint,
      void Function(List<_Region>) store,
    ) async {
      if (value.trim().isEmpty) return;
      try {
        final data = await _fetchRegions(
          '$endpoint/${Uri.encodeComponent(value)}',
          token,
        );
        if (!mounted || generation != _regionGeneration) return;
        setState(() => store(data));
      } catch (e) {
        if (!mounted || generation != _regionGeneration) return;
        setState(() {
          if (endpoint.contains('/kabupaten')) _cityError = _apiError(e);
          if (endpoint.contains('/kecamatan')) _districtError = _apiError(e);
          if (endpoint.contains('/desa')) _villageError = _apiError(e);
        });
      }
    }

    await next(_provinsi.text, '/wilayah/kabupaten', (v) => _cities = v);
    await next(_kabupaten.text, '/wilayah/kecamatan', (v) => _districts = v);
    await next(_kecamatan.text, '/wilayah/desa', (v) => _villages = v);
  }

  Future<void> _loadRegionChildren(int level, String parent) async {
    final generation = ++_regionGeneration;
    final token = await _token();
    final path = switch (level) {
      1 => '/wilayah/kabupaten',
      2 => '/wilayah/kecamatan',
      _ => '/wilayah/desa',
    };
    setState(() {
      if (level == 1) {
        _loadingCity = true;
        _cityError = null;
      }
      if (level == 2) {
        _loadingDistrict = true;
        _districtError = null;
      }
      if (level == 3) {
        _loadingVillage = true;
        _villageError = null;
      }
    });
    try {
      final result = await _fetchRegions(
        '$path/${Uri.encodeComponent(parent)}',
        token,
      );
      if (!mounted || generation != _regionGeneration) return;
      setState(() {
        if (level == 1) _cities = result;
        if (level == 2) _districts = result;
        if (level == 3) _villages = result;
      });
    } catch (e) {
      if (!mounted || generation != _regionGeneration) return;
      setState(() {
        if (level == 1) _cityError = _apiError(e);
        if (level == 2) _districtError = _apiError(e);
        if (level == 3) _villageError = _apiError(e);
      });
    } finally {
      if (mounted && generation == _regionGeneration) {
        setState(() {
          if (level == 1) _loadingCity = false;
          if (level == 2) _loadingDistrict = false;
          if (level == 3) _loadingVillage = false;
        });
      }
    }
  }

  void _selectRegion(int level, String? id) {
    setState(() {
      if (level == 0) {
        _provinsi.text = id ?? '';
        _kabupaten.clear();
        _kecamatan.clear();
        _desa.clear();
        _cities = [];
        _districts = [];
        _villages = [];
      } else if (level == 1) {
        _kabupaten.text = id ?? '';
        _kecamatan.clear();
        _desa.clear();
        _districts = [];
        _villages = [];
      } else if (level == 2) {
        _kecamatan.text = id ?? '';
        _desa.clear();
        _villages = [];
      } else {
        _desa.text = id ?? '';
      }
      _cityError = null;
      _districtError = null;
      _villageError = null;
    });
    if (id != null && level < 3) _loadRegionChildren(level + 1, id);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _dateNotice = null;
    });
    try {
      final token = await _token();
      final res = await ApiClient.dio.get<dynamic>(
        '/pesanan/edit/${Uri.encodeComponent(widget.noPesanan)}',
        options: _options(token),
      );
      final body = _map(res.data);
      if (body['success'] != true || body['data'] is! Map) {
        throw const FormatException('Data pesanan tidak dapat ditampilkan.');
      }
      final raw = _map(body['data']);
      final order = _map(raw['pesanan']);
      final buyer = _map(raw['informasiPembeli']);
      final address = _map(buyer['address']);
      _raw = raw;
      _nama.text = _firstText(buyer, ['namaPembeli', 'nama_pembeli']);
      _phone.text = _firstText(buyer, ['phone']);
      _alamat.text = _firstText(address, ['alamatLengkap', 'alamat_lengkap']);
      _notes.text = _firstText(order, ['catatanPesanan', 'notes']);
      _chatMasuk.text = _dateText(
        _firstText(order, ['chatMasuk', 'chat_masuk_at']),
      );
      _provinsi.text = _firstText(address, ['provinsi']);
      _kabupaten.text = _firstText(address, [
        'kabupatenKota',
        'kabupaten_kota',
      ]);
      _kecamatan.text = _firstText(address, ['kecamatan']);
      _desa.text = _firstText(address, ['desa']);
      // Untuk alur CS ini, Tanggal Order menggunakan Tanggal Input.
      // Gunakan sumber yang sama dengan Daftar dan Detail Pesanan.
      var originalDate = _firstText(order, [
        'tanggalInput',
        'tanggal_input',
        'input_at',
        'tanggalOrder',
        'tanggal_order',
        'tanggal',
      ]);
      if (originalDate.isEmpty) {
        // Cadangan ketika endpoint Edit belum menyertakan tanggal input.
        // Endpoint Detail biasanya memiliki pesanan.tanggalInput.
        try {
          final detailResponse = await ApiClient.dio.get<dynamic>(
            '/pesanan/detail/${Uri.encodeComponent(widget.noPesanan)}',
            options: _options(token),
          );
          final detailData = _map(_map(detailResponse.data)['data']);
          final detailOrder = _map(detailData['pesanan']);
          originalDate = _firstText(detailOrder, [
            'tanggalInput',
            'tanggal_input',
            'input_at',
            'tanggalOrder',
            'tanggal_order',
            'tanggal',
          ]);
        } catch (_) {
          // Tetap izinkan pengguna memilih tanggal jika data belum ada.
        }
      }
      _tanggal.text = _dateText(originalDate);
      if (_tanggal.text.isEmpty) {
        _dateNotice =
            'Tanggal input pesanan belum tersedia. '
            'Pilih tanggal dan waktu yang benar sebelum menyimpan.';
      }
      if (!mounted) return;
      setState(() => _loading = false);
      await _loadInitialRegions(token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = _apiError(e);
        _loading = false;
      });
    }
  }

  Future<void> _chooseDateTime(
    TextEditingController controller, {
    bool isOrderDate = false,
  }) async {
    final parsed = DateTime.tryParse(
      controller.text.trim().replaceFirst(' ', 'T'),
    );
    final now = DateTime.now();
    final initial = parsed == null || parsed.isAfter(now) ? now : parsed;

    final day = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: now,
    );
    if (day == null || !mounted) return;

    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (time == null || !mounted) return;

    final selected = DateTime(
      day.year,
      day.month,
      day.day,
      time.hour,
      time.minute,
    );
    if (selected.isAfter(DateTime.now())) {
      _toast('Tanggal dan waktu tidak boleh di masa depan.');
      return;
    }

    String two(int n) => n.toString().padLeft(2, '0');
    setState(() {
      controller.text =
          '${selected.year}-${two(selected.month)}-${two(selected.day)} '
          '${two(selected.hour)}:${two(selected.minute)}:00';
      if (isOrderDate) _dateNotice = null;
    });
  }

  Future<void> _chooseDate() => _chooseDateTime(_tanggal, isOrderDate: true);

  Future<void> _chooseChatDate() => _chooseDateTime(_chatMasuk);

  Future<void> _pickProof() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 85,
    );
    if (file == null || !mounted) return;
    final ext = file.name.split('.').last.toLowerCase();
    if (!['jpg', 'jpeg', 'png'].contains(ext) ||
        await file.length() > 5 * 1024 * 1024) {
      _toast('Bukti pembayaran harus JPG/PNG maksimal 5 MB.');
      return;
    }
    setState(() => _proof = file);
  }

  void _toast(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  String? _required(String? v) =>
      v == null || v.trim().isEmpty ? 'Wajib diisi' : null;

  // Laravel memvalidasi total_hpp, total_harga, total_admin sebagai integer.
  // Jangan kirim '9000.0' atau '9000.00'.
  String _integerAmount(dynamic value, String field) {
    final parsed = num.tryParse(_str(value));
    if (parsed == null ||
        !parsed.isFinite ||
        parsed < 0 ||
        parsed != parsed.roundToDouble()) {
      throw const FormatException('Data biaya pesanan belum sesuai.');
    }
    return parsed.toInt().toString();
  }

  String _numericAmount(dynamic value) =>
      (num.tryParse(_str(value)) ?? 0).toString();

  // Cek ulang sebelum perubahan dikirim, untuk menghindari memakai status
  // resi yang berubah sejak halaman dibuka.
  Future<bool> _periksaStatusTerbaru() async {
    final response = await ApiClient.dio.get<dynamic>(
      '/pesanan/edit/${Uri.encodeComponent(widget.noPesanan)}',
      options: _options(await _token()),
    );
    final body = _map(response.data);
    if (body['success'] != true || body['data'] is! Map) {
      throw const FormatException('Data pesanan tidak dapat diperiksa.');
    }
    final terbaru = _map(_map(body['data'])['pesanan']);
    final hasFlag = terbaru.containsKey('pengajuan_resi_meta');
    final hasResi =
        terbaru.containsKey('noResi') || terbaru.containsKey('no_resi');
    final flag = _yes(terbaru['pengajuan_resi_meta']);
    final resi = _str(terbaru['noResi'] ?? terbaru['no_resi']).trim();
    if (!hasFlag || !hasResi || (resi.isNotEmpty != flag)) {
      _toast(_pesanStatusTidakSinkron);
      return false;
    }
    if (flag != _approval || resi != _resi) {
      _toast(
        'Status pengiriman pesanan sudah berubah. '
        'Buka kembali pesanan untuk melihat informasi terbaru.',
      );
      return false;
    }
    return true;
  }

  Future<void> _save() async {
    if (_saving) return;
    if (_statusTidakSinkron) {
      _toast(_pesanStatusTidakSinkron);
      return;
    }
    if (!(_form.currentState?.validate() ?? false)) return;
    final date = DateTime.tryParse(_tanggal.text.replaceFirst(' ', 'T'));
    if (date == null || date.isAfter(DateTime.now())) {
      _toast('Tanggal order tidak valid.');
      return;
    }
    final chatRaw = _chatMasuk.text.trim();
    if (chatRaw.isNotEmpty) {
      final chat = DateTime.tryParse(chatRaw.replaceFirst(' ', 'T'));
      if (chat == null || chat.isAfter(DateTime.now())) {
        _toast('Tanggal chat masuk tidak valid.');
        return;
      }
    }
    if (!RegExp(r'^628\d{7,13}$').hasMatch(_phone.text.trim())) {
      _toast('WhatsApp harus berawalan 628 dan hanya berisi angka.');
      return;
    }
    if (_provinsi.text.isEmpty ||
        _kabupaten.text.isEmpty ||
        _kecamatan.text.isEmpty) {
      _toast('Pilih Provinsi, Kabupaten/Kota, dan Kecamatan.');
      return;
    }
    if (_raw == null || _payment.isEmpty) {
      _toast('Data pesanan atau pembayaran lama tidak ditemukan.');
      return;
    }
    final o = _order;
    final hpp = o['totalHpp'] ?? o['total_hpp'];
    final price = o['totalHarga'] ?? o['total_harga'];
    final admin = o['totalAdmin'] ?? o['total_admin'];
    if (hpp == null || price == null || admin == null) {
      _toast('Rincian biaya pesanan belum lengkap. Hubungi Admin Logistik.');
      return;
    }
    setState(() => _saving = true);
    try {
      if (!await _periksaStatusTerbaru()) return;
      final payload = <String, dynamic>{
        '_method': 'PATCH',
        'no_pesanan': widget.noPesanan,
        'tanggal_order': _tanggal.text.trim(),
        'nama_pembeli': _nama.text.trim(),
        'total_hpp': _integerAmount(hpp, 'total_hpp'),
        'total_harga': _integerAmount(price, 'total_harga'),
        'total_admin': _integerAmount(admin, 'total_admin'),
        'notes': _notes.text.trim(),
        if (chatRaw.isNotEmpty) 'chat_masuk_at': chatRaw,
        'provinsi': _provinsi.text,
        'kabupaten_kota': _kabupaten.text,
        'kecamatan': _kecamatan.text,
        if (_desa.text.isNotEmpty) 'desa': _desa.text,
        'alamat_lengkap': _alamat.text.trim(),
        'phone': _phone.text.trim(),
        'jenis_transaksi': _str(_payment['jenis_transaksi']),
        'cod': _numericAmount(_payment['cod']),
        'non_cod': _numericAmount(_payment['non_cod']),
        'dp': _numericAmount(_payment['dp']),
        'por': _numericAmount(_payment['por']),
        if (_proof != null)
          'bukti_bayar': await MultipartFile.fromFile(
            _proof!.path,
            filename: _proof!.name,
          ),
      };
      final r = await ApiClient.dio.post<dynamic>(
        '/pesanan/update',
        data: FormData.fromMap(payload),
        options: _options(await _token()),
      );
      final body = _map(r.data);
      final nested = _map(body['data']);
      if (body['success'] != true || nested['success'] == false) {
        throw StateError(
          _firstText(nested, ['message']).isNotEmpty
              ? _str(nested['message'])
              : _str(body['message']),
        );
      }
      if (!mounted) return;
      _toast(
        _approval
            ? 'Pengajuan perubahan berhasil dikirim. Menunggu persetujuan Admin Logistik.'
            : 'Perubahan pesanan berhasil disimpan.',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      _toast('Gagal menyimpan: ${_apiError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    if (_saving || _raw == null) return;
    if (_statusTidakSinkron || (!_deleteDirect && !_deleteRequest)) {
      _toast(_pesanStatusTidakSinkron);
      return;
    }
    _alasanHapus.clear();
    final requested = _deleteRequest;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          requested ? 'Ajukan hapus pesanan?' : 'Hapus pesanan permanen?',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              requested
                  ? 'Pesanan ${widget.noPesanan} tidak langsung dihapus dan perlu persetujuan Admin Logistik.'
                  : 'Pesanan ${widget.noPesanan} beserta data terkait akan dihapus. Tidak bisa dibatalkan.',
            ),
            if (requested) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _alasanHapus,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Alasan penghapusan (wajib)',
                  border: OutlineInputBorder(),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Batal'),
          ),
          FilledButton(
            onPressed: () {
              if (requested && _alasanHapus.text.trim().isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('Alasan wajib diisi.')),
                );
                return;
              }
              Navigator.pop(ctx, true);
            },
            child: Text(requested ? 'Kirim Pengajuan' : 'Ya, Hapus'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    setState(() => _saving = true);
    try {
      if (!await _periksaStatusTerbaru()) return;
      final res = await ApiClient.dio.delete<dynamic>(
        '/pesanan/delete/${Uri.encodeComponent(widget.noPesanan)}',
        data: {'keterangan': requested ? _alasanHapus.text.trim() : ''},
        options: _options(await _token()),
      );
      final result = _map(res.data);
      if (result['success'] != true) throw StateError(_str(result['message']));
      if (!mounted) return;
      _toast(
        requested
            ? 'Pengajuan penghapusan berhasil dikirim ke Admin Logistik.'
            : 'Pesanan berhasil dihapus.',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      _toast('Gagal menghapus: ${_apiError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _money(dynamic v) {
    final n = num.tryParse(_str(v)) ?? 0;
    return 'Rp${n.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (m) => '${m[1]}.')}';
  }

  Widget _section(String title, IconData icon, List<Widget> children) => Card(
    elevation: 0,
    color: Colors.white,
    margin: const EdgeInsets.only(bottom: 14),
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(17),
      side: const BorderSide(color: Color(0xFFE3EBF3)),
    ),
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: AppTheme.navy, size: 21),
              const SizedBox(width: 9),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 16,
                    color: AppTheme.navy,
                  ),
                ),
              ),
            ],
          ),
          const Divider(height: 24),
          ...children,
        ],
      ),
    ),
  );

  Widget _field(
    String title,
    TextEditingController controller, {
    bool required = true,
    int lines = 1,
    bool readOnly = false,
    VoidCallback? onTap,
    IconData? icon,
    TextInputType? keyboard,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 13),
    child: TextFormField(
      controller: controller,
      readOnly: readOnly,
      onTap: onTap,
      maxLines: lines,
      keyboardType: keyboard,
      validator: required ? _required : null,
      decoration: InputDecoration(
        labelText: title,
        prefixIcon: icon == null ? null : Icon(icon, size: 20),
        suffixIcon: readOnly && onTap != null
            ? const Icon(Icons.calendar_month_outlined)
            : null,
        filled: true,
        fillColor: readOnly && onTap == null
            ? const Color(0xFFF2F5F8)
            : Colors.white,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 13,
          vertical: 14,
        ),
      ),
    ),
  );

  Widget _readonly(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            label,
            style: const TextStyle(fontSize: 12, color: Color(0xFF60758A)),
          ),
        ),
        Expanded(
          child: Text(
            value.trim().isEmpty ? '-' : value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  Future<void> _chooseRegion({
    required String label,
    required List<_Region> list,
    required int level,
  }) async {
    if (list.isEmpty) return;
    final selected = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => _RegionSearchSheet(label: label, options: list),
    );
    if (!mounted || selected == null) return;
    _selectRegion(level, selected);
  }

  Widget _regionField(
    String label,
    TextEditingController controller,
    List<_Region> items,
    int level,
    bool loading,
    String? error, {
    bool enabled = true,
  }) {
    final name = items
        .where((e) => e.id == controller.text)
        .map((e) => e.name)
        .firstOrNull;
    return Padding(
      padding: const EdgeInsets.only(bottom: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: enabled && !loading && items.isNotEmpty
                ? () => _chooseRegion(label: label, list: items, level: level)
                : null,
            borderRadius: BorderRadius.circular(12),
            child: InputDecorator(
              decoration: InputDecoration(
                labelText: label,
                filled: true,
                fillColor: enabled ? Colors.white : const Color(0xFFF3F5F7),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                suffixIcon: loading
                    ? const Padding(
                        padding: EdgeInsets.all(13),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const Icon(Icons.keyboard_arrow_down),
              ),
              child: Text(
                name ??
                    (controller.text.isNotEmpty
                        ? 'Kode ${controller.text} (nama belum ditemukan)'
                        : (enabled
                              ? 'Pilih $label'
                              : 'Pilih wilayah sebelumnya')),
                style: TextStyle(
                  color: name == null ? const Color(0xFF7A8998) : AppTheme.navy,
                  fontSize: 13,
                ),
              ),
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 5),
              child: Text(
                error,
                style: const TextStyle(color: Colors.red, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = _order;
    final p = _payment;
    final products = (_raw?['informasiProduk'] is List)
        ? (_raw!['informasiProduk'] as List).whereType<Map>().toList()
        : <Map>[];
    return Scaffold(
      backgroundColor: const Color(0xFFF5F8FC),
      appBar: AppBar(
        backgroundColor: AppTheme.navy,
        foregroundColor: Colors.white,
        title: const Text('Kelola Pesanan CS'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline,
                      size: 45,
                      color: Colors.red,
                    ),
                    const SizedBox(height: 12),
                    Text(_error!, textAlign: TextAlign.center),
                    TextButton.icon(
                      onPressed: _load,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Coba Lagi'),
                    ),
                  ],
                ),
              ),
            )
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(15),
                children: [
                  _section('Informasi Pesanan', Icons.receipt_long_outlined, [
                    _readonly('Nomor pesanan', widget.noPesanan),
                    _readonly(
                      'Nomor resi',
                      _resi.isEmpty ? 'Belum tersedia' : _resi,
                    ),
                    _readonly(
                      'Status',
                      _statusTidakSinkron
                          ? 'Perlu pemeriksaan Admin Logistik'
                          : (_approval
                                ? 'Perlu persetujuan Admin Logistik'
                                : 'Dapat diubah langsung'),
                    ),
                    if (_approval && !_statusTidakSinkron)
                      const Padding(
                        padding: EdgeInsets.only(top: 8),
                        child: Text(
                          'Perubahan akan diajukan ke Admin Logistik, bukan langsung mengubah pesanan.',
                          style: TextStyle(
                            color: Color(0xFFA36810),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (_statusTidakSinkron)
                      Padding(
                        padding: const EdgeInsets.only(top: 9),
                        child: Text(
                          _pesanStatusTidakSinkron,
                          style: const TextStyle(
                            color: Color(0xFFB45309),
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ]),
                  _section('Informasi Pembeli', Icons.person_outline, [
                    _field('Nama Pembeli', _nama, icon: Icons.badge_outlined),
                    _field(
                      'Nomor WhatsApp',
                      _phone,
                      icon: Icons.phone_outlined,
                      keyboard: TextInputType.phone,
                    ),
                    _field(
                      'Tanggal Order',
                      _tanggal,
                      readOnly: true,
                      onTap: _chooseDate,
                      icon: Icons.calendar_today_outlined,
                    ),
                    if (_dateNotice != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 13),
                        child: Text(
                          _dateNotice!,
                          style: const TextStyle(
                            color: Colors.deepOrange,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    _field(
                      'Tanggal Chat Masuk',
                      _chatMasuk,
                      required: false,
                      readOnly: true,
                      onTap: _chooseChatDate,
                      icon: Icons.schedule_outlined,
                    ),
                    _field(
                      'Catatan Pesanan',
                      _notes,
                      required: false,
                      lines: 3,
                      icon: Icons.notes_outlined,
                    ),
                  ]),
                  _section('Alamat Pengiriman', Icons.location_on_outlined, [
                    const Padding(
                      padding: EdgeInsets.only(bottom: 13),
                      child: Text(
                        'Pilih nama wilayah secara berurutan seperti form Tambah Pesanan.',
                        style: TextStyle(color: Colors.black54, fontSize: 12),
                      ),
                    ),
                    _regionField(
                      'Provinsi',
                      _provinsi,
                      _provinces,
                      0,
                      _loadingProvince,
                      _provinceError,
                    ),
                    _regionField(
                      'Kabupaten/Kota',
                      _kabupaten,
                      _cities,
                      1,
                      _loadingCity,
                      _cityError,
                      enabled: _provinsi.text.isNotEmpty,
                    ),
                    _regionField(
                      'Kecamatan',
                      _kecamatan,
                      _districts,
                      2,
                      _loadingDistrict,
                      _districtError,
                      enabled: _kabupaten.text.isNotEmpty,
                    ),
                    _regionField(
                      'Desa/Kelurahan',
                      _desa,
                      _villages,
                      3,
                      _loadingVillage,
                      _villageError,
                      enabled: _kecamatan.text.isNotEmpty,
                    ),
                    _field(
                      'Alamat Lengkap',
                      _alamat,
                      lines: 3,
                      icon: Icons.home_outlined,
                    ),
                  ]),
                  _section(
                    'Pembayaran (Tidak Dapat Diubah)',
                    Icons.payments_outlined,
                    [
                      _readonly(
                        'Metode',
                        _str(p['jenis_transaksi']).toUpperCase(),
                      ),
                      _readonly('COD', _money(p['cod'])),
                      _readonly('NON COD', _money(p['non_cod'])),
                      _readonly('DP', _money(p['dp'])),
                      _readonly('POR', _money(p['por'])),
                      _readonly(
                        'Total Harga',
                        _money(o['totalHarga'] ?? o['total_harga']),
                      ),
                      _readonly(
                        'Total HPP',
                        _money(o['totalHpp'] ?? o['total_hpp']),
                      ),
                      _readonly(
                        'Biaya Admin',
                        _money(o['totalAdmin'] ?? o['total_admin']),
                      ),
                      _readonly(
                        'Bukti Lama',
                        _str(p['nama_file']).isNotEmpty
                            ? _str(p['nama_file'])
                            : (_str(p['bukti_bayar']).isNotEmpty
                                  ? 'Sudah ada'
                                  : 'Belum ada'),
                      ),
                      const SizedBox(height: 6),
                      OutlinedButton.icon(
                        onPressed: _saving ? null : _pickProof,
                        icon: const Icon(Icons.upload_file_outlined),
                        label: Text(
                          _proof == null
                              ? 'Ganti / Tambah Bukti Pembayaran'
                              : _proof!.name,
                        ),
                      ),
                      const Text(
                        'Jika tidak memilih bukti baru, file lama tetap dipertahankan. JPG/PNG maks. 5 MB.',
                        style: TextStyle(fontSize: 11, color: Colors.black54),
                      ),
                    ],
                  ),
                  _section(
                    'Produk (Tidak Dapat Diubah)',
                    Icons.inventory_2_outlined,
                    [
                      if (products.isEmpty)
                        const Text('Data produk tidak tersedia.'),
                      for (final item in products) ...[
                        Builder(
                          builder: (context) {
                            final product = _map(item['produk']);
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _readonly(
                                  'Produk',
                                  _str(product['nama_produk']),
                                ),
                                _readonly('Variasi', _str(product['variasi'])),
                                _readonly('SKU', _str(item['sku'])),
                                _readonly('Jumlah', _str(item['jumlah'])),
                                _readonly('Harga', _money(item['harga'])),
                                _readonly('HPP', _money(item['hpp'])),
                                _readonly(
                                  'Catatan Produk',
                                  _str(item['catatan']),
                                ),
                                const Divider(height: 24),
                              ],
                            );
                          },
                        ),
                      ],
                    ],
                  ),
                  FilledButton.icon(
                    onPressed: _saving || _statusTidakSinkron ? null : _save,
                    icon: const Icon(Icons.save_outlined),
                    label: Text(
                      _saving
                          ? 'Memproses...'
                          : (_approval ? 'Ajukan Edit' : 'Simpan Perubahan'),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.navy,
                      minimumSize: const Size.fromHeight(49),
                    ),
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed:
                        _saving ||
                            _statusTidakSinkron ||
                            (!_deleteDirect && !_deleteRequest)
                        ? null
                        : _delete,
                    icon: const Icon(Icons.delete_outline),
                    label: Text(
                      _deleteRequest ? 'Ajukan Hapus Pesanan' : 'Hapus Pesanan',
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.red,
                      minimumSize: const Size.fromHeight(48),
                    ),
                  ),
                  if (!_deleteDirect && !_deleteRequest)
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Status pengiriman perlu diperiksa oleh Admin Logistik sebelum pesanan dapat dihapus.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.deepOrange,
                        ),
                      ),
                    ),
                  const SizedBox(height: 26),
                ],
              ),
            ),
    );
  }
}

class _RegionSearchSheet extends StatefulWidget {
  final String label;
  final List<_Region> options;
  const _RegionSearchSheet({required this.label, required this.options});
  @override
  State<_RegionSearchSheet> createState() => _RegionSearchSheetState();
}

class _RegionSearchSheetState extends State<_RegionSearchSheet> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final options = widget.options
        .where(
          (e) =>
              e.name.toLowerCase().contains(query.toLowerCase()) ||
              e.id.contains(query),
        )
        .toList();
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(context).height * .73,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pilih ${widget.label}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      autofocus: true,
                      onChanged: (v) => setState(() => query = v),
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.search),
                        hintText: 'Cari nama wilayah...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: options.length,
                  itemBuilder: (ctx, i) {
                    final item = options[i];
                    return ListTile(
                      title: Text(item.name),
                      onTap: () => Navigator.pop(context, item.id),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
