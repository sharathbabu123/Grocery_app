// lib/isolate_service.dart

import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:tflite_flutter/tflite_flutter.dart';

// Data classes and other functions remain the same...
class CameraImageData {
  final int width;
  final int height;
  final List<Uint8List> planesBytes;
  final List<int> planesBytesPerRow;
  final List<int?> planesBytesPerPixel;
  CameraImageData({required this.width, required this.height, required this.planesBytes, required this.planesBytesPerRow, required this.planesBytesPerPixel,});
}
class StaticImageData {
  final Uint8List imageBytes;
  StaticImageData(this.imageBytes);
}
class IsolateData {
  final dynamic imageData;
  final int interpreterAddress;
  final List<String> labels;
  IsolateData(this.imageData, this.interpreterAddress, this.labels);
}
void isolateEntryPoint(SendPort mainSendPort) {
  final isolateReceivePort = ReceivePort();
  mainSendPort.send(isolateReceivePort.sendPort);
  isolateReceivePort.listen((dynamic data) {
    if (data is IsolateData) {
      try {
        final recognitions = runObjectDetection(data);
        mainSendPort.send(recognitions);
      } catch (e, s) {
        debugPrint("Error in isolate: $e\n$s");
        mainSendPort.send(<String>{'Error: $e'});
      }
    }
  });
}
Set<String> runObjectDetection(IsolateData isolateData) {
  final interpreter = Interpreter.fromAddress(isolateData.interpreterAddress);
  img.Image? image;
  if (isolateData.imageData is CameraImageData) {
    image = convertYUV420toImage(isolateData.imageData as CameraImageData);
  } else if (isolateData.imageData is StaticImageData) {
    final staticImageData = isolateData.imageData as StaticImageData;
    image = img.decodeImage(staticImageData.imageBytes);
  }
  if (image == null) {
    return {};
  }
  return _performInference(image, interpreter, isolateData.labels);
}

// ============================================================================
//  THE FIX IS IN THIS FUNCTION
// ============================================================================
/// The core inference logic, now adapted for a QUANTIZED classification model.
Set<String> _performInference(img.Image image, Interpreter interpreter, List<String> labels) {
  // Lower the threshold to catch more potential items. We will filter them later.
  const double confidenceThreshold = 0.2; 

  // Pre-processing is the same
  final resizedImage = img.copyResize(image, width: 224, height: 224);
  final imageBytes = resizedImage.getBytes(order: img.ChannelOrder.rgb);
  final input = List.generate(
    224, (y) => List.generate(
      224, (x) {
        final pixelIndex = (y * 224 + x) * 3;
        return [
          imageBytes[pixelIndex],
          imageBytes[pixelIndex + 1],
          imageBytes[pixelIndex + 2],
        ];
      },
    ),
  );
  final inputBatched = [input];
  final numClasses = labels.length;
  // IMPORTANT: The output shape must match the number of labels.
  final output = List.filled(1 * numClasses, 0).reshape([1, numClasses]);

  interpreter.run(inputBatched, output);

  // --- NEW ACCURACY LOGIC ---
  final Set<String> recognitions = {};
  final scores = output[0];
  
  // Instead of finding only the single best score, we now check ALL scores.
  for (int i = 0; i < scores.length; i++) {
    // Convert the uint8 score (0-255) to a probability (0.0-1.0)
    final prob = scores[i] / 255.0; 
    
    // If a score is above our threshold, add its label to the results.
    if (prob > confidenceThreshold) {
      if (i < labels.length) {
        recognitions.add(labels[i]);
      }
    }
  }

  return recognitions;
}

// YUV Converter remains the same
img.Image? convertYUV420toImage(CameraImageData cameraImage) {
  // ... (no changes to this function)
  if (cameraImage.planesBytes.length < 3) return null;
  final int width = cameraImage.width;
  final int height = cameraImage.height;
  final Uint8List y = cameraImage.planesBytes[0];
  final Uint8List u = cameraImage.planesBytes[1];
  final Uint8List v = cameraImage.planesBytes[2];
  final int yRowStride = cameraImage.planesBytesPerRow[0];
  final int uvRowStride = cameraImage.planesBytesPerRow[1];
  final int uvPixelStride = cameraImage.planesBytesPerPixel[1] ?? 2;
  final img.Image rgbImage = img.Image(width: width, height: height, numChannels: 3);
  for (int r = 0; r < height; r++) {
    for (int c = 0; c < width; c++) {
      final int yIndex = r * yRowStride + c;
      final int uvIndex = (r ~/ 2) * uvRowStride + (c ~/ 2) * uvPixelStride;
      if (yIndex >= y.length || uvIndex >= u.length || uvIndex >= v.length) continue;
      final int Y = y[yIndex];
      final int U = u[uvIndex];
      final int V = v[uvIndex];
      int R = (Y + 1.402 * (V - 128)).round().clamp(0, 255);
      int G = (Y - 0.344136 * (U - 128) - 0.714136 * (V - 128)).round().clamp(0, 255);
      int B = (Y + 1.772 * (U - 128)).round().clamp(0, 255);
      rgbImage.setPixelRgb(c, r, R, G, B);
    }
  }
  return rgbImage;
}
