# Lantern

A small, experimental webserver in **Haskell**, with a Caddy-style configuration
and independently implemented HTTP, TLS 1.3, and ACME. MIT licensed.

Serve files or proxy an app without creating configuration:

```sh
nix build
./result/bin/lantern serve ./public
./result/bin/lantern proxy http://127.0.0.1:3000
# open http://localhost:8080
```

Both commands bind only to loopback by default and accept any valid Host. Use
`--listen 0.0.0.0:8080` to make the listener public. Hidden files and symlinks remain
blocked. An HTTPS upstream is verified using the system trust store.

For automatic HTTPS, point public DNS at this server, allow ports 80/443, then run:

```sh
lantern serve ./public --domain example.com --email you@example.com
lantern proxy http://127.0.0.1:3000 --domain app.example.com --email you@example.com
```

These use Let's Encrypt production and bind `[::]:443` (IPv4 and IPv6 on Linux).
Using ACME agrees to the CA's terms. Add `--staging` while trying issuance; staging
certificates are not browser-trusted. State defaults to
`$XDG_DATA_HOME/lantern/production` (or `~/.local/share/lantern/production`), with a
separate `staging` subdirectory for testing. Override with `--state-dir DIRECTORY`.
Keep state private and outside served roots. `--help` explains all options.
Quickstart paths are relative to the current directory. Ctrl-C stops gracefully;
SIGHUP refreshes the same command-line settings. Change arguments by restarting.

For multiple hosts or more settings, use a Lanternfile:

```sh
lantern run examples/Lanternfile
```

```text
listen 127.0.0.1:8080
site localhost {
    root ./public
}
```

Paths are relative to the Lanternfile. `lantern run` and `lantern check` default
to `./Lanternfile`. `lantern check path/to/Lanternfile` validates without binding
ports, contacting a CA, or creating an account. `lantern version` prints the
version (`--version` is equivalent). `--help`, `-h`, `help run`, and `help check`
show usage without loading configuration. Both commands also accept
`--config FILE` or `--config=FILE`; use `run -- FILE` / `check -- FILE` for a
filename beginning with a dash. Expected failures print one concise diagnostic
to stderr and exit with status 1. Diagnostics and filenames use UTF-8 even in a
C locale. Interrupting startup/check with Ctrl-C exits 130; the running server's
SIGINT handler still performs its normal graceful stop.

Send **SIGHUP** to reload routes/headers and manual TLS credentials;
invalid reloads retain the complete working configuration. Send **SIGTERM** for
a ten-second drain followed by connection cancellation. Requests admitted before
stop may finish. Existing keep-alive sockets cannot admit new work after stop;
responses committed during drain advertise `Connection: close`, and buffered
following requests are not dispatched. Idle/header/handshake sockets close promptly on stop. Requests admitted before
stop retain the grace period; late clients may observe EOF/reset instead of 503.

## Automatic HTTPS

```text
listen [::]:443
auto_https you@example.com /var/lib/lantern
acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
site example.com {
    root /srv/www/example
}
```

Automatic HTTPS currently supports DNS identifiers only. IPv4 and other
all-numeric dotted site names are rejected during validation; IP-address
issuance is not implemented. Numeric labels such as `123.example.org` are allowed.
This restriction does not apply to plain or manual-TLS site configuration.

Point public DNS at this machine and make HTTP port 80 reachable. `[::]` binds
IPv6 and IPv4 on Linux; `0.0.0.0` is IPv4-only. For an existing HTTP front end,
set `acme_http_port 8081` and route this site's port-80 traffic to that listener.
TLS can remain on a separate configured port. The HTTP listener serves active
HTTP-01 tokens and redirects other paths to the canonical configured HTTPS host.
Unknown hosts and unknown challenge tokens are rejected.

Start with staging. Its roots are deliberately absent from normal trust stores.
For publicly trusted issuance, remove `acme_ca` to use the default production
Let's Encrypt directory. Using ACME agrees to the chosen CA's terms. Separate
state directories for staging/production are recommended. The implementation uses
our own HTTPS client, JWS signing glue, account registration, nonces, HTTP-01,
orders, CSRs, certificate download, and renewal; there is no Certbot/lego helper.
Cryptographic primitives and PKIX verification remain established dependencies.

