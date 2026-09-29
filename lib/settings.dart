import 'package:shared_preferences/shared_preferences.dart';

class StreamPreset {
  const StreamPreset(this.label, this.level, this.quality);
  final String label;
  final int level;
  final int quality;
}

const streamPresets = [
  StreamPreset('Low 720x480', 0, 55),
  StreamPreset('Medium 1280x720', 1, 60),
  StreamPreset('High 1920x1080', 2, 70),
];

class Settings {
  Settings({
    this.lens = 'back',
    this.preset = 2,
    this.rotation = 0,
    this.torch = false,
    this.background = true,
    this.fullResStill = false,
  });

  String lens;
  int preset;
  int rotation;
  bool torch;
  bool background;
  bool fullResStill;

  static Future<Settings> load() async {
    final p = await SharedPreferences.getInstance();
    return Settings(
      lens: p.getString('lens') ?? 'back',
      preset: (p.getInt('preset') ?? 2).clamp(0, streamPresets.length - 1),
      rotation: p.getInt('rotation') ?? 0,
      torch: p.getBool('torch') ?? false,
      background: p.getBool('background') ?? true,
      fullResStill: p.getBool('fullStill') ?? false,
    );
  }

  Future<void> save() async {
    final p = await SharedPreferences.getInstance();
    await p.setString('lens', lens);
    await p.setInt('preset', preset);
    await p.setInt('rotation', rotation);
    await p.setBool('torch', torch);
    await p.setBool('background', background);
    await p.setBool('fullStill', fullResStill);
  }
}
