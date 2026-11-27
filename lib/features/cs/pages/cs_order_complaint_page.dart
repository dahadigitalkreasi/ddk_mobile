import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:video_compress/video_compress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:video_player/video_player.dart';

import '../../../app/app_theme.dart';
import '../../../core/network/api_client.dart';

class _ComplaintAttachment {
  final String name;
  final String path;
  final int size;

  const _ComplaintAttachment({
    required this.name,
    required this.path,
    required this.size,
  });
}

class CsOrderComplaintPage extends StatefulWidget {
  final String noPesanan;

  const CsOrderComplaintPage({super.key, required this.noPesanan});

  @override
  State<CsOrderComplaintPage> createState() => _CsOrderComplaintPageState();
}

class _CsOrderComplaintPageState extends State<CsOrderComplaintPage> {
  static const _storage = FlutterSecureStorage();
  static const _maxBytes = 5 * 1024 * 1024;
  static const _extensions = <String>[
    'jpg',
    'jpeg',
    'png',
    'webp',
    'mp4',
    'mov',
  ];

  final _keterangan = TextEditingController();
  final List<_ComplaintAttachment> _files = [];
  Map<String, dynamic>? _detail;
  bool _loading = true;
  bool _sending = false;
  bool _processingFiles = false;
  String? _processingLabel;
  String? _error;
  String? _statusInfo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _keterangan.dispose();
    // Berkas sementara disimpan di cache perangkat dan dapat dibersihkan OS.
    super.dispose();
  }

  Map<String, dynamic> _asMap(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  Future<String> _token() async {
    final token = await _storage.read(key: 'auth_token');
    if (token == null || token.isEmpty) {
      throw StateError('Sesi login sudah berakhir. Silakan masuk kembali.');
    }
    return token;
  }

  String _friendlyError(Object error) {
    if (error is DioException) {
      final code = error.response?.statusCode;
      if (code == 401) {
        return 'Sesi login sudah berakhir. Silakan masuk kembali.';
      }
      if (code == 403) {
        return 'Akun ini tidak memiliki izin untuk mengajukan komplain.';
      }
      if (code == 404) {
        return 'Pesanan tidak ditemukan. Periksa kembali nomor pesanan.';
      }
      if (code == 405) {
        return 'Layanan pengajuan komplain belum tersedia. Hubungi admin.';
      }
      if (code == 408 || code == 429) {
        return 'Layanan sedang sibuk. Periksa riwayat komplain sebelum mencoba lagi.';
      }
      if (code == 413) {
        return 'Ukuran berkas terlalu besar. Pilih berkas yang lebih kecil.';
      }
      if (code == 422) {
        final body = _asMap(error.response?.data);
        final errors = _asMap(body['errors']);
        if (errors.containsKey('files') ||
            errors.keys.any((key) => key.toString().startsWith('files.'))) {
          return 'Bukti tidak sesuai. Gunakan foto atau video dengan ukuran maksimal 5 MB per file.';
        }
        return 'Data komplain belum sesuai. Periksa nomor pesanan dan bukti yang dipilih.';
      }
      if (code != null && code >= 500) {
        return 'Layanan sedang mengalami kendala. Coba lagi beberapa saat atau hubungi admin.';
      }
      if (error.type == DioExceptionType.connectionTimeout ||
          error.type == DioExceptionType.sendTimeout ||
          error.type == DioExceptionType.receiveTimeout) {
        return 'Waktu pengiriman habis. Periksa riwayat bukti sebelum mengirim ulang.';
      }
      if (error.type == DioExceptionType.connectionError) {
        return 'Koneksi ke layanan komplain terputus. Periksa internet atau hubungi admin.';
      }
      return 'Pengajuan belum dapat diselesaikan. Periksa riwayat komplain atau hubungi admin.';
    }
    if (error is StateError) {
      return error.message;
    }
    return 'Ada kendala saat memproses komplain. Silakan coba lagi.';
  }

  Future<void> _load() async {
    if (!mounted) {
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final token = await _token();
      final response = await ApiClient.dio.get<dynamic>(
        '/pesanan/komplain/${Uri.encodeComponent(widget.noPesanan)}',
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        ),
      );
      final body = _asMap(response.data);
      if (body['success'] != true || body['data'] is! Map) {
        throw const FormatException('Respons detail komplain tidak sesuai.');
      }
      if (!mounted) {
        return;
      }
      setState(() => _detail = _asMap(body['data']));
    } catch (error) {
      if (!mounted) {
        return;
      }
      // Dokumentasi API menyatakan 404 berarti pesanan tidak ditemukan,
      // bukan bukti bahwa pengajuan komplain belum ada.
      setState(() => _error = _friendlyError(error));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _snack(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  bool _isVideoFile(String name) =>
      RegExp(r'\.(mp4|mov)$', caseSensitive: false).hasMatch(name);

  Future<_ComplaintAttachment?> _prepareEvidence(PlatformFile original) async {
    final source = original.path;
    if (source == null || source.isEmpty) {
      throw StateError(
        'Berkas ${original.name} tidak dapat dibuka. Pilih ulang.',
      );
    }
    final originalFile = File(source);
    if (!await originalFile.exists()) {
      throw StateError(
        'Berkas ${original.name} sudah tidak tersedia. Pilih ulang.',
      );
    }
    final bytes = await originalFile.length();
    if (bytes <= _maxBytes) {
      return _ComplaintAttachment(
        name: original.name,
        size: bytes,
        path: source,
      );
    }

    if (_isVideoFile(original.name)) {
      return _compressVideo(original);
    }
    return _compressPhoto(original);
  }

  Future<_ComplaintAttachment?> _compressPhoto(PlatformFile original) async {
    final cache = await getTemporaryDirectory();
    // JPG lebih hemat ukuran untuk bukti foto. File asli tidak diubah.
    const attempts = <(int, int)>[
      (85, 1920),
      (75, 1600),
      (65, 1280),
      (50, 960),
      (35, 720),
    ];
    for (var i = 0; i < attempts.length; i++) {
      final (quality, dimension) = attempts[i];
      final output =
          '${cache.path}/komplain_${DateTime.now().microsecondsSinceEpoch}_$i.jpg';
      final result = await FlutterImageCompress.compressAndGetFile(
        original.path!,
        output,
        quality: quality,
        minWidth: dimension,
        minHeight: dimension,
        format: CompressFormat.jpeg,
        keepExif: false,
      );
      if (result == null) {
        continue;
      }
      final compressed = File(result.path);
      final length = await compressed.length();
      if (length > 0 && length <= _maxBytes) {
        return _ComplaintAttachment(
          name: '${_basename(original.name)}_compressed.jpg',
          size: length,
          path: compressed.path,
        );
      }
    }
    return null;
  }

  Future<_ComplaintAttachment?> _compressVideo(PlatformFile original) async {
    // Tidak memberikan startTime maupun duration: seluruh durasi dipertahankan.
    // Audio tetap disertakan. Menurunkan resolusi/bitrate jika diperlukan.
    final originalInfo = await VideoCompress.getMediaInfo(original.path!);
    final qualities = <VideoQuality>[
      VideoQuality.Res960x540Quality,
      VideoQuality.Res640x480Quality,
      VideoQuality.LowQuality,
    ];
    for (final quality in qualities) {
      final result = await VideoCompress.compressVideo(
        original.path!,
        quality: quality,
        deleteOrigin: false,
        includeAudio: true,
      );
      final outputPath = result?.path;
      if (outputPath == null || outputPath.isEmpty) {
        continue;
      }
      final compressed = File(outputPath);
      if (!await compressed.exists()) {
        continue;
      }
      final bytes = await compressed.length();
      // Cek durasi agar tidak ada video terpotong. Toleransi 1 detik untuk
      // perbedaan pembulatan metadata codec.
      final originalDuration = originalInfo.duration;
      final outputDuration = result?.duration;
      if (originalDuration != null &&
          outputDuration != null &&
          (originalDuration - outputDuration).abs() > 1000) {
        continue;
      }
      if (bytes > 0 && bytes <= _maxBytes) {
        return _ComplaintAttachment(
          name: '${_basename(original.name)}_compressed.mp4',
          size: bytes,
          path: outputPath,
        );
      }
    }
    return null;
  }

  String _basename(String name) => name
      .replaceFirst(RegExp(r'\.[^.]+$'), '')
      .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');

  Future<void> _pickFiles() async {
    if (_sending || _processingFiles) {
      return;
    }
    try {
      final picked = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: _extensions,
      );
      if (picked.isEmpty || !mounted) {
        return;
      }
      setState(() => _processingFiles = true);
      final additions = <_ComplaintAttachment>[];
      final failed = <String>[];
      for (var i = 0; i < picked.length; i++) {
        final original = picked[i];
        if (!mounted) {
          break;
        }
        setState(
          () => _processingLabel =
              'Menyiapkan bukti ${i + 1} dari ${picked.length}...',
        );
        try {
          final ext = (original.extension ?? original.name.split('.').last)
              .toLowerCase();
          if (!_extensions.contains(ext)) {
            failed.add(original.name);
            continue;
          }
          if (_files.any((f) => f.path == original.path) ||
              additions.any((f) => f.path == original.path)) {
            continue;
          }
          final prepared = await _prepareEvidence(original);
          if (prepared == null) {
            failed.add(original.name);
          } else {
            additions.add(prepared);
          }
        } catch (_) {
          failed.add(original.name);
        }
      }
      if (!mounted) {
        return;
      }
      setState(() => _files.addAll(additions));
      if (failed.isNotEmpty) {
        _snack(
          '${failed.length} berkas tidak berhasil diperkecil ke 5 MB. '
          'Pilih foto/video yang lebih kecil atau coba rekam ulang.',
        );
      }
    } catch (_) {
      _snack('Tidak bisa memilih atau memproses bukti. Silakan coba lagi.');
    } finally {
      if (mounted) {
        setState(() {
          _processingFiles = false;
          _processingLabel = null;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (_sending || _processingFiles) {
      return;
    }
    if (_files.isEmpty) {
      _snack('Tambahkan minimal satu foto atau video sebagai bukti komplain.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Kirim komplain?'),
        content: Text(
          'Anda akan mengirim ${_files.length} bukti untuk pesanan ${widget.noPesanan}. Pastikan semuanya sudah benar.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Periksa Lagi'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Kirim Komplain'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _sending = true);
    try {
      final token = await _token();
      final form = FormData();
      form.fields.add(MapEntry('no_pesanan', widget.noPesanan));
      final note = _keterangan.text.trim();
      if (note.isNotEmpty) form.fields.add(MapEntry('keterangan', note));
      for (final file in _files) {
        if (file.size > _maxBytes || file.size <= 0) {
          throw StateError('Ukuran bukti harus maksimal 5 MB per berkas.');
        }
        final path = file.path;
        form.files.add(
          MapEntry(
            'files[]',
            await MultipartFile.fromFile(path, filename: file.name),
          ),
        );
      }
      final response = await ApiClient.dio.post<dynamic>(
        '/pesanan/komplain',
        data: form,
        options: Options(
          headers: {
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
          contentType: 'multipart/form-data',
          // Upload foto/video bisa lebih lama daripada permintaan data biasa.
          sendTimeout: const Duration(minutes: 2),
          receiveTimeout: const Duration(minutes: 2),
        ),
      );
      final body = _asMap(response.data);
      if (body['success'] != true) {
        throw const FormatException(
          'Pengajuan komplain belum dapat dipastikan.',
        );
      }
      if (!mounted) {
        return;
      }
      setState(() {
        _files.clear();
        _keterangan.clear();
        _statusInfo =
            'Pengajuan komplain berhasil dikirim. Menunggu pemeriksaan admin.';
      });
      _snack('Komplain berhasil diajukan.');
      await _load();
    } catch (error) {
      // Diagnostic debug saja. Jangan cetak token maupun isi file.
      if (error is DioException) {
        final status = error.response?.statusCode;
        final serverBody = _asMap(error.response?.data);
        final serverMessage = serverBody['message'];
        final validationKeys = _asMap(serverBody['errors']).keys.join(', ');
        debugPrint(
          '[KOMPLAIN POST] status=${status ?? '-'} '
          'type=${error.type.name} '
          'path=${error.requestOptions.path} '
          'message=${serverMessage ?? '-'} '
          'fields=${validationKeys.isEmpty ? '-' : validationKeys}',
        );
      } else {
        debugPrint('[KOMPLAIN POST] ${error.runtimeType}: $error');
      }
      // Dokumen API menyatakan beberapa berkas mungkin tersimpan meskipun
      // upload berikutnya gagal, dan pengajuan ulang dapat menimpa berkas.
      // Karena itu, jangan retry otomatis ataupun menghapus pilihan pengguna.
      _snack(
        '${_friendlyError(error)} Jika proses sempat berjalan, periksa riwayat bukti sebelum mengirim ulang.',
      );
      await _load();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  String _statusText(String value) {
    switch (value.toLowerCase()) {
      case 'pending':
        return 'Menunggu Persetujuan';
      case 'approve':
        return 'Disetujui';
      case 'reject':
        return 'Ditolak';
      default:
        return value.isEmpty ? 'Belum Ada Pengajuan' : 'Sedang Diproses';
    }
  }

  Color _statusColor(String value) {
    switch (value.toLowerCase()) {
      case 'pending':
        return const Color(0xFFA65A04);
      case 'approve':
        return const Color(0xFF0B8B65);
      case 'reject':
        return const Color(0xFFB42332);
      default:
        return const Color(0xFF61758A);
    }
  }

  Widget _card({
    required String title,
    required IconData icon,
    required Widget child,
    String? subtitle,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE5EBF2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: const Color(0xFFEAF3FA),
                  borderRadius: BorderRadius.circular(11),
                ),
                child: Icon(icon, color: AppTheme.primary, size: 20),
              ),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppTheme.navy,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: Color(0xFF718096),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }

  Widget _infoRow(String label, String value) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 102,
          child: Text(
            label,
            style: const TextStyle(color: Color(0xFF718096), fontSize: 12),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            value.isEmpty ? '-' : value,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.navy,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );

  bool _isVideo(String url) {
    final parsed = Uri.tryParse(url);
    final path = parsed?.queryParameters['path'] ?? parsed?.path ?? url;
    return RegExp(r'\.(mp4|mov)$', caseSensitive: false).hasMatch(path);
  }

  Future<void> _openEvidence(String url, bool video) async {
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      'Bukti Komplain',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              Flexible(
                child: video
                    ? _ComplaintVideo(url: url)
                    : InteractiveViewer(
                        child: Image.network(
                          url,
                          fit: BoxFit.contain,
                          errorBuilder: (context, error, stackTrace) =>
                              const Padding(
                                padding: EdgeInsets.all(25),
                                child: Text(
                                  'Foto belum dapat dibuka. Silakan coba lagi.',
                                ),
                              ),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final order = _asMap(_detail?['pesanan']);
    final evidence = (_detail?['bukti'] is List)
        ? (_detail!['bukti'] as List).whereType<Map>().map(_asMap).toList()
        : <Map<String, dynamic>>[];
    final complaintReason = '${order['komplain'] ?? ''}'.trim();
    final status = '${order['pengajuanKomplain'] ?? ''}';
    final statusColor = _statusColor(status);
    final busy = _sending || _processingFiles;
    final canSubmit = status.isEmpty && !_loading && _error == null;

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FA),
      appBar: AppBar(
        backgroundColor: const Color(0xFF103961),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Komplain Pesanan',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            tooltip: 'Muat ulang',
            onPressed: busy ? null : _load,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          children: [
            Container(
              padding: const EdgeInsets.fromLTRB(18, 18, 18, 25),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  colors: [Color(0xFF103961), Color(0xFF145B91)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.vertical(
                  bottom: Radius.circular(24),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'NOMOR PESANAN',
                    style: TextStyle(
                      fontSize: 11,
                      color: Color(0xFFD2E5F7),
                      letterSpacing: 1,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  SelectableText(
                    widget.noPesanan,
                    style: const TextStyle(
                      fontSize: 22,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 15),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF27618F),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          status.isEmpty
                              ? Icons.assignment_outlined
                              : status == 'approve'
                              ? Icons.check_circle_outline
                              : status == 'reject'
                              ? Icons.cancel_outlined
                              : Icons.hourglass_top_rounded,
                          color: Colors.white,
                          size: 18,
                        ),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Text(
                            status.isEmpty
                                ? 'Belum ada pengajuan komplain'
                                : _statusText(status),
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 18, 15, 20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _card(
                    title: 'Informasi Pesanan',
                    icon: Icons.receipt_long_outlined,
                    subtitle: 'Identitas pesanan yang akan diperiksa',
                    child: Column(
                      children: [
                        _infoRow('Pembeli', '${order['namaPembeli'] ?? '-'}'),
                        const Divider(height: 1, color: Color(0xFFEEF1F5)),
                        _infoRow(
                          'Nomor resi',
                          '${order['noResi'] ?? ''}'.trim().isEmpty
                              ? 'Belum ada resi'
                              : '${order['noResi']}',
                        ),
                        if (status.isNotEmpty) ...[
                          const Divider(height: 1, color: Color(0xFFEEF1F5)),
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Row(
                              children: [
                                Container(
                                  width: 8,
                                  height: 8,
                                  decoration: BoxDecoration(
                                    color: statusColor,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    'Pengajuan: ${_statusText(status)}',
                                    style: TextStyle(
                                      color: statusColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                        if (_loading) ...[
                          const SizedBox(height: 12),
                          const LinearProgressIndicator(minHeight: 3),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: 12),
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF3F2),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Icon(
                                  Icons.info_outline,
                                  color: Color(0xFFB42332),
                                  size: 20,
                                ),
                                const SizedBox(width: 9),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        _error!,
                                        style: const TextStyle(
                                          color: Color(0xFF9D2834),
                                          fontSize: 12,
                                        ),
                                      ),
                                      TextButton.icon(
                                        onPressed: busy ? null : _load,
                                        icon: const Icon(
                                          Icons.refresh,
                                          size: 17,
                                        ),
                                        label: const Text('Coba lagi'),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_statusInfo != null)
                    _card(
                      title: 'Informasi',
                      icon: Icons.check_circle_outline,
                      child: Text(
                        _statusInfo!,
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  if (status.isNotEmpty || evidence.isNotEmpty)
                    _card(
                      title: 'Alasan Komplain',
                      icon: Icons.description_outlined,
                      subtitle: 'Keterangan yang disampaikan saat pengajuan',
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(13),
                        decoration: BoxDecoration(
                          color: const Color(0xFFF6F8FB),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          complaintReason.isEmpty
                              ? 'Tidak ada keterangan tambahan.'
                              : complaintReason,
                          style: const TextStyle(
                            color: AppTheme.navy,
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                      ),
                    ),
                  _card(
                    title: 'Bukti Komplain',
                    icon: Icons.perm_media_outlined,
                    subtitle: '${evidence.length} bukti yang sudah tercatat',
                    child: evidence.isEmpty
                        ? Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 22,
                            ),
                            decoration: BoxDecoration(
                              color: const Color(0xFFF6F8FB),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Column(
                              children: [
                                Icon(
                                  Icons.collections_outlined,
                                  color: Color(0xFF9CA9B8),
                                  size: 28,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Belum ada bukti komplain',
                                  style: TextStyle(
                                    color: Color(0xFF718096),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          )
                        : LayoutBuilder(
                            builder: (context, constraints) {
                              final width = (constraints.maxWidth - 20) / 3;
                              return Wrap(
                                spacing: 10,
                                runSpacing: 10,
                                children: evidence.map((item) {
                                  final url = '${item['path'] ?? ''}';
                                  if (url.isEmpty) {
                                    return const SizedBox.shrink();
                                  }
                                  final isVideo = _isVideo(url);
                                  return InkWell(
                                    onTap: () => _openEvidence(url, isVideo),
                                    borderRadius: BorderRadius.circular(12),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: SizedBox(
                                        width: width,
                                        height: width,
                                        child: Stack(
                                          fit: StackFit.expand,
                                          children: [
                                            if (!isVideo)
                                              Image.network(
                                                url,
                                                fit: BoxFit.cover,
                                                cacheWidth: 280,
                                                loadingBuilder:
                                                    (context, child, progress) {
                                                      if (progress == null) {
                                                        return child;
                                                      }
                                                      return const ColoredBox(
                                                        color: Color(
                                                          0xFFEAF3FA,
                                                        ),
                                                        child: Center(
                                                          child:
                                                              CircularProgressIndicator(
                                                                strokeWidth: 2,
                                                              ),
                                                        ),
                                                      );
                                                    },
                                                errorBuilder:
                                                    (
                                                      context,
                                                      error,
                                                      stackTrace,
                                                    ) => const ColoredBox(
                                                      color: Color(0xFFEAF3FA),
                                                      child: Center(
                                                        child: Icon(
                                                          Icons
                                                              .broken_image_outlined,
                                                          color:
                                                              AppTheme.primary,
                                                          size: 30,
                                                        ),
                                                      ),
                                                    ),
                                              )
                                            else
                                              const ColoredBox(
                                                color: Color(0xFFEAF3FA),
                                                child: Center(
                                                  child: Icon(
                                                    Icons
                                                        .play_circle_fill_outlined,
                                                    size: 38,
                                                    color: AppTheme.primary,
                                                  ),
                                                ),
                                              ),
                                            Positioned(
                                              bottom: 0,
                                              left: 0,
                                              right: 0,
                                              child: Container(
                                                color: const Color(0x990E3252),
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      vertical: 5,
                                                    ),
                                                child: Text(
                                                  isVideo
                                                      ? 'Putar video'
                                                      : 'Lihat foto',
                                                  textAlign: TextAlign.center,
                                                  style: const TextStyle(
                                                    color: Colors.white,
                                                    fontSize: 10,
                                                    fontWeight: FontWeight.w600,
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  );
                                }).toList(),
                              );
                            },
                          ),
                  ),
                  if (canSubmit)
                    _card(
                      title: 'Ajukan Komplain',
                      icon: Icons.edit_document,
                      subtitle: 'Jelaskan masalah dan tambahkan bukti',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _keterangan,
                            enabled: !busy,
                            maxLines: 3,
                            maxLength: 1000,
                            decoration: InputDecoration(
                              labelText: 'Keterangan (opsional)',
                              hintText:
                                  'Contoh: Barang diterima dalam kondisi rusak',
                              hintStyle: const TextStyle(fontSize: 12),
                              alignLabelWithHint: true,
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                          const SizedBox(height: 5),
                          InkWell(
                            onTap: busy ? null : _pickFiles,
                            borderRadius: BorderRadius.circular(14),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 19,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFFF3F8FC),
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: const Color(0xFFC9DCEB),
                                  width: 1.2,
                                ),
                              ),
                              child: Column(
                                children: [
                                  const Icon(
                                    Icons.add_photo_alternate_outlined,
                                    size: 32,
                                    color: AppTheme.primary,
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    'Tambah Foto atau Video',
                                    style: TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.navy,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 5),
                                  const Text(
                                    'Bisa memilih beberapa file sekaligus',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Color(0xFF718096),
                                      fontSize: 11,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          const Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.info_outline,
                                size: 16,
                                color: Color(0xFF718096),
                              ),
                              SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  'Maksimal 5 MB per file. Foto/video yang lebih besar akan dicoba dikompresi tanpa memotong durasi video.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Color(0xFF718096),
                                    height: 1.5,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (_processingFiles) ...[
                            const SizedBox(height: 12),
                            const LinearProgressIndicator(minHeight: 3),
                            const SizedBox(height: 5),
                            Text(
                              _processingLabel ?? 'Menyiapkan berkas...',
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                          if (_files.isNotEmpty) ...[
                            const SizedBox(height: 17),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Bukti dipilih (${_files.length})',
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: AppTheme.navy,
                                    ),
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: busy ? null : _pickFiles,
                                  icon: const Icon(Icons.add, size: 17),
                                  label: const Text('Tambah lagi'),
                                ),
                              ],
                            ),
                            ..._files.asMap().entries.map((entry) {
                              final file = entry.value;
                              final isVideo = _isVideoFile(file.name);
                              return Container(
                                margin: const EdgeInsets.only(bottom: 8),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 7,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFF6F8FB),
                                  borderRadius: BorderRadius.circular(11),
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(9),
                                      child: SizedBox(
                                        width: 48,
                                        height: 48,
                                        child: isVideo
                                            ? const ColoredBox(
                                                color: Color(0xFFE6F0F8),
                                                child: Icon(
                                                  Icons.videocam_outlined,
                                                  color: AppTheme.primary,
                                                  size: 24,
                                                ),
                                              )
                                            : Image.file(
                                                File(file.path),
                                                fit: BoxFit.cover,
                                                cacheWidth: 144,
                                                errorBuilder:
                                                    (
                                                      context,
                                                      error,
                                                      stackTrace,
                                                    ) => const ColoredBox(
                                                      color: Color(0xFFE6F0F8),
                                                      child: Icon(
                                                        Icons
                                                            .broken_image_outlined,
                                                        color: AppTheme.primary,
                                                      ),
                                                    ),
                                              ),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            file.name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            '${(file.size / (1024 * 1024)).toStringAsFixed(2)} MB',
                                            style: const TextStyle(
                                              color: Color(0xFF718096),
                                              fontSize: 11,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: 'Hapus dari pilihan',
                                      onPressed: busy
                                          ? null
                                          : () {
                                              setState(
                                                () =>
                                                    _files.removeAt(entry.key),
                                              );
                                            },
                                      icon: const Icon(Icons.close, size: 19),
                                    ),
                                  ],
                                ),
                              );
                            }),
                          ],
                          const SizedBox(height: 18),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton.icon(
                              onPressed: busy ? null : _submit,
                              style: FilledButton.styleFrom(
                                backgroundColor: AppTheme.primary,
                                padding: const EdgeInsets.symmetric(
                                  vertical: 15,
                                ),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                              icon: _sending
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Icon(Icons.send_outlined),
                              label: Text(
                                _sending
                                    ? 'Mengirim komplain...'
                                    : 'Kirim Pengajuan Komplain',
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (status.isNotEmpty)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAF3FA),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(
                            Icons.info_outline,
                            color: AppTheme.primary,
                            size: 19,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'Komplain sudah tercatat. Lihat status dan bukti di atas.',
                              style: const TextStyle(
                                color: AppTheme.navy,
                                fontSize: 12,
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ComplaintVideo extends StatefulWidget {
  final String url;
  const _ComplaintVideo({required this.url});
  @override
  State<_ComplaintVideo> createState() => _ComplaintVideoState();
}

class _ComplaintVideoState extends State<_ComplaintVideo> {
  late final VideoPlayerController _controller;
  late final Future<void> _initialize;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _initialize = _controller.initialize();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _initialize,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return const Padding(
          padding: EdgeInsets.all(20),
          child: Text('Video belum dapat diputar. Silakan coba lagi.'),
        );
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Center(child: CircularProgressIndicator());
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: VideoPlayer(_controller),
          ),
          IconButton(
            icon: Icon(
              _controller.value.isPlaying
                  ? Icons.pause_circle
                  : Icons.play_circle,
            ),
            iconSize: 42,
            onPressed: () async {
              if (_controller.value.isPlaying) {
                await _controller.pause();
              } else {
                await _controller.play();
              }
              if (mounted) setState(() {});
            },
          ),
        ],
      );
    },
  );
}
