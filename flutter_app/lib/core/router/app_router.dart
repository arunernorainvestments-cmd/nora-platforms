import 'package:flutter/foundation.dart';
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
import '../../features/explore/screens/celebrity_profile_screen.dart';
import '../../features/hot_topic/screens/hot_topic_screen.dart';
import '../../features/legal/screens/privacy_policy_screen.dart';
import '../../features/legal/screens/terms_of_service_screen.dart';
import '../../features/profile/screens/score_dashboard_screen.dart';
import '../../features/arena/screens/arena_screen.dart';
import '../../features/arena/screens/arena_match_screen.dart';
import '../../features/battle/screens/battle_lobby_screen.dart';
import '../../features/battle/screens/battle_match_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/home/screens/plan_screen.dart';
import '../../features/campaigns/screens/campaigns_list_screen.dart';
import '../../features/campaigns/screens/campaign_detail_screen.dart';
import '../../features/campaigns/screens/campaign_create_screen.dart';
import '../../features/campaigns/screens/campaign_revenue_screen.dart';
import '../../features/campaigns/screens/campaign_earnings_screen.dart';
import '../../features/campaigns/screens/campaign_proposals_screen.dart';
import '../../features/campaigns/screens/campaign_proposal_detail_screen.dart';
import '../../features/campaigns/screens/campaign_proposal_create_screen.dart';
import '../../features/campaigns/screens/campaign_updates_screen.dart';
import '../../features/campaigns/providers/campaigns_providers.dart';
import '../../features/settings/screens/support_screen.dart';
import '../../features/settings/screens/faq_screen.dart';
import '../shell/main_shell.dart';

// Notifier that triggers GoRouter to re-evaluate its redirect without
// recreating the router instance. ref.listen (not ref.watch) is used so
// routerProvider itself never rebuilds on auth state changes — only the
// redirect callback is re-fired. This preserves the navigation stack on
// page refresh and prevents the "auth state change → new router → back to /"
// race condition.
class _RouterNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

final routerProvider = Provider<GoRouter>((ref) {
  final notifier = _RouterNotifier();
  ref.listen(authStateProvider, (_, __) => notifier.notify());
  ref.listen(approvalStatusProvider, (_, __) => notifier.notify());
  ref.onDispose(notifier.dispose);

  return GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    redirect: (context, state) {
      final authState = ref.read(authStateProvider);
      final approvalStatus = ref.read(approvalStatusProvider);

      // ── Do not redirect while auth session is being restored ─────────────
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
              loc.startsWith('/w/') ||
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
        '/markets', '/profile', '/wallet', '/mybets', '/arena', '/battle',
        '/campaigns',
      ];
      // sub-paths are also protected
      final isProtected = protectedRoutes.contains(loc) ||
          loc.startsWith('/arena/') ||
          loc.startsWith('/battle/') ||
          loc.startsWith('/campaigns/') ||
          loc.startsWith('/campaign/') ||
          loc == '/campaigns/earnings';
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

      // ── Viral waitlist deep-link (/w/:token) ──────────────────────────────
      // Public route. Logged-in + approved users are redirected to /home above.
      // Unauthenticated visitors see the waitlist Returning state for that token.
      GoRoute(
        path: '/w/:token',
        builder: (context, state) => LaunchScreen(
          referralToken: state.pathParameters['token'],
        ),
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
        routes: [
          GoRoute(
            path: ':celebId',
            builder: (context, state) => CelebrityProfileScreen(
              celebId: state.pathParameters['celebId']!,
            ),
          ),
        ],
      ),

      // ── /explore redirects to /news for backwards compat ─────────────────
      GoRoute(
        path: '/explore',
        redirect: (context, state) => '/news',
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

      // ── Help & settings routes (public, no auth) ──────────────────────────
      GoRoute(
        path: '/support',
        builder: (context, state) => const SupportScreen(),
      ),
      GoRoute(
        path: '/faq',
        builder: (context, state) => const FaqScreen(),
      ),
      GoRoute(
        path: '/dashboard',
        builder: (context, state) => const ScoreDashboardScreen(),
      ),

      // ── Campaign detail — public read, auth required to invest ───────────
      GoRoute(
        path: '/campaign/:id',
        builder: (context, state) => CampaignDetailScreen(
          campaignId: state.pathParameters['id']!,
        ),
      ),

      // ── Campaign create — auth required, no bottom nav ────────────────────
      GoRoute(
        path: '/campaigns/new',
        builder: (context, state) => const CampaignCreateScreen(),
      ),

      // ── Campaign revenue report — creator only ────────────────────────────
      GoRoute(
        path: '/campaign/:id/revenue',
        builder: (context, state) {
          final campaign = state.extra as Campaign?;
          return CampaignRevenueScreen(
            campaignId: state.pathParameters['id']!,
            campaignTitle: campaign?.title ?? 'Campaign',
            isSimulated: campaign?.isSimulated ?? true,
          );
        },
      ),

      // ── Backer earnings dashboard ─────────────────────────────────────────
      GoRoute(
        path: '/campaigns/earnings',
        builder: (context, state) => const CampaignEarningsScreen(),
      ),

      // ── Campaign proposals list ───────────────────────────────────────────
      GoRoute(
        path: '/campaign/:id/proposals',
        builder: (context, state) {
          final extra = state.extra as Map<String, dynamic>?;
          return CampaignProposalsScreen(
            campaignId: state.pathParameters['id']!,
            isCreator: extra?['isCreator'] as bool? ?? false,
            escrowBalanceCents: extra?['escrowBalanceCents'] as int? ?? 0,
          );
        },
      ),

      // ── Create proposal — creator only ────────────────────────────────────
      GoRoute(
        path: '/campaign/:id/proposals/new',
        builder: (context, state) => CampaignProposalCreateScreen(
          campaignId: state.pathParameters['id']!,
          escrowBalanceCents: state.extra as int? ?? 0,
        ),
      ),

      // ── Single proposal detail ────────────────────────────────────────────
      GoRoute(
        path: '/campaign/:id/proposals/:proposalId',
        builder: (context, state) => CampaignProposalDetailScreen(
          proposalId: state.pathParameters['proposalId']!,
        ),
      ),

      // ── Campaign updates feed ─────────────────────────────────────────────
      GoRoute(
        path: '/campaign/:id/updates',
        builder: (context, state) => CampaignUpdatesScreen(
          campaignId: state.pathParameters['id']!,
          isCreator: state.extra as bool? ?? false,
        ),
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
          // Hot Topic — public, inside ShellRoute for bottom nav persistence.
          GoRoute(
            path: '/hot-topic',
            builder: (context, state) => const HotTopicScreen(),
          ),
          GoRoute(
            path: '/battle',
            builder: (context, state) => const BattleLobbyScreen(),
          ),
          GoRoute(
            path: '/battle/:matchId',
            builder: (context, state) => BattleMatchScreen(
              matchId: state.pathParameters['matchId']!,
            ),
          ),
          GoRoute(
            path: '/campaigns',
            builder: (context, state) => const CampaignsListScreen(),
          ),
        ],
      ),
    ],
  );
});
