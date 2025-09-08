import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'inventory_item.dart';
import 'inventory_page.dart';

class QrScanPage extends StatefulWidget {
  const QrScanPage({Key? key}) : super(key: key);

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(formats: const [BarcodeFormat.qrCode]);
  bool _handled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _controller.stop();
    } else if (state == AppLifecycleState.resumed) {
      _controller.start();
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    if (_handled) return;
    final codes = capture.barcodes;
    if (codes.isEmpty) return;
    final value = codes.first.rawValue;
    if (value == null || value.trim().isEmpty) return;
    _handled = true;
    await _controller.stop();

    // For now, treat the QR payload as an item name. You can
    // define a custom schema later (e.g., name|qty|category).
    final initialDetected = <String>[value.trim()];

    if (!mounted) return;
    final List<InventoryItem>? confirmedItems = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InventoryPage(detectedItems: initialDetected),
      ),
    );
    if (!mounted) return;
    Navigator.of(context).pop<List<InventoryItem>>(confirmedItems);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan QR Code')),
      body: MobileScanner(
        controller: _controller,
        onDetect: _onDetect,
      ),
    );
  }
}

