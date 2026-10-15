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
