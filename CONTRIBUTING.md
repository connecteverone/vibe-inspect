# Contributing

Thanks for contributing to Vibe Inspect.

## Ground Rules

- Keep changes scoped and reviewable.
- Prefer fixes with tests or reproducible validation steps.
- Avoid unrelated refactors in the same commit.
- Keep all examples/doc snippets sanitized (no real credentials).

## Setup

```bash
git clone https://github.com/connecteverone/vibe-inspect.git
cd vibe-inspect
git submodule update --init --recursive
cd mobile && flutter pub get
```

## Required Checks

Run these before opening a PR:

```bash
cd mobile && flutter test
cd mobile && flutter analyze
./scripts/flutter_test.sh
./scripts/flutter_analyze.sh
./scripts/security_scan.sh
```

Optional browser smoke check:

```bash
cd mobile && flutter build web
cd mobile/build/web && python3 -m http.server 8030 --bind 127.0.0.1
```

## Commit Guidance

- Use clear, conventional-style commit messages:
  - `feat(scope): ...`
  - `fix(scope): ...`
  - `docs(scope): ...`
  - `chore(scope): ...`
- Keep each commit focused on one logical change.

## Security Expectations

- Never commit API keys, private keys, passwords, or production tokens.
- Use placeholders like `<AUTH_TOKEN>` and `<SESSION_ID>` in docs/examples.
- Follow [`SECURITY.md`](SECURITY.md) for disclosure and reporting policy.

## iOS RustDesk FFI Guardrail

If you modify RustDesk iOS FFI symbols or linker flags, verify symbols are retained in release builds:

```bash
cd mobile && flutter build ios --release --no-codesign
cd mobile && nm -gU build/ios/iphoneos/Runner.app/Runner | rg "rustdesk_main_init|rustdesk_set_direct_only|rustdesk_session_add"
```

Reference:
- [`docs/remote_rustdesk_integration.md`](docs/remote_rustdesk_integration.md)
