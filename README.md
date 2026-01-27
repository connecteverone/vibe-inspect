# Vibe Inspect

## Project Structure
- `mobile/`: Flutter mobile client scaffold
- `desktop/`: Rust/Tauri desktop agent scaffold
- `scripts/`: helper scripts for Flutter verification

## Dependency Installs
### Flutter (mobile)
- `flutter pub add collection`
- `flutter pub add cupertino_icons`
- `flutter pub get`

### Rust/Tauri (desktop)
- `cargo add tauri`
- `cargo add tauri-build --build`

## Verification
- `./scripts/flutter_test.sh`
- `./scripts/flutter_analyze.sh`

## Negative Case (Analyze)
If `collection` is removed from `mobile/pubspec.yaml`, `flutter analyze` fails with
`Target of URI doesn't exist: 'package:collection/collection.dart'.`
