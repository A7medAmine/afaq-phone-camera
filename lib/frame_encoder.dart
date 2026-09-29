import 'dart:isolate';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

class FrameEncoder {
  static const _channel = MethodChannel('afaq/jpeg');

  /// Rotates and JPEG-compresses a camera frame natively (Android YuvImage) on a background thread.
  static Future<Uint8List> encodeFrame(
    CameraImage frame, {
    required int rotation,
    required int quality,
  }) async {
    final r = await _channel.invokeMethod<Uint8List>('encode', {
      'y': frame.planes[0].bytes,
      'u': frame.planes[1].bytes,
      'v': frame.planes[2].bytes,
      'w': frame.width,
      'h': frame.height,
      'yStride': frame.planes[0].bytesPerRow,
      'uvStride': frame.planes[1].bytesPerRow,
      'uvPixel': frame.planes[1].bytesPerPixel ?? 1,
      'rotation': rotation,
      'quality': quality,
    });
    return r!;
  }

  /// Applies EXIF orientation and the extra rotation to the pixels of a full-size JPEG.
  static Future<Uint8List> uprightStill(Uint8List jpeg, int extraRotation) {
    return Isolate.run(() {
      final decoded = img.decodeJpg(jpeg);
      if (decoded == null) return jpeg;
      final orientation = decoded.exif.imageIfd.orientation ?? 1;
      if (orientation == 1 && extraRotation == 0) return jpeg;
      var out = img.bakeOrientation(decoded);
      if (extraRotation != 0) out = img.copyRotate(out, angle: extraRotation);
      return Uint8List.fromList(img.encodeJpg(out, quality: 92));
    });
  }
}
