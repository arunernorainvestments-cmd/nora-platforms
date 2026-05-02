-- Migration 051: Idempotent reseed of dev test creators
--
-- BRANCH DECISION (see arena-dev-simulator comments):
--   Migration 026 originally seeded 20 test creators. Migration 027 (teardown)
--   was NOT applied per CLAUDE.md. This migration is a safety net — it's a no-op
--   if creators already exist (ON CONFLICT DO NOTHING throughout).
--
-- What this adds vs 026:
--   - momentum_score set to varied values (0–80) for richer match simulation
--   - dev_arena_back() helper function used by arena-dev-simulator edge function
--     (bypasses auth.uid() requirement of arena_back() RPC for service-role callers)
--   - Safe to run on a fresh DB (Branch C) or one with existing creators (Branch A/B)
--
-- UUID ranges (same as 026):
--   profiles/auth.users: 10000000-0000-0000-0000-000000000001 → …000020
--   platform_connections: 20000000-0000-0000-0000-000000000001 → …000020
--   platform_metrics:     30000000-0000-0000-0000-000000000001 → …000020

-- ── 1. Auth users (trigger creates profiles + token_balances) ─────────────────
INSERT INTO auth.users (
  id, instance_id, aud, role,
  email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_user_meta_data
) VALUES
  ('10000000-0000-0000-0000-000000000001','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_athlete_basketball_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Athlete 1"}'),
  ('10000000-0000-0000-0000-000000000002','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_athlete_football_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Athlete 2"}'),
  ('10000000-0000-0000-0000-000000000003','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_musician_dj_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Musician 1"}'),
  ('10000000-0000-0000-0000-000000000004','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_musician_singer_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Musician 2"}'),
  ('10000000-0000-0000-0000-000000000005','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_healthcare_doctor_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Healthcare 1"}'),
  ('10000000-0000-0000-0000-000000000006','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_healthcare_nurse_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Healthcare 2"}'),
  ('10000000-0000-0000-0000-000000000007','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_performer_comedian_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Performer 1"}'),
  ('10000000-0000-0000-0000-000000000008','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_performer_dancer_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Performer 2"}'),
  ('10000000-0000-0000-0000-000000000009','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_gamer_streamer_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Gamer 1"}'),
  ('10000000-0000-0000-0000-000000000010','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_gamer_competitive_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Gamer 2"}'),
  ('10000000-0000-0000-0000-000000000011','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_influencer_fitness_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Influencer 1"}'),
  ('10000000-0000-0000-0000-000000000012','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_influencer_travel_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Influencer 2"}'),
  ('10000000-0000-0000-0000-000000000013','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_educator_teacher_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Educator 1"}'),
  ('10000000-0000-0000-0000-000000000014','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_educator_author_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Educator 2"}'),
  ('10000000-0000-0000-0000-000000000015','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_politician_congress_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Politician 1"}'),
  ('10000000-0000-0000-0000-000000000016','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_politician_governor_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Politician 2"}'),
  ('10000000-0000-0000-0000-000000000017','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_religion_pastor_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Religion 1"}'),
  ('10000000-0000-0000-0000-000000000018','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_religion_rabbi_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Religion 2"}'),
  ('10000000-0000-0000-0000-000000000019','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_business_startup_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Business 1"}'),
  ('10000000-0000-0000-0000-000000000020','00000000-0000-0000-0000-000000000000','authenticated','authenticated','test+test_business_nonprofit_1@noraplatforms.com','',now(),now(),now(),'{"full_name":"Test Business 2"}')
ON CONFLICT DO NOTHING;

