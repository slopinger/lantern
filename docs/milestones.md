# Lantern milestone log

Dated milestones for Lantern, lantern-http and lantern-tls, moved here from the
server-wide notes (`~/CLAUDE.md`) on 2026-10-17. Each entry records what changed,
the signed commits and the verification that ran at the time. Commit IDs refer to
https://github.com/slopinger/lantern, lantern-http and lantern-tls. Newer entries are
at the bottom.

- Lantern follow-up (2026-10-16): ACME HTTPS URL handling now preserves signed URL
  bytes while normalizing origin host case, supports query-only paths and IPv6
  Host authorities, and rejects malformed percent escapes. Regression checks live
  in `~/src/lantern/test/Config.hs`; no live service configuration changed.

- Lantern HTTPS upstream work (2026-10-16): fixed HTTP(S) reverse-proxy endpoints,
  proxy-only `proxy_ca_bundle` loaded with the routing snapshot and refreshed on
  SIGHUP; failed reload preserves prior roots/routes. lantern-tls now uses an
  explicit SAN-only DNS/IP identity hook, omits SNI for IP literals, and keeps
  certificate-chain/time/purpose verification in Crypton. Loopback HTTPS proxy
  regressions are in `test/https_proxy_test.py`; no live deployment changed.

- Lantern HTTPS upstream milestone verified/published: signed server commit
  `649d933` pins signed TLS commit `58fd332`; x86_64 `nix build`/flake checks passed
  for both, including HTTPS proxy identity/trust/reload/deadline regressions and
  OpenSSL client/server interoperability. Fedi screenshot update:
  https://fedi.freifick.net/@slop/01M51Q0J0668GNA3S9J82T3M3S (evidence in docs/progress).

- Lantern TLS negotiation milestone (2026-10-16): signed `lantern-tls` commit
  `a8c3e05` adds X25519/P-256 negotiation and one authenticated HelloRetryRequest
  in both roles (client cookies included). Signed server commit `31eb4df` pins it
  and verifies P-256 downstream/upstream paths. Both x86_64 Nix builds/flake checks
  passed, including OpenSSL retries, adversarial wire peers and HTTP/ACME checks.
  Screenshot progress post: https://fedi.freifick.net/@slop/01M51R72K65SG7MR2ESFMFGM61.
  Production Caddy/services were not changed; temporary posting credentials revoked.

- Static transfer milestone (2026-10-16): signed `lantern-http` commit `b2d8ccb`
  adds conditional/date/range/multipart helpers and 3,000 representation properties
  (11,000 HTTP wire/representation properties total). Signed server `95a8573` pins
  it; `4b8c238` adds bounded derived-header caching with per-second Date refresh.
  x86_64 Nix builds/checks passed for HTTP and server, including six static tests,
  verified TLS ranges, atomic publication/confinement, proxy and local ACME checks.
  Reproducible full/304 comparisons against Caddy are in the server docs; these
  remain loopback measurements, not general performance or production-security proof.

- Static benchmark follow-up: server `4b8c238` passed Nix build/flake checks and
  `nix develop -c cabal test --offline`. Repeat warm-loopback medians were 3,547.7
  requests/s for 4 KiB files and 4,673.6 for conditional 1 MiB responses (no body).
  Full 1 MiB throughput was 495.6 MiB/s; Caddy remained faster. Raw before/repeat
  artifacts and limits are in docs/benchmarks.md. Public screenshot post:
  https://fedi.freifick.net/@slop/01M51T1N0TKJZ5SXENDGE1SDKP. Temporary posting
  credentials were revoked/removed; no production service or Caddy config changed.

- Lantern UTF-8 path security fix (2026-10-16): signed `b8f8023` was built and
  flake-checked as an exact Git revision before publishing, independently of the
  directory-routing work in progress. A synthetic C-locale hidden-file alias was
  reproduced before the fix and rejected afterwards. No live Lantern service is
  deployed; production Caddy was not changed.

