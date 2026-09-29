import 'dart:async';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'camera_service.dart';
import 'http_server.dart';
import 'settings.dart';

const blue = Color(0xFF2460E7);
const navy = Color(0xFF030A2E);
const sun = Color(0xFFFFD23F);
const pink = Color(0xFFFF5FA2);

@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveHandler());
}

class _KeepAliveHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp, bool isTimeout) async {}
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  FlutterForegroundTask.init(
    androidNotificationOptions: AndroidNotificationOptions(
      channelId: 'afaq_camera',
      channelName: 'AFAQ camera',
      channelDescription: 'Shown while the camera server is running.',
      onlyAlertOnce: true,
    ),
    iosNotificationOptions: const IOSNotificationOptions(),
    foregroundTaskOptions: ForegroundTaskOptions(
      eventAction: ForegroundTaskEventAction.nothing(),
      allowWakeLock: true,
      allowWifiLock: true,
    ),
  );
  runApp(const BoothCameraApp());
}

class BoothCameraApp extends StatelessWidget {
  const BoothCameraApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AFAQ Booth Camera',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: blue, brightness: Brightness.dark, surface: navy),
        scaffoldBackgroundColor: navy,
        fontFamily: 'sans-serif',
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  CameraService? _cam;
  CameraServer? _server;
  Timer? _ipTimer;
  String? _ip;
  bool _denied = false;
  bool _loading = true;
  String? _serverError;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
    _ipTimer = Timer.periodic(const Duration(seconds: 5), (_) => _refreshIp());
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _denied = false;
    });
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _denied = true;
        _loading = false;
      });
      return;
    }
    WakelockPlus.enable();
    final settings = await Settings.load();
    final cam = _cam ?? CameraService(settings);
    _cam = cam;
    await cam.start();
    final server = _server ?? CameraServer(cam);
    _server = server;
    try {
      await server.start();
      _serverError = null;
    } catch (e) {
      _serverError = 'Could not start the server: $e';
    }
    await _syncService();
    await _refreshIp();
    setState(() => _loading = false);
  }

  Future<void> _syncService() async {
    final cam = _cam;
    if (cam == null) return;
    final running = await FlutterForegroundTask.isRunningService;
    if (cam.settings.background && !running) {
      await FlutterForegroundTask.requestNotificationPermission();
      await FlutterForegroundTask.startService(
        serviceId: 256,
        serviceTypes: [ForegroundServiceTypes.camera],
        notificationTitle: 'AFAQ camera is running',
        notificationText: 'Serving the booth camera on port $serverPort',
        callback: startCallback,
      );
    } else if (!cam.settings.background && running) {
      await FlutterForegroundTask.stopService();
    }
  }

  Future<void> _refreshIp() async {
    String? found;
    try {
      final ifaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
      for (final i in ifaces) {
        for (final a in i.addresses) {
          final ip = a.address;
          final private = ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);
          if (!private) continue;
          final mobile = i.name.startsWith('rmnet') || i.name.startsWith('ccmni');
          if (mobile) continue;
          found ??= ip;
          if (i.name.startsWith('wlan')) found = ip;
        }
      }
    } catch (_) {}
    if (mounted && found != _ip) setState(() => _ip = found);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final cam = _cam;
    if (state == AppLifecycleState.resumed && cam != null && !cam.running && !_denied) {
      cam.restart();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ipTimer?.cancel();
    _server?.stop();
    _cam?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cam = _cam;
    return Scaffold(
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _denied || cam == null
                ? _PermissionView(onRetry: _boot)
                : ListenableBuilder(
                    listenable: cam,
                    builder: (context, _) => _Main(
                      cam: cam,
                      server: _server!,
                      ip: _ip,
                      serverError: _serverError,
                      onRetry: _boot,
                      onServiceChange: _syncService,
                    ),
                  ),
      ),
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView({required this.onRetry});
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Camera access needed', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            const Text(
              'This app turns the phone into the photo booth camera. It only sends pictures to the booth on your own network.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            _ChunkyButton(label: 'Try again', color: sun, onTap: onRetry),
            const SizedBox(height: 12),
            TextButton(onPressed: openAppSettings, child: const Text('Open phone settings')),
          ],
        ),
      ),
    );
  }
}

class _Main extends StatelessWidget {
  const _Main({
    required this.cam,
    required this.server,
    required this.ip,
    required this.serverError,
    required this.onRetry,
    required this.onServiceChange,
  });

  final CameraService cam;
  final CameraServer server;
  final String? ip;
  final String? serverError;
  final VoidCallback onRetry;
  final Future<void> Function() onServiceChange;