-- ── 2. Profile metadata (idempotent UPDATE — no-op if already correct) ────────
UPDATE public.profiles SET username='test_athlete_basketball_1', display_name='Test Athlete 1',       category_1='Athlete',     subcategory='Basketball',    is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000001';
UPDATE public.profiles SET username='test_athlete_football_1',   display_name='Test Athlete 2',       category_1='Athlete',     subcategory='Football',      is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000002';
UPDATE public.profiles SET username='test_musician_dj_1',        display_name='Test Musician 1',      category_1='Musician',    subcategory='DJ',            is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000003';
UPDATE public.profiles SET username='test_musician_singer_1',    display_name='Test Musician 2',      category_1='Musician',    subcategory='Singer',        is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000004';
UPDATE public.profiles SET username='test_healthcare_doctor_1',  display_name='Test Healthcare 1',    category_1='Healthcare',  subcategory='Doctor General',is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000005';
UPDATE public.profiles SET username='test_healthcare_nurse_1',   display_name='Test Healthcare 2',    category_1='Healthcare',  subcategory='Nurse',         is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000006';
UPDATE public.profiles SET username='test_performer_comedian_1', display_name='Test Performer 1',     category_1='Performer',   subcategory='Comedian',      is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000007';
UPDATE public.profiles SET username='test_performer_dancer_1',   display_name='Test Performer 2',     category_1='Performer',   subcategory='Dancer',        is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000008';
UPDATE public.profiles SET username='test_gamer_streamer_1',     display_name='Test Gamer 1',         category_1='Gamer',       subcategory='Streamer',      is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000009';
UPDATE public.profiles SET username='test_gamer_competitive_1',  display_name='Test Gamer 2',         category_1='Gamer',       subcategory='Competitive',   is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000010';
UPDATE public.profiles SET username='test_influencer_fitness_1', display_name='Test Influencer 1',    category_1='Influencer',  subcategory='Fitness',       is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000011';
UPDATE public.profiles SET username='test_influencer_travel_1',  display_name='Test Influencer 2',    category_1='Influencer',  subcategory='Travel',        is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000012';
UPDATE public.profiles SET username='test_educator_teacher_1',   display_name='Test Educator 1',      category_1='Educator',    subcategory='Teacher',       is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000013';
UPDATE public.profiles SET username='test_educator_author_1',    display_name='Test Educator 2',      category_1='Educator',    subcategory='Author',        is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000014';
UPDATE public.profiles SET username='test_politician_congress_1',display_name='Test Politician 1',    category_1='Politician',  subcategory='Congress',      is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000015';
UPDATE public.profiles SET username='test_politician_governor_1',display_name='Test Politician 2',    category_1='Politician',  subcategory='Governor',      is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000016';
UPDATE public.profiles SET username='test_religion_pastor_1',    display_name='Test Religion 1',      category_1='Religion',    subcategory='Pastor',        is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000017';
UPDATE public.profiles SET username='test_religion_rabbi_1',     display_name='Test Religion 2',      category_1='Religion',    subcategory='Rabbi',         is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000018';
UPDATE public.profiles SET username='test_business_startup_1',   display_name='Test Business 1',      category_1='Business',    subcategory='Startup',       is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000019';
UPDATE public.profiles SET username='test_business_nonprofit_1', display_name='Test Business 2',      category_1='Business',    subcategory='Non Profit',    is_market_maker=true, pending_opt_out=false, is_approved=true, is_test_account=true WHERE id='10000000-0000-0000-0000-000000000020';

-- ── 3. Token balances — ensure 1000 tokens for spending room ─────────────────
-- If the trigger already created a row (via auth.users insert above), this updates it.
-- If the row existed from migration 026, this ensures it's at 1000.
UPDATE public.token_balances
SET available_tokens = 1000, lifetime_earned = 1000, updated_at = now()
WHERE user_id IN (
  '10000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000004',
  '10000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000006',
  '10000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000008',
  '10000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000010',
  '10000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000012',
  '10000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000014',
  '10000000-0000-0000-0000-000000000015','10000000-0000-0000-0000-000000000016',
  '10000000-0000-0000-0000-000000000017','10000000-0000-0000-0000-000000000018',
  '10000000-0000-0000-0000-000000000019','10000000-0000-0000-0000-000000000020'
);

