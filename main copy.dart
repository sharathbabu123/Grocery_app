import 'dart:async';
import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import 'inventory_item.dart';
import 'inventory_page.dart'; // Changed from results_page.dart
import 'isolate_service.dart';

// Main and MyApp are unchanged, but MyApp now points to our new HomePage
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Grocery Inventory',
      theme: ThemeData(primarySwatch: Colors.green),
      home: const HomePage(), // The app starts here now
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

  // This method handles the navigation to the scanning page and receives the data back.
  Future<void> _navigateToScanner() async {
    // We expect a List<InventoryItem> to be returned from the scanning flow.
    final List<InventoryItem>? newItems = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CameraPage()),
    );

    // If new items were returned and the widget is still mounted, update the state.
    if (newItems != null && mounted) {
      setState(() {
        // Merge by name: increment quantity if item exists, else add.
        for (final newItem in newItems) {
          final idx = _masterInventoryList.indexWhere((i) => i.name == newItem.name);
          if (idx == -1) {
            _masterInventoryList.add(newItem);
          } else {
            _masterInventoryList[idx].quantity += newItem.quantity;
          }
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('My Grocery Inventory'),
      ),
      // The FloatingActionButton is the primary way to start scanning.
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _navigateToScanner,
        label: const Text('Scan New Items'),
        icon: const Icon(Icons.camera_alt),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: _masterInventoryList.isEmpty
          // Show a helpful message if the inventory is empty.
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24.0),
                child: Text(
                  'Your inventory is empty.\nTap the "Scan New Items" button to get started!',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, color: Colors.grey),
                ),
              ),
            )
          // Display the list of inventory items.
          : ListView.builder(
              padding: const EdgeInsets.only(bottom: 80), // Space for the FAB
              itemCount: _masterInventoryList.length,
              itemBuilder: (context, index) {
                final item = _masterInventoryList[index];
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  elevation: 4,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: Theme.of(context).primaryColorLight,
                      child: Text(item.name[0].toUpperCase()), // First letter of the item name
                    ),
                    title: Text(item.name, style: const TextStyle(fontWeight: FontWeight.bold)),
                    subtitle: Text('Category: ${item.category.displayName}'),
                    trailing: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text('Qty: ${item.quantity}'),
                        if (item.expiryDate != null)
                          Text(DateFormat.yMMMd().format(item.expiryDate!)),
                      ],
                    ),
                  ),
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
    _mainReceivePort?.close();
    _isolate = null;
    _isolateSendPort = null;
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

  void _handleIsolateResult(Set<String> labelsFound) {
    if (!mounted) {
      _isProcessing = false;
      return;
    }
    if (!setEquals(_frameSpecific, labelsFound)) {
      setState(() {
        _frameSpecific.clear();
        _frameSpecific.addAll(labelsFound);
      });
    }
    final newlyCapturedLabels = labelsFound.difference(_inventoryItems);
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
    if (_controller != null && _controller!.value.isInitialized) {
      if (!_controller!.value.isStreamingImages) {
        await _controller!.startImageStream(_processCameraImage);
      }
      return;
    }
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
        ResolutionPreset.low,
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
      setState(() {});
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
    if (_isolateSendPort == null || _interpreter == null || _isProcessing || !mounted)
      return;
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
    final isolateData = IsolateData(
      cameraImageData,
      _interpreter!.address,
      _labels,
    );
    _isolateSendPort!.send(isolateData);
  }

  Future<void> _captureAndProcessImage() async {
    if (_controller == null || !_controller!.value.isInitialized || _isCapturing) {
      return;
    }
    try {
      setState(() {
        _isCapturing = true;
        _log('Capturing image...');
      });
      await _stopStream();
      final XFile imageFile = await _controller!.takePicture();
      final Uint8List imageBytes = await imageFile.readAsBytes();
      setState(() {
        _capturedImages.add(imageBytes);
      });
      final staticImageData = StaticImageData(imageBytes);
      final isolateData = IsolateData(
        staticImageData,
        _interpreter!.address,
        _labels,
      );
      _log('Sending captured image for detection...');
      _isProcessing = true;
      _isolateSendPort?.send(isolateData);
    } catch (e) {
      _log('Error capturing image: $e');
      _isProcessing = false;
    } finally {
      await Future.delayed(const Duration(milliseconds: 500));
      if (mounted) {
        await _initializeCamera();
        setState(() {
          _isCapturing = false;
        });
      }
    }
  }

  // --- MODIFIED: This method now pushes to the InventoryPage and waits for a result ---
  Future<void> _submitInventory() async {
    if (!mounted) return;

    await _stopStream();

    // Navigate to the InventoryPage and wait for it to pop with a result.
    final List<InventoryItem>? confirmedItems = await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => InventoryPage(
          detectedItems: _inventoryItems.toList(),
        ),
      ),
    );

    // If the user saved on the InventoryPage, we receive the final list.
    // We then pop this CameraPage and send the result back to the HomePage.
    if (confirmedItems != null) {
      Navigator.of(context).pop(confirmedItems);
    } else {
      // If the user just pressed the back button, we simply restart the camera.
      if (mounted) {
        await _initializeCamera();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // The UI of this page is largely the same as your previous version.
    final canSubmit = _inventoryItems.isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Scan Items')),
      floatingActionButton: FloatingActionButton(
        onPressed: _captureAndProcessImage,
        child: const Icon(Icons.camera_alt),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      body: Stack(
        children: [
          // Camera preview
          if (_controller != null && _controller!.value.isInitialized)
            Positioned.fill(child: CameraPreview(_controller!))
          else
            const Center(
                child: CircularProgressIndicator(
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.green))),
          // UI Overlays for logs, chips, thumbnails, and submit button
          // These are identical to your last version.
          // Log overlay
          Positioned(left: 12, top: 12, right: 12, child: IgnorePointer(child: Container(padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(8),), child: SizedBox(height: 96, child: ListView.builder(reverse: true, itemCount: _liveLog.length, itemBuilder: (_, i) => Text(_liveLog[_liveLog.length - 1 - i], style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 12),),),),),),),
          // Live detection chips
          Positioned(left: 0, right: 0, bottom: 270, child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: _frameSpecific.map((item) => Padding(padding: const EdgeInsets.only(right: 8), child: Chip(label: Text(item), backgroundColor: Colors.yellow.withOpacity(0.95), side: const BorderSide(color: Colors.orange),),)).toList(),),),),
          // Consolidated list of all detected items
          Positioned(left: 0, right: 0, bottom: 180, child: Container(padding: const EdgeInsets.symmetric(vertical: 8), color: Colors.black.withOpacity(0.2), child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: _inventoryItems.map((item) => Padding(padding: const EdgeInsets.only(right: 8), child: Chip(label: Text(item), backgroundColor: Colors.lightBlueAccent.withOpacity(0.95), side: const BorderSide(color: Colors.blue),),)).toList(),),),),),
          // Row of captured thumbnails (no text)
          Positioned(left: 0, right: 0, bottom: 90, child: Container(height: 80, color: Colors.black.withOpacity(0.2), child: ListView.builder(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), itemCount: _capturedImages.length, itemBuilder: (context, index) {final imageBytes = _capturedImages[index]; return Padding(padding: const EdgeInsets.only(right: 10.0), child: Container(width: 64, height: 64, decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: Colors.white, width: 2),), child: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.memory(imageBytes, fit: BoxFit.cover,),),),);},),),),
          // Submit button
          Positioned(left: 16, right: 16, bottom: 16, child: ElevatedButton(style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)), onPressed: canSubmit ? _submitInventory : null, child: const Text('Confirm Detections', style: TextStyle(fontSize: 18)),),),
          // Loading indicator for capture
          if (_isCapturing) Positioned.fill(child: Container(color: Colors.black.withOpacity(0.5), child: const Center(child: CircularProgressIndicator(valueColor: AlwaysStoppedAnimation<Color>(Colors.white),),),),),
        ],
      ),
    );
  }
}
