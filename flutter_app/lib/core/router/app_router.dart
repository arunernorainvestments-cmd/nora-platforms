import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/screens/forgot_password_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/referral_screen.dart';
import '../../features/auth/screens/signup_screen.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/discover/screens/discover_screen.dart';
import '../../features/markets/screens/markets_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/profile/screens/public_profile_screen.dart';
import '../../features/profile/providers/platform_connection_providers.dart';
import '../../features/wallet/screens/wallet_screen.dart';
import '../shell/main_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/home',
    redirect: (context, state) {
      final isLoggedIn = authState.value?.session != null;
      final loc = state.matchedLocation;

      // Only these routes require authentication
      const protectedRoutes = ['/markets', '/profile', '/wallet'];
      final isProtected = protectedRoutes.contains(loc);

      // Logged-out user hits a protected route → login with ?next= for return
      if (!isLoggedIn && isProtected) {
        return '/login?next=${Uri.encodeComponent(loc)}';
      }

      // Logged-in user hits an auth page → go home (or ?next= destination)
      if (isLoggedIn &&
          (loc == '/login' ||
              loc == '/signup' ||
              loc == '/forgot-password')) {
        final next = state.uri.queryParameters['next'];
        if (next != null && next.isNotEmpty) return next;
        return '/home';
      }

      return null;
    },
    routes: [
      // ── Auth routes ───────────────────────────────────────────────────────
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginScreen(),
      ),
      GoRoute(
        path: '/signup',
        builder: (context, state) => const SignupScreen(),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),

      // ── Public routes (no bottom nav) ─────────────────────────────────────
      GoRoute(
        path: '/join',
        builder: (context, state) => ReferralScreen(
          refParam: state.uri.queryParameters['ref'],
        ),
      ),
      GoRoute(
        path: '/u/:username',
        builder: (context, state) => PublicProfileScreen(
          username: state.pathParameters['username']!,
        ),
      ),

      // ── Authenticated shell routes ─────────────────────────────────────────
      ShellRoute(
        builder: (context, state, child) => MainShell(child: child),
        routes: [
          GoRoute(
            path: '/home',
            builder: (context, state) => const HomeScreen(),
          ),
          GoRoute(
            path: '/discover',
            builder: (context, state) => const DiscoverScreen(),
          ),
          GoRoute(
            path: '/markets',
            builder: (context, state) => const MarketsScreen(),
          ),
          GoRoute(
            path: '/profile',
            redirect: (context, state) {
              final connected = state.uri.queryParameters['connected'];
              if (connected != null) {
                ref.invalidate(platformConnectionsProvider);
              }
              return null;
            },
            builder: (context, state) => ProfileScreen(
              connectedPlatform: state.uri.queryParameters['connected'],
            ),
          ),
          GoRoute(
            path: '/wallet',
            builder: (context, state) => const WalletScreen(),
          ),
        ],
      ),
    ],
  );
});
