# Security Policy

## Supported Scope

This repository contains:
- `mobile/` Flutter client
- `desktop/` Rust desktop agent
- `scripts/` local verification and benchmark scripts
- `third_party/rustdesk` as a git submodule

## Reporting a Vulnerability

If you discover a security issue, do not open a public issue with exploit details.

Please report privately to the maintainers first (repository owner on GitHub):
- https://github.com/connecteverone/vibe-inspect

Include:
- affected component and version/commit
- reproduction steps
- expected vs actual behavior
- impact assessment

## Secret Handling Rules

- Never commit API keys, passwords, private keys, or production tokens.
- Keep runtime credentials in local environment variables or secret managers.
- Files like `.env`, `GoogleService-Info.plist`, `google-services.json`, and certificate/key files are git-ignored by default.
- Commit only sanitized examples (`*.example.*`) when needed.

## Pre-Publish Checklist

Before opening source or tagging a release:
1. Run `./scripts/security_scan.sh`
2. Run `git grep -nE 'AIza|AKIA|ghp_|BEGIN .* PRIVATE KEY' -- .`
3. Confirm no local logs/artifacts are tracked (`git status --short`)
4. Verify CI checks pass (`flutter test`, `flutter analyze`)

## Notes

- `third_party/rustdesk` is maintained upstream as a submodule. Its history and files are not authored by this repository.
