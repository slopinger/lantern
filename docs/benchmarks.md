# Initial performance observations

Measured 2026-10-15 on the shared Arch/Proxmox VM: x86_64, 12 logical CPUs,
no CPU affinity isolation. Both server runtimes used two schedulers (Lantern's
compiled `-N2`, Caddy's `GOMAXPROCS=2`); wrk used two threads and 32 connections.
Each body had a one-second warmup and three four-second trials. Files were in a
warm page cache. The script checked identical 200-response bytes before measuring.

| Local HTTP/1.1 workload | Lantern median | Caddy median |
| --- | ---: | ---: |
| 4 KiB file | 3,136.7 requests/s | 5,954.0 requests/s |
| 1 MiB file | 411.4 requests/s | 519.1 requests/s |
| 1 MiB file, body throughput | 411.4 MiB/s | 519.1 MiB/s |

Caddy was faster in both workloads. This is an initial baseline, not a performance
claim against mature webservers. Defaults and features differ: Lantern opens each
file through openat2, streams through bounded Haskell buffers, and limits a
connection to 100 requests. Caddy has a different file-serving implementation and
supports substantially more functionality. No tuning beyond runtime schedulers,
loopback binding, and disabling unused Caddy administration/TLS automation was
applied. The machine also runs other services.

These numbers do not measure TLS, handshake rates, WAN latency, proxy performance,
slow clients, cold storage, long-run stability, or denial-of-service resilience.
No socket errors, timeouts, or non-success responses were reported by wrk in these
trials. The raw outputs, RSS observations, executable SHA-256, server version,
platform, and all trial values are in [benchmark-2026-10-15.json](benchmark-2026-10-15.json).

Reproduce with:

```sh
nix build
nix develop -c python test/benchmark.py \
  --lantern ./result/bin/lantern --out benchmark.json
```

The script creates loopback-only temporary Lantern/Caddy instances and cleans them
up. It does not benchmark or write to live services. Future optimization should
keep the malformed-message, symlink-race, admission, and reload tests passing.
