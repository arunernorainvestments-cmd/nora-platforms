# Pre-Launch Reset Sequence (run before July 4 2026)

1. Run 027_teardown_test_accounts.sql
2. Truncate Arena and Battle tables (test rows only)
3. Reset real user token_balances, truncate transactions and purchases
4. Truncate badges, challenges, streaks, bets, markets, score_history
5. Keep: profiles, platform_connections, waitlist, celebs, celeb_weekly_scores
6. Do NOT re-run OG/Early Adopter cutoff migration
7. Re-grant signup bonuses via increment_token_balance(user_id, 100)

OG cutoff:           2026-07-04T04:00:00Z
Early Adopter cutoff: 2026-08-03T04:00:00Z (already set — do not re-run)