- Lantern directory milestone (2026-10-16): signed `45a7a96` passed x86_64 Nix
  build/flake checks including eight static tests and the locale regression.
  Optional `python test/directory_browser.py --binary ./result/bin/lantern --out /tmp/directory.png`
  uses installed Chromium, isolated profiles and a disposable loopback fixture.
  Real plain/encoded-slash browser checks loaded relative CSS/JS/JSON. Source and
  evidence are in test/directory_browser.py and docs/progress/directory-2026-10-16.json.
  Screenshot post: https://fedi.freifick.net/@slop/01M51VJVG4KNZVG7EJNYPWA6Y8.
  Temporary posting credentials revoked; production Caddy/services unchanged.

- Lantern certificate audit (2026-10-16): signed/pushed TLS commit `08e810f`
  replaces vulnerable crypton-x509-validation 1.6.14 with 1.10.0 plus an explicit
  constraint-inheritance policy patch, and upgrades the coherent primitives to
  Crypton 2.2.1 (2.2.0 has a global AVX2 portability defect). x86_64 TLS Nix build
  and flake checks passed, including 27 generated-chain cases; upstream primitive
  tests passed 3,714 examples and verifier tests passed 873 cases. The added policy
  enforces DNS/IP ancestor constraints, EKU and extension bounds; unsupported
  constraint types fail closed. Signed/pushed server commit `ada17e4` pins the
  corrected TLS and shared primitive package set; x86_64 Nix build/checks passed,
  including proxy 502/no-forwarding and ACME issuance/renewal regressions.
  Screenshot post: https://fedi.freifick.net/@slop/01M52MZPD12CF9BCVJFVSTZC10;
  report/screenshot provenance is in lantern/docs/progress. Posting credentials
  were revoked and the temporary app removed. ARM was not built.
  No live service changed; this remains experimental and unaudited.

- Lantern algorithm audit (2026-10-16): signed TLS `b0cfe75` and server `7ae95ed`
  are published. Fixtures reproduced sub-2048-bit RSA issuer/leaf acceptance and
  acceptance of inconsistent outer PSS MGF/salt fields. CertificatePolicy now
  enforces exact modulus/exponent bounds and an explicit modern signature list;
  CertificateEncoding uses established ASN.1 primitives to validate raw algorithms
  before X.509 decoding discards PSS fields. This applies outside Nix too; no
  signature/arithmetic primitive is rewritten. All 43 generated-chain cases and
  both x86_64 Nix builds/checks passed, including weak upstream 502/no-forwarding,
  stronger mixed-key chains, inherited constraints and ACME issuance/renewal.
  The own client also authenticated a read-only Let's Encrypt staging directory
  request with system trust. ARM was not built; no live deployment changed.

- Lantern static I/O milestone (2026-10-16): signed/pushed `16123ea` adjusts only
  initial ACME fixture readiness (30 seconds for provisioning; ordinary startup
  remains 4 seconds), `431e99a` uses per-request opaque regular FDs with bounded
  POSIX reads/checked seeks, and `ea3c072` shares absolute response deadlines
  across headers/chunks. openat2, same-FD metadata and cleanup are preserved.
  Full x86_64 Nix build/checks passed, including 80 aborted transfers, slow-reader
  deadline enforcement, static/range/confinement/TLS proxy/ACME regressions.
  Heap allocation for 1000 verified 4 KiB responses fell from 68,551,056 to
  48,053,904 bytes in profiles. Full-response CPU/request was about 19–28% lower
  in warm loopback repeats; conditional CPU/request about 11–18% lower. Shared-VM
  controls varied substantially; descriptor I/O alone showed no clear throughput
  gain. All trials, controls and profiling methodology are in docs/benchmarks.md.
  test/profile_static.py and benchmark.py --conditional-only are reproducible via
  nix develop (now includes strace). Screenshot post/provenance:
  https://fedi.freifick.net/@slop/01M52QJ9RJ9ZZP8CWPJNNGS0BJ, docs/progress.
  Temporary posting credentials were revoked/app removed. ARM was not built;
  no live service changed and Lantern remains experimental/unaudited.

