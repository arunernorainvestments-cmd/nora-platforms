import 'package:go_router/go_router.dart';

import 'features/character_select/screens/character_select_screen.dart';
import 'features/license_sync/screens/license_sync_screen.dart';

/// App routes. Auth + battle/arena/profile routes are added in later phases
/// (doc6 migration checklist). Character select is the V1 entry while the
/// import flow is the focus.
final appRouter = GoRouter(
  initialLocation: '/characters',
  routes: [
    GoRoute(
      path: '/characters',
      builder: (_, __) => const CharacterSelectScreen(),
    ),
    GoRoute(
      path: '/license-sync',
      builder: (_, __) => const LicenseSyncScreen(),
    ),
  ],
);
