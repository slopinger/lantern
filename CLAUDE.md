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
