import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/auth/screens/forgot_password_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/auth/screens/pending_approval_screen.dart';
import '../../features/auth/screens/referral_screen.dart';
import '../../features/auth/screens/signup_screen.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/challenges/screens/challenges_screen.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/markets/screens/markets_screen.dart';
import '../../features/markets/screens/my_bets_screen.dart';
import '../../features/profile/screens/profile_screen.dart';
import '../../features/profile/screens/public_profile_screen.dart';
import '../../features/profile/providers/platform_connection_providers.dart';
import '../../features/markets/screens/market_detail_screen.dart';
import '../../features/wallet/screens/wallet_screen.dart';
import '../../features/launch/screens/launch_screen.dart';
import '../../features/explore/screens/celebrity_heat_screen.dart';
import '../../features/explore/screens/hot_topic_screen.dart';
import '../../features/legal/screens/privacy_policy_screen.dart';
import '../../features/legal/screens/terms_of_service_screen.dart';
import '../../features/profile/screens/score_dashboard_screen.dart';
import '../../features/arena/screens/arena_screen.dart';
import '../../features/arena/screens/arena_match_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/home/screens/plan_screen.dart';
import '../shell/main_shell.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final authState = ref.watch(authStateProvider);
  final approvalStatus = ref.watch(approvalStatusProvider);

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      // ── Do not redirect while auth session is being restored ─────────────
      // authStateProvider is a StreamProvider — its initial value is
      // AsyncValue.loading() until the first onAuthStateChange event fires.
      // Acting on that loading state would redirect every external deep-link
      // to /login even for users who are already signed in.
      if (authState.isLoading) return null;

      final isLoggedIn = authState.value?.session != null;
      final isApproved = approvalStatus.value; // null = loading or not logged in
      final loc = state.matchedLocation;

      // ── Beta gate: hard-block unapproved users ────────────────────────────
      if (isLoggedIn && isApproved == false && loc != '/pending-approval') {
        return '/pending-approval';
      }
      if (isLoggedIn && isApproved == true && loc == '/pending-approval') {
        return '/home';
      }

      // ── Logged-in user on auth/launch pages → intended destination or home ─
      if (isLoggedIn &&
          isApproved == true &&
          (loc == '/' ||
              loc == '/login' ||
              loc == '/signup' ||
              loc == '/forgot-password')) {
        // Prefer the Riverpod-stored destination (set before the /login redirect)
        // over the URL ?next= param — it survives GoRouter's async re-fire chain.
        final pending = ref.read(pendingNavigationProvider);
        if (pending != null) {
          ref.read(pendingNavigationProvider.notifier).state = null;
          return pending;
        }
        final next = state.uri.queryParameters['next'];
        if (next != null && next.isNotEmpty) return next;
        return '/home';
      }

      // ── Protected routes require authentication ───────────────────────────
      // /home, /news, /explore, /hot-topic are intentionally PUBLIC.
      const protectedRoutes = [
        '/markets', '/profile', '/wallet', '/mybets', '/arena',
      ];
      // /arena/:matchId sub-paths are also protected
      final isProtected = protectedRoutes.contains(loc) ||
          loc.startsWith('/arena/');
      if (!isLoggedIn && isProtected) {
        // Store destination in Riverpod — reliable across async redirect re-fires
        ref.read(pendingNavigationProvider.notifier).state = loc;
        return '/login?next=${Uri.encodeComponent(loc)}';
      }

      return null;
    },
    routes: [
      // ── Launch / pre-release cover ────────────────────────────────────────
      GoRoute(
        path: '/',
        builder: (context, state) => const LaunchScreen(),
      ),

      // ── Auth routes ───────────────────────────────────────────────────────
      GoRoute(
        path: '/pending-approval',
        builder: (context, state) => const PendingApprovalScreen(),
      ),
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

      // ── My Bets — standalone screen, no bottom nav ───────────────────────
      GoRoute(
        path: '/mybets',
        builder: (context, state) => const MyBetsScreen(),
      ),

      // ── Backwards-compat redirect: /markets/mybets → /mybets ─────────────
      GoRoute(
        path: '/markets/mybets',
        redirect: (context, state) => '/mybets',
      ),

      // ── News (celebrity heat) — canonical route, public ──────────────────
      GoRoute(
        path: '/news',
        builder: (context, state) => const CelebrityHeatScreen(),
      ),

      // ── /explore redirects to /news for backwards compat ─────────────────
      GoRoute(
        path: '/explore',
        redirect: (context, state) => '/news',
      ),

      // ── Hot Topic placeholder — public, no bottom nav ────────────────────
      GoRoute(
        path: '/hot-topic',
        builder: (context, state) => const HotTopicScreen(),
      ),

      // ── Roadmap / Phase 2 & 3 — public, no bottom nav ────────────────────
      GoRoute(
        path: '/plan',
        builder: (context, state) => const PlanScreen(),
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
          GoRoute(
            path: '/arena',
            builder: (context, state) => const ArenaScreen(),
          ),
          // /arena/:matchId — auth-required, inside ShellRoute for bottom nav.
          // Direct navigation (refresh at noraplatforms.com/arena/<uuid>) works
          // because Vercel's catch-all rewrite sends all paths to /index.html and
          // GoRouter parses the matchId parameter from the URL.
          GoRoute(
            path: '/arena/:matchId',
            builder: (context, state) => ArenaMatchScreen(
              matchId: state.pathParameters['matchId']!,
            ),
          ),
        ],
      ),
    ],
  );
});