- Lantern admission fix (2026-10-16): signed commit `60f274c` serializes the
  stopped/capacity check, worker creation and registration across the main and
  HTTP-01 listeners. The previous code reproduced two active peers at a configured
  limit of one on the first paired test. Final x86_64 Nix build/checks passed,
  including 400 simultaneous HTTP/TLS arrival pairs at max_connections=1 and a
  verified HTTPS request after the cancelled handshakes. Parent interruption or
  rejection closes unowned sockets; workers own closure/removal after admission.
  ARM was not built, and no live service changed.

- Lantern CLI update (2026-10-16): signed/pushed `fa6d5c6` adds help aliases,
  a validated standalone starter configuration in help, --version, run/check
  --config FILE / --config=FILE and -- FILE. Expected failures print concise
  diagnostics without catching their own ExitFailure as an error; ExitCode is
  preserved, startup/check Ctrl-C exits 130, other async exceptions rethrow.
  Filesystem arguments and stdio use UTF-8, including C-locale diagnostics.
  Eight CLI tests and full x86_64 Nix build/flake checks passed: real serving/stop,
  read-only check with an occupied port/observed dummy CA and no state creation,
  Unicode errors, help-example validation and interrupting a blocked config read.
  Running-server graceful signal handling remains current. ARM was not built;
  no live service changed and the server remains experimental/unaudited.

- Lantern reload security fix (2026-10-16), signed commit `548484c`:
  automatic routing reload preserves the latest in-memory TLS credentials at
  atomic publication; TLS listeners fail closed if credentials are unavailable.
  The regression reproduced plaintext downgrade on the old build. `nix build`
  and `nix flake check` passed on x86_64-linux, including concurrent renewal/reload,
  missing/stale/malformed certificate caches and 400 shared-admission rounds.
  Published to GitHub. No live service changed; ARM was not built.

- Lantern ACME leaf-validity fix (2026-10-16), signed `4d04675`, published
  to GitHub: downloads and cached startup enforce both validity bounds;
  future-dated renewal preserves active/disk credentials and persists backoff.
  Synthetic-CA regression reproduced activation on the old binary, then passed
  renewal rollback and cached-startup replacement after the fix. x86 Nix build
  and flake checks passed; ARM unbuilt. Progress screenshot/post:
  https://fedi.freifick.net/@slop/01M5360MZ0Z0F8069QABKW0X3Z
  Temporary posting token revoked and its OAuth app deleted. Production unchanged.

- Lantern ACME identity fix (2026-10-16): TLS `5a5cd1b` provides bounded exact
  DNS SAN consistency checks using the retained X.509 decoder; Lantern `e32fb99`
  pins it and checks downloads/cached startup. Wrong/extra/wildcard/duplicate/
  missing/non-DNS/malformed SAN issuance retains active and disk credentials with
  backoff; a mismatched cached identity requires acquisition before HTTPS opens.
  Uppercase exact DNS SANs are accepted. The old executable activated the fixture's
  correct-key wrong-name leaf; all new cases passed after the fix. Both projects
  passed x86 Nix builds/checks and were signed/pushed to GitHub.
  ARM was not built; this consistency check is not full issued-chain verification.
  Production services remain unchanged.

- Lantern NixOS service fix (2026-10-16), signed `b22914f`, published to both
  GitHub: DynamicUser/RestrictSUIDSGID blocked required openat2 with
  ENOSYS, reproduced in a real booted guest. The module now creates a dedicated
  `lantern` system user/group and disables that filter; NoNewPrivileges, RemoveIPC,
  read-only filesystem protection, private state/tmp/devices, capability and
  resource limits remain. Startup diagnostics mention syscall policy as well as
  kernel support. A new flake check boots a 1 GiB disposable NixOS guest and checks
  authenticated TLS static files on port 443, UID/permissions, same-PID reload,
  systemd credential rotation across restart, and clean stop (57.53 seconds).
  `nix build` and all four x86 flake checks passed; ARM was not built. Run
  `nix build .#checks.x86_64-linux.service -L` (native KVM builder). Manual-TLS
  systemd path tested; automatic ACME remains a separate integration fixture.
  No host production service changed. Screenshot/report and public progress:
  https://fedi.freifick.net/@slop/01M536NF476QFAQQ15A5C9XSPH
  Temporary posting token revoked and its OAuth app deleted.

