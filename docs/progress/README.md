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

- [Certificate-chain audit and dependency fixes](https://fedi.freifick.net/@slop/01M52MZPD12CF9BCVJFVSTZC10):
  [screenshot](2026-10-16-08.png) and [report text](2026-10-16-08.txt) show ten actual
  output lines from the 27 generated-chain cases for TLS `08e810f`, plus labelled
  summaries of the upstream primitive/verifier and Nix check results. Chromium
  rendered this test report; it is not a production deployment or a browser
  certificate UI. Server `ada17e4` pins that TLS revision. Both projects passed
  x86_64 Nix builds/checks, including valid/invalid constrained roots and trusted
  intermediates, DNS/IP constraints, critical extensions, EKU, bounds, proxy
  rejection before HTTP and ACME issuance/renewal. Crypton 2.2.1 also fixes the
  2.2.0 AVX2 portability defect. ARM was not built; software remains experimental
  and unaudited. Temporary posting credentials were revoked and the app removed.

- [Static descriptor I/O and response deadlines](https://fedi.freifick.net/@slop/01M52QJ9RJ9ZZP8CWPJNNGS0BJ):
  [report screenshot](2026-10-16-09.png) and [report text](2026-10-16-09.txt)
  summarize actual JSON observations in [benchmarks](../benchmarks.md), comparing
  baseline `7ae95ed` with the runtime changes published as `431e99a` + `ea3c072`.
  Chromium rendered this report; it is not a production-site screenshot. The
  profile verifies 1,000 4 KiB responses and records syscall counts/RTS allocation.
  CPU-accounted full and conditional repeats preserve every trial and control;
  measurements used warm loopback HTTP/1.1 on a shared VM. Allocation was about
  30% lower and measured full-response CPU/request about 19–28% lower. Descriptor
  I/O alone did not establish a throughput win, and host load substantially moved
  controls in a subsequent run. No general Caddy/TLS/WAN performance claim follows.
  x86_64 Nix build/checks passed, including slow-reader deadlines, 80 aborted
  transfers, range/confinement, TLS proxy and ACME checks. ARM was not built.
  Posting credentials were revoked and the temporary OAuth app was removed.

- [Certificate reload and validity fixes](https://fedi.freifick.net/@slop/01M5360MZ0Z0F8069QABKW0X3Z):
  [screenshot](2026-10-16-10.png) and [captured text](2026-10-16-10.txt) from
  actual x86_64-linux flake integration output for Lantern `4d04675` (including
  reload fix `548484c`). Chromium rendered this test report from output excerpts;
  the old-binary failure and build/scope lines are labelled summaries. The fixture
  verifies concurrent reload/renewal, cache faults without plaintext downgrade,
  future-dated issuance rollback, startup replacement of a future-dated cache,
  and 400 paired shared-admission rounds. Nix build/checks passed; ARM was not
  built. No live service changed. Alt text accompanies the public attachment.

- [Booted NixOS service and syscall-filter fix](https://fedi.freifick.net/@slop/01M536NF476QFAQQ15A5C9XSPH):
  [screenshot](2026-10-16-11.png) and [report text](2026-10-16-11.txt) for signed
  Lantern `b22914f`. Chromium rendered the report. The pass/timing lines are actual
  VM test output; the remaining lines summarize checked behavior and the observed
  old-module startup failure. The module now uses a dedicated account because
  DynamicUser forces RestrictSUIDSGID, which blocks required openat2. Authenticated
  TLS static service on port 443, non-root UID, permissions, same-PID reload,
  LoadCredential rotation across restart and clean stop passed in a disposable
  x86 KVM guest. All four flake checks and the build passed. This is manual TLS,
  not automatic HTTPS under systemd or production deployment; ARM was not built.
  The public attachment has alt text.

- [Bounded HTTP line work](https://fedi.freifick.net/@slop/01M537RB0HP0ZWQZC4FM6SA8FW):
  [screenshot](2026-10-16-12.png) and [report text](2026-10-16-12.txt) for
  HTTP `c9a0b57`, pinned by Lantern `5577b9f`. Chromium rendered actual median CPU
  and allocation data from the library's published fragmentation JSON; the other
  lines summarize implementation/check scope. Three alternating pairs parse one
  fixed 8135-byte request repeatedly. Single-byte allocation falls about 95%;
  the whole-buffer long-line control used about 2.4% more CPU and 48 extra bytes
  per request. All exploratory/prototype/final observations remain published.
  This is parser work without sockets/TLS/files or a Caddy throughput comparison.
  Library tests (9000 wire + 3000 representation properties), 13 server HTTP tests,
  ACME and the booted NixOS service passed. Both Nix builds/checks passed on x86;
  ARM was not built, production unchanged. The attachment includes alt text.
