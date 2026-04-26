-- Migration 026: Seed test accounts
-- Creates 20 synthetic Market Maker accounts (2 per primary category) for
-- dev/QA use. All accounts are marked is_test_account=true and are filtered
-- from production-facing queries. Idempotent: ON CONFLICT DO NOTHING throughout.
--
-- UUID range: 10000000-0000-0000-0000-000000000001 → ...000020
-- Connection UUIDs: 20000000-0000-0000-0000-000000000001 → ...000020
-- Metric UUIDs:     30000000-0000-0000-0000-000000000001 → ...000020
--
-- Token balance: 1000 per account (signup bonus carried through; topped to 1000
-- so tests have spending room without needing Stripe).
-- Passwords: empty string — accounts are data-only, never logged into via UI.

-- ── 1. Insert auth.users (trigger creates profiles + token_balances) ──────────
-- handle_new_user() fires on each insert and creates:
--   profiles row (is_approved based on waitlist — will be false, fixed in step 2)
--   balances row
--   token_balances row (100 tokens signup bonus)

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

-- ── 2. Update profiles with test account metadata ─────────────────────────────
-- Sets username, category, market maker flags, approval, and is_test_account.
-- Uses service role so the protect_is_test_account trigger allows the change.

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

-- ── 3. Set token balances to 1000 for testing convenience ─────────────────────
-- (100 signup bonus was granted by trigger; top up to 1000 for spending room)
UPDATE public.token_balances
SET available_tokens = 1000, lifetime_earned = 1000
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

-- ── 4. Synthetic platform_connections (is_test_account=true) ─────────────────
-- One 'youtube' connection per account. access_token is empty — these are never
-- synced. sync-platform-metrics skips rows where is_test_account=true.

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

-- ── 5. Platform metrics — seeded with varied heat_score (5–95) ───────────────
-- display_score spread low/mid/high to give matchmaking variety.
-- heat_score spread: 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55, 60, 65, 70, 75, 80, 85, 88, 92, 95

INSERT INTO public.platform_metrics (
  id, platform_connection_id, user_id, platform,
  heat_score, display_score, follower_count, is_live
) VALUES
  ('30000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','youtube', 5,  1200,    1200,    false),
  ('30000000-0000-0000-0000-000000000002','20000000-0000-0000-0000-000000000002','10000000-0000-0000-0000-000000000002','youtube',10,  3400,    3400,    false),
  ('30000000-0000-0000-0000-000000000003','20000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000003','youtube',15,  6800,    6800,    false),
  ('30000000-0000-0000-0000-000000000004','20000000-0000-0000-0000-000000000004','10000000-0000-0000-0000-000000000004','youtube',20,  9500,    9500,    false),
  ('30000000-0000-0000-0000-000000000005','20000000-0000-0000-0000-000000000005','10000000-0000-0000-0000-000000000005','youtube',25, 14200,   14200,   false),
  ('30000000-0000-0000-0000-000000000006','20000000-0000-0000-0000-000000000006','10000000-0000-0000-0000-000000000006','youtube',30, 22000,   22000,   false),
  ('30000000-0000-0000-0000-000000000007','20000000-0000-0000-0000-000000000007','10000000-0000-0000-0000-000000000007','youtube',35, 31500,   31500,   false),
  ('30000000-0000-0000-0000-000000000008','20000000-0000-0000-0000-000000000008','10000000-0000-0000-0000-000000000008','youtube',40, 47000,   47000,   false),
  ('30000000-0000-0000-0000-000000000009','20000000-0000-0000-0000-000000000009','10000000-0000-0000-0000-000000000009','youtube',45, 68000,   68000,   false),
  ('30000000-0000-0000-0000-000000000010','20000000-0000-0000-0000-000000000010','10000000-0000-0000-0000-000000000010','youtube',50, 95000,   95000,   false),
  ('30000000-0000-0000-0000-000000000011','20000000-0000-0000-0000-000000000011','10000000-0000-0000-0000-000000000011','youtube',55,130000,  130000,  false),
  ('30000000-0000-0000-0000-000000000012','20000000-0000-0000-0000-000000000012','10000000-0000-0000-0000-000000000012','youtube',60,180000,  180000,  false),
  ('30000000-0000-0000-0000-000000000013','20000000-0000-0000-0000-000000000013','10000000-0000-0000-0000-000000000013','youtube',65,240000,  240000,  false),
  ('30000000-0000-0000-0000-000000000014','20000000-0000-0000-0000-000000000014','10000000-0000-0000-0000-000000000014','youtube',70,310000,  310000,  false),
  ('30000000-0000-0000-0000-000000000015','20000000-0000-0000-0000-000000000015','10000000-0000-0000-0000-000000000015','youtube',75,390000,  390000,  false),
  ('30000000-0000-0000-0000-000000000016','20000000-0000-0000-0000-000000000016','10000000-0000-0000-0000-000000000016','youtube',80,480000,  480000,  false),
  ('30000000-0000-0000-0000-000000000017','20000000-0000-0000-0000-000000000017','10000000-0000-0000-0000-000000000017','youtube',85,590000,  590000,  false),
  ('30000000-0000-0000-0000-000000000018','20000000-0000-0000-0000-000000000018','10000000-0000-0000-0000-000000000018','youtube',88,720000,  720000,  false),
  ('30000000-0000-0000-0000-000000000019','20000000-0000-0000-0000-000000000019','10000000-0000-0000-0000-000000000019','youtube',92,890000,  890000,  false),
  ('30000000-0000-0000-0000-000000000020','20000000-0000-0000-0000-000000000020','10000000-0000-0000-0000-000000000020','youtube',95,1100000, 1100000, false)
ON CONFLICT DO NOTHING;
