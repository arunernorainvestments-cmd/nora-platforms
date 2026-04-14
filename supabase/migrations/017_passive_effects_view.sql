-- Migration 017: user_passive_effects view
--
-- Aggregates passive badge effects per user from their earned badges.
-- Used by:
--   • Discover/Spotlight queries  — multiply rank by (1 + visibility_multiplier)
--   • resolve-markets             — apply token_earn_rate bonus to winnings
--   • apply-promotion             — apply promotion_discount to cost
--   • Signup/referral flow        — apply referral_bonus_tokens on referred signup
--
-- Stacking rules (per spec):
--   visibility_multiplier  — additive sum across all earned badges
--   token_earn_rate        — additive sum across all earned badges
--   promotion_discount     — MAX (discounts do NOT stack)
--   referral_bonus         — MAX bonus_tokens (highest tier wins)
--
-- Returns one row per user who has at least one badge with a passive_effect.
-- Consumers must LEFT JOIN or COALESCE to default zeros for users with no row.

CREATE OR REPLACE VIEW public.user_passive_effects AS
SELECT
  ub.user_id,

  -- Additive: sum all visibility_multiplier values across earned badges
  COALESCE(
    SUM(
      CASE WHEN bd.passive_effect->>'type' = 'visibility_multiplier'
        THEN (bd.passive_effect->>'value')::numeric
        ELSE 0
      END
    ),
    0
  ) AS visibility_multiplier,

  -- Additive: sum all token_earn_rate values across earned badges
  COALESCE(
    SUM(
      CASE WHEN bd.passive_effect->>'type' = 'token_earn_rate'
        THEN (bd.passive_effect->>'value')::numeric
        ELSE 0
      END
    ),
    0
  ) AS token_earn_rate,

  -- Non-stacking: take the highest promotion_discount value
  COALESCE(
    MAX(
      CASE WHEN bd.passive_effect->>'type' = 'promotion_discount'
        THEN (bd.passive_effect->>'value')::numeric
        ELSE NULL
      END
    ),
    0
  ) AS promotion_discount,

  -- Highest-tier referral bonus tokens unlocked
  COALESCE(
    MAX(
      CASE WHEN bd.passive_effect->>'type' = 'referral_bonus'
        THEN (bd.passive_effect->>'bonus_tokens')::integer
        ELSE NULL
      END
    ),
    0
  ) AS referral_bonus_tokens,

  -- Minimum referrals required for the highest-tier referral bonus
  COALESCE(
    MAX(
      CASE WHEN bd.passive_effect->>'type' = 'referral_bonus'
        THEN (bd.passive_effect->>'after_n')::integer
        ELSE NULL
      END
    ),
    0
  ) AS referral_bonus_after_n

FROM public.user_badges ub
JOIN public.badge_definitions bd ON bd.id = ub.badge_id
WHERE bd.passive_effect IS NOT NULL
GROUP BY ub.user_id;

-- Grant read access to authenticated users (each user queries their own row)
GRANT SELECT ON public.user_passive_effects TO authenticated;
GRANT SELECT ON public.user_passive_effects TO anon;
