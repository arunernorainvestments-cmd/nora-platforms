# /.well-known/

`nora-public-key.pem` (the ECDSA P-256 **public** key for the licensing
verification API) belongs here. It is generated and installed by
`scripts/lkn-signing-key-setup.sh` — it is **not** committed yet because the
matching private key must be generated in a secure environment first (see the
script's header).

Once present, this file is served at:

    https://noraplatforms.com/.well-known/nora-public-key.pem

referenced by `lkn-verify` responses (`public_key_url`) so third parties can
verify the signature on a verification response.

Note: the signature is **raw IEEE-P1363** (64 bytes, base64), as produced by
WebCrypto ECDSA — not DER. Verifiers must account for that.

After `flutter build web`, confirm `.well-known/nora-public-key.pem` was copied
into `build/web/.well-known/`; if your Flutter version skips hidden dirs, copy it
into the build output (or a Vercel static dir) as part of the deploy.
