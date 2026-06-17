#!/usr/bin/env bash
# scripts/lkn-signing-key-setup.sh
#
# Generates the N.O.R.A. licensing-API signing keypair (ECDSA P-256) and installs it:
#   - private key  -> Supabase edge-function secret  NORA_SIGNING_PRIVATE_KEY  (PKCS8 PEM)
#   - public key   -> flutter_app/web/.well-known/nora-public-key.pem (served by Vercel)
#
# RUN THIS IN YOUR OWN SECURE ENVIRONMENT — never in a shared/ephemeral sandbox or CI
# log. The private key signs every verification response; back it up (password manager
# / secrets vault) BEFORE deleting the local copy. If it is ever lost, every signature
# already issued becomes unverifiable.
#
# Signature format note: lkn-verify uses WebCrypto ECDSA, which emits a RAW IEEE-P1363
# signature (64 bytes r||s), base64-encoded — NOT OpenSSL's DER. Third-party verifiers
# must treat it as P1363 (e.g. WebCrypto verify, or convert P1363->DER for OpenSSL).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WELL_KNOWN_DIR="$REPO_ROOT/flutter_app/web/.well-known"
PRIV="nora-signing-private.pem"
PUB="$WELL_KNOWN_DIR/nora-public-key.pem"

if [[ -f "$PRIV" ]]; then
  echo "Refusing to overwrite existing $PRIV — move it aside first." >&2
  exit 1
fi

echo "==> Generating ECDSA P-256 private key (PKCS8): $PRIV"
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$PRIV"
chmod 600 "$PRIV"

echo "==> Deriving public key (SPKI): $PUB"
mkdir -p "$WELL_KNOWN_DIR"
openssl pkey -in "$PRIV" -pubout -out "$PUB"

echo "==> Public key (safe to commit / publish):"
cat "$PUB"

cat <<EOF

Next steps (do these now):

1) Set the private key as a Supabase edge-function secret. Either:

   # via Supabase CLI (project must be linked):
   supabase secrets set NORA_SIGNING_PRIVATE_KEY="\$(cat $PRIV)"

   # OR via the Management API (replace TOKEN; runs against ref cceisywxwhgljdpisjrl):
   curl -s -X POST "https://api.supabase.com/v1/projects/cceisywxwhgljdpisjrl/secrets" \\
     -H "Authorization: Bearer \$SUPABASE_ACCESS_TOKEN" \\
     -H "Content-Type: application/json" \\
     -d "\$(jq -nc --arg v "\$(cat $PRIV)" '[{name:"NORA_SIGNING_PRIVATE_KEY", value:\$v}]')"

2) Back up $PRIV to your password manager / secrets vault.

3) Commit the public key:  git add $PUB && git commit
   Then verify it is reachable after deploy:
     curl https://noraplatforms.com/.well-known/nora-public-key.pem
   (Flutter web build must copy .well-known/ into build/web — confirm it appears there.)

4) Securely delete the local private key once backed up + secret is set:
     shred -u $PRIV   # or: rm -P $PRIV
EOF
