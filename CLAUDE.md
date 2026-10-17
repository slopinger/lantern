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

- Confined directory observations return Nothing from withFileBelow; regular
  callbacks return Just. Redirect nonslash GET/HEAD URLs with directoryRedirect,
  preserving escaped path/query and adding a literal slash. Slash requests still
  select index.html, which must be regular; never redirect an invalid index loop.
- EACCES may trigger a same-policy O_PATH directory probe for search-only dirs.
  It does not read regular files or follow symlinks. All probe descriptors close.
- Static tests include directory canonicalization, relative assets, query/Unicode/
  encoded-slash cases, HEAD reuse, descriptor cleanup and directory symlink races.

- TLS security dependency update uses the TLS flake's lib.cryptoPackages for the
  server build and dev shell, keeping Crypton 2.2.1/ram types consistent. Proxy
  tests include invalid name constraints, critical extensions and issuer EKU,
  requiring 502 without forwarding HTTP. No live deployment is changed.
- HTTPS proxy tests also offer 1024-bit issuer and 2047-bit leaf RSA keys through
  an independent test peer; both must return 502 without forwarding HTTP. The TLS
  dependency checks exact modulus bits and certificate signature algorithms.

- Static streaming borrows an opaque RegularFile descriptor inside withFileBelow.
  readFileChunk uses bounded (<=64 KiB) POSIX fdReadBuf through the established
  unix package; seekFile uses checked absolute FileOffset conversion. No Handle
  conversion, file-byte cache, FD cache, or change to openat2 confinement. Preserve
  per-request same-descriptor metadata and exception-safe closeFd cleanup.
- test/static_test.py checks descriptor cleanup after 80 interrupted sparse-file
  transfers. test/profile_static.py verifies 1000 4 KiB responses and records strace
  counts plus RTS stats; timing under tracing is not a throughput result. strace
  is available in nix develop. Keep profiling separate from wrk measurements.
- The ACME fixture permits 30 seconds for initial key generation/issuance before
  the HTTPS listener opens. Ordinary fixture startup remains four seconds; tests
  include server output on readiness timeout. Production deadlines are unchanged.
- Response output uses one absolute deadline around dispatch; raw header/chunk
  writes do not register nested per-chunk timers. Error and HTTP-01 responses
  each have a whole-response deadline too; 100-continue retains its bounded
  interim write and a partial failure forbids further responses. The slow-reader
  static test verifies the file closes despite ongoing client progress.
- The benchmark records process user+system ticks per reported request, including
  server threads, and --conditional-only measures 304s without bulk-load trials.
  Shared-VM throughput varied substantially, including Caddy controls; preserve
  raw trials and report the actual workload/CPU metric, not a general speed claim.

Connection admission is atomic across the main and HTTP-01 listeners: the stopped
flag, capacity check, worker creation and registration share the registry lock.
Worker cleanup cannot overtake registration. A socket rejected or interrupted
before transfer of ownership closes; accepted workers own closure and removal.
The ACME fixture tests 400 paired HTTP/TLS arrivals at max_connections=1, requiring
at most one peer to receive protocol bytes and continued successful admissions.

- CLI help aliases (-h/--help/help), --version, run/check --config FILE (also
  --config=FILE), and -- FILE are supported. Ordinary positional/default config
  paths remain supported; dash-prefixed names use -- or --config. Main preserves
  ExitCode, handles startup/check SIGINT as 130 and
  rethrows other asynchronous exceptions. Expected errors omit GHC backtraces;
  stdout/stderr and filesystem arguments are explicitly UTF-8.
- test/cli_test.py is in flake integration: real run/stop, argument/error status,
  C-locale Unicode diagnostics, interrupting a pending config read, and check with
  an occupied port/observed dummy CA and no state creation. Runtime config/read
  validation and the server's graceful SIGINT/SIGTERM behavior remain enforced.

Automatic-mode reload stages routes/trust/cache only. It atomically preserves the
current in-memory credentials rather than re-reading the ACME disk cache; renewal
atomically replaces credentials while preserving the latest routing/trust/cache.
Missing, stale or malformed cached certificate files cannot clear or roll back
active credentials during SIGHUP. TLS-mode listeners fail closed if credentials
are unavailable; only plain mode and the HTTP-01 listener select plain transport.
The ACME fixture pauses reload in trust-file I/O while renewal activates, then
checks the new certificate and new routes both survive, plus cache-fault cases.

