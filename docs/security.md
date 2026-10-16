# Threat model and security limits

Lantern is experimental and has not had an independent security audit. A memory-safe
implementation plus passing tests does not establish protocol security. The custom
TLS library's supported profile and open gaps are documented in its own repository.

Remote clients and upstream servers are untrusted wire peers. Local configuration,
operator-managed document roots, runtime key storage, system trust roots, wall clock,
Linux kernel, GHC runtime, and Crypton primitives are trusted. Applications behind
the proxy must still authenticate/authorize users and understand their proxy boundary.

## Enforced boundaries

- Parsing rejects ambiguous HTTP framing and closes on all protocol errors. Metadata,
  decoded request bodies, chunk overhead, connection counts, requests per connection,
  and absolute operation deadlines are bounded independently.
- A 64 MiB admission budget reserves declared body sizes, or the configured cap for
  chunked bodies, before accepting an upload. Buffer concatenation still has a peak
  copy cost; the NixOS service adds a 512 MiB process memory limit. Limits bound work,
  not all denial-of-service strategies.
- Static opens use a bounded, decoded relative path and Linux openat2 with BENEATH,
  NO_SYMLINKS and NO_MAGICLINKS. Only regular files are served. Hidden/dot/traversal,
  NUL, backslash and invalid UTF-8 components are rejected. There is no unsafe fallback.
  Configured roots are resolved at load time; operator-controlled roots must not
  contain unintended hard links, bind mounts, or mutable secret content.
- Every request uses one immutable routing snapshot. A reload provisions/validates
  before replacing it; rejection preserves the prior snapshot. TLS certificate
  rotation affects new handshakes while existing sessions retain their own keys.
- The proxy discards client forwarding identity and hop fields. It reconstructs
  request lengths after decoding and regenerates outgoing chunk framing as needed.
  Upstreams are configured, not taken from request URLs. No pooling or HTTP retry
  can carry unread/ambiguous bytes into another exchange. HTTPS upstreams use our
  TLS client with SAN identity, certificate-chain/time/purpose verification and
  system roots or an explicit proxy-only bundle. No HTTP bytes precede successful
  authentication. The TLS dependency pins Crypton 2.2.1 and the 1.10.0 certificate
  verifier, with additional bounded DNS/IP constraints and inherited purpose checks;
  unsupported constraint forms fail closed (see the TLS library security profile).
  No plaintext fallback or certificate-verification bypass exists.
  TLS handshakes fall within the full upstream deadline. Trust roots are immutable
  per routing snapshot; failed reloads preserve the prior roots and routes.
- There is no public management HTTP endpoint, shell command interpolation, CGI,
  executable configuration, remote config fetch, or default access log. Generic
  client errors contain no filesystem paths or upstream internals.
- ACME uses authenticated HTTPS with same-origin resource URLs, explicit CA roots,
  separate account/site keys, RSA JWS signatures, bounded JSON, replay nonces, bounded
  polling, and persisted Retry-After backoff. Tokens exist only during authorization.
  State is private, locked, flushed and atomically replaced. Old credentials stay
  active on renewal failure. Complete new chain/key loading precedes publication.

## Important limits

TLS supports a restricted 1.3 profile, not every standards-required feature. There
is no resumption, mutual TLS, post-quantum
handshake, revocation/OCSP fetching, or guarantee of secret erasure from managed
memory. The client relies on Crypton's certificate-path validation primitives;
there is no insecure verification switch. Test-only staging roots must not be
added to a normal system/browser trust store.

ACME supports HTTP-01 DNS identifiers only, one SAN certificate for all configured
hosts, no wildcards/EAB/revocation/account-key rotation/ARI. The authority's terms
are accepted during account creation. Deployment must provide correct DNS and
port-80 reachability. A failed initial acquisition exits with an error; persisted
backoff prevents supervisor restarts from hammering the CA. Renewal failures are
reported to stderr and can eventually cause certificate expiry if not resolved.

There is no WAF, per-IP rate limiter, disk quota manager, request decompression,
HTTP/2/3 or application authorization. Defaults bind loopback. A publicly bound
listener is exposed according to the host network/firewall; the module does not
change firewall policy. The NixOS service is hardened but has only been evaluated,
not boot-tested as a full NixOS host here.

## Validation and future work

Regression tests include symlink replacement races, malformed/pipelined HTTP,
chunking, forwarding spoof attempts, partial bodies, timeouts, admission exhaustion,
concurrent requests, invalid reloads, TLS interoperability and local CA failures.
Let’s Encrypt staging issuance, cached startup and in-process renewal also passed.
Benchmarks measure supported paths, not security. Independent review, richer
coverage-guided fuzzing, formal state-machine work, secret-memory handling and a
real NixOS service boot test remain before any production-security claim.

