import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart'; // WriteBuffer
import 'package:flutter/material.dart';
import 'package:google_mlkit_object_detection/google_mlkit_object_detection.dart';

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

class _HomePageState extends State<HomePage> {
  CameraController? _controller;
  late final ObjectDetector _objectDetector;
  bool _isProcessing = false;
  final Set<String> _detectedItems = <String>{};

  @override
  void initState() {
    super.initState();
    _initializeDetector();
    _initializeCamera();
  }

  Future<void> _initializeDetector() async {
    final options = ObjectDetectorOptions(
      classifyObjects: true,
      multipleObjects: true,
      mode: DetectionMode.stream,
    );
    _objectDetector = ObjectDetector(options: options);
  }

  Future<void> _initializeCamera() async {
    final cameras = await availableCameras();
    final camera = cameras.first;
    _controller = CameraController(
      camera,
      ResolutionPreset.medium,
      enableAudio: false,
    );
    await _controller!.initialize();
    _controller!.startImageStream(_processCameraImage);
    if (mounted) {
      setState(() {});
    }
  }

  void _processCameraImage(CameraImage image) async {
    if (_isProcessing) return;
    _isProcessing = true;
    try {
      final inputImage = _inputImageFromCameraImage(image);
      final objects = await _objectDetector.processImage(inputImage);
      if (objects.isNotEmpty) {
        setState(() {
          for (final obj in objects) {
            for (final label in obj.labels) {
              _detectedItems.add(label.text);
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Error processing image: $e');
    }
    _isProcessing = false;
  }

  InputImage _inputImageFromCameraImage(CameraImage image) {
    // 1. Flatten the planes of the image into a single Uint8List.
    final WriteBuffer allBytes = WriteBuffer();
    for (final Plane plane in image.planes) {
      allBytes.putUint8List(plane.bytes);
    }
    final Uint8List bytes = allBytes.done().buffer.asUint8List();

    // 2. Get image metadata.
    final Size imageSize = Size(image.width.toDouble(), image.height.toDouble());
    final camera = _controller!.description;
    final InputImageRotation imageRotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
            InputImageRotation.rotation0deg;

    final InputImageFormat inputImageFormat =
        InputImageFormatValue.fromRawValue(image.format.raw) ??
            InputImageFormat.nv21;

    // 3. Create the InputImageMetadata for the correct API version.
    // This version of the library expects 'bytesPerRow' instead of 'planeData'.
    final metadata = InputImageMetadata(
      size: imageSize,
      rotation: imageRotation,
      format: inputImageFormat,
      bytesPerRow: image.planes.first.bytesPerRow,
    );

    // 4. Create and return the InputImage.
    return InputImage.fromBytes(bytes: bytes, metadata: metadata);
  }

  @override
  void dispose() {
    _controller?.dispose();
    _objectDetector.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Pantry Scanner')),
      body: Column(
        children: [
          Expanded(
            flex: 3,
            child: _controller == null || !_controller!.value.isInitialized
                ? const Center(child: CircularProgressIndicator())
                : CameraPreview(_controller!),
          ),
          Expanded(
            flex: 2,
            child: ListView(
              children: _detectedItems
                  .map((item) => ListTile(title: Text(item)))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }
}