-- ── 4. Platform connections ───────────────────────────────────────────────────
INSERT INTO public.platform_connections (
  id, user_id, platform, platform_user_id, platform_username,
  access_token, is_active, is_test_account
) VALUES
  ('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','youtube','test_yt_001','Test Athlete 1',       '',true,true),
  ('20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','youtube','test_yt_002','Test Athlete 2',       '',true,true),
  ('20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003','youtube','test_yt_003','Test Musician 1',      '',true,true),
  ('20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004','youtube','test_yt_004','Test Musician 2',      '',true,true),
  ('20000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000005','youtube','test_yt_005','Test Healthcare 1',    '',true,true),
  ('20000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000006','youtube','test_yt_006','Test Healthcare 2',    '',true,true),
  ('20000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000007','youtube','test_yt_007','Test Performer 1',     '',true,true),
  ('20000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000008','youtube','test_yt_008','Test Performer 2',     '',true,true),
  ('20000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000009','youtube','test_yt_009','Test Gamer 1',         '',true,true),
  ('20000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000010','youtube','test_yt_010','Test Gamer 2',         '',true,true),
  ('20000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000011','youtube','test_yt_011','Test Influencer 1',    '',true,true),
  ('20000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000012','youtube','test_yt_012','Test Influencer 2',    '',true,true),
  ('20000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000013','youtube','test_yt_013','Test Educator 1',      '',true,true),
  ('20000000-0000-0000-0000-000000000014','10000000-0000-0000-0000-000000000014','youtube','test_yt_014','Test Educator 2',      '',true,true),
  ('20000000-0000-0000-0000-000000000015','10000000-0000-0000-0000-000000000015','youtube','test_yt_015','Test Politician 1',    '',true,true),
  ('20000000-0000-0000-0000-000000000016','10000000-0000-0000-0000-000000000016','youtube','test_yt_016','Test Politician 2',    '',true,true),
  ('20000000-0000-0000-0000-000000000017','10000000-0000-0000-0000-000000000017','youtube','test_yt_017','Test Religion 1',      '',true,true),
  ('20000000-0000-0000-0000-000000000018','10000000-0000-0000-0000-000000000018','youtube','test_yt_018','Test Religion 2',      '',true,true),
  ('20000000-0000-0000-0000-000000000019','10000000-0000-0000-0000-000000000019','youtube','test_yt_019','Test Business 1',      '',true,true),
  ('20000000-0000-0000-0000-000000000020','10000000-0000-0000-0000-000000000020','youtube','test_yt_020','Test Business 2',      '',true,true)
ON CONFLICT DO NOTHING;

-- ── 5. Platform metrics ───────────────────────────────────────────────────────
-- Includes momentum_score (0–80 range) for Arena simulation variety.
-- display_score spread 10k–500k. heat_score 5–95.
-- arena_rating defaults to 1000 (from migration 039 column default).

INSERT INTO public.platform_metrics (
  id, platform_connection_id, user_id, platform,
  heat_score, display_score, follower_count, is_live, momentum_score
) VALUES
  ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','youtube',  5,   12000,  12000, false,  0),
  ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','youtube', 10,   34000,  34000, false,  5),
  ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003','youtube', 15,   68000,  68000, false, 10),
  ('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004','youtube', 20,   95000,  95000, false, 15),
  ('30000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000005','youtube', 25,  142000, 142000, false, 20),
  ('30000000-0000-0000-0000-000000000006','20000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000006','youtube', 30,  220000, 220000, false, 25),
  ('30000000-0000-0000-0000-000000000007','20000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000007','youtube', 35,  315000, 315000, false, 30),
  ('30000000-0000-0000-0000-000000000008','20000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000008','youtube', 40,  470000, 470000, false, 35),
  ('30000000-0000-0000-0000-000000000009','20000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000009','youtube', 45,  680000, 680000, false, 40),
  ('30000000-0000-0000-0000-000000000010','20000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000010','youtube', 50,  950000, 950000, false, 45),
  ('30000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000011','youtube', 55, 1300000,1300000, false, 50),
  ('30000000-0000-0000-0000-000000000012','20000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000012','youtube', 60, 1800000,1800000, false, 55),
  ('30000000-0000-0000-0000-000000000013','20000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000013','youtube', 65, 2400000,2400000, false, 60),
  ('30000000-0000-0000-0000-000000000014','20000000-0000-0000-0000-000000000014','10000000-0000-0000-0000-000000000014','youtube', 70, 3100000,3100000, false, 65),
  ('30000000-0000-0000-0000-000000000015','20000000-0000-0000-0000-000000000015','10000000-0000-0000-0000-000000000015','youtube', 75, 3900000,3900000, false, 70),
  ('30000000-0000-0000-0000-000000000016','20000000-0000-0000-0000-000000000016','10000000-0000-0000-0000-000000000016','youtube', 80, 4800000,4800000, false, 72),
  ('30000000-0000-0000-0000-000000000017','20000000-0000-0000-0000-000000000017','10000000-0000-0000-0000-000000000017','youtube', 85, 5900000,5900000, false, 75),
  ('30000000-0000-0000-0000-000000000018','20000000-0000-0000-0000-000000000018','10000000-0000-0000-0000-000000000018','youtube', 88, 7200000,7200000, false, 78),
  ('30000000-0000-0000-0000-000000000019','20000000-0000-0000-0000-000000000019','10000000-0000-0000-0000-000000000019','youtube', 92, 8900000,8900000, false, 80),
  ('30000000-0000-0000-0000-000000000020','20000000-0000-0000-0000-000000000020','10000000-0000-0000-0000-000000000020','youtube', 95,11000000,11000000,false, 80)
