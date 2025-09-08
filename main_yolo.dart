import 'dart:async';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

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
  static const double _confidenceThreshold = 0.70; // 0.70 as you set (raise/lower as needed)
  static const Duration _minProcessInterval = Duration(milliseconds: 220); // ~4.5 FPS

  CameraController? _controller;
  Interpreter? _interpreter;
  late final List<String> _labels;

  bool _isProcessing = false;
  bool _streaming = false;
  DateTime _lastProcessed = DateTime.fromMillisecondsSinceEpoch(0);
  int _frameCount = 0;

  // Cached input dims read from model
  int _modelH = 640, _modelW = 640, _modelC = 3;

  // Per-frame live sets (not persisted)
  final Set<String> _frameSpecific = <String>{};

  // --- PERSISTED session list (what you asked for) ---
  final Set<String> _capturedItems = <String>{};

  // For small on-screen console + de-spam logs
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
    unawaited(_loadModel());
    unawaited(_initializeCamera());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _controller?.dispose();
    _interpreter?.close();
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

  Future<void> _loadModel() async {
    // 1) labels
    final raw = await DefaultAssetBundle.of(context).loadString('assets/labels.txt');
    _labels = raw.split('\n').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();

    // 2) interpreter (await here is correct)
    final options = InterpreterOptions()
      ..threads = 2
      ..useNnApiForAndroid = false;
    try { options.addDelegate(XNNPackDelegate()); } catch (_) {}

    _interpreter = await Interpreter.fromAsset('assets/models/grocery_model.tflite', options: options);

    // 3) discover/force input shape
    final in0 = _interpreter!.getInputTensor(0);
    final inShape = in0.shape; // expect [1, 640, 640, 3]
    _modelH = inShape[inShape.length - 3];
    _modelW = inShape[inShape.length - 2];
    _modelC = inShape[inShape.length - 1];

    // ❌ no await here
    _interpreter!.resizeInputTensor(0, [1, _modelH, _modelW, _modelC]);
    _interpreter!.allocateTensors(); // ❌ no await

    final outShape = _interpreter!.getOutputTensor(0).shape;
    _log('Model loaded: input=${_modelH}×${_modelW}×${_modelC}, out=$outShape, labels=${_labels.length}');
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
        ResolutionPreset.low, // keep low; we downscale to 640 anyway
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
    if (_interpreter == null) return;

    _isProcessing = true;
    _lastProcessed = now;
    _frameCount++;

    try {
      // 1) Convert YUV420 -> RGB image
      final rgb = _yuv420ToImage(image); // img.Image in RGB888

      // 2) Resize to model input (H,W)
      final resized = img.copyResize(rgb, width: _modelW, height: _modelH);
      final inputNHWC = _imageToNHWC4D(resized);

      // Create a 3-D output container matching the interpreter's output shape
      final outTensor = _interpreter!.getOutputTensor(0);
      final oshape = outTensor.shape; // e.g. [1, 16, 8400] or [1, 8400, 16]
      final A = oshape.length >= 3 ? oshape[1] : 0;
      final B = oshape.length >= 3 ? oshape[2] : 0;

      final out3d = List.generate(
        1,
        (_) => List.generate(
          A,
          (_) => List<double>.filled(B, 0.0, growable: false),
          growable: false,
        ),
        growable: false,
      );

      // Run with 4-D input and 3-D output
      _interpreter!.run(inputNHWC, out3d);

      // Decode raw YOLO head → labels
      final labelsFound = _decodeYolo3D(out3d, _labels, _confidenceThreshold);

      // 7) Update session
      _frameSpecific
        ..clear()
        ..addAll(labelsFound);

      final newlyCaptured = _frameSpecific.difference(_capturedItems);
      if (newlyCaptured.isNotEmpty) {
        _capturedItems.addAll(newlyCaptured);
        for (final item in newlyCaptured) _log('Captured new item: $item');
      }

      if (!mounted) return;
      setState(() {});

      _lastFrameSpecific
        ..clear()
        ..addAll(_frameSpecific);
    } catch (e) {
      debugPrint('Error processing image: $e');
    } finally {
      _isProcessing = false;
    }
  }

  // === Image conversion ===
  // Convert CameraImage (YUV420) to img.Image (RGB888)
  img.Image _yuv420ToImage(CameraImage image) {
    final w = image.width, h = image.height;
    final out = img.Image(width: w, height: h); // v4 Image

    final yPlane = image.planes[0];
    final uPlane = image.planes[1];
    final vPlane = image.planes[2];

    final yRowStride = yPlane.bytesPerRow;
    final uvRowStride = uPlane.bytesPerRow;
    final uvPixelStride = uPlane.bytesPerPixel ?? 1;

    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;

    for (int y = 0; y < h; y++) {
      final uvRow = y ~/ 2;
      for (int x = 0; x < w; x++) {
        final uvCol = x ~/ 2;
        final yIndex = y * yRowStride + x;
        final uvIndex = uvRow * uvRowStride + uvCol * uvPixelStride;

        final Y = yBytes[yIndex];
        final U = uBytes[uvIndex];
        final V = vBytes[uvIndex];

        final c = (Y - 16).clamp(0, 255);
        final d = U - 128;
        final e = V - 128;

        final r = ((298 * c + 409 * e + 128) >> 8).clamp(0, 255);
        final g = ((298 * c - 100 * d - 208 * e + 128) >> 8).clamp(0, 255);
        final b = ((298 * c + 516 * d + 128) >> 8).clamp(0, 255);

        out.setPixelRgb(x, y, r, g, b); // v4 API
      }
    }
    return out;
  }


  // Convert img.Image (RGB888) -> Float32List [1,H,W,3] normalized to [0..1]
    // A) Keep your resizing as-is, but create a 4-D list:
  List _imageToNHWC4D(img.Image im) {
    final H = im.height, W = im.width;
    final out = List.generate(1,
        (_) => List.generate(H,
            (_) => List.generate(W, (_) => List<double>.filled(3, 0.0, growable: false),
                growable: false),
            growable: false),
        growable: false);

    for (int y = 0; y < H; y++) {
      for (int x = 0; x < W; x++) {
        final px = im.getPixel(x, y);
        out[0][y][x][0] = px.r / 255.0;
        out[0][y][x][1] = px.g / 255.0;
        out[0][y][x][2] = px.b / 255.0;
      }
    }
    return out; // List shape [1,H,W,3]
  }

  // === YOLO decode (labels only, no boxes overlay) ===
  // Accepts output shapes like [1, N, D] or [1, D, N], where:
  //   D = 4 + C         (no obj)   OR
  //   D = 5 + C         (with obj)
  // Returns set of label strings above threshold after simple maxClass selection.
  Set<String> _decodeYolo3D(
      List<List<List<double>>> out3d,
      List<String> labels,
      double confTh,
    ) {
      // out3d is [1, A, B] where either A=D,B=N  or  A=N,B=D
      final A = out3d[0].length;
      final B = out3d[0][0].length;

      final d = math.min(A, B);   // feature dimension (4(+obj)+C)
      final n = math.max(A, B);   // candidates
      final transposed = (A == d); // true for [1, D, N] like [1,16,8400]

      final c = labels.length;
      final hasObj = (d == 5 + c);
      final clsFrom = hasObj ? 5 : 4;

      double _sigm(double x) => 1.0 / (1.0 + math.exp(-x));
      double v(int i, int j) => transposed ? out3d[0][j][i] : out3d[0][i][j];

      final found = <String>{};
      for (int i = 0; i < n; i++) {
        final obj = hasObj ? _sigm(v(i, 4)) : 1.0;

        int bestK = 0;
        double bestScore = -1e9;
        for (int k = 0; k < c; k++) {
          final prob = _sigm(v(i, clsFrom + k)); // robust to logits or probs
          final score = obj * prob;
          if (score > bestScore) {
            bestScore = score;
            bestK = k;
          }
        }
        if (bestScore >= confTh) {
          found.add(labels[bestK]);
        }
      }
      return found;
    }


  double _sigmoid(double x) => 1.0 / (1.0 + math.exp(-x));

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
