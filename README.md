# Egg System Flutter Scaffold

This folder contains a Flutter Material scaffold that mirrors the current Egg System web app routing and module layout using only local sample data.

## Included Files

- `lib/main.dart`
- `lib/app_state.dart`
- `lib/app_router.dart`
- `lib/flutter_conversion.dart`

## Route Map

Primary routes:

- `/auth`
- `/dashboard`
- `/production`
- `/grading`
- `/inventory`
- `/reports`
- `/profile`
- `*` -> local not found page

Legacy redirects:

- `/` -> `/dashboard`
- `/quality-control` -> `/grading`
- `/collection` -> `/production`
- `/sales` -> `/inventory`
- `/losses` -> `/grading`
- `/notifications` -> `/dashboard`
- `/audit` -> `/reports`
- `/security` -> `/profile`

## Behavior

- Uses Flutter `material.dart` only.
- Keeps all data in memory with demo admin and worker sign-in flows.
- Restricts `inventory` and `reports` to admin users.
- Redirects unauthenticated users to `/auth`.

## Next Step

If you want to run this scaffold as a full Flutter app, create or connect it to a Flutter project root and keep these files under `lib/`.