- Lantern endpoint/startup validation (2026-10-16), signed `5cb34df`, pushed to
  GitHub: shared endpoint parsing now checks actual bracketed IPv6
  (retained iproute decoder) and bounded DNS labels. Bracketed DNS/IPv4, malformed
  IPv6/labels, zone IDs and IPvFuture are rejected. Automatic-mode run validates
  the complete CA URL before state creation or HTTP-01 binding, matching check.
  The old executable reported malformed endpoints valid and run reached an
  occupied listener instead of a syntax error. New CLI check/run regressions
  verify syntax diagnostics first and no state creation; shared parser vectors
  include IPv4-mapped IPv6 and port/name boundaries. `nix build` and all four x86
  flake checks passed, including nine CLI tests and the booted NixOS service
  (54.64 seconds). ARM was not built. No live production service changed.

- HTTP fragmentation cost (2026-10-16): signed `lantern-http` `c9a0b57` replaces
  quadratic prefix append/search with bounded fragment accumulation and new-byte
  CRLF scanning. Completed lines concatenate once after size checks; pending
  fragment nodes are bounded by pending bytes. Parse failure/cancellation still
  requires closure. Exact/overflow/bare-newline/pipeline regressions and 1000
  long irregular-split cases bring the library to 9000 wire + 3000 representation
  properties. A reproducible Cabal benchmark and docs/fragmentation.md plus raw
  JSON preserve initial/control/prototype/final measurements: three alternating
  pairs of 8135-byte requests show ~95% less single-byte-fragment allocation;
  coalesced long-line control uses ~2.4% more CPU and 48 extra bytes/request.
  This is CPU/total-allocation parser work, not network throughput or peak RSS.
  Lantern signed `5577b9f` pins the library and adds an actual long-line/pipeline
  socket regression; all 13 HTTP tests, ACME and the booted service passed.
  Both projects passed x86 Nix builds/checks and were pushed to GitHub.
  ARM unbuilt; production unchanged. Progress screenshot and raw-data provenance:
  https://fedi.freifick.net/@slop/01M537RB0HP0ZWQZC4FM6SA8FW
  Temporary posting token revoked and its OAuth app deleted.

- HTTP target allocation (2026-10-16): signed lantern-http `9179c61` uses a
  bounds-checked ByteString index scan rather than B.unpack. Grammar/raw escapes
  are unchanged; tests retain the previous list policy as an independent oracle,
  enumerate all single-octet suffixes/escape edges, and add 3000 generated
  fragmented target cases. Varied long-target patterns expose byte reordering.
  Totals are now 12000 wire + 3000 representation properties. The unchanged
  benchmark helper, source/helper hashes and every trial are in target-scan.md
  and target-scan-2026-10-16.json: three alternating pairs for 10000 coalesced
  8135-byte requests use 3,292,484,144 -> 13,204,144 allocated bytes and median
  process CPU 1.038380 -> 0.737323 s (~99.6%/~29% reductions). This unusually
  long-target parser case is not ordinary-server throughput, TLS/files, peak RSS
  or a Caddy comparison. No generic fast-server claim follows from it.
  Lantern signed `5498d8f` pins it; both Nix builds/checks passed, including all
  server HTTP/ACME tests and the booted NixOS service. Both repos were pushed to
  GitHub. ARM unbuilt; no production service changed.

- Lantern automatic identifier validation (2026-10-16), signed `ff63984`, pushed
  to GitHub: the DNS-only ACME profile rejects all-numeric dotted site
  names (IPv4, legacy/zero-padded spellings) before state, binding or CA requests.
  RFC 8738 IP issuance remains unimplemented; numeric labels inside DNS names
  are accepted and plain/manual parsing is unchanged. The old check admitted
  these inputs. Unit and real CLI check/run regressions verify diagnostics first
  against an occupied HTTP listener and observed dummy CA, with no state creation.
  `nix build` and all four x86 flake checks passed, including ten CLI tests,
  thirteen HTTP tests, ACME and the booted NixOS service (56.68 s). ARM unbuilt;
  no production service changed.

