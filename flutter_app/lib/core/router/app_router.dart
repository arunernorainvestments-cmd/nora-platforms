import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/screens/forgot_password_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/referral_screen.dart';
import '../../features/auth/screens/signup_screen.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/challenges/screens/challenges_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/markets/screens/markets_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/profile/screens/public_profile_screen.dart';
import '../../features/profile/providers/platform_connection_providers.dart';
import '../../features/markets/screens/market_detail_screen.dart';
import '../../features/wallet/screens/wallet_screen.dart';
import '../../features/launch/screens/launch_screen.dart';
import '../../features/legal/screens/privacy_policy_screen.dart';
import '../../features/legal/screens/terms_of_service_screen.dart';
import '../../features/profile/screens/score_dashboard_screen.dart';
import '../shell/main_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/launch',
    redirect: (context, state) {
      final isLoggedIn = authState.value?.session != null;
      final loc = state.matchedLocation;

      // Logged-in user on the launch/auth pages → go home (or ?next= destination)
      if (isLoggedIn &&
          (loc == '/launch' ||
              loc == '/login' ||
              loc == '/signup' ||
              loc == '/forgot-password')) {
        final next = state.uri.queryParameters['next'];
        if (next != null && next.isNotEmpty) return next;
        return '/home';
      }

      // Only these routes require authentication
      const protectedRoutes = ['/markets', '/profile', '/wallet'];
      final isProtected = protectedRoutes.contains(loc);

      // Logged-out user hits a protected route → login with ?next= for return
      if (!isLoggedIn && isProtected) {
        return '/login?next=${Uri.encodeComponent(loc)}';
      }

      return null;
    },
    routes: [
      // ── Launch / pre-release cover ────────────────────────────────────────
      GoRoute(
        path: '/launch',
        builder: (context, state) => const LaunchScreen(),
      ),

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

      // ── Challenges screen (authenticated, no bottom nav) ──────────────────
      GoRoute(
        path: '/challenges',
        builder: (context, state) => const ChallengesScreen(),
      ),

      // ── Legal routes (public, no auth) ───────────────────────────────────
      GoRoute(
        path: '/privacy',
        builder: (context, state) => const PrivacyPolicyScreen(),
      ),
      GoRoute(
        path: '/terms',
        builder: (context, state) => const TermsOfServiceScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const ScoreDashboardScreen(),
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
      GoRoute(
        path: '/markets/:id',
        builder: (context, state) => MarketDetailScreen(
          marketId: state.pathParameters['id']!,
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
            path: '/search',
            builder: (context, state) => const SearchScreen(),
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
            builder: (context, state) => WalletScreen(
              purchaseResult: state.uri.queryParameters['purchase'],
            ),
          ),
        ],
      ),
    ],
  );
});
