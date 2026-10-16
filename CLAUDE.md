# Lantern
- Experimental Haskell webserver, public MIT: https://git.freifick.net/slop/lantern.
- HTTP and TLS are independent pinned public projects lantern-http and lantern-tls;
  never replace them with a third-party protocol stack. Cryptographic primitives and
  client PKIX verification stay in Crypton. ACME is implemented here, without helpers.
- Source map: Config (Lanternfile), Server (routing/proxy/admission/lifecycle),
  HTTP transport adapters in Transport/Client, ACME + bounded JSON, Files + cbits/confine.c.
- Nix: nix build; nix flake check. Checks run package/config, isolated HTTP + local ACME,
  and NixOS module evaluation. nix develop exposes compiler, cabal, Python, OpenSSL,
  wrk, Caddy. Independent libraries have their own checks.
- Default loopback 127.0.0.1:8080. No live production service installed. Do not replace
  the host Caddy without an explicit migration task.
- Reload routes/headers/manual credentials via SIGHUP. SIGTERM drains for 10 seconds.
  SIGUSR1 forces ACME renewal. Listener/limits/TLS mode/auto hostnames need restart.
- Private ACME state (one process/dir, 0700/0600) must never enter git or the Nix store.
- Safety invariants: parser errors close connections; no response after partial commit;
  64 MiB global request-body reservations; openat2 confinement with no unsafe fallback;
  forwarding identity overwritten; fresh upstream connection per request; failed reload
  and renewal keep working state. Document intentional protocol gaps.
- Test keys, roots, and fixtures are synthetic and temporary. Staging was tested on
  2026-10-15; temporary DNS/Caddy routing was removed afterwards.
- Progress posts with screenshots are authorized for this task; use real evidence,
  no secrets/session links, and alt text. Log published post links in docs/progress.

- ACME URL parser preserves original JWS URLs, compares hostnames case-insensitively,
  handles query-only targets and IPv6 authorities, and rejects malformed escapes.

- Reverse proxies support fixed HTTP or authenticated HTTPS endpoints. Global
  proxy_ca_bundle replaces roots only for upstream TLS, resolved config-relative,
  loaded once per routing snapshot and refreshed on SIGHUP. Bundle-path changes
  require restart; failed refresh preserves the prior routes and trust roots.
- test/https_proxy_test.py uses disposable Python/OpenSSL peers for successful
  RSA/ECDSA streaming and trust/name/expiry/version rejection; it sends no live traffic.

- The pinned TLS library supports X25519/P-256 ECDHE and one HelloRetryRequest;
  retries retain the original deadline and authenticated transcript. HTTP/TLS
  integration checks both P-256 downstream service and P-256-only upstreams.

- Static requests use lantern-http's Representation helpers for conditions/ranges.
  Same-descriptor stat/stream metadata, weak metadata ETags and Last-Modified;
  never claim strong byte identity. If-Range with these validators falls back 200.
- Max 16 range elements, overlap/adjacency coalescing, streamed multipart with
  Crypton random boundaries/exact lengths; HEAD ignores Range. Static validator/
  range headers are reserved. Configured Content-Encoding disables ranges.
- test/static_test.py checks real HTTP/TLS conditions, multipart framing/reuse,
  numeric bounds, confined ranges and atomic metadata/body publication races.
- Benchmark --conditional also measures each server's own verified ETag/304 path;
  response_body_bytes distinguishes avoided file bytes from delivered bytes.

- A StaticCache in each routing snapshot holds at most 256 derived metadata entries
  plus a Date value per UTC second; every hit still follows confined open/fstat.
  No file bytes/FDs are cached. Keys include inode/device, size, high-res mtime/ctime,
  media/config headers (no retained URI spellings). Reloads start fresh; ACME credential renewal preserves
  the current cache/routes. Do not infer stronger ETag guarantees from caching.

- Filesystem FFI paths must use explicit UTF-8 (withUTF8Path), never locale-based
  withCString for URL/config paths: LC_ALL=C can discard characters after checks.
  test/path_encoding_test.py exercises exact Unicode paths and hidden/dot-prefix
  non-aliasing under a C-locale child server, including Unicode config/root paths.
  CLI/config loading fixes filesystem encoding to UTF-8. NUL bytes remain rejected.