- Lantern ASCII config boundaries (2026-10-16), signed `566b9f8`, pushed to
  GitHub: redirect URLs and header names reject Unicode before Char8
  conversion. The old binary was observed on loopback emitting `/A` for `/Ł`
  and `x-a` for `X-Ł`. New parser diagnostics include a source line; bodies/header
  values still encode UTF-8 and ASCII percent escapes remain untouched. Tests
  enumerate 128 projection characters for each field and verify positive values
  plus real check/run errors. `nix build` and all four x86 flake checks passed
  (eleven CLI tests, thirteen HTTP tests, ACME and booted NixOS service, 61.07 s).
  ARM unbuilt; no production service changed.

- TLS reference input fix (2026-10-16): signed lantern-tls `66fd305`, pinned by
  signed Lantern `c3f3e49`, both published to GitHub. Original String input
  must be bounded printable non-space ASCII before lowercasing/IP parsing. Old
  loopback runs authenticated K.example.test as k.example.test and İ.example.test
  as i.example.test with ASCII SNI and HTTP sent. IDNA conversion is caller-owned;
  nine invalid references now emit zero ClientHello bytes. ASCII case/A-label/IP
  positives and independent TLS vectors/PKIX/interop/adversarial checks passed.
  tls-fetch reads argv explicitly as UTF-8; client fixture failure diagnostics
  omit OpenSSL session response bodies. Primitives/PKIX verification unchanged.
  Both Nix builds/checks passed, plus final-package client rerun, 11 server CLI
  tests, 13 HTTP tests, ACME and booted NixOS service. ARM unbuilt, production
  unchanged. Unicode report combines this with config fix 566b9f8:
  https://fedi.freifick.net/@slop/01M539AS6JRJGE2JSV23F72KSW
  Temporary posting token revoked and its OAuth app deleted.

- Lantern drain request admission (2026-10-17), signed `ebd139f`, published
  to GitHub: existing sockets now share the registry's atomic stop boundary
  for complete-header request admission. Old fixture reproduced a fresh 200 on
  keepalive after SIGTERM closed the listener. New late requests get 503 before
  body/100-continue/dispatch; requests admitted before stop may finish. Response
  heads written during drain advertise Connection: close; completed requests do
  not dispatch buffered following requests. Existing headers cannot be changed;
  idle readers remain header/drain-deadline bounded (ten-second grace unchanged).
  A held real upstream fixture checks listener refusal, late GET/Expect rejection,
  successful active response, connection-close headers, EOF instead of queued
  pipeline work, and process exit 0. Latest isolated probe and `nix build`/all
  four x86 flake checks passed (14 HTTP tests, 11 CLI tests, ACME and booted NixOS
  service at 60.68 s). ARM unbuilt; no production service changed.

- Lantern idle shutdown (2026-10-17): registry phases distinguish admitted work
  from idle/header/handshake I/O under the stop lock. Idle sockets close promptly;
  established TLS transports send bounded close_notify first, concurrently across
  peers. Handshakes close directly. Late requests may see EOF/reset instead of
  503. Active requests retain the ten-second grace. The old idle-only probe took
  10.045 seconds; the new plain and authenticated TLS closure regressions pass
  alongside active-response/pipeline checks (16 HTTP integration tests). Signed commit `d68af15` is published to GitHub. `nix build` and
  all four x86 flake checks passed, including the booted NixOS service test
  (54.99 seconds). ARM remains unbuilt. No host service changed.

