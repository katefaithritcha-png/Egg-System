# Live Inspection Backend

This backend receives live egg inspection results from a model inference client and exposes them to the Flutter app. It also hosts the authentication API.

## Run

Full inspection + auth:

```bash
python backend/live_inspection_backend.py
```

Auth only (no TensorFlow / camera stack):

```bash
python backend/auth_server.py
```

Copy `backend/.env.example` to `backend/.env` and set seed passwords plus SMTP if you have it. Seed passwords never ship in the Flutter client. If they are omitted, random passwords are generated on first boot and written only to `backend/data/bootstrap_credentials.txt` and the server log.

**Storage:** Farm auth, sessions, and the farm ledger (production / grading / inventory / sales) are saved in **Firebase Firestore** (`farm_users`, `farm_sessions`, `farm_email_tokens`, `farm_shared`). Egg inspection history stays in `egg_readings`. Set `FIREBASE_PROJECT_ID` and `FIREBASE_WEB_API_KEY` in `.env`, then deploy `backend/firestore.rules`. On first boot, existing `data/auth.sqlite` (if present) is migrated once into Firestore. Without Firebase env vars, the auth API uses in-memory storage (tests / local dry-run only).

Without SMTP, verification and reset emails are written to `backend/data/outbox/`.

## Auth endpoints

- `POST /auth/signup` - create a worker account and send an email verification link
- `POST /auth/login` - verify credentials and issue an expiring session
- `POST /auth/logout` - revoke the current session
- `GET /auth/me` - return the current user if the session is valid
- `POST /auth/verify-email` / `GET /auth/verify-email?token=` - confirm email
- `POST /auth/resend-verification` - send a new verification link
- `POST /auth/forgot-password` - send an expiring reset link
- `POST /auth/reset-password` - consume a reset token and set a new password
- `POST /auth/change-password` - change password for the signed-in user

## Inspection endpoints

- `GET /metrics` - returns the latest egg counts and status
- `POST /report` - accepts JSON payloads from the inference client
- `GET /recent` - returns the recent inference results
