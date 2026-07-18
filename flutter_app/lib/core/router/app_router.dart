import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;
import '../widgets/not_found_screen.dart';
import '../../features/auth/screens/forgot_password_screen.dart';
import '../../features/auth/screens/update_password_screen.dart';
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
import '../../features/profile/screens/score_dashboard_screen.dart';
import '../../features/arena/screens/arena_screen.dart';
import '../../features/arena/screens/arena_match_screen.dart';
import '../../features/battle/screens/battle_hub_screen.dart';
import '../../features/battle/screens/battle_play_screen.dart';
import '../../features/battle/screens/battle_spectate_screen.dart';
import '../../features/battle/screens/find_match_screen.dart';
import '../../features/home/screens/home_screen.dart';
import '../../features/mint/screens/mint_moment_screen.dart';
import '../../features/collection/screens/collection_screen.dart';
import '../../features/market/screens/market_screen.dart';
import '../../features/home/screens/plan_screen.dart';
import '../../features/settings/screens/support_screen.dart';
import '../../features/settings/screens/faq_screen.dart';
import '../../features/marketplace/screens/marketplace_screen.dart';
import '../../features/licensing/screens/licensing_marketplace_home_screen.dart';
import '../../features/licensing/screens/licensing_listing_detail_screen.dart';
import '../../features/licensing/screens/license_checkout_screen.dart';
import '../../features/licensing/screens/my_licenses_screen.dart';
import '../../features/licensing/screens/create_listing_screen.dart';
import '../../features/licensing/screens/partners_portal_screen.dart';
import '../../features/licensing/screens/license_public_record_screen.dart';
import '../../features/polls/screens/poll_screen.dart';
import '../../features/kyc/screens/kyc_screen.dart';
import '../../features/emergency_fund/screens/emergency_fund_screen.dart';
import '../../features/emergency_fund/screens/contribute_screen.dart';
import '../../features/emergency_fund/screens/request_funds_screen.dart';
import '../../features/emergency_fund/screens/my_requests_screen.dart';
import '../../features/emergency_fund/screens/vote_screen.dart';
import '../../features/admin/screens/admin_screen.dart';
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
  ref.listen(authStateProvider, (_, next) {
    // A password-reset link produces a recovery session. Latch it so the
    // redirect below pins the user to /update-password instead of /home.
    if (next.value?.event == AuthChangeEvent.passwordRecovery) {
      ref.read(passwordRecoveryProvider.notifier).state = true;
    }
    notifier.notify();
  });
  ref.listen(approvalStatusProvider, (_, __) => notifier.notify());
  ref.onDispose(notifier.dispose);

  final router = GoRouter(
    initialLocation: '/',
    refreshListenable: notifier,
    // Unknown URLs get the branded dead-end instead of GoRouter's stock error.
    errorBuilder: (context, state) =>
        NotFoundScreen(location: state.uri.path),
    redirect: (context, state) {
      final authState = ref.read(authStateProvider);
      final approvalStatus = ref.read(approvalStatusProvider);

      // ── Do not redirect while auth session is being restored ─────────────
      if (authState.isLoading) return null;

      final isLoggedIn = authState.value?.session != null;
      final isApproved = approvalStatus.value; // null = loading or not logged in
      final loc = state.matchedLocation;

      // ── Password recovery: pin to /update-password ────────────────────────
      // A reset link grants a recovery session; without this pin the blocks
      // below would bounce the user straight to /home and they could never set
      // a new password.
      if (ref.read(passwordRecoveryProvider) && loc != '/update-password') {
        return '/update-password';
      }

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
        '/marketplace', '/verify-identity',
        '/my-licenses', '/create-listing', '/mint', '/collection', '/market',
        '/admin',
      ];
      // sub-paths are also protected
      final isProtected = protectedRoutes.contains(loc) ||
          loc.startsWith('/arena/') ||
          loc.startsWith('/battle/') ||
          loc.startsWith('/marketplace/') ||
          loc == '/emergency-fund/request' ||
          loc == '/emergency-fund/my-requests' ||
          loc.startsWith('/emergency-fund/vote/') ||
          // Licensing: marketplace browsing is public, but buying a license
          // requires auth (lkn-purchase-license is user-scoped).
          loc.contains('/buy/');
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
      // Target of the password-reset email link (redirectTo). Public so the
      // recovery session can be exchanged from the URL before the user is
      // "logged in"; the screen handles the expired-link case itself.
      GoRoute(
        path: '/update-password',
        builder: (context, state) => const UpdatePasswordScreen(),
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

      // Legal pages (/privacy, /terms) are static HTML served by Vercel
      // rewrites, not Flutter routes — link out via openUrlInBrowser.

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

      // ── Campaigns are ARCHIVED (migration 089) — old links land on /plan ──
      GoRoute(
        path: '/campaigns',
        redirect: (context, state) => '/plan',
      ),
      GoRoute(
        path: '/campaigns/:rest',
        redirect: (context, state) => '/plan',
      ),
      GoRoute(
        path: '/campaign/:id',
        redirect: (context, state) => '/plan',
        routes: [
          GoRoute(
            path: ':rest',
            redirect: (context, state) => '/plan',
          ),
        ],
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

      // ── Card Marketplace (Doc 3) ──────────────────────────────────────────
      GoRoute(
        path: '/marketplace',
        builder: (context, state) => const MarketplaceScreen(),
        routes: [
          GoRoute(
            path: 'card/:cardId',
            builder: (context, state) => CardDetailScreen(
              cardId: state.pathParameters['cardId']!,
            ),
          ),
          GoRoute(
            path: 'offering/:offeringId',
            builder: (context, state) => OfferingDetailScreen(
              offeringId: state.pathParameters['offeringId']!,
            ),
          ),
        ],
      ),

      // ── Licensing Marketplace (Doc 5) ────────────────────────────────────
      // Browsing is public; /my-licenses, /create-listing and the buy flow
      // require auth (enforced in redirect above).
      GoRoute(
        path: '/licenses',
        builder: (context, state) => const LicensingMarketplaceHomeScreen(),
      ),
      GoRoute(
        path: '/licenses/:listingId',
        builder: (context, state) => LicensingListingDetailScreen(
          listingId: state.pathParameters['listingId']!,
        ),
      ),
      GoRoute(
        path: '/licenses/:listingId/buy/:tierId',
        builder: (context, state) => LicenseCheckoutScreen(
          listingId: state.pathParameters['listingId']!,
          tierId: state.pathParameters['tierId']!,
        ),
      ),
      GoRoute(
        path: '/my-licenses',
        builder: (context, state) => const MyLicensesScreen(),
      ),
      GoRoute(
        path: '/create-listing',
        builder: (context, state) => const CreateListingScreen(),
      ),
      GoRoute(
        path: '/partners',
        builder: (context, state) => const PartnersPortalScreen(),
      ),
      GoRoute(
        path: '/license/:licenseId',
        builder: (context, state) => LicensePublicRecordScreen(
          licenseId: state.pathParameters['licenseId']!,
        ),
      ),

      // ── Weekly Polls (Doc 3) — /poll/:pollId/embed is the shareable embed ──
      GoRoute(
        path: '/poll/:pollId',
        builder: (context, state) => PollScreen(
          pollId: state.pathParameters['pollId']!,
        ),
        routes: [
          GoRoute(
            path: 'embed',
            builder: (context, state) => PollScreen(
              pollId: state.pathParameters['pollId']!,
              isEmbed: true,
            ),
          ),
        ],
      ),

      // ── Emergency Fund (Doc 4) ────────────────────────────────────────────
      GoRoute(
        path: '/emergency-fund',
        builder: (context, state) => const EmergencyFundScreen(),
      ),
      GoRoute(
        path: '/emergency-fund/contribute',
        builder: (context, state) => const ContributeScreen(),
      ),
      GoRoute(
        path: '/emergency-fund/request',
        builder: (context, state) => const RequestFundsScreen(),
      ),
      GoRoute(
        path: '/emergency-fund/my-requests',
        builder: (context, state) => const MyRequestsScreen(),
      ),
      GoRoute(
        path: '/emergency-fund/vote/:assignmentId',
        builder: (context, state) => VoteScreen(
          assignmentId: state.pathParameters['assignmentId']!,
        ),
      ),

      // ── Admin operations console (auth here; is_admin enforced by the
      // admin-review edge function — a non-admin sees the locked state) ─────
      GoRoute(
        path: '/admin',
        builder: (context, state) => const AdminScreen(),
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
            path: '/verify-identity',
            builder: (context, state) => const KycScreen(),
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
          // Battle under the crossplay structure (NORA_PLATFORMS_CROSSPLAY_
          // SPEC.md): mint + find-a-match (shared web/Arena queue) + play +
          // spectate. The legacy 1v1 fighter web client was removed 2026-07-12.
          GoRoute(
            path: '/battle',
            builder: (context, state) => const BattleHubScreen(),
          ),
          // Minting v2 §1 — "Create Your BattleChit" (auth-required).
          GoRoute(
            path: '/mint',
            builder: (context, state) => const MintMomentScreen(),
          ),
          // The user's minted moment chits — where a finalized card lands.
          GoRoute(
            path: '/collection',
            builder: (context, state) => const CollectionScreen(),
          ),
          // Chit marketplace (M3) — fixed-price token resale of moment chits.
          // NOTE: '/market' ≠ '/marketplace' (likeness cards) ≠ '/markets'
          // (prediction markets).
          GoRoute(
            path: '/market',
            builder: (context, state) => const MarketScreen(),
          ),
          GoRoute(
            path: '/battle/find',
            builder: (context, state) => const FindMatchScreen(),
          ),
          GoRoute(
            path: '/battle/play/:matchId',
            builder: (context, state) => BattlePlayScreen(
              matchId: state.pathParameters['matchId']!,
            ),
          ),
          GoRoute(
            path: '/battle/spectate/:matchId',
            builder: (context, state) => BattleSpectateScreen(
              matchId: state.pathParameters['matchId']!,
            ),
          ),
        ],
      ),
    ],
  );

  // Per-route browser-tab/history titles: index.html ships one static <title>,
  // so every screen read the same. Track navigation and retitle the document.
  void syncTitle() {
    web.document.title =
        _documentTitleFor(router.routerDelegate.currentConfiguration.uri.path);
  }

  router.routerDelegate.addListener(syncTitle);
  ref.onDispose(() => router.routerDelegate.removeListener(syncTitle));

  return router;
});