ON CONFLICT DO NOTHING;

-- ── 6. Update momentum_score for creators whose platform_metrics rows already ──
-- existed from migration 026 (where momentum_score defaulted to 0 via migration 037).
-- Gives simulation variety; Arena-only value, dev accounts only.
UPDATE public.platform_metrics SET momentum_score =  0 WHERE id = '30000000-0000-0000-0000-000000000001';
UPDATE public.platform_metrics SET momentum_score =  5 WHERE id = '30000000-0000-0000-0000-000000000002';
UPDATE public.platform_metrics SET momentum_score = 10 WHERE id = '30000000-0000-0000-0000-000000000003';
UPDATE public.platform_metrics SET momentum_score = 15 WHERE id = '30000000-0000-0000-0000-000000000004';
UPDATE public.platform_metrics SET momentum_score = 20 WHERE id = '30000000-0000-0000-0000-000000000005';
UPDATE public.platform_metrics SET momentum_score = 25 WHERE id = '30000000-0000-0000-0000-000000000006';
UPDATE public.platform_metrics SET momentum_score = 30 WHERE id = '30000000-0000-0000-0000-000000000007';
UPDATE public.platform_metrics SET momentum_score = 35 WHERE id = '30000000-0000-0000-0000-000000000008';
UPDATE public.platform_metrics SET momentum_score = 40 WHERE id = '30000000-0000-0000-0000-000000000009';
UPDATE public.platform_metrics SET momentum_score = 45 WHERE id = '30000000-0000-0000-0000-000000000010';
UPDATE public.platform_metrics SET momentum_score = 50 WHERE id = '30000000-0000-0000-0000-000000000011';
UPDATE public.platform_metrics SET momentum_score = 55 WHERE id = '30000000-0000-0000-0000-000000000012';
UPDATE public.platform_metrics SET momentum_score = 60 WHERE id = '30000000-0000-0000-0000-000000000013';
UPDATE public.platform_metrics SET momentum_score = 65 WHERE id = '30000000-0000-0000-0000-000000000014';
UPDATE public.platform_metrics SET momentum_score = 70 WHERE id = '30000000-0000-0000-0000-000000000015';
UPDATE public.platform_metrics SET momentum_score = 72 WHERE id = '30000000-0000-0000-0000-000000000016';
UPDATE public.platform_metrics SET momentum_score = 75 WHERE id = '30000000-0000-0000-0000-000000000017';
UPDATE public.platform_metrics SET momentum_score = 78 WHERE id = '30000000-0000-0000-0000-000000000018';
UPDATE public.platform_metrics SET momentum_score = 80 WHERE id = '30000000-0000-0000-0000-000000000019';
UPDATE public.platform_metrics SET momentum_score = 80 WHERE id = '30000000-0000-0000-0000-000000000020';

-- ── 7. dev_arena_back() helper — used by arena-dev-simulator edge function ────
-- arena_back() requires auth.uid() (authenticated caller). The simulator runs
-- under service role with no auth context, so we need this variant that accepts
-- the backer_id explicitly.
-- SECURITY: SECURITY DEFINER so it can write across RLS-protected tables.
-- The ALLOW_DEV_TOOLS gate on the calling edge function is the primary defence.

