import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:http/http.dart' as http;

import 'inventory_item.dart';
import 'inventory_page.dart';

class BarcodeScanPage extends StatefulWidget {
  const BarcodeScanPage({Key? key}) : super(key: key);

  @override
  State<BarcodeScanPage> createState() => _BarcodeScanPageState();
}

class _BarcodeScanPageState extends State<BarcodeScanPage> with WidgetsBindingObserver {
  final MobileScannerController _controller = MobileScannerController(
    // Common retail formats
    formats: const [
      BarcodeFormat.ean13,
      BarcodeFormat.ean8,
      BarcodeFormat.code128,
    ],
  );

  // Track scanning state
  final Set<String> _seenBarcodes = <String>{};
  final Set<String> _seenNames = <String>{}; // normalized product names
  final Map<String, String> _resolvedNames = <String, String>{}; // barcode -> display name
  final Map<String, ItemCategory> _resolvedCategories = <String, ItemCategory>{};
  final Set<String> _pending = <String>{};
  String? _error;

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

  Future<Map<String, dynamic>?> _fetchProduct(String barcode) async {
    try {
      final uri = Uri.parse('https://world.openfoodfacts.org/api/v2/product/$barcode.json');
      final resp = await http.get(uri);
      if (resp.statusCode != 200) return null;
      final data = json.decode(resp.body) as Map<String, dynamic>;
      if (data['status'] != 1) return null; // 1 means found
      return data['product'] as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  ItemCategory _mapCategories(List<dynamic>? tags) {
    final lower = (tags ?? const <dynamic>[])
        .map((e) => e.toString().toLowerCase())
        .toList(growable: false);
    if (lower.any((t) => t.contains('beverage'))) return ItemCategory.beverages;
    if (lower.any((t) => t.contains('dairy'))) return ItemCategory.dairy;
    if (lower.any((t) => t.contains('spice') || t.contains('condiment'))) return ItemCategory.spices;
    if (lower.any((t) => t.contains('frozen'))) return ItemCategory.frozen;
    if (lower.any((t) => t.contains('fruit') || t.contains('vegetable') || t.contains('produce'))) return ItemCategory.produce;
    if (lower.isNotEmpty) return ItemCategory.pantry;
    return ItemCategory.other;
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    for (final code in capture.barcodes) {
      final raw = code.rawValue?.trim();
      if (raw == null || raw.isEmpty) continue;
      if (_seenBarcodes.contains(raw) || _pending.contains(raw)) continue; // de-dupe + throttle

      _seenBarcodes.add(raw);
      _pending.add(raw);
      setState(() {});

      final product = await _fetchProduct(raw);
      if (!mounted) return;

      if (product == null) {
        // fallback: use the barcode itself as a placeholder name
        final resolved = raw; // barcode text as name
        final normalized = resolved.trim().toLowerCase();
        if (!_seenNames.contains(normalized)) {
          _resolvedNames[raw] = resolved;
          _resolvedCategories[raw] = ItemCategory.other;
          _seenNames.add(normalized);
        }
        _pending.remove(raw);
        // Do not surface a persistent error for not-found items
        setState(() {});
        continue;
      }

      final name = (product['product_name'] ?? '').toString().trim();
      final brand = (product['brands'] ?? '').toString().split(',').first.trim();
      final categoriesTags = product['categories_tags'] as List<dynamic>?;

      final displayName = [name, if (brand.isNotEmpty) brand]
          .where((s) => s.isNotEmpty)
          .join(' - ');
      final resolved = displayName.isEmpty ? raw : displayName;
      final category = _mapCategories(categoriesTags);

      final normalized = resolved.trim().toLowerCase();
      if (!_seenNames.contains(normalized)) {
        _resolvedNames[raw] = resolved;
        _resolvedCategories[raw] = category;
        _seenNames.add(normalized);
      }
      _pending.remove(raw);
      setState(() {});
    }
  }

  Future<void> _finishScan() async {
    // Ensure unique names in final list (preserve insertion order)
    final Set<String> unique = <String>{};
    for (final name in _resolvedNames.values) {
      final normalized = name.trim().toLowerCase();
      if (!unique.any((e) => e.trim().toLowerCase() == normalized)) {
        unique.add(name);
      }
    }
    final detectedNames = unique.toList(growable: false);
    if (!mounted) return;
    final List<InventoryItem>? confirmedItems = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InventoryPage(detectedItems: detectedNames),
      ),
    );
    if (!mounted) return;
    // Apply category hints from lookups to first occurrences
    if (confirmedItems != null) {
      for (final item in confirmedItems) {
        // find a barcode whose name matched this item to map category
        final match = _resolvedNames.entries.firstWhere(
          (e) => e.value == item.name,
          orElse: () => const MapEntry('', ''),
        );
        final cat = _resolvedCategories[match.key];
        if (cat != null) item.category = cat;
      }
    }
    Navigator.of(context).pop<List<InventoryItem>>(confirmedItems);
  }

  @override
  Widget build(BuildContext context) {
    final entries = _resolvedNames.entries.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Barcodes')),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // Sliding panel at bottom showing collected items
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.55),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(12),
                  topRight: Radius.circular(12),
                ),
              ),
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'Detected: ${entries.length}${_pending.isNotEmpty ? ' (+${_pending.length} pending)' : ''}',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      ),
                      TextButton(
                        onPressed: entries.isEmpty && _pending.isEmpty ? null : _finishScan,
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.white,
                          backgroundColor: Colors.green,
                        ),
                        child: const Text('Finish Scan'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 120,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemBuilder: (context, index) {
                        final e = entries[index];
                        final cat = _resolvedCategories[e.key];
                        return Container(
                          width: 180,
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.95),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(e.value, maxLines: 2, overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontWeight: FontWeight.bold)),
                              const SizedBox(height: 6),
                              Text('Barcode: ${e.key}', style: const TextStyle(fontSize: 12, color: Colors.black54)),
                              if (cat != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 4),
                                  child: Text('Category: ${cat.displayName}', style: const TextStyle(fontSize: 12)),
                                ),
                            ],
                          ),
                        );
                      },
                      separatorBuilder: (_, __) => const SizedBox(width: 8),
                      itemCount: entries.length,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (_error != null)
            Positioned(
              left: 12,
              right: 12,
              bottom: 160,
              child: Container(
                decoration: BoxDecoration(color: Colors.red.withOpacity(0.85), borderRadius: BorderRadius.circular(8)),
                padding: const EdgeInsets.all(10),
                child: Text(_error!, style: const TextStyle(color: Colors.white)),
              ),
            ),
        ],
      ),
    );
  }
}