State is private (directory 0700, files 0600), locked to one process. Account and
site keys are separate and persist across restarts. Certificates are renewed at
two-thirds of their actual lifetime, checked on startup and every six hours.
**SIGUSR1** requests immediate renewal in automatic mode. Credentials activate
without restarting listeners; failures preserve the working chain and credentials.
Retry-After/backoff survives restarts. Downloaded and cached certificates must
be within their validity period; future-dated issuance preserves the working
certificate and retries with backoff. A future-dated cache requires fresh issuance
before the HTTPS listener opens. In automatic mode, route reloads retain the
latest active in-memory certificate; certificate activation belongs to renewal.
Missing or stale cache files cannot turn a running HTTPS listener into plaintext
or roll its certificate back during a reload. Keep state out of git and back it up privately.
Changing automatic certificate hostnames, listener/TLS paths/mode, CA, or resource
limits requires a restart; route and header changes can reload.

Manual TLS is `tls /run/credentials/lantern.service/chain.pem /run/credentials/lantern.service/key.pem`
instead of `auto_https`. The current server profile needs an RSA certificate/key.

## Routes and configuration

Each hostname has an optional default action and path handlers. `site *` is an optional fallback after exact host
matching for plain/manual TLS configurations; automatic HTTPS requires explicit
DNS hostnames. Add multiple `site` blocks for virtual hosts:

```text
site app.example.com {
    reverse_proxy http://127.0.0.1:3000
}
site health.example.com {
    respond "ok"
    header Content-Type "text/plain; charset=utf-8"
}
site old.example.com {
    redirect https://example.com/new
}
```

Redirect URLs and response header names must be ASCII. Percent-encode Unicode
in redirect paths and use DNS A-labels for internationalized hosts. Bodies and
header values retain UTF-8 text. Unsupported Unicode wire fields fail validation
with a source line instead of silently changing characters.

Combine actions under one host with path handlers:

```text
site example.com {
    root ./public
    handle /api/* {
        reverse_proxy http://127.0.0.1:3000
    }
    handle /api/health {
        respond "healthy"
    }
}
```

`handle` takes an exact path or a prefix ending in `/*`. The longest matching
path wins; an exact match wins over a prefix of the same length, regardless of
configuration order. Matching uses the raw escaped path without its query.
`/api/*` matches `/api/users`, but not `/api`; add an exact handler for that path
if needed. The original path and query reach the upstream unchanged. A root in a
handler also keeps the complete path. URL escapes are not normalized for matching.

The ordinary site action is the fallback. A site with only handlers returns 404
when none matches. Each handler contains one root, reverse_proxy, respond or
redirect action; put shared headers at site level. Nested handlers and duplicate
patterns are rejected; at most 128 handlers per site. Roots remain relative to
the Lanternfile, confined and checked at startup. HTTPS upstreams retain normal
certificate verification. Handler changes reload with SIGHUP.

Quoted values support spaces, escaped quotes and backslashes. `#` starts a comment
outside quotes. Unknown directives, duplicate global directives, duplicate hosts,
multiple actions, and unsafe response headers fail validation. DNS names use
ASCII A-labels. `listen` requires a numeric address and explicit port. Endpoint hosts use valid
ASCII DNS labels or bracketed IPv6 literals; malformed labels/literals, bracketed
DNS names, zone identifiers and IPvFuture are rejected during validation.
Automatic-HTTPS startup validates CA URLs before creating state or binding HTTP-01. All modes
support HTTP/1.1 keep-alive and pipelining. HTTP/1.0 has a strict limited profile.

