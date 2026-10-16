# Lantern

A small, experimental webserver in **Haskell**, with a Caddy-style configuration
and independently implemented HTTP, TLS 1.3, and ACME. MIT licensed.

```sh
nix build
./result/bin/lantern run examples/Lanternfile
# open http://localhost:8080
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
version. Send **SIGHUP** to reload routes/headers and manual TLS credentials;
invalid reloads retain the complete working configuration. Send **SIGTERM** for
a ten-second drain followed by connection cancellation.

## Automatic HTTPS

```text
listen [::]:443
auto_https you@example.com /var/lib/lantern
acme_ca https://acme-staging-v02.api.letsencrypt.org/directory
site example.com {
    root /srv/www/example
}
```

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
Retry-After/backoff survives restarts. Keep state out of git and back it up privately.
Changing automatic certificate hostnames, listener/TLS paths/mode, CA, or resource
limits requires a restart; route and header changes can reload.

Manual TLS is `tls /run/credentials/lantern.service/chain.pem /run/credentials/lantern.service/key.pem`
instead of `auto_https`. The current server profile needs an RSA certificate/key.

## Routes and configuration

Each exact hostname has one action. Add multiple `site` blocks for virtual hosts:

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

Quoted values support spaces, escaped quotes and backslashes. `#` starts a comment
outside quotes. Unknown directives, duplicate global directives, duplicate hosts,
multiple actions, and unsafe response headers fail validation. DNS names use
ASCII A-labels. `listen` requires a numeric address and explicit port. All modes
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
and sends HTTP only after authentication. `proxy_ca_bundle` replaces system roots
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

Not included: HTTP/2/3, WebSockets/CONNECT, compression, directory-slash redirects, wildcard hosts, DNS-01,
external-account binding, ACME revocation/account rotation, or configurable route
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
directory/filepath/time, small parser/concurrency helpers, and MIME lookup. The
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
that verifies JWS/CSRs and fetches the real HTTP-01 endpoint. Its issuance,
restart, renewal, failure preservation, and backoff checks need no internet or
live service. Library checks add 11,000 HTTP wire/representation properties, 3,000 TLS record properties,
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
