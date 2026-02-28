## Summary

- What changed?
- Why is this needed?

## Validation

- [ ] `cd mobile && flutter test`
- [ ] `cd mobile && flutter analyze`
- [ ] `./scripts/flutter_test.sh`
- [ ] `./scripts/flutter_analyze.sh`
- [ ] `./scripts/security_scan.sh`

## UI / UX Checklist

- [ ] No visible layout overflow or misalignment on primary screens.
- [ ] Buttons and menus are clickable and trigger expected actions.
- [ ] In fullscreen + landscape mode, keyboard/controls remain usable.
- [ ] New/changed labels are clear and not truncated.

## Functional Checklist

- [ ] Critical path is verified end-to-end (pairing, command, session flow).
- [ ] Error states are handled (network/auth/invalid payload).
- [ ] Backward compatibility considered for existing clients.

## Security Checklist

- [ ] No keys/passwords/tokens/certs committed.
- [ ] Examples use placeholders only (`<AUTH_TOKEN>`, `<SESSION_ID>`, etc.).
- [ ] New endpoints/commands include auth and input validation.

## Notes

- Risk/rollback notes, if any.
