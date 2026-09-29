import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'camera_service.dart';

const serverPort = 8080;

class CameraServer {
  CameraServer(this.camera);

  final CameraService camera;
  HttpServer? _server;
  final _clients = <_StreamClient>{};

  bool get running => _server != null;

  Future<void> start() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.anyIPv4, serverPort, shared: true);
    camera.log('server listening on $serverPort');
    _server!.listen(_handle, onError: (Object e) => camera.log('server error: $e'));
    camera.frames.listen(_broadcast);
  }

  Future<void> stop() async {
    for (final c in _clients.toList()) {
      c.close();
    }
    _clients.clear();
    camera.viewersChanged(0);
    await _server?.close(force: true);
    _server = null;
  }

  void _broadcast(Uint8List jpeg) {
    for (final c in _clients.toList()) {
      c.send(jpeg);
    }
  }

  Map<String, Object?> health() => {
        'ok': camera.running,
        'camera': camera.settings.lens,
        'width': camera.streamW,
        'height': camera.streamH,
        'stillWidth': camera.stillW,
        'stillHeight': camera.stillH,
      };

  void _cors(HttpResponse r) {
    r.headers
      ..set('Access-Control-Allow-Origin', '*')
      ..set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
      ..set('Access-Control-Allow-Headers', 'Content-Type');
  }

  Future<void> _json(HttpResponse r, int status, Object body) async {
    _cors(r);
    r.statusCode = status;
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(body));
    await r.close();
  }

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    final path = req.uri.path;
    if (path != '/stream') camera.log('${req.method} $path');
    try {
      if (req.method == 'OPTIONS') {
        _cors(res);
        res.statusCode = 204;
        await res.close();
      } else if (req.method == 'GET' && path == '/health') {
        await _json(res, 200, health());
      } else if (req.method == 'GET' && path == '/stream') {
        _stream(req);
      } else if (req.method == 'GET' && path == '/photo') {
        await _photo(res);
      } else if (req.method == 'POST' && path == '/camera') {
        final body = await _readJson(req);
        final lens = body['lens'];
        if (lens != 'front' && lens != 'back') {
          await _json(res, 400, {'ok': false, 'error': 'lens must be front or back'});
        } else {
          await camera.setLens(lens as String);
          await _json(res, 200, health());
        }
      } else if (req.method == 'POST' && path == '/torch') {
        final body = await _readJson(req);
        await camera.setTorch(body['on'] == true);
        await _json(res, 200, {'ok': true});
      } else {
        await _json(res, 404, {'ok': false, 'error': 'not found'});
      }
    } catch (e) {
      camera.log('error $path: $e');
      try {
        await _json(res, 500, {'ok': false, 'error': e.toString()});
      } catch (_) {}
    }
  }

  Future<Map<String, dynamic>> _readJson(HttpRequest req) async {
    final text = await utf8.decoder.bind(req).join();
    if (text.isEmpty) return {};
    final v = jsonDecode(text);
    return v is Map<String, dynamic> ? v : {};
  }

  Future<void> _photo(HttpResponse res) async {
    try {
      final jpeg = await camera.takePhoto();
      _cors(res);
      res.headers
        ..contentType = ContentType('image', 'jpeg')
        ..set('Cache-Control', 'no-store')
        ..contentLength = jpeg.length;
      res.add(jpeg);
      await res.close();
    } on BusyException {
      _cors(res);
      res.headers.set('Retry-After', '1');
      await _json(res, 503, {'ok': false, 'error': 'busy'});
    }
  }

  void _stream(HttpRequest req) {
    final res = req.response;
    _cors(res);
    res.statusCode = 200;
    res.bufferOutput = false;
    res.headers
      ..set('Content-Type', 'multipart/x-mixed-replace; boundary=frame')
      ..set('Cache-Control', 'no-store');
    late final _StreamClient c;
    c = _StreamClient(res, () {
      _clients.remove(c);
      camera.viewersChanged(_clients.length);
      camera.log('viewer left (${_clients.length})');
    });
    _clients.add(c);
    camera.viewersChanged(_clients.length);
    camera.log('viewer joined (${_clients.length})');
  }
}

class _StreamClient {
  _StreamClient(this.res, this.onDone) {
    res.done.then((_) => _finish()).catchError((_) => _finish());
  }

  final HttpResponse res;
  final void Function() onDone;
  bool _busy = false;
  bool _closed = false;

  void _finish() {
    if (_closed) return;
    _closed = true;
    onDone();
  }

  void send(Uint8List jpeg) {
    if (_busy || _closed) return;
    _busy = true;
    try {
      res.add(utf8.encode(
        '--frame\r\nContent-Type: image/jpeg\r\nContent-Length: ${jpeg.length}\r\n\r\n',
      ));
      res.add(jpeg);
      res.add(const [13, 10]);
      res.flush().then((_) {
        _busy = false;
      }).catchError((_) {
        _busy = false;
        _finish();
      });
    } catch (_) {
      _busy = false;
      _finish();
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    res.close().catchError((_) {});
  }
}
