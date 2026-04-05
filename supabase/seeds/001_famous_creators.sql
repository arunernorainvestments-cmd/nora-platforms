-- ============================================
-- FAMOUS CREATORS SEED
-- Display-only creators populated from public data.
-- These rows live in famous_creators only — they have
-- no entry in auth.users or profiles.
-- Follower counts are approximate as of early 2025.
-- is_claimed = false for all; claimed later when/if the
-- real creator signs up and verifies ownership.
-- ============================================

insert into public.famous_creators (
  name,
  slug,
  bio,
  platform_youtube,
  platform_tiktok,
  platform_x,
  platform_twitch,
  platform_kick,
  platform_instagram,
  total_followers,
  is_claimed
) values

-- ============================================
-- GAMING
-- ============================================

(
  'Ninja',
  'ninja',
  'Professional gamer and streamer. Former Fortnite world record holder. One of the most recognisable gaming personalities on the internet.',
  'Ninja',
  '@ninja',
  '@Ninja',
  'ninja',
  null,
  '@ninja',
  53000000,
  false
),

(
  'Pokimane',
  'pokimane',
  'Streamer, content creator, and co-founder of Myna Media. Known for variety gaming, IRL streams, and being one of the most-followed women on Twitch.',
  'Pokimane',
  '@pokimanelol',
  '@pokimanelol',
  'pokimane',
  null,
  '@pokimanelol',
  21000000,
  false
),

(
  'xQc',
  'xqc',
  'Felix Lengyel — high-energy variety streamer and former Overwatch League pro. One of the most-watched live streamers globally.',
  'xQcOW',
  '@xqc',
  '@xQc',
  'xqcow',
  'xqc',
  '@xqcow',
  26000000,
  false
),

(
  'Shroud',
  'shroud',
  'Former CS:GO pro turned full-time streamer. Renowned for near-superhuman aim across every FPS he touches.',
  'shroud',
  null,
  '@shroud',
  'shroud',
  null,
  '@shroud',
  18000000,
  false
),

(
  'Valkyrae',
  'valkyrae',
  'Co-owner of 100 Thieves and variety streamer. YouTube Gaming''s most-watched female streamer for multiple consecutive years.',
  'Valkyrae',
  '@valkyrae',
  '@Valkyrae',
  'valkyrae',
  null,
  '@valkyrae',
  10000000,
  false
),

(
  'Kai Cenat',
  'kai-cenat',
  'Record-breaking Twitch streamer and AMP member. Holds the all-time subathon record on Twitch and brings a new generation to live streaming.',
  'Kai Cenat',
  '@kaicenat',
  '@KaiCenat',
  'kaicenat',
  null,
  '@kaicenat',
  25000000,
  false
),

-- ============================================
-- GENERAL ENTERTAINMENT
-- ============================================

(
  'MrBeast',
  'mrbeast',
  'Jimmy Donaldson — YouTube''s most-subscribed solo creator. Known for large-scale challenges, philanthropy, and viral stunts watched by hundreds of millions.',
  'MrBeast',
  '@mrbeast',
  '@MrBeast',
  null,
  null,
  '@mrbeast',
  490000000,
  false
),

(
  'Logan Paul',
  'logan-paul',
  'YouTuber, boxer, and co-founder of PRIME. Transitioned from viral video fame to professional sports and consumer brands.',
  'Logan Paul',
  '@loganpaul',
  '@LoganPaul',
  null,
  null,
  '@loganpaul',
  70000000,
  false
),

(
  'KSI',
  'ksi',
  'JJ Olatunji — YouTuber, rapper, boxer, and co-founder of PRIME. One of the UK''s biggest internet exports.',
  'KSI',
  '@ksi',
  '@KSI',
  null,
  null,
  '@ksi',
  50000000,
  false
),

(
  'Markiplier',
  'markiplier',
  'Mark Fischbach — one of YouTube''s longest-standing gaming creators. Known for horror let''s plays, charity livestreams, and original productions.',
  'Markiplier',
  '@markiplier',
  '@markiplier',
  'markiplier',
  null,
  '@markiplier',
  41000000,
  false
),

(
  'IShowSpeed',
  'ishowspeed',
  'Darren Watkins Jr. — explosive variety streamer known for unpredictable reactions, soccer content, and collaborations with global sports stars.',
  'IShowSpeed',
  '@ishowspeed',
  '@ishowspeed',
  null,
  null,
  '@ishowspeed',
  46000000,
  false
),

-- ============================================
-- MUSIC
-- ============================================

(
  'Bad Bunny',
  'bad-bunny',
  'Benito Antonio Martínez Ocasio — Puerto Rican reggaeton and Latin trap artist. Spotify''s most-streamed artist multiple years running.',
  'BadBunnyPR',
  '@badbunnypr',
  '@sanbenito',
  null,
  null,
  '@badbunnypr',
  135000000,
  false
),

(
  'Taylor Swift',
  'taylor-swift',
  'Singer-songwriter and record-breaking touring artist. One of the most followed people on every major social platform.',
  'Taylor Swift',
  '@taylorswift',
  '@taylorswift13',
  null,
  null,
  '@taylorswift',
  442000000,
  false
),

(
  'Drake',
  'drake',
  'Aubrey Graham — Toronto-born rapper and co-founder of OVO Sound. One of the best-selling music artists of all time.',
  'Drake',
  '@champagnepapi',
  '@Drake',
  null,
  null,
  '@champagnepapi',
  200000000,
  false
),

-- ============================================
-- SPORTS
-- ============================================

(
  'Cristiano Ronaldo',
  'cristiano-ronaldo',
  'CR7 — Portuguese football icon, five-time Ballon d''Or winner, and the most followed person on Instagram globally.',
  'Cristiano',
  '@cristiano',
  '@Cristiano',
  null,
  null,
  '@cristiano',
  885000000,
  false
),

(
  'LeBron James',
  'lebron-james',
  'Los Angeles Lakers forward and four-time NBA champion. One of the most followed athletes in the world across social platforms.',
  'LeBron James',
  '@kingjames',
  '@KingJames',
  null,
  null,
  '@kingjames',
  235000000,
  false
),

-- ============================================
-- KICK / RISING PLATFORMS
-- ============================================

(
  'Adin Ross',
  'adin-ross',
  'IRL and variety streamer who made his name on Twitch before migrating to Kick. Known for celebrity collabs and unpredictable streams.',
  'Adin Live',
  '@adinross',
  '@AdinRoss',
  null,
  'adinross',
  '@adinross',
  11000000,
  false
),

(
  'Sneako',
  'sneako',
  'Content creator and commentator. Migrated to Kick after platform bans, building a loyal audience around culture and debate content.',
  'SNEAKO',
  '@sneako',
  '@SNEAKO',
  null,
  'sneako',
  '@sneako',
  2000000,
  false
),

(
  'Caseoh',
  'caseoh',
  'Variety streamer who blew up on TikTok and Twitch simultaneously. Known for gaming clips, meme content, and an intensely devoted fanbase.',
  'caseoh_',
  '@caseoh_',
  '@caseoh_',
  'caseoh_',
  null,
  '@caseoh_',
  8500000,
  false
),

(
  'HasanAbi',
  'hasanabi',
  'Political commentator and Twitch''s largest political streamer. Known for long-form news reaction streams and left-leaning commentary.',
  'HasanAbi',
  '@hasanthehun',
  '@hasanthehun',
  'hasanabi',
  null,
  '@hasanthehun',
  6000000,
  false
);
