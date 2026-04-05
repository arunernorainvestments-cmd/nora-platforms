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
import '../../features/wallet/screens/wallet_screen.dart';
import '../shell/main_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);

  return GoRouter(
    initialLocation: '/home',
    redirect: (context, state) {
      final isLoggedIn = authState.value?.session != null;
      final loc = state.matchedLocation;

      // Routes accessible without login
      final isPublicRoute = loc == '/login' ||
          loc == '/signup' ||
          loc == '/forgot-password' ||
          loc == '/join' ||
          loc.startsWith('/u/');

      if (!isLoggedIn && !isPublicRoute) return '/login';
      // Redirect logged-in users away from auth-only pages
      if (isLoggedIn &&
          (loc == '/login' ||
              loc == '/signup' ||
              loc == '/forgot-password')) {
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
            builder: (context, state) => const ProfileScreen(),
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
