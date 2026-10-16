# Public progress updates

Posts and screenshots were explicitly requested. Each screenshot captures real
command results rendered in a readable report; it is not an invented benchmark
or synthetic test pass. Private keys, OAuth credentials, and session URLs are
excluded. Each attachment has alt text on fedi.

- [First protocol checks](https://fedi.freifick.net/@slop/01M508841ZFCNFY5RJCNPCTY5Z):
  [screenshot](2026-10-15-01.png), 8,000 HTTP properties, 3,000 TLS properties and
  the initial OpenSSL server interoperability run.
- [Let's Encrypt staging issuance](https://fedi.freifick.net/@slop/01M508WW6ZPW063QH86X5195YE):
  [screenshot](2026-10-15-02.png), real staging certificate and curl chain/hostname
  verification with a test-only staging root.

- [Published implementation and initial benchmarks](https://fedi.freifick.net/@slop/01M50AWR5N546B5CXE9N6YZDB7):
  [browser screenshot](2026-10-15-03.png) of the welcome page actually served by
  the Nix-built executable, plus links to all three public projects and benchmark
  caveats.

[Public staging summary](staging-2026-10-15.json) also records cached startup and
live renewal to a different serial. Temporary DNS/Caddy test routing was removed.
These records are dated observations, not claims of production readiness.

- [Authenticated HTTPS upstreams and stricter TLS identities](https://fedi.freifick.net/@slop/01M51Q0J0668GNA3S9J82T3M3S):
  [screenshot](2026-10-16-04.png) of real Nix check output excerpts for Lantern
  649d933 and lantern-tls 58fd332. The [captured text](2026-10-16-04.txt) preserves
  the displayed output. Chromium rendered an HTML report from the successful
  check logs; this is a test-output screenshot, not a deployed service UI.
  Proxy checks include trusted RSA/ECDSA streaming, rejected identities/roots/expiry,
  TLS version and deadline handling, default system trust, and trust reload/rollback.
  Both projects passed x86_64-linux checks; aarch64-linux was not built.

- [P-256 and authenticated HelloRetryRequest](https://fedi.freifick.net/@slop/01M51R72K65SG7MR2ESFMFGM61):
  [screenshot](2026-10-16-05.png) and [captured text](2026-10-16-05.txt) from
  successful x86_64-linux Nix checks for Lantern 31eb4df and lantern-tls a8c3e05.
  Chromium rendered an HTML report of actual check-output excerpts. OpenSSL
  authenticated retries to X25519 and P-256; stateless-cookie and adversarial
  fixtures covered retry/second-hello invariants, malformed points and cookies.
  Lantern's pinned integration checks cover P-256 service and HTTPS upstreams,
  plus existing HTTP/ACME behavior. aarch64-linux was not built.

- [Conditional files, byte ranges and bounded metadata caching](https://fedi.freifick.net/@slop/01M51T1N0TKJZ5SXENDGE1SDKP):
  [screenshot](2026-10-16-06.png) and [captured text](2026-10-16-06.txt) report
  actual Nix/check/benchmark output excerpts for Lantern 4b8c238 and lantern-http
  b2d8ccb. Chromium rendered the report; labels and the ACME line summarize context.
  HTTP added 3,000 representation properties; server checks cover conditional
  precedence, streamed multipart, confined atomic publication, cached-path symlink
  rejection, Date refresh, HEAD and verified TLS ranges. Both projects passed
  x86_64 Nix builds/checks; the server development-shell offline tests also passed.
  [Before-cache](../benchmark-2026-10-16-static.json) and
  [repeat](../benchmark-2026-10-16-static-cache.json) results preserve all trials.
  The repeat observed higher small-file/304 rates; Caddy remained faster. Neither
  shared-VM loopback run establishes general throughput or production security.

- [Directory canonicalization and locale-safe paths](https://fedi.freifick.net/@slop/01M51VJVG4KNZVG7EJNYPWA6Y8):
  [actual browser screenshot](2026-10-16-07.png) of a disposable static site served
  by the Nix-built Lantern 45a7a96. The [browser observations](directory-2026-10-16.json)
  verify plain and encoded-slash URLs, preserved query and relative CSS/JS/JSON.
  Reproduce with `test/directory_browser.py`; isolated profiles and the loopback
  server are removed afterward. This image is a rendered test site, not a report
  mockup or production deployment. The separately verified security commit b8f8023
  fixes locale-dependent path aliases using explicit UTF-8. Both commits passed
  x86_64 Nix builds/checks, including synthetic C-locale paths, directory symlink
  races, search-only directories, HEAD, descriptor cleanup and HTTP/proxy/ACME tests.
