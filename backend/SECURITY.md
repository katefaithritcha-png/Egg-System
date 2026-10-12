# SMARTSORT authentication setup

Passwords are handled by Firebase Authentication. The Flutter app does not hash passwords and does not write passwords, hashes, or ID tokens to Cloud Firestore.

## 1. Enable Firebase Authentication

1. Open the Firebase console for project `egg-system-c36f5`.
2. Authentication > Sign-in method > enable Email/Password.
3. Authentication > Settings > enable email enumeration protection if it is available.

## 2. Create the administrator

Do this in the Firebase console, not in the app. The app cannot grant administrator access.

1. Authentication > Users > Add user with the administrator email.
2. Mark that user's email as verified.
3. Firestore > `users` > add a document whose ID is that user's UID:

```
email: the same email
name: administrator name
role: admin
assignedZone: Operations HQ
createdAt: timestamp
```

Do not add `password`, `passwordHash`, or `token`.

Workers sign up in the app. Their profile is created with `role: worker`. Firestore rules reject a self-assigned `admin` role.

## 3. Publish Firestore rules

From the project root, after installing the Firebase CLI and logging in:

```
firebase deploy --only firestore:rules
```

Rules live in `backend/firestore.rules`. Unsigned requests are denied. Inventory and reports require `role == admin`. Users cannot change their own role.

## 4. What was tested locally

These checks do not call the live Firebase project:

- `flutter test test/smartsort_security_test.dart` checks generic login wording, secret-field rejection, and role-change policy.
- `python -m unittest test_firestore_security.py` checks that the rules file denies open access and that profile payloads omit passwords.

Live login, Firestore rejects, password reset, and email verification still need a run against the Firebase project after the rules are deployed. Until that run passes, do not treat the deployed project as verified.