ACME checks both leaf validity bounds before activation and before cached startup
(`notBefore <= now < notAfter`). Future-dated downloads retain the active and
persisted chain and enter normal retry backoff. A future-dated cache triggers
initial acquisition before the HTTPS listener opens. Renewal considers a
not-yet-valid cache due. The synthetic CA fixture issues a future-dated leaf
with the correct site key to test both renewal rollback and startup replacement.
These checks do not claim a full ACME-issued chain policy audit.

ACME requires the downloaded leaf SAN set to match the configured DNS identifiers
exactly, ignoring ASCII case/order. Wrong, extra, duplicate, wildcard or non-DNS
identifiers, absent/malformed/duplicate SAN extensions are rejected before disk
publication. Cached identity mismatches trigger acquisition before HTTPS opens.
The TLS PKI helper uses the retained X.509 decoder; no primitives are rewritten.
The local CA fixture covers incorrect issuance rollback and wrong-name cache
replacement, plus successful uppercase SAN issuance. This is not full chain trust
verification of the downloaded certificate.

- nix/service-test.nix boots the actual exported NixOS module in a disposable
  1 GiB guest (KVM/native builder required). Runtime-only synthetic manual TLS
  credentials, dedicated-user/low-port TLS, private paths, same-PID reload,
  LoadCredential source rotation across reload/restart and clean stop are checked
  with authenticated curl. No host ports/services are changed. Run
  `nix build .#checks.x86_64-linux.service -L`; flake checks also include it.
  This is manual-TLS module testing, separate from the local ACME fixture.

