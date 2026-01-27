# AGENTS

## Verification
- `cd mobile && flutter test`
- `cd mobile && flutter analyze`
- `./scripts/flutter_test.sh`
- `./scripts/flutter_analyze.sh`
## Browser UI Check
- `cd mobile && flutter build web`
- `cd mobile/build/web && python3 -m http.server 8030 --bind 127.0.0.1`