| Directive | Default / meaning |
| --- | --- |
| `listen ADDRESS:PORT` | `127.0.0.1:8080`; bracket IPv6 addresses |
| `header_timeout SECONDS` | 10; absolute complete-header deadline, max 300 |
| `body_timeout SECONDS` | 30; absolute complete-request-body deadline, max 3600 |
| `write_timeout SECONDS` | 30; complete response/proxy deadline, max 3600 |
| `max_connections COUNT` | 256, including handshakes and ACME HTTP; max 4096 |
| `body_limit BYTES` | 1 MiB; max 16 MiB per request |
| `tls CHAIN KEY` | Manual unencrypted RSA PEM credentials |
| `auto_https EMAIL STATE_DIR` | Own ACME HTTP-01 automation |
| `acme_ca HTTPS_URL` | Let's Encrypt production directory |
| `acme_http_port PORT` | 80; separate HTTP-01/redirect listener |
| `acme_ca_bundle FILE` | Explicit ACME CA trust roots; default system trust |
| `proxy_ca_bundle FILE` | Trust roots for all HTTPS upstreams; default system trust |

Static files stream in 64 KiB pieces. `/` and `/directory/` select `index.html`.
An existing directory requested without a literal trailing slash returns 308 to
its slash URL, preserving escaped path bytes and the query. GET/HEAD redirects are
origin-relative and need no configured host/scheme. Search-only directories with
readable indexes work too. Missing/nonregular indexes remain 404; there is no listing.
There is no directory listing, hidden-file serving, or symlink following. Linux
`openat2` confines the open itself below the configured root, including during
symlink replacement races. Publish into operator-controlled roots with atomic
file/release replacement; do not rewrite a streamed file in place.

Static responses include weak metadata ETags and Last-Modified. If-Match,
If-Unmodified-Since, If-None-Match and If-Modified-Since follow HTTP precedence;
matching conditional retrievals return bodyless 304. ETags are deliberately weak:
metadata is not a proof of byte identity, and no whole-file hash delays a download.
The static route reserves its validator/range response headers. A 256-entry
per-snapshot cache reuses only derived validator/date text after each confined open
and descriptor stat; it stores no file bytes or file descriptors. Date refreshes
each second, and route reloads start a fresh cache.

GET supports closed, open-ended and suffix byte ranges, including multipart 206.
Overlapping/adjacent ranges merge; at most 16 comma-separated elements are allowed.
Wholly unsatisfiable or excessive ranges return 416; unknown/malformed ranges are
ignored. HEAD ignores Range. If-Range needs strong evidence: the static server's
weak ETag/date validators therefore cause a full 200 fallback. An empty file's
nonzero suffix range also falls back to its empty full response. Operator-specified
Content-Encoding disables ranges; Lantern does not encode the multipart envelope.
Files stream from the same confined descriptor that supplied size and timestamps.

Reverse proxy upstreams are fixed `http://host:port` or `https://host:port`
endpoints (explicit ports, no paths or credentials). HTTPS uses Lantern's own TLS
client, verifies the configured host against its certificate SANs and trust roots,
and sends HTTP only after authentication. The TLS reference must be an ASCII DNS
A-label or IP literal; it is validated before case normalization/IP parsing.
The library does not perform IDNA conversion. `proxy_ca_bundle` replaces system roots
for every HTTPS upstream, independently of ACME trust. It is resolved relative to
the Lanternfile and loaded once per routing snapshot; SIGHUP reloads its contents
atomically. Changing the configured bundle path requires a restart. TLS failures
return 502 before response headers; later failures close the downstream stream.
Client-supplied forwarding identity is replaced with the actual peer and selected host/scheme.
Hop-by-hop fields are removed in both directions. Requests are bounded and
buffered; responses stream with backpressure. One upstream connection per request,
no implicit proxies, redirects, pooled connections, or request retries. A global
64 MiB reservation budget bounds concurrent request-body memory; excess body
requests get 503. Known upstream responses over 1 GiB are rejected before headers.

Not included: HTTP/2/3, WebSockets/CONNECT, compression, wildcard DNS hosts, DNS-01,
external-account binding, ACME revocation/account rotation, or regular-expression/method route
matchers. This is not a complete Caddy replacement.

## Independent libraries