  @override
  Widget build(BuildContext context) {
    final s = cam.settings;
    final address = ip == null ? null : 'http://$ip:$serverPort';
    final controller = cam.controller;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('AFAQ Booth Camera', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: sun)),
        const SizedBox(height: 12),
        _Card(
          child: SizedBox(
            height: 200,
            child: cam.error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(cam.error!, textAlign: TextAlign.center),
                        const SizedBox(height: 10),
                        _ChunkyButton(label: 'Try again', color: sun, onTap: onRetry),
                      ],
                    ),
                  )
                : controller != null && controller.value.isInitialized
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Center(child: CameraPreview(controller)),
                      )
                    : const Center(child: CircularProgressIndicator()),
          ),
        ),
        const SizedBox(height: 12),
        _Card(
          color: blue,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.circle, size: 14, color: server.running ? Colors.greenAccent : pink),
                  const SizedBox(width: 8),
                  Text(server.running ? 'Running' : 'Stopped', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${cam.viewers} viewer${cam.viewers == 1 ? '' : 's'}'
                      '${cam.viewers > 0 ? ' · ${cam.fps.toStringAsFixed(1)} fps' : ''}'),
                ],
              ),
              const SizedBox(height: 12),
              if (address != null) ...[
                const Text('Type this address into the booth:'),
                const SizedBox(height: 4),
                SelectableText(address, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: sun)),
                const SizedBox(height: 8),
                _ChunkyButton(
                  label: 'Copy',
                  color: sun,
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: address));
                    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Address copied')));
                  },
                ),
              ] else
                const Text(
                  'Not connected to Wi-Fi.\nConnect to the booth Wi-Fi, or turn on this phone\'s hotspot and connect the booth PC to it.',
                  style: TextStyle(fontWeight: FontWeight.w600),
                ),
              if (serverError != null) ...[
                const SizedBox(height: 8),
                Text(serverError!, style: const TextStyle(color: sun)),
              ],
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Card(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: _ChunkyButton(
                      label: s.lens == 'back' ? 'Use front camera' : 'Use back camera',
                      color: pink,
                      onTap: () => cam.setLens(s.lens == 'back' ? 'front' : 'back'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _ChunkyButton(
                      label: s.torch ? 'Torch off' : 'Torch on',
                      color: sun,
                      onTap: () => cam.setTorch(!s.torch),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const Text('Stream quality'),
                  const Spacer(),
                  DropdownButton<int>(
                    value: s.preset,
                    items: [
                      for (var i = 0; i < streamPresets.length; i++)
                        DropdownMenuItem(value: i, child: Text(streamPresets[i].label)),
                    ],
                    onChanged: (v) {
                      s.preset = v ?? s.preset;
                      cam.updateSettings();
                    },
                  ),
                ],
              ),
              Row(
                children: [
                  Text('Rotation: ${s.rotation} degrees'),
                  const Spacer(),
                  _ChunkyButton(
                    label: 'Rotate 90 degrees',
                    color: Colors.white,
                    onTap: () {
                      s.rotation = (s.rotation + 90) % 360;
                      cam.updateSettings();
                    },
                  ),
                ],
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Full-size photos (slower)'),
                subtitle: const Text('Off: instant photo at stream size. On: about 12 MP, but the picture freezes for a moment'),
                value: s.fullResStill,
                onChanged: (v) {
                  s.fullResStill = v;
                  cam.updateSettings();
                },
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Keep server running in background'),
                value: s.background,
                onChanged: (v) async {
                  s.background = v;
                  await cam.updateSettings();
                  await onServiceChange();
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              builder: (_) => _LogSheet(cam: cam),
            ),
            child: const Text('Logs'),
          ),
        ),
      ],
    );
  }
}

class _LogSheet extends StatelessWidget {
  const _LogSheet({required this.cam});
  final CameraService cam;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<String>>(
      valueListenable: cam.logs,
      builder: (context, lines, _) => ListView(
        padding: const EdgeInsets.all(12),
        reverse: true,
        children: [
          for (final l in lines.reversed)
            Text(l, style: const TextStyle(fontFamily: 'monospace', fontSize: 12)),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child, this.color});
  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color ?? Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white, width: 2),
      ),
      child: child,
    );
  }
}

class _ChunkyButton extends StatelessWidget {
  const _ChunkyButton({required this.label, required this.color, required this.onTap});
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: color,
        foregroundColor: navy,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: navy, width: 2),
        ),
        textStyle: const TextStyle(fontWeight: FontWeight.w800),
      ),
      child: Text(label, textAlign: TextAlign.center),
    );
  }
}
