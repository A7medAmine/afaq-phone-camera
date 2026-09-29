# AFAQ Booth Camera

Flutter app that turns an Android phone into the network camera for the AFAQ photo booth. It serves HTTP on port 8080 and shows the address to type into the booth.

## Build and run

```
flutter pub get
flutter run                     # phone plugged in with USB debugging
flutter build apk --release     # build\app\outputs\flutter-apk\app-release.apk
adb install -r build\app\outputs\flutter-apk\app-release.apk
```

Notes for this machine: the project lives on `X:` while the pub cache is on `C:`, so `android/gradle.properties` sets `kotlin.incremental=false`. Do not remove it or the Kotlin build fails.

## HTTP contract

All responses carry `Access-Control-Allow-Origin: *`.

- `GET /health` returns `{"ok":true,"camera":"back","width":1280,"height":720,"stillWidth":4032,"stillHeight":3024}`. `stillWidth` and `stillHeight` are 0 until the first photo has been taken.
- `GET /stream` returns MJPEG (`multipart/x-mixed-replace; boundary=frame`). Frames are dropped for slow clients. No frames are converted when nobody is watching.
- `GET /photo` returns one full-size upright JPEG. Concurrent requests get `503` with `Retry-After: 1`.
- `POST /camera` with `{"lens":"front"|"back"}`, `POST /torch` with `{"on":true}`.

## Test with curl

```
curl http://PHONE_IP:8080/health
curl -o test.jpg http://PHONE_IP:8080/photo
curl -X POST -H "Content-Type: application/json" -d "{\"on\":true}" http://PHONE_IP:8080/torch
```

Open `http://PHONE_IP:8080/stream` in a desktop browser for the live preview.

## How it works and limits

- The `camera` plugin (CameraX) uses one resolution for preview, stills and frames. The stream always runs at 1280x720 and is downscaled to the chosen preset while converting to JPEG (in a worker isolate).
- By default `/photo` comes from the running camera at the stream resolution (1080p on High) and is instant, with no stream freeze. With "Full-size photos" on, the app closes the camera, reopens it at maximum resolution, takes the picture, then restores the stream in the background. That gives about 12 MP but freezes the stream for a moment.
- Orientation: the app is locked to portrait. Frames and photos are rotated by the camera sensor angle. If the phone is mounted in landscape, press "Rotate 90 degrees" until the picture is upright.
- The camera stops if the app goes to the background or the screen turns off. Keep the app open in front. The screen is kept awake while the app is open. The foreground service and its notification keep the process alive but cannot keep CameraX open in the background.
- Pictures are never mirrored by the phone. The booth applies mirroring.

## Connection options

- Phone hotspot with the booth PC connected to it (recommended). The phone address stays the same, usually `http://192.168.43.1:8080` or similar. Check the address the app shows.
- Same venue Wi-Fi. Works, but venue networks often block device-to-device traffic.
- Booth PC hotspot with the phone connected to it.
- USB: `adb forward tcp:8080 tcp:8080` (see `docs/event-setup.md` in the booth repo). The booth then uses `http://localhost:8080`.

## Status

`flutter analyze` is clean and the release APK builds. Not yet verified on real hardware: camera, frame rate, photo time, orientation, heat and background behaviour.
