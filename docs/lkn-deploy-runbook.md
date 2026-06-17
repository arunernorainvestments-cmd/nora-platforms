# Licensing Marketplace (lkn_) — Deploy Runbook

Pre-deploy checklist for doc5. **Do these in order, after this branch is merged to
`main`.** As of writing, the remote DB (`cceisywxwhgljdpisjrl`) is at migration
**106** — migrations 107–113 are NOT applied. Apply them through the normal
git-driven flow, not by hand, so the migration ledger stays consistent.

## 1. Apply migrations (107 then 108–113)

The remote is behind by 107 as well. Use your standard flow so the ledger records them:

```bash
# from the repo root, project linked (supabase link --project-ref cceisywxwhgljdpisjrl)
supabase db push        # applies 107, then 108–113 in order
```

Verify:

```sql
select version from supabase_migrations.schema_migrations order by version desc limit 8;
-- expect 113 at the top
select tablename from pg_tables where schemaname='public' and tablename like 'lkn_%' order by 1;
-- expect: lkn_agreement_events, lkn_agreements, lkn_api_call_log, lkn_api_keys,
--         lkn_license_templates, lkn_license_tiers, lkn_licensor_verifications,
--         lkn_listings, lkn_partners, lkn_public_registry
```

> Do NOT hand-run the migration SQL via the Management API query endpoint — that
> applies the DDL without recording it in `schema_migrations`, which then breaks the
> next `supabase db push`.

## 2. Create the private Storage bucket `lkn-partner-docs`

No client-accessible policies — partner docs are written/read by the service role only
(via `lkn-partner-apply` and staff review).

```sql
insert into storage.buckets (id, name, public)
values ('lkn-partner-docs', 'lkn-partner-docs', false)
on conflict (id) do nothing;
```

## 3. Signing keypair (ECDSA P-256)

Run **in your own secure environment** (not CI / not a shared sandbox):

```bash
./scripts/lkn-signing-key-setup.sh
```

It generates the keypair, writes the public key to
`flutter_app/web/.well-known/nora-public-key.pem`, prints the exact command to set
`NORA_SIGNING_PRIVATE_KEY` as an edge-function secret, and reminds you to back up and
shred the local private key. Commit the public key. `lkn-verify` degrades gracefully
(returns `signature: null`) until the secret is set, so this can be done before or
after function deploy.

## 4. Deploy the edge functions

Public endpoints use `--no-verify-jwt` (they authenticate via API key or are open):

```bash
supabase functions deploy lkn-verify           --no-verify-jwt
supabase functions deploy lkn-register-api-key  --no-verify-jwt
supabase functions deploy lkn-partner-apply     --no-verify-jwt
# auth (JWT-gated) endpoints:
supabase functions deploy lkn-register-licensor
supabase functions deploy lkn-create-listing
supabase functions deploy lkn-submit-template
supabase functions deploy lkn-purchase-license
supabase functions deploy lkn-revoke-license
```

Optional env: `LKN_PAYMENTS` (defaults to `sim`; set `live` only once Stripe Checkout
is wired into `lkn-purchase-license`).

## 5. Gateway / routing for api.noraplatforms.com

`lkn-verify` is documented as `GET https://api.noraplatforms.com/v1/verify`. Point that
host/path at the deployed function (Cloudflare route or Vercel rewrite →
`https://cceisywxwhgljdpisjrl.functions.supabase.co/lkn-verify`). The function reads
`license_id` / `licensee_nora_id` / `use_category` from the query string.

## 6. Smoke test

```bash
# register a key
curl -s -X POST https://<functions-host>/lkn-register-api-key \
  -H 'Content-Type: application/json' \
  -d '{"owner_name":"Test","owner_email":"t@example.com"}'
# -> { api_key: "lkn_live_...", ... }   (save it)

# verify (unknown id -> not_found, still 200)
curl -s "https://<functions-host>/lkn-verify?license_id=LKN-2026-NOPE" \
  -H "X-NORA-API-Key: lkn_live_..."
```

## Still outstanding (not blockers for the above)

- `lkn-generate-contract` — needs the attorney-seeded `lkn_contract_clauses` table
  (not yet created). Do not fabricate legal language.
- Flutter screens (doc5 §"Flutter Screens").
- CLAUDE.md: add the Licensing Marketplace section + Hard Rules 29–32.