The TLS client and server support X25519/P-256 ECDHE and a single HelloRetryRequest.
A retry does not reset the handshake or upstream deadline. Its original hello,
synthetic message_hash, retry and second hello are authenticated by the handshake.
The independent TLS project tests parameter immutability, malformed points and
cookie handling; Lantern integration checks P-256 client and server paths.

Static conditional/range semantics use the independent HTTP representation module.
File size/timestamps are read from the confined descriptor before it becomes the
streaming handle, avoiding path-stat/reopen races. Metadata ETags are weak, not
content digests or proofs against malicious in-place writes; publish immutable
files through atomic replacement. If-Range falls back to full content for these
weak validators. Generated metadata headers cannot be overridden on a static site.

Range lists have a 16-element cap, bounded decimal arithmetic, overlap/adjacency
coalescing and no duplicate body bytes. Multipart boundaries use 128 random bits
from Crypton; prefixes and exact Content-Length are computed before transmission.
File data still streams in 64 KiB chunks under the whole-response deadline. Too
many/unsatisfiable ranges get 416; malformed/unknown units are ignored. Preconditions
run before ranges, and 304/HEAD never emit a representation body. A configured
Content-Encoding disables ranges rather than mislabeling a multipart envelope.

The static metadata cache holds at most 256 derived entries per routing snapshot,
plus one Date value keyed by its UTC second. A hit never bypasses confined open,
regular-file validation or descriptor stat. Keys include device/inode, size,
high-resolution modification/change times, media type and configured headers.
URI spelling is not a cache key: repeated-slash aliases cannot retain long paths.
No body data or file descriptors are retained. A miss at capacity replaces the
map; a reload creates a new cache. This optimization does not strengthen metadata
ETags or relax the atomic-publication requirement. Tests replace a warmed path
with an escaping symlink and check Date refresh on repeated cached responses.

UTF-8 URL/config paths use explicit UTF-8 at the filesystem FFI boundary. The
locale-dependent C-string conversion could discard non-ASCII characters under
LC_ALL=C after path validation, potentially resolving a different or hidden file.
The CLI and configuration loader select UTF-8 filesystem encoding before
reading arguments/files, and the shim boundary encodes UTF-8 explicitly with NUL
rejection. A C-locale loopback
regression checks exact Unicode filenames and hidden/dot-prefix non-aliasing using
synthetic files. Confinement remains kernel-enforced for the exact encoded bytes.

Directory canonicalization uses the confined descriptor's type rather than a
separate path-stat lookup. The shim closes observed directories and reports a
directory result; only regular files become streaming handles. A search-only
directory may be detected with O_PATH after EACCES, retaining the same openat2
BENEATH/NO_SYMLINKS/NO_MAGICLINKS policy. Neither ordinary file permission failures
nor symlinks become readable through this probe.

Redirect locations preserve original escaped path/query bytes, insert a literal
slash before the query, and stay origin-relative. They contain no request-derived
scheme/authority. Directory indexes that are directories or symlinks return 404
instead of creating redirect loops or following links. HEAD redirects are bodyless;
range/conditional headers do not override the ordinary redirect decision. Tests
cover encoded separators, Unicode, queries, relative assets, search-only directories,
reused connections, repeated directory descriptor cleanup, and symlink-swap races.

HTTPS certificate key policy requires exact RSA modulus bounds throughout the
selected path (2048–8192 bits); rounded byte size cannot establish the minimum.
Only the TLS library's advertised modern certificate algorithms are accepted.
The proxy regressions cover weak issuer and weak leaf rejection before HTTP.

Response deadlines cover the complete dispatch/stream. Header/chunk writes share
that deadline rather than registering independent nested timers. Error and
HTTP-01 responses also have one complete write deadline. A failed partial interim
100-continue write prevents a second response; a successful interim still permits
normal final/error responses. Slow-reader tests verify continuing progress cannot
extend a static transfer beyond its absolute write budget.

Connection admission is atomic across the main and HTTP-01 listeners: the stopped
flag, capacity check, worker creation and registration share the registry lock.
Worker cleanup cannot overtake registration. A socket rejected or interrupted
before transfer of ownership closes; accepted workers own closure and removal.
The ACME fixture tests 400 paired HTTP/TLS arrivals at max_connections=1, requiring
at most one peer to receive protocol bytes and continued successful admissions.
