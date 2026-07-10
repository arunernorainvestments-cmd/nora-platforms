// Mobile-width layout tests for the 2026-07-10 UX pass: the redesigned Profile
// screen and the shared NBackButton must render without overflow on phone
// viewports (Flutter surfaces RenderFlex overflows as test failures).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:nora_platforms/core/widgets/n_back_button.dart';
import 'package:nora_platforms/features/auth/providers/auth_provider.dart';
import 'package:nora_platforms/features/challenges/providers/challenge_providers.dart';
import 'package:nora_platforms/features/profile/models/platform_connection.dart';
import 'package:nora_platforms/features/profile/providers/platform_connection_providers.dart';
import 'package:nora_platforms/features/profile/providers/profile_providers.dart';
import 'package:nora_platforms/features/profile/screens/profile_screen.dart';

UserProfile _profile({required bool marketMaker}) => UserProfile(
      id: 'user-1',
      username: 'longish_creator_name',
      displayName: 'A Fairly Long Display Name',
      bio: 'Creator of moments, minter of BattleChits, and a bio long enough '
          'to need the two-line ellipsis in the header card.',
      isCreator: true,
      isMarketMaker: marketMaker,
      pendingOptOut: false,
      popularityScorePublic: true,
      referralCode: 'REF12345',
      category1: 'Gaming',
      subcategory: 'Speedruns',
      isApproved: true,
    );

User _user() => User(
      id: 'user-1',
      appMetadata: const {},
      userMetadata: const {},
      aud: 'authenticated',
      createdAt: DateTime.now().toIso8601String(),
      email: 'a.long.email.address@noraplatforms.com',
    );

Widget _app({required bool marketMaker}) => ProviderScope(
      overrides: [
        userProfileProvider
            .overrideWith((ref) async => _profile(marketMaker: marketMaker)),
        profileTokenBalanceProvider.overrideWith((ref) async => 1250),
        spotlightTierProvider.overrideWith((ref) async => 'rising'),
        currentUserProvider.overrideWithValue(_user()),
        platformConnectionsProvider
            .overrideWith((ref) async => <PlatformConnection>[]),
        userBadgesProvider.overrideWith((ref, userId) async => []),
      ],
      child: MaterialApp(
        theme: ThemeData.dark(), // avoid GoogleFonts network fetch in tests
        home: const ProfileScreen(),
      ),
    );

Future<void> _pumpAtSize(WidgetTester tester, Widget widget, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(widget);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Profile lays out at iPhone width without overflow',
      (tester) async {
    await _pumpAtSize(tester, _app(marketMaker: false), const Size(375, 812));
    expect(find.text('longish_creator_name'), findsOneWidget);
    expect(find.text('Preview Profile'), findsOneWidget);
    expect(find.text('Challenges'), findsOneWidget);
  });

  testWidgets('Profile (market maker) lays out at narrow 320px width',
      (tester) async {
    await _pumpAtSize(tester, _app(marketMaker: true), const Size(320, 568));
    expect(find.text('Score Dashboard'), findsOneWidget);
    expect(find.text('Promote'), findsOneWidget);
    expect(find.text('Sign Out'), findsOneWidget);
  });

  testWidgets('Profile lays out at desktop width (max-width cap applies)',
      (tester) async {
    await _pumpAtSize(tester, _app(marketMaker: true), const Size(1440, 900));
    expect(find.text('Preview Profile'), findsOneWidget);
  });

  testWidgets('NBackButton renders in a crowded narrow AppBar', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        appBar: AppBar(
          leading: const NBackButton(fallback: '/battle'),
          title: const Text('My BattleChits'),
          actions: [
            IconButton(icon: const Icon(Icons.trending_up), onPressed: () {}),
            IconButton(
                icon: const Icon(Icons.storefront_outlined), onPressed: () {}),
            IconButton(icon: const Icon(Icons.add), onPressed: () {}),
          ],
        ),
        body: const SizedBox.shrink(),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(NBackButton), findsOneWidget);
    expect(find.byIcon(Icons.arrow_back), findsOneWidget);
  });
}