The module uses a dedicated static system account because systemd's
`RestrictSUIDSGID` seccomp filter blocks `openat2` with ENOSYS; `DynamicUser`
forces that filter on. The boot fixture reproduced the old module exiting
before listening. `RestrictSUIDSGID` is disabled; NoNewPrivileges, RemoveIPC,
strict read-only filesystem protection, private state/tmp/devices, capability
bounds and resource limits remain enabled. There is no unsafe filesystem
fallback. See [systemd's upstream discussion](https://github.com/systemd/systemd/issues/38711).

- Shared endpoint parsing validates DNS label syntax/length and actual bracketed
  IPv6 literals (retained iproute decoder, also used by the TLS library). Bracketed
  DNS/IPv4, malformed IPv6, zone IDs and IPvFuture are rejected. Endpoints require
  explicit ports; the ACME URL layer supplies its HTTPS default before validation.
  Automatic-mode run validates the complete CA URL before creating state or
  binding HTTP-01, matching check. CLI regression uses an occupied HTTP port to
  prove invalid CA syntax is diagnosed first, with no state directory created.

HTTP line parsing uses the independent library's bounded fragment accumulation
and new-byte/CRLF-boundary search, avoiding quadratic prefix copying/scanning.
Complete-buffer lines retain a direct slice path. Error/cancellation requires
connection closure; deadlines and admission are still mandatory. The HTTP flake
adds exact/overflow line and irregular request/body/pipeline regressions (12000
wire properties plus 3000 representation cases). See the library's fragmentation
report for raw parser CPU/allocation trials and the coalesced-control tradeoff.

The pinned HTTP library scans request targets with checked indices rather than
allocating a byte list. Grammar and raw escapes are unchanged. An independent
previous-policy oracle covers all single-octet suffixes, percent boundaries and
3000 generated fragmented requests; long pipeline tests use varied target bytes.
Current library totals are 12000 wire plus 3000 representation properties.

Automatic HTTPS accepts DNS identifiers only. All-numeric dotted site names
(including IPv4 and legacy/zero-padded spellings) fail configuration validation
before state creation, binding or CA requests. Numeric labels inside a DNS name
remain valid. This restriction is automatic-mode-only; plain/manual site parsing
keeps its existing numeric-host support. CLI regression observes an occupied
HTTP port and dummy CA to verify diagnostic ordering and absence of side effects.

Redirect URLs and response header names must be ASCII before Char8 conversion.
Reject non-ASCII input rather than projecting each code point to its low byte;
this prevents silent aliasing (for example Ł -> A). Redirects may contain literal
ASCII percent escapes. Response bodies and header values still encode UTF-8.
Config tests retain representative Unicode projection failures and positive
UTF-8/escaped values; CLI UTF-8 diagnostic handling is checked separately.

The pinned TLS client validates original reference input before case normalization
or IP parsing: bounded printable ASCII DNS A-labels/IP literals only, no spaces
or controls. This prevents Unicode fold aliases and whitespace-tolerant IP reads.
The server config already requires ASCII endpoint names; the independent TLS
String API now enforces the same input profile. IDNA conversion belongs to the
caller. TLS tests cover two fold aliases, ASCII/A-label/IP success, and nine
invalid inputs emitting no ClientHello. No cryptographic primitive changed.

Request admission also shares the registry's stop boundary on existing sockets.
A complete header admitted before SIGTERM may finish; valid later headers fail
503 before body/100-continue/dispatch. Responses committed during drain advertise
Connection: close, and completion does not consume a buffered next request.
Headers already committed before stop cannot be changed. Idle readers close
promptly; admitted requests retain the drain deadline. The shutdown fixture holds a real upstream
response, proves listener closure, rejects new idle-keepalive work, completes the
active response and checks the queued pipeline request is not dispatched.

The connection registry tracks admitted-request versus idle/header/handshake
phase under the stop lock. Shutdown closes idle/header/handshake sockets promptly,
while admitted requests drain. Request admission and return-to-idle are atomic
with that classification, so stop cannot close a newly admitted active request.
Late requests may see EOF/reset rather than 503; no new work or 100-continue is
admitted. An idle-only fixture with a 30-second header timeout verifies process
exit within two seconds instead of consuming the ten-second grace. The held
upstream/pipeline fixture still verifies active completion and no queued work.

Idle shutdown records the established transport close action under the registry
lock. It sends TLS close_notify before closing idle sockets; handshakes without
a transport close directly. Closers run concurrently, with a one-second TLS
finish deadline, so slow idle peers do not serialize the grace period. A real
Python/OpenSSL peer with ragged EOF suppression disabled verifies authenticated
TLS closure, alongside the plain idle and active/pipelined drain tests.

The pinned TLS library tracks read and write closure separately: finishing a
transport closes its write direction once; authenticated peer EOF does not
automatically close writes. The server uses lantern-http readRequestMaybe to
finish cleanly at a request boundary without emitting HTTP 400 after a peer
close. Partial request EOF still fails. Tests cover plain TCP half-close and an
OpenSSL TLS unwrap after a complete keepalive response, plus idle stop/draining.

Pinned HTTP response parsing rejects Transfer-Encoding on HTTP/1.0 status lines,
including HEAD/304 and informational paths. The proxy fixture previously saw
200/304; now these faulty upstream messages produce 502 before downstream commit.

- Prioritize usable server features and Caddy-like setup; tests should support
  those features rather than continually extending protocol edge-case coverage.
- Quickstart commands: serve [DIRECTORY] and proxy UPSTREAM_URL, default loopback
  HTTP without a Lanternfile. --domain plus --email enables automatic HTTPS on
  [::]:443; --staging selects testing CA; --state-dir overrides XDG data state.
  Shared configuration parsing/resolution and runWith avoid temporary files or
  a second runtime. SIGHUP refreshes fixed quickstart settings. site * is a
  fallback after exact host lookup; automatic HTTPS still requires DNS names.
Quickstart automatic file serving rejects state inside the canonical document
root before creating state or contacting the CA. Prefer separate production and
staging directories. Explicit public bind/domain flags retain their usual effects.

- Path routing: handle /exact or /prefix/* { ACTION }; optional one default action.
  Longest raw escaped path match, exact before equal-length prefix; query excluded
  from matching and preserved upstream. No stripping, normalization or nesting.
  Max 128 unique patterns/site; shared headers validated against every leaf.
  Recursive root resolution and proxy trust detection cover handler actions.
  Missing route/default returns 404. ACME HTTP-01 dispatch bypasses path routing.
  Routes reload within existing snapshots; quickstart remains unchanged.

- Test maintenance: keep user-visible feature checks and known-bug regressions.
  Removed duplicate socket fragmentation matrix (the independent HTTP library
  controls fragments directly), duplicate CLI Unicode wire-field checks, and
  repeated endpoint/numeric startup matrices. One startup side-effect fixture
  retains representative invalid endpoint and DNS-identifier cases. Unicode
  projection checks use actual regression characters instead of 256 combinations.
