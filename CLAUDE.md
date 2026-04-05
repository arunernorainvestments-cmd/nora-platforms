# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

N.O.R.A. Platforms is a Flutter web application for a prediction market platform based on creator popularity metrics. The backend is Supabase (PostgreSQL + Auth).

## Commands

All Flutter commands run from the `flutter_app/` directory:

```bash
# Install dependencies
cd flutter_app && flutter pub get

# Run code generation (Riverpod providers, etc.)
cd flutter_app && flutter pub run build_runner build

# Watch mode for code generation
cd flutter_app && flutter pub run build_runner watch --delete-conflicting-outputs

# Lint
cd flutter_app && flutter analyze

# Run tests
cd flutter_app && flutter test

# Run a single test file
cd flutter_app && flutter test test/path/to/test_file.dart

# Build for web (production)
cd flutter_app && flutter build web --release --no-tree-shake-icons
```

## Environment Setup

Copy `.env.example` to `.env` in `flutter_app/` and fill in values:
```
SUPABASE_URL=...
SUPABASE_ANON_KEY=...
```

The `.env` file is loaded as an asset at runtime via `flutter_dotenv`.

## Architecture

**State management**: Riverpod with code generation. Providers use `@riverpod` annotations; run `build_runner` after changing them.

**Routing**: GoRouter (`lib/core/router/app_router.dart`). Unauthenticated users redirect to `/login`; authenticated users land on `/home`. The main shell (`lib/core/shell/main_shell.dart`) wraps authenticated routes with a bottom nav bar.

**Feature structure**: Each feature lives in `lib/features/<name>/` with subdirectories for `screens/`, `widgets/`, and `providers/`. Features currently implemented: `auth`, `home`, `profile`. Stubs exist for `discover` (Phase 3), `wallet`/Stripe (Phase 4), and `markets` (Phase 5).

**Supabase schema** (`supabase/migrations/001_initial_schema.sql`): tables are `profiles`, `social_connections`, `metrics_history`, `markets`, `bets`, `balances`, `transactions`. All have RLS enabled. A trigger auto-creates a profile + balance row on signup.

## Deployment

Push to `main` triggers the GitHub Actions workflow (`.github/workflows/deploy.yml`), which builds the Flutter web app and deploys to Vercel. The `vercel.json` at the repo root rewrites all paths to `/index.html` for SPA routing.

Required GitHub secrets: `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`.

## Deferred Features (Build Later)

### Profile Picture
- Profile pictures should be pulled automatically from the first social media account a user connects (Phase 3)
- No manual profile picture upload should ever be added — avatar always comes from connected social accounts
- Until a social account is connected, show the first letter of username as avatar (current behavior is correct)
- When social connection is built in Phase 3, update profile_providers.dart to pull avatar_url from the connected platform and save it to profiles.avatar_url