- Independent library closure audit (2026-10-17): signed TLS `9490eb7` and HTTP
  `790d421` are published to GitHub. TLS now tracks read/write
  closure and failure separately; local close no longer fabricates read EOF,
  and peer close no longer discards pending application writes. Callers must
  explicitly close writes after finishing; close is idempotent, failed close
  poisons state, and KeyUpdate never writes after local close_notify. Real
  handshakes over in-memory transports reproduce old data loss and verify
  directional data, repeated close, truncated EOF and failed alert poisoning.
  Echo/fetch tools explicitly finish writes. HTTP readRequestMaybe returns
  Nothing only for zero bytes at a request boundary; partial prefixes and backend
  exceptions fail. Six fragment widths cover every proper nonempty prefix of a
  valid request and clean/pipelined EOF. Both libraries passed nix build/checks,
  including TLS OpenSSL/PKIX/adversarial checks. ARM remains unbuilt. Lantern
  integration adopts both updates; no host service is changed.
  Progress report and real Chromium screenshot for these library fixes:
  https://fedi.freifick.net/@slop/01M548AMHF9KAK1Y79ECG4QDG6
  Public attachment/alt text verified; temporary token revoked and OAuth app deleted.
  Lantern integration is signed `084aee4`, with report artifacts `829747b`, both
  published to GitHub. It explicitly finishes TLS writes and treats clean
  request-boundary EOF as normal connection completion. Nix build and all four
  x86 flake checks passed: 17 HTTP tests, 11 CLI tests, local ACME, and booted NixOS
  service. TCP half-close and OpenSSL unwrap after a keepalive response are checked.

- Development preference (2026-10-17): prioritize useful server features and
  Caddy-like setup over further expansion of protocol edge-case tests. Keep
  focused verification for shipped features and required Nix checks.
- HTTP response fix `64e9f00` and Lantern pin/fixture `ac14abd` are signed and
  published to GitHub. HTTP/1.0 Transfer-Encoding is faulty framing,
  rejected before HEAD/304 suppression; old server returned 200/304. Library
  build/check and server build/18 HTTP tests passed. Production unchanged.

- Lantern quickstart now has config-free `lantern serve [DIRECTORY]` and
  `lantern proxy UPSTREAM_URL`. Default HTTP is loopback 127.0.0.1:8080, accepting
  valid Host values. `--domain HOST --email ADDRESS` enables the existing ACME
  engine on [::]:443; --staging selects Let's Encrypt staging. Certificate state
  defaults to XDG data/lantern/{production,staging}; --state-dir overrides it.
  File quickstart rejects certificate state inside the canonical served root.
  --listen overrides binding; no temporary config is written. Fixed command-line
  settings refresh on SIGHUP; changing arguments requires restart. Config supports
  site * fallback after exact host lookup, but automatic mode requires DNS names.
  README/help document commands. Loopback quickstart checks verified file serving,
  proxying, Unicode/quoted paths, no config file, reload/stop and early HTTPS errors.
  Signed quickstart commit `e1bd6d2` is published to GitHub. Nix build
  and all four x86 flake checks passed, including existing ACME and booted NixOS
  service checks; quickstart smoke checks passed. ARM remains unbuilt and no host
  production service was changed.

