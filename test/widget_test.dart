import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:daha_digital_kreasi/app/app.dart';

void main() {
  testWidgets('Aplikasi Daha Digital Kreasi berhasil ditampilkan', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DahaDigitalKreasiApp());

    await tester.pump();

    // Pastikan aplikasi memiliki MaterialApp.
    expect(find.byType(MaterialApp), findsOneWidget);

    // Pastikan tidak ada exception saat render awal.
    expect(tester.takeException(), isNull);
  });
}