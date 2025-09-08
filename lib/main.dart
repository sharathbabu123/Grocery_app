import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'firebase_options.dart';
import 'inventory_item.dart';
import 'inventory_page.dart';
import 'isolate_service.dart';
import 'barcode_scan_page.dart';
import 'qr_scan_page.dart';
import 'login_page.dart';
import 'get_started_page.dart';
import 'inventory_repository.dart';

// Main and MyApp are unchanged, but MyApp now points to our new HomePage
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grocery Inventory',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const AuthGate(), // Show login if signed-out
    );
  }
}

//==============================================================================
// AUTH GATE - Shows LoginPage when signed out, HomePage when signed in
//==============================================================================

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final user = snapshot.data;
        if (user == null) {
          return const _OnboardingDecider();
        }
        return const HomePage();
      },
    );
  }
}

// Decides between GetStartedPage and LoginPage when signed-out
class _OnboardingDecider extends StatelessWidget {
  const _OnboardingDecider();

  Future<bool> _seenOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('onboarding_seen') ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _seenOnboarding(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        final seen = snapshot.data ?? false;
        if (!seen) return const GetStartedPage();
        return const LoginPage();
      },
    );
  }
}

//==============================================================================
// NEW HOME PAGE - Displays the final inventory
//==============================================================================

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // This is the master list of all items in the user's inventory.
  final List<InventoryItem> _masterInventoryList = [];
  late final InventoryRepository _repo;

  @override
  void initState() {
    super.initState();
    _repo = InventoryRepository(FirebaseFirestore.instance);
  }

  // This method handles the navigation to the scanning page and receives the data back.
  Future<void> _navigateToScanner() async {
    // We expect a List<InventoryItem> to be returned from the scanning flow.
    final List<InventoryItem>? newItems = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CameraPage()),
    );

    // If new items were returned and the widget is still mounted, update the state.
    if (newItems != null && mounted) {
      // Update local (legacy) list for immediate UI feedback
      setState(() {
        for (final newItem in newItems) {
          final idx = _masterInventoryList.indexWhere((i) => i.name == newItem.name);
          if (idx == -1) {
            _masterInventoryList.add(newItem);
          } else {
            _masterInventoryList[idx].quantity += newItem.quantity;
          }
        }
      });
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await _repo.upsertDetectedItems(uid, newItems);
      }
    }
  }

  Future<void> _navigateToBarcode() async {
    final List<InventoryItem>? newItems = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const BarcodeScanPage()),
    );
    if (newItems != null && mounted) {
      setState(() {
        for (final newItem in newItems) {
          final idx = _masterInventoryList.indexWhere((i) => i.name == newItem.name);
          if (idx == -1) {
            _masterInventoryList.add(newItem);
          } else {
            _masterInventoryList[idx].quantity += newItem.quantity;
          }
        }
      });
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await _repo.upsertDetectedItems(uid, newItems);
      }
    }
  }

  Future<void> _navigateToQr() async {
    final List<InventoryItem>? newItems = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const QrScanPage()),
    );
    if (newItems != null && mounted) {
      setState(() {
        for (final newItem in newItems) {
          final idx = _masterInventoryList.indexWhere((i) => i.name == newItem.name);
          if (idx == -1) {
            _masterInventoryList.add(newItem);
          } else {
            _masterInventoryList[idx].quantity += newItem.quantity;
          }
        }
      });
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) {
        await _repo.upsertDetectedItems(uid, newItems);
      }
    }
  }

  Future<void> _showItemDialog({InventoryItem? item}) async {
    final nameController = TextEditingController(text: item?.name ?? '');
    final qtyController = TextEditingController(text: (item?.quantity ?? 1).toString());
    ItemCategory category = item?.category ?? ItemCategory.other;
    DateTime? expiry = item?.expiryDate;
    await showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text(item == null ? 'Add Item' : 'Edit Item'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: qtyController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Quantity'),
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<ItemCategory>(
                  value: category,
                  decoration: const InputDecoration(labelText: 'Category'),
                  items: ItemCategory.values
                      .map((c) => DropdownMenuItem(value: c, child: Text(c.displayName)))
                      .toList(),
                  onChanged: (v) => category = v ?? category,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        expiry == null
                            ? 'No expiry'
                            : 'Expires: ${DateFormat.yMMMd().format(expiry!)}',
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: expiry ?? DateTime.now(),
                          firstDate: DateTime.now(),
                          lastDate: DateTime(2101),
                        );
                        if (picked != null) {
                          expiry = picked;
                        }
                      },
                      child: const Text('Pick date'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final name = nameController.text.trim();
                final qty = int.tryParse(qtyController.text.trim()) ?? 1;
                if (name.isEmpty) return;
                final uid = FirebaseAuth.instance.currentUser?.uid;
                if (uid == null) return;
                final newItem = InventoryItem(
                  id: item?.id ?? '',
                  name: name,
                  quantity: qty,
                  expiryDate: expiry,
                  category: category,
                );
                await _repo.addOrUpdateItem(uid, newItem);
                if (!mounted) return;
                Navigator.pop(context);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Grocery Inventory'),
        actions: [
          IconButton(
            tooltip: 'Add item',
            icon: const Icon(Icons.add),
            onPressed: () => _showItemDialog(),
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await FirebaseAuth.instance.signOut();
            },
          ),
        ],
      ),
      // The FloatingActionButton is the primary way to start scanning.
      floatingActionButton: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingActionButton.extended(
            heroTag: 'scan_items',
            onPressed: _navigateToScanner,
            label: const Text('Scan Items'),
            icon: const Icon(Icons.camera_alt),
          ),
          const SizedBox(width: 12),
          FloatingActionButton.extended(
            heroTag: 'scan_barcode',
            onPressed: _navigateToBarcode,
            label: const Text('Scan Barcode'),
            icon: const Icon(Icons.qr_code),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: Builder(
        builder: (context) {
          final uid = FirebaseAuth.instance.currentUser?.uid;
          if (uid == null) {
            return const Center(child: Text('Not signed in'));
          }
          return StreamBuilder<List<InventoryItem>>(
            stream: _repo.streamInventory(uid),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              final items = snapshot.data ?? const <InventoryItem>[];
              if (items.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: Text(
                      'Your inventory is empty.\nTap Scan or the + button to add items.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 18, color: Colors.grey),
                    ),
                  ),
                );
              }
              return ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return Card(
                    margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    elevation: 4,
                    child: ListTile(
                      onTap: () => _showItemDialog(item: item),
                      leading: CircleAvatar(
                        backgroundColor: Theme.of(context).primaryColorLight,
                        child: Text(item.name[0].toUpperCase()),
                      ),
                      title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text('Category: ${item.category.displayName}' +
                          (item.expiryDate != null
                              ? '\nExpires: ${DateFormat.yMMMd().format(item.expiryDate!)}'
                              : '')),
                      isThreeLine: item.expiryDate != null,
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            onPressed: () async {
                              final newQty = item.quantity - 1;
                              final uid = FirebaseAuth.instance.currentUser!.uid;
                              if (newQty <= 0) {
                                await _repo.deleteItem(uid, item.id);
                              } else {
                                await _repo.setQuantity(uid, item.id, newQty);
                              }
                            },
                          ),
                          Text(' ${item.quantity} '),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            onPressed: () async {
                              final uid = FirebaseAuth.instance.currentUser!.uid;
                              await _repo.incrementQuantity(uid, item.id, 1);
                            },
                          ),
                          IconButton(
                            tooltip: 'Delete',
                            icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
                            onPressed: () async {
                              final uid = FirebaseAuth.instance.currentUser!.uid;
                              await _repo.deleteItem(uid, item.id);
                            },
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}


//==============================================================================
// RENAMED CAMERA PAGE - The screen with the live camera feed
//==============================================================================

class CameraPage extends StatefulWidget {
  const CameraPage({Key? key}) : super(key: key);
  @override
  State<CameraPage> createState() => _CameraPageState();
}

class _CameraPageState extends State<CameraPage> with WidgetsBindingObserver {
  // All state variables and methods from your previous main.dart are moved here.
  static const Duration _minProcessInterval = Duration(milliseconds: 700);

  CameraController? _controller;
  Interpreter? _interpreter;
  late List<String> _labels;
  bool _isProcessing = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  Isolate? _isolate;
  ReceivePort? _mainReceivePort;
  SendPort? _isolateSendPort;
  final Set<String> _frameSpecific = <String>{};
  final List<String> _liveLog = <String>[];
  bool _isCapturing = false;
  final List<Uint8List> _capturedImages = [];
  final Set<String> _inventoryItems = <String>{};
  
  // --- REMOVED: The _groceryWhitelist is no longer needed. ---

  void _log(String msg) {
    if (!mounted) return;
    final now = DateTime.now();
    final ts = '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')}';
    debugPrint('[DETECT $ts] $msg');
    setState(() {
      _liveLog.add('$ts $msg');
      if (_liveLog.length > 60) _liveLog.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    _log('Initializing...');
    await _startIsolate();
    await _loadModelAndLabels();
    await _initializeCamera();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _teardown();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    final controller = _controller;
    if (controller == null) {
      if (state == AppLifecycleState.resumed) {
        _initialize();
      }
      return;
    }
    if (!controller.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _teardown();
    } else if (state == AppLifecycleState.resumed) {
      _initialize();
    }
  }

  Future<void> _teardown() async {
    _log('Tearing down...');
    await _stopStream();
    await _controller?.dispose();
    _controller = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _isolateSendPort = null;
    _mainReceivePort?.close();
    _log('Teardown complete.');
  }

  Future<void> _startIsolate() async {
    if (_isolate != null) return;
    _mainReceivePort = ReceivePort();
    _isolate =
        await Isolate.spawn(isolateEntryPoint, _mainReceivePort!.sendPort);
    _mainReceivePort!.listen((message) {
      if (_isolateSendPort == null && message is SendPort) {
        _isolateSendPort = message;
        _log('Isolate connection established.');
      } else if (message is Set<String>) {
        _handleIsolateResult(message);
      }
    });
  }

  // --- MODIFIED: This method now accepts all high-confidence detections ---
  void _handleIsolateResult(Set<String> labelsFound) {
    if (!mounted) {
      _isProcessing = false;
      return;
    }
    // Clean up the labels from the model (e.g., "tabby, tabby cat" -> "tabby")
    // but do not filter them against a whitelist.
    final cleanedLabels = labelsFound.map((label) {
      return label.split(',').first;
    }).toSet();

    if (!setEquals(_frameSpecific, cleanedLabels)) {
      setState(() {
        _frameSpecific.clear();
        _frameSpecific.addAll(cleanedLabels);
      });
    }

    final newlyCapturedLabels = cleanedLabels.difference(_inventoryItems);
    if (newlyCapturedLabels.isNotEmpty) {
      setState(() {
        _inventoryItems.addAll(newlyCapturedLabels);
        for (final label in newlyCapturedLabels) {
          _log('Added to inventory: $label');
        }
      });
    } else if (_isCapturing) {
      _log('Nothing new detected in captured image.');
    }
    _isProcessing = false;
  }

  Future<void> _loadModelAndLabels() async {
    if (_interpreter != null) return;
    try {
      final rawLabels =
          await DefaultAssetBundle.of(context).loadString('assets/labels.txt');
      _labels = rawLabels
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
      final options = InterpreterOptions()..threads = 2;
      _interpreter = await Interpreter.fromAsset(
          'assets/models/grocery_model.tflite',
          options: options);
      _log('Model loaded. Labels count: ${_labels.length}');
    } catch (e) {
      _log('Error loading model: $e');
    }
  }

  Future<void> _initializeCamera() async {
    if (_controller != null) return; // Prevent reinitialization
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        _log('No cameras found!');
        return;
      }
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _controller = CameraController(
        camera,
        ResolutionPreset.low, // CRITICAL FIX for performance
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller!.initialize();
      if (!mounted) return;
      await _controller!.startImageStream(_processCameraImage);
      setState(() {});
      _log('Camera initialized and stream started.');
    } catch (e) {
      _log('Camera init error: $e');
    }
  }

  Future<void> _stopStream() async {
    if (_controller != null && _controller!.value.isStreamingImages) {
      try {
        await _controller!.stopImageStream();
      } catch (e) {
        _log('Error stopping stream: $e');
      }
    }
  }
  
  void _processCameraImage(CameraImage image) {
      if (_isolateSendPort == null || _interpreter == null || _isProcessing || !mounted) return;
      final now = DateTime.now();
      if (now.difference(_lastProcessed) < _minProcessInterval) return;
      _isProcessing = true;
      _lastProcessed = now;
      var cameraImageData = CameraImageData(
          width: image.width,
          height: image.height,
          planesBytes: image.planes.map((p) => p.bytes).toList(),
          planesBytesPerRow: image.planes.map((p) => p.bytesPerRow).toList(),
          planesBytesPerPixel: image.planes.map((p) => p.bytesPerPixel).toList(),
      );
      final isolateData = IsolateData(cameraImageData, _interpreter!.address, _labels);
      _isolateSendPort!.send(isolateData);
  }

  Future<void> _captureAndProcessImage() async {
    if (_controller == null || !_controller!.value.isInitialized || _isCapturing) {
      return;
    }
    try {
      setState(() => _isCapturing = true);
      _log('Capturing image...');
      await _stopStream();
      
      final XFile imageFile = await _controller!.takePicture();
      final Uint8List imageBytes = await imageFile.readAsBytes();

      setState(() => _capturedImages.add(imageBytes));

      final staticImageData = StaticImageData(imageBytes);
      final isolateData = IsolateData(staticImageData, _interpreter!.address, _labels);
      
      _log('Sending captured image for detection...');
      _isProcessing = true;
      _isolateSendPort?.send(isolateData);
    } catch (e) {
      _log('Error capturing image: $e');
      _isProcessing = false;
    } finally {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        await _controller?.startImageStream(_processCameraImage);
        setState(() => _isCapturing = false);
      }
    }
  }

  Future<void> _submitInventory() async {
    if (!mounted) return;
    await _stopStream();
    final List<InventoryItem>? confirmedItems = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InventoryPage(
          detectedItems: _inventoryItems.toList(),
        ),
      ),
    );
    if (confirmedItems != null) {
      Navigator.of(context).pop(confirmedItems);
    } else {
      if (mounted) {
        await _controller?.startImageStream(_processCameraImage);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _inventoryItems.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Items')),
      floatingActionButton: FloatingActionButton(onPressed: _captureAndProcessImage, child: const Icon(Icons.camera_alt)),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: Stack(
        children: [
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(child: CameraPreview(_controller!))
          else
            const Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.green))),
          Positioned(left: 12, top: 12, right: 12, child: IgnorePointer(child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(8)), child: SizedBox(height: 96, child: ListView.builder(reverse: true, itemCount: _liveLog.length, itemBuilder: (_, i) => Text(_liveLog[_liveLog.length - 1 - i], style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12))))))),
          Positioned(left: 0, right: 0, bottom: 270, child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: _frameSpecific.map((item) => Padding(padding: const EdgeInsets.only(right: 8), child: Chip(label: Text(item), backgroundColor: Colors.yellow.withOpacity(0.95), side: const BorderSide(color: Colors.orange)))).toList()))),
          Positioned(left: 0, right: 0, bottom: 180, child: Container(padding: const EdgeInsets.symmetric(vertical: 8), color: Colors.black.withOpacity(0.2), child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: _inventoryItems.map((item) => Padding(padding: const EdgeInsets.only(right: 8), child: Chip(label: Text(item), backgroundColor: Colors.lightBlueAccent.withOpacity(0.95), side: const BorderSide(color: Colors.blue)))).toList())))),
          Positioned(left: 0, right: 0, bottom: 90, child: Container(height: 80, color: Colors.black.withOpacity(0.2), child: ListView.builder(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), itemCount: _capturedImages.length, itemBuilder: (context, index) { final imageBytes = _capturedImages[index]; return Padding(padding: const EdgeInsets.only(right: 10.0), child: Container(width: 64, height: 64, decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white, width: 2)), child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(imageBytes, fit: BoxFit.cover)))); }))),
          Positioned(left: 16, right: 16, bottom: 16, child: ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)), onPressed: canSubmit ? _submitInventory : null, child: const Text('Confirm Detections', style: TextStyle(fontSize: 18)))),
          if (_isCapturing) Positioned.fill(child: Container(color: Colors.black.withOpacity(0.5), child: const Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.white))))),
        ],
      ),
    );
  }
}
