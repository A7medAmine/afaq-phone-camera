import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';

import 'frame_encoder.dart';
import 'settings.dart';

class BusyException implements Exception {}

class CameraService extends ChangeNotifier {
  CameraService(this.settings);

  final Settings settings;
  final _frames = StreamController<Uint8List>.broadcast();
  final _logs = ValueNotifier<List<String>>([]);

  List<CameraDescription> _cameras = [];
  CameraController? controller;
  ResolutionPreset? _openPreset;
  bool _converting = false;
  bool _photoBusy = false;
  bool _restarting = false;
  int viewers = 0;
  String? error;
  int streamW = 1280;
  int streamH = 720;
  int stillW = 0;
  int stillH = 0;
  double fps = 0;
  int _fpsCount = 0;
  DateTime _fpsStart = DateTime.now();

  Stream<Uint8List> get frames => _frames.stream;
  ValueListenable<List<String>> get logs => _logs;
  bool get running => controller?.value.isInitialized ?? false;

  void log(String line) {
    final t = DateTime.now().toIso8601String().substring(11, 19);
    final next = [..._logs.value, '$t $line'];
    _logs.value = next.length > 50 ? next.sublist(next.length - 50) : next;
  }

  void viewersChanged(int n) {
    viewers = n;
    if (n == 0) fps = 0;
    notifyListeners();
  }

  CameraDescription? _pick(String lens) {
    final want = lens == 'front' ? CameraLensDirection.front : CameraLensDirection.back;
    for (final c in _cameras) {
      if (c.lensDirection == want) return c;
    }
    return _cameras.isEmpty ? null : _cameras.first;
  }

  int get _sensor => controller?.description.sensorOrientation ?? 90;

  ResolutionPreset get _streamPreset => const [
        ResolutionPreset.medium,
        ResolutionPreset.high,
        ResolutionPreset.veryHigh,
      ][streamPresets[settings.preset].level];

  Future<void> start() async {
    await _open(_streamPreset);
  }

  Future<void> _open(ResolutionPreset preset, {bool stream = true}) async {
    try {
      if (_cameras.isEmpty) _cameras = await availableCameras();
      final desc = _pick(settings.lens);
      if (desc == null) throw CameraException('none', 'No camera found on this phone');
      final c = CameraController(
        desc,
        preset,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await c.initialize();
      controller = c;
      _openPreset = preset;
      error = null;
      if (settings.torch) await _applyTorch(c, true);
      if (stream) await c.startImageStream(_onFrame);
      log('camera ${desc.lensDirection.name} ready');
    } on CameraException catch (e) {
      error = e.description ?? e.code;
      controller = null;
      log('camera error: $error');
    } catch (e) {
      error = e.toString();
      controller = null;
      log('camera error: $error');
    }
    notifyListeners();
  }

  Future<void> _close() async {
    final c = controller;
    controller = null;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
    try {
      await c.dispose();
    } catch (_) {}
  }

  Future<void> restart() async {
    if (_restarting || _photoBusy) return;
    _restarting = true;
    await _close();
    notifyListeners();
    await _open(_streamPreset);
    _restarting = false;
  }

  Future<void> _applyTorch(CameraController c, bool on) async {
    try {
      await c.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    } catch (e) {
      log('torch error: $e');
    }
  }

  Future<void> setTorch(bool on) async {
    settings.torch = on;
    final c = controller;
    if (c != null && c.value.isInitialized) await _applyTorch(c, on);
    await settings.save();
    notifyListeners();
  }

  Future<void> setLens(String lens) async {
    settings.lens = lens;
    await settings.save();
    await restart();
  }

  Future<void> updateSettings() async {
    await settings.save();
    notifyListeners();
    if (running && _openPreset != _streamPreset) await restart();
  }

  void _onFrame(CameraImage frame) {
    if (_converting || viewers == 0 || _photoBusy) return;
    _converting = true;
    final rotation = (_sensor + settings.rotation) % 360;
    FrameEncoder.encodeFrame(frame, rotation: rotation, quality: streamPresets[settings.preset].quality)
        .then((jpeg) {
          final swap = rotation == 90 || rotation == 270;
          streamW = swap ? frame.height : frame.width;
          streamH = swap ? frame.width : frame.height;
          _frames.add(jpeg);
          _fpsCount++;
          final ms = DateTime.now().difference(_fpsStart).inMilliseconds;
          if (ms >= 2000) {
            fps = _fpsCount * 1000 / ms;
            _fpsCount = 0;
            _fpsStart = DateTime.now();
          }
        })
        .catchError((Object e) {
          log('encode error: $e');
        })
        .whenComplete(() => _converting = false);
  }

  /// The camera plugin uses one resolution for preview, stills and frames, so a
  /// full-size still means reopening the camera at max resolution for a moment.
  Future<Uint8List> takePhoto() async {
    if (_photoBusy || _restarting) throw BusyException();
    _photoBusy = true;
    final sw = Stopwatch()..start();
    try {
      final bytes = await _capture();
      // Browsers apply the EXIF orientation themselves, so pixels are only rewritten for a manual rotation.
      final upright = settings.rotation == 0 ? bytes : await FrameEncoder.uprightStill(bytes, settings.rotation);
      final size = _jpegSize(upright);
      final turned = (_lastSensor + settings.rotation) % 180 == 90;
      final landscape = size.$1 >= size.$2;
      stillW = turned == landscape ? size.$2 : size.$1;
      stillH = turned == landscape ? size.$1 : size.$2;
      log('photo ${stillW}x$stillH ${upright.length ~/ 1024} KB in ${sw.elapsedMilliseconds} ms');
      return upright;
    } catch (e) {
      _photoBusy = false;
      rethrow;
    }
  }

  int _lastSensor = 90;

  /// Returns as soon as the picture exists. The stream camera is restored in the background.
  Future<Uint8List> _capture() async {
    _lastSensor = _sensor;
    if (!settings.fullResStill) {
      final c = controller;
      if (c == null || !c.value.isInitialized) throw StateError('Camera is not running');
      try {
        return await (await c.takePicture()).readAsBytes();
      } finally {
        _photoBusy = false;
      }
    }
    await _close();
    await _open(ResolutionPreset.max, stream: false);
    Uint8List? bytes;
    String? failure;
    try {
      final shot = await controller?.takePicture();
      bytes = await shot?.readAsBytes();
    } catch (e) {
      failure = e.toString();
    }
    final reason = failure ?? error ?? 'Camera is not running';
    _close().then((_) => _open(_streamPreset)).whenComplete(() => _photoBusy = false);
    if (bytes == null) throw StateError(reason);
    return bytes;
  }

  (int, int) _jpegSize(Uint8List b) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xFF) {
        i++;
        continue;
      }
      final m = b[i + 1];
      if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) {
        return ((b[i + 7] << 8) | b[i + 8], (b[i + 5] << 8) | b[i + 6]);
      }
      i += 2 + ((b[i + 2] << 8) | b[i + 3]);
    }
    return (0, 0);
  }

  @override
  Future<void> dispose() async {
    await _close();
    await _frames.close();
    super.dispose();
  }
}