CREATE OR REPLACE FUNCTION public.dev_arena_back(
  p_backer_id uuid,
  p_match_id  uuid,
  p_target_id uuid,
  p_amount    integer
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_is_p1 boolean;
BEGIN
  -- Deduct from backer
  UPDATE public.token_balances
  SET available_tokens = available_tokens - p_amount,
      lifetime_spent   = lifetime_spent   + p_amount,
      updated_at       = now()
  WHERE user_id           = p_backer_id
    AND available_tokens >= p_amount;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'dev_arena_back: insufficient tokens for user %', p_backer_id;
  END IF;

  -- Record spend
  INSERT INTO public.token_transactions (user_id, type, amount, reference_id, description)
  VALUES (p_backer_id, 'arena_back', p_amount, p_match_id, 'Dev simulator: backed creator in arena match');

  -- Arena event (processed=false so tick loop picks up flow contribution)
  INSERT INTO public.arena_events (match_id, user_id, target_id, type, value)
  VALUES (p_match_id, p_backer_id, p_target_id, 'back', p_amount);

  -- Update pool total
  SELECT (player_1_id = p_target_id) INTO v_is_p1
  FROM public.arena_matches WHERE id = p_match_id;

  IF v_is_p1 THEN
    UPDATE public.arena_state
    SET total_pool_p1 = total_pool_p1 + p_amount, updated_at = now()
    WHERE match_id = p_match_id;
  ELSE
    UPDATE public.arena_state
    SET total_pool_p2 = total_pool_p2 + p_amount, updated_at = now()
    WHERE match_id = p_match_id;
  END IF;
END;
$$;

-- ── 8. dev_arena_reset_matches() helper — used by arena-dev-reset edge fn ─────
-- Deletes all arena rows for test creators in a single DB roundtrip.
-- Avoids PostgREST URL length limits that arise when passing 1000+ match IDs
-- through an .in() filter from the edge function.
-- Delete order respects FK constraints (children before parents).

-- Note: if this function already exists with a different return signature,
-- drop it first: DROP FUNCTION IF EXISTS public.dev_arena_reset_matches(uuid[]);
CREATE OR REPLACE FUNCTION public.dev_arena_reset_matches(p_test_ids uuid[])
RETURNS TABLE(
  deleted_ability_uses   bigint,
  deleted_events         bigint,
  deleted_round3_results bigint,
  deleted_telemetry      bigint,
  deleted_state          bigint,
  deleted_matches        bigint
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_abu bigint := 0;
  v_evt bigint := 0;
  v_r3r bigint := 0;
  v_tel bigint := 0;
  v_st  bigint := 0;
  v_mt  bigint := 0;
BEGIN
  DELETE FROM public.arena_ability_uses
  WHERE match_id IN (
    SELECT id FROM public.arena_matches
    WHERE player_1_id = ANY(p_test_ids) OR player_2_id = ANY(p_test_ids)
  );
  GET DIAGNOSTICS v_abu = ROW_COUNT;

  DELETE FROM public.arena_events
  WHERE match_id IN (
    SELECT id FROM public.arena_matches
    WHERE player_1_id = ANY(p_test_ids) OR player_2_id = ANY(p_test_ids)
  );
  GET DIAGNOSTICS v_evt = ROW_COUNT;

  -- arena_round3_results also FKs to arena_matches — must be deleted before matches
  DELETE FROM public.arena_round3_results
  WHERE match_id IN (
    SELECT id FROM public.arena_matches
    WHERE player_1_id = ANY(p_test_ids) OR player_2_id = ANY(p_test_ids)
  );
  GET DIAGNOSTICS v_r3r = ROW_COUNT;

  DELETE FROM public.arena_match_telemetry
  WHERE match_id IN (
    SELECT id FROM public.arena_matches
    WHERE player_1_id = ANY(p_test_ids) OR player_2_id = ANY(p_test_ids)
  );
  GET DIAGNOSTICS v_tel = ROW_COUNT;

  DELETE FROM public.arena_state
  WHERE match_id IN (
    SELECT id FROM public.arena_matches
    WHERE player_1_id = ANY(p_test_ids) OR player_2_id = ANY(p_test_ids)
  );
  GET DIAGNOSTICS v_st = ROW_COUNT;

  DELETE FROM public.arena_matches
  WHERE player_1_id = ANY(p_test_ids) OR player_2_id = ANY(p_test_ids);
  GET DIAGNOSTICS v_mt = ROW_COUNT;

  RETURN QUERY SELECT v_abu, v_evt, v_r3r, v_tel, v_st, v_mt;
END;
$$;
