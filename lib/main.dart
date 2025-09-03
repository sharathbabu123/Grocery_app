import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:google_mlkit_image_labeling/google_mlkit_image_labeling.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

import 'results_page.dart';

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
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({Key? key}) : super(key: key);
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  // --- Tunables ---
  static const double _confidenceThreshold = 0.7;              // << threshold = 0.5
  static const Duration _minProcessInterval = Duration(milliseconds: 200); // ~5 fps

  CameraController? _controller;
  late final ObjectDetector _objectDetector;
  late final ImageLabeler _labeler;

  bool _isProcessing = false;
  bool _streaming = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  int _frameCount = 0;

  // Per-frame live sets (not persisted)
  final Set<String> _frameCoarse = <String>{};    // "Food", "Home goods", etc.
  final Set<String> _frameSpecific = <String>{};  // "banana", "bottle", etc.

  // --- PERSISTED session list (what you asked for) ---
  final Set<String> _capturedItems = <String>{};

  // For small on-screen console + de-spam logs
  final Set<String> _lastFrameCoarse = <String>{};
  final Set<String> _lastFrameSpecific = <String>{};
  final List<String> _liveLog = <String>[];
  void _log(String msg) {
    if (!mounted) return;
    final ts = TimeOfDay.now().format(context);
    debugPrint('[DETECT $ts] $msg');
    setState(() {
      _liveLog.add('$ts  $msg');
      if (_liveLog.length > 60) _liveLog.removeAt(0);
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _objectDetector = ObjectDetector(
      options: ObjectDetectorOptions(
        mode: DetectionMode.stream,
        multipleObjects: true,
        classifyObjects: true, // gives coarse categories
      ),
    );

    _labeler = ImageLabeler(
      options: ImageLabelerOptions(
        confidenceThreshold: _confidenceThreshold, // apply 0.5 on labeler
      ),
    );

    unawaited(_initializeCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _controller?.dispose();
    _objectDetector.close();
    _labeler.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _stopStream();
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      unawaited(_initializeCamera());
    }
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      final camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        camera,
        ResolutionPreset.low, // lighter to avoid buffer starvation
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );

      _controller = controller;
      await controller.initialize();
      if (!mounted) return;

      await _startStream();
      setState(() {});
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  Future<void> _startStream() async {
    if (_streaming) return;
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;
    try {
      await controller.startImageStream(_processCameraImage);
      _streaming = true;
    } catch (e) {
      debugPrint('startImageStream error: $e');
    }
  }

  Future<void> _stopStream() async {
    if (!_streaming) return;
    try {
      await _controller?.stopImageStream();
    } catch (_) {
      // ignore
    } finally {
      _streaming = false;
    }
  }

  // ---- Frame analyzer (throttled) ----
  void _processCameraImage(CameraImage image) async {
    final now = DateTime.now();
    if (now.difference(_lastProcessed) < _minProcessInterval) return;
    if (_isProcessing) return;

    _isProcessing = true;
    _lastProcessed = now;
    _frameCount++;

    try {
      final inputImage = _inputImageFromCameraImage(image);

      // 1) Object Detection (coarse categories) with threshold on label confidence
      _frameCoarse.clear();
      final objects = await _objectDetector.processImage(inputImage);
      for (final o in objects) {
        for (final l in o.labels) {
          final conf = l.confidence ?? 1.0;
          if (conf >= _confidenceThreshold) {
            _frameCoarse.add(l.text);
          }
        }
      }
      // Log newly-seen coarse labels this frame
      for (final label in _frameCoarse.difference(_lastFrameCoarse)) {
        _log('Coarse: $label');
      }

      // 2) Specific labels (whole-frame labeler) every 3rd frame
      if (_frameCount % 3 == 0) {
        _frameSpecific.clear();
        final labels = await _labeler.processImage(inputImage);
        for (final lab in labels) {
          if (lab.confidence >= _confidenceThreshold) {
            _frameSpecific.add(lab.label);
          }
        }
        for (final s in _frameSpecific.difference(_lastFrameSpecific)) {
          _log('Specific: $s');
        }
      }

      // 3) Persist into session list (does not clear on camera movement)
      // Prefer specific labels; if none, fall back to coarse.
      final toCapture = _frameSpecific.isNotEmpty ? _frameSpecific : _frameCoarse;
      final newlyCaptured = toCapture.difference(_capturedItems);
      if (newlyCaptured.isNotEmpty) {
        _capturedItems.addAll(newlyCaptured);
        for (final item in newlyCaptured) {
          _log('Captured new item: $item'); // sticky in session
        }
      }

      if (!mounted) return;
      setState(() {
        // no-op; we already updated sets; this rebuilds chips & button state
      });

      // update last-frame trackers
      _lastFrameCoarse
        ..clear()
        ..addAll(_frameCoarse);
      _lastFrameSpecific
        ..clear()
        ..addAll(_frameSpecific);
    } catch (e) {
      debugPrint('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // ---- Image conversion helpers ----
  Uint8List _yuv420ToNV21(CameraImage image) {
    final int width = image.width;
    final int height = image.height;

    final int ySize = width * height;
    final int uvSize = (width * height) >> 1;

    final Uint8List nv21 = Uint8List(ySize + uvSize);

    // Y plane
    nv21.setRange(0, ySize, image.planes[0].bytes);

    // Interleave V and U (NV21)
    final Plane uPlane = image.planes[1];
    final Plane vPlane = image.planes[2];
    final int uvRowStride = uPlane.bytesPerRow;
    final int uvPixelStride = uPlane.bytesPerPixel ?? 1;

    int pos = ySize;
    for (int row = 0; row < height ~/ 2; row++) {
      for (int col = 0; col < width ~/ 2; col++) {
        final int uvIndex = row * uvRowStride + col * uvPixelStride;
        nv21[pos++] = vPlane.bytes[uvIndex]; // V
        nv21[pos++] = uPlane.bytes[uvIndex]; // U
      }
    }
    return nv21;
  }

  InputImage _inputImageFromCameraImage(CameraImage image) {
    final rotation = InputImageRotationValue.fromRawValue(
            _controller!.description.sensorOrientation) ??
        InputImageRotation.rotation0deg;

    if (Platform.isAndroid) {
      final bytes = _yuv420ToNV21(image);
      return InputImage.fromBytes(
        bytes: bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.nv21,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    } else {
      // iOS BGRA8888
      return InputImage.fromBytes(
        bytes: image.planes[0].bytes,
        metadata: InputImageMetadata(
          size: Size(image.width.toDouble(), image.height.toDouble()),
          rotation: rotation,
          format: InputImageFormat.bgra8888,
          bytesPerRow: image.planes[0].bytesPerRow,
        ),
      );
    }
  }

  // Navigate to results with the PERSISTED session list
  Future<void> _submitInventory() async {
    await _stopStream();
    if (!mounted) return;

    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => ResultsPage(
          detectedItems: _capturedItems.toList(),
        ),
      ),
    );

    if (!mounted) return;
    await _startStream();
  }

  @override
  Widget build(BuildContext context) {
    final canSubmit = _capturedItems.isNotEmpty; // stays true once something captured
    return Scaffold(
      appBar: AppBar(title: const Text('Pantry Scanner')),
      body: Stack(
        children: [
          // Camera preview
          Positioned.fill(
            child: _controller == null || !_controller!.value.isInitialized
                ? const Center(child: CircularProgressIndicator())
                : CameraPreview(_controller!),
          ),

          // Live console overlay
          Positioned(
            left: 12,
            right: 12,
            top: 12,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.black.withOpacity(0.45),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SizedBox(
                  height: 96,
                  child: ListView.builder(
                    reverse: true,
                    itemCount: _liveLog.length,
                    itemBuilder: (_, i) => Text(
                      _liveLog[_liveLog.length - 1 - i],
                      style: const TextStyle(
                        color: Colors.white,
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Row A: Live (this-frame) specific labels (yellow)
          Positioned(
            left: 0,
            right: 0,
            bottom: 140,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: _frameSpecific.map((item) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(
                      label: Text(item),
                      backgroundColor: Colors.yellow.withOpacity(0.95),
                      side: const BorderSide(color: Colors.orange),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Row B: PERSISTED "Captured so far" items (blue)
          Positioned(
            left: 0,
            right: 0,
            bottom: 90,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                children: _capturedItems.map((item) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(
                      label: Text(item),
                      backgroundColor: Colors.lightBlueAccent.withOpacity(0.95),
                      side: const BorderSide(color: Colors.blue),
                    ),
                  );
                }).toList(),
              ),
            ),
          ),

          // Submit button (stays enabled after first capture)
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(minimumSize: const Size.fromHeight(50)),
              onPressed: canSubmit ? _submitInventory : null,
              child: const Text('Submit Inventory', style: TextStyle(fontSize: 18)),
            ),
          ),
        ],
      ),
    );
  }
}