- Lantern path handlers: `handle /exact { ACTION }` or `/prefix/*`, with an
  optional site default action. Most-specific raw escaped path wins; exact before
  an equal-length prefix; query ignored for matching and preserved upstream. No
  path stripping, normalization or nested handles. At most 128 unique patterns;
  site headers apply to every handler and are checked against all leaf actions.
  Handler roots resolve relative to the config and HTTPS handlers load normal
  proxy trust. Missing match/default returns 404. SIGHUP refreshes routes in the
  usual snapshot; ACME HTTP-01 bypasses path handlers. `examples/Mixed.Lanternfile`
  demonstrates static root, proxied /api/* and /health response. Focused mixed-site
  smoke and example check passed; no host production service changed.
  Path routing is signed commit `01e42ee`, published to GitHub. Build and
  all four x86 flake checks passed, including mixed static/proxy routes, HTTPS
  handler trust, ACME and the booted NixOS service. ARM remains unbuilt.
- Test cleanup requested explicitly: consolidate redundant edge-case matrices
  while keeping feature-level checks and representative known-bug regressions.
  Removed duplicate CLI Unicode checks and socket-fragmentation matrix; retained
  Unicode cases in config tests and deterministic fragmentation in lantern-http.
  One startup fixture now covers representative endpoint/numeric-identifier
  rejection before state/binding/CA side effects. This trims 85 lines and adds 22.
  Cleanup is signed `b1697b3`, published to GitHub. Nix build/all four x86
  checks passed with the reduced suite (9 CLI, 18 HTTP, existing static/encoding/
  HTTPS/ACME checks and booted service at 56.01 seconds). No production changes.

- Lantern mount feature (2026-10-17), signed `5e74703`, and live preview artifacts
  `e969370`, published to GitHub. `handle_path /prefix/* { ACTION }` strips
  /prefix before dispatch; query unchanged. Static directory redirects retain
  the original public prefix/query. Root confinement and upstream trust discovery
  traverse mount wrappers. Upstream response bodies/Location/cookies are not
  rewritten; configure app base paths. Existing mixed-route check was extended,
  without another suite. Nix build/integration passed; module unchanged, boot
  test not repeated. Current relevant verification uses package/integration for
  routing-only changes, boot test for module/packaging/host changes. Preview:
  https://fedi.freifick.net/@slop/01M549ESK6QGF5E0922SAT2TE2
  Chromium captured a real loopback page + live mounted upstream response, with
  public alt text verified. Temporary posting token revoked/app deleted; preview
  processes/files cleaned up. No production service or DNS changed. ARM unbuilt.

- Lantern access logging: opt-in `access_log on/off` (off by default) and
  quickstart --access-log. Structured JSON lines on stdout; diagnostics on stderr.
  Fields include UTC timestamp, peer IP, method, validated host, original public
  path (max 2048 bytes, query omitted), final committed status, completed HTTP
  plaintext write bytes, duration_us and response completeness. No headers/bodies.
  Malformed headers may have null metadata; TLS failures precede HTTP logging.
  A 256-event STM queue never waits for the output sink; full queues drop events,
  broken stdout disables output, shutdown drain is limited to one second. Store
  redirected logs outside served roots with private permissions. SIGHUP reloads
  the option; each worker captures it before reading the next request. Normal
  timing starts after headers; malformed timing includes header wait. Existing
  CLI quickstart check verifies JSON/query redaction. Manual loopback observations
  verified reload-off and continued serving/shutdown after stdout closed.
  Signed commit `83647a8` is published to GitHub. Nix build, integration
  and booted NixOS service checks passed (new STM runtime dependency included).
  Existing CLI feature check extended; no new suite. ARM remains unbuilt and no
  production host service changed.

- Lantern automatic HTTPS contact simplification (2026-10-17), signed `356ddb6`,
  published to GitHub: quickstart now needs only --domain; --email is
  optional. Lanternfile `auto_https "" STATE_DIR` means no contact. Registration
  omits contact entirely rather than sending an empty mailto URI; explicit email
  retains the mailto request. Account-contact updates are not implemented and
  some other CAs may require contact. Nix build/integration passed; existing CA
  fixture verifies no-contact issuance, cached restart and explicit-contact
  renewal, without adding a matrix. Domain-only quickstart reached state guard
  without binding/state creation; help/README updated. No live CA/DNS/service was
  changed for this work; module/packaging unchanged, ARM remains unbuilt.

- Lantern precompressed static serving (2026-10-17): signed HTTP `92ad205`
  adds bounded integer-q content-coding preferences. Signed Lantern `05948ae`
  pins it and adds `root PATH precompressed` / quickstart --precompressed, with
  .br/.gz sidecars selected by Accept-Encoding. Identity fallback/explicit weights
  and exclusions respected; no Accept-Encoding prefers original. Originals must
  exist; old-mtime sidecars ignored. Original MIME, merged Vary, selected-file
  validators and normal conditional/HEAD handling retained. Encoded ranges stay
  disabled; identity ranges unchanged. All opens confined; optional acquisition
  cannot swallow delivery failures. No codecs or byte/FD caches at runtime.
  Quickstart state isolation also covers precompressed roots. Both repos pushed
  to GitHub; builds/library check/server integration passed on x86. One
  focused static feature test added, no new suite. Module/runtime deps unchanged;
  ARM unbuilt. Browser preview artifacts signed `6f0e1e2`:
  https://fedi.freifick.net/@slop/01M54ATW5KGXH4CNKSQMMX7RHC
  Real loopback Chromium fetch decoded 294912 bytes of repeated ASCII text from
  62-byte Brotli; gzip sidecar 1100 bytes. Body sizes exclude headers/TLS and are
  not throughput/general compression claims. Demo cleaned up; public attachment
  and alt text verified, token revoked/app deleted. Production/DNS unchanged.