- [lantern-http](https://git.freifick.net/slop/lantern-http): incremental wire parsing,
  framing, chunk decoding, response serialization, and hop-field filtering;
  runtime dependencies are base, bytestring and time.
- [lantern-tls](https://git.freifick.net/slop/lantern-tls): own client/server TLS 1.3
  state/record/key-schedule code, PEM/DER server credentials and CSRs; Crypton
  provides primitives and client PKIX verification.

The committed flake lock pins exact revisions of both libraries. Other runtime
support consists of GHC/base, bytestring, text/containers, network sockets, unix,
directory/filepath/time, small parser/concurrency helpers, IP address decoding, and MIME lookup. The
only C code is a small Linux filesystem confinement primitive. None implements
HTTP or TLS on our behalf.

## Checks and development

```sh
nix build
nix flake check
nix develop
# inside the shell:
cabal test --offline
LANTERN_BIN=./result/bin/lantern python test/http_test.py
LANTERN_BIN=./result/bin/lantern python test/static_test.py
LANTERN_BIN=./result/bin/lantern python test/https_proxy_test.py
LANTERN_BIN=./result/bin/lantern python test/acme_test.py
python test/benchmark.py --lantern ./result/bin/lantern --out benchmark.json
```

`nix flake check` builds the package, runs configuration/JSON properties, isolated
HTTP/TLS/file-race/deadline/admission/proxy/reload tests, and a disposable ACME CA
that verifies JWS/CSRs and fetches the real HTTP-01 endpoint. A disposable NixOS VM
also boots the exported service module and verifies runtime credentials, low-port
TLS, unprivileged startup, reload, rotation and clean stop; a native KVM builder
is required. Its issuance,
restart, renewal, failure preservation, and backoff checks need no internet or
live service. Library checks add 15,000 HTTP wire/representation properties, 3,000 TLS record properties,
known answers, and real OpenSSL interoperability. x86_64-linux is tested here;
aarch64-linux is defined but has not been built here.

[Research and architecture](docs/research.md), [security scope](docs/security.md),
[deployment](docs/deployment.md), [benchmark results](docs/benchmarks.md), and
[progress screenshots/posts](docs/progress/README.md) provide the evidence and limits.

ACME HTTPS URLs preserve their original bytes for JWS signing, normalize host
case for origin checks, support query-only targets and bracketed IPv6 authorities,
and reject malformed percent escapes. Redirects and embedded credentials remain
unsupported.

The TLS library supports X25519 and P-256 key agreement and one HelloRetryRequest
within the original handshake deadline. The server can request a missing key
share; the HTTPS client can answer P-256 and cookie retries. Transcript and
parameter-change checks apply to retries as well as ordinary handshakes.

Filesystem paths are passed to the confinement shim as explicit UTF-8 bytes.
Process locale does not change a validated URL's filename; this also protects
hidden/dot-component checks when the service starts under the C locale.

Optional real-browser directory QA (Chromium installed or provided via Nix):

```sh
python test/directory_browser.py --binary ./result/bin/lantern --out /tmp/lantern-directory.png
```

It starts a disposable loopback site, verifies plain/encoded-slash redirects and
relative CSS/JS/JSON in isolated browser profiles, captures the fixture page, then
stops the server. This does not deploy or browse production services.

The Nix build uses the TLS flake's shared primitive package set (Crypton 2.2.1,
certificate verifier 1.10.0). HTTPS peers must satisfy its bounded certificate
policy; unsupported name-constraint forms are rejected. See
[security limits](docs/security.md) and the TLS library's own profile.

Static file bodies use bounded POSIX reads from the same confined descriptor used
for metadata. The file is closed at the end of each request, including errors;
no file bodies or descriptors are cached. To inspect per-request syscall costs:

```sh
nix develop -c python test/profile_static.py --out syscalls.json
```

The helper creates a disposable loopback server and verifies 1,000 responses.
Tracing changes timings; use its syscall counts alongside the separate benchmark
instructions in [performance observations](docs/benchmarks.md).

The connection limit is shared atomically by HTTPS and HTTP-01 listeners, including
clients still handshaking or waiting for request headers. The loopback ACME fixture
also exercises concurrent arrivals at a one-connection limit.

ACME-issued leaf DNS SANs must exactly match the requested site names (case and
order ignored). Incorrect issuance retains the working certificate and enters
retry backoff. A mismatched cached identity requires new issuance before HTTPS
opens. Wildcard/CN substitution and additional identifiers are not accepted.

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

Quickstart automatic file serving rejects certificate state inside the served
directory, before binding or issuance. Choose an external `--state-dir` if needed.
