# Vibe Inspect

## Project Structure
- `mobile/`: Flutter mobile client scaffold
- `desktop/`: Rust/Tauri desktop agent scaffold
- `scripts/`: helper scripts for Flutter verification

## Dependency Installs
### Flutter (mobile)
- `flutter pub add collection`
- `flutter pub add cupertino_icons`
- `flutter pub add sqflite`
- `flutter pub add flutter_secure_storage`
- `flutter pub get`
Local timeline history uses SQLite with a secure key stored in the device keychain.

### Rust/Tauri (desktop)
- `cargo add tauri`
- `cargo add tauri-build --build`

## Verification
- `./scripts/flutter_test.sh`
- `./scripts/flutter_analyze.sh`

## Negative Case (Analyze)
If `collection` is removed from `mobile/pubspec.yaml`, `flutter analyze` fails with
`Target of URI doesn't exist: 'package:collection/collection.dart'.`
