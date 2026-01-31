# Guardrails (Signs)

> Lessons learned from failures. Read before acting.

## Core Signs

### Sign: Read Before Writing
- **Trigger**: Before modifying any file
- **Instruction**: Read the file first
- **Added after**: Core principle

### Sign: Test Before Commit
- **Trigger**: Before committing changes
- **Instruction**: Run required tests and verify outputs
- **Added after**: Core principle

---

## Learned Signs

### Sign: Document Known Flutter Analyze Failures
- **Trigger**: When `flutter analyze` or `./scripts/flutter_analyze.sh` fails on third_party/flutter_quic build_tool imports
- **Instruction**: Record the failure as a known external dependency issue and proceed without attempting to fix unrelated third_party tooling
- **Added after**: Iteration 2 - flutter analyze repeatedly failed due to missing build_tool dependencies