/// Browser-tab title per top-level route (keyed on the first path segment so
/// detail routes inherit their section's title).
String _documentTitleFor(String path) {
  const brand = 'N.O.R.A. Platforms';
  final segment =
      path.split('/').firstWhere((s) => s.isNotEmpty, orElse: () => '');
  final section = switch (segment) {
    '' || 'w' => null, // launch/waitlist cover — keep the brand headline
    'home' => 'Home',
    'login' => 'Sign in',
    'signup' => 'Create account',
    'forgot-password' || 'update-password' => 'Reset password',
    'pending-approval' => 'Pending approval',
    'join' => 'Join',
    'mint' => 'Create Your BattleChit',
    'collection' => 'My Collection',
    'market' => 'Chit Market',
    'battle' => 'Battle Arena',
    'arena' => 'Arena',
    'markets' => 'Creator Markets',
    'mybets' => 'My Bets',
    'news' || 'explore' => 'Celebrity News',
    'hot-topic' => 'Hot Topic',
    'search' => 'Search',
    'profile' => 'Profile',
    'u' => 'Profile',
    'wallet' => 'Wallet',
    'verify-identity' => 'Verify identity',
    'challenges' => 'Challenges',
    'dashboard' => 'Score Dashboard',
    'marketplace' => 'Card Marketplace',
    'licenses' || 'license' => 'Licensing',
    'my-licenses' => 'My Licenses',
    'create-listing' => 'Create Listing',
    'partners' => 'Partners',
    'poll' => 'Weekly Poll',
    'emergency-fund' => 'Emergency Fund',
    'plan' => 'Roadmap',
    'support' => 'Support',
    'faq' => 'FAQ',
    'admin' => 'Admin',
    _ => null,
  };
  return section == null ? '$brand — Moments Card Battler' : '$section · $brand';
}
