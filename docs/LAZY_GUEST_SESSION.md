# Lazy guest session (Family Space)

Same pattern as Remont (`remont_ai_front/docs/LAZY_GUEST_SESSION.md`).

## Behaviour

1. Cold start, no JWT → `localAnonymousStatus()` (`user_id == 0`). Onboarding opens. No `POST auth/guest`.
2. First onboarding write → `ensureMaterializedSession` → `auth/guest` (+ device bind), then the write.
3. Returning device with prior guest → `auth/device-auth` still restores without creating a new user.

## Key files

| Area | Location |
|------|----------|
| Sentinel status | `lib/features/auth/session/local_anonymous.dart` |
| Materialize + mutex | `lib/features/auth/session/session_materialize.dart` |
| UI helper | `lib/features/auth/session/ensure_remote_session_for_write.dart` |
| Bootstrap | `lib/app/bootstrap_screen.dart` |
| Write hooks | `lib/features/onboarding/presentation/onboarding_screen.dart` |
