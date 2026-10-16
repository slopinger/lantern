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

## Conditional/static milestone, 2026-10-16

Server commit `95a8573`, independent HTTP library `b2d8ccb`. The same loopback
method was run with `--conditional`, using each server’s own ETag and verifying
304 plus an empty response body before measurement. Caddy was v2.11.7.
The run had three four-second trials per case, two schedulers per server,
two generator threads and 32 connections. Start load averages were [0.734375, 0.85546875, 1.89306640625].

| Workload | Lantern median requests/s | Caddy median requests/s |
| --- | ---: | ---: |
| 4 KiB, full | 2,681.6 | 8,072.1 |
| 4 KiB, not-modified | 3,352.7 | 10,907.0 |
| 1024 KiB, full | 503.9 | 749.6 |
| 1024 KiB, not-modified | 3,287.7 | 10,897.2 |

Caddy remained faster. A successful 304 avoided the entire file body; its
request rate is not file-throughput performance. Full 1 MiB transfers measured
503.9 MiB/s for Lantern and 749.6 MiB/s for Caddy. Do not attribute differences
from the October 15 baseline solely to code: this shared VM has no load or
CPU-affinity isolation. This run does not measure TLS, ranges or cold storage.
[Raw outputs and binary digest](benchmark-2026-10-16-static.json) include
all trials. No wrk socket errors or unexpected response classes were reported.

## Derived-header cache follow-up

Server commit `4b8c238` reuses derived weak-tag/Last-Modified text and the
per-second Date header. It still opens/confines/stats every file request,
retains no file bytes/descriptors, and bounds metadata entries at 256 per
routing snapshot. The identical generator/settings were run again, after
the Nix checks completed. Start load averages were [1.38134765625, 1.18701171875, 1.63623046875].

| Workload | Lantern before cache | Lantern repeat with cache | Caddy in repeat |
| --- | ---: | ---: | ---: |
| 4 KiB, full, requests/s | 2,681.6 | 3,547.7 | 8,175.6 |
| 4 KiB, not-modified, requests/s | 3,352.7 | 4,656.5 | 10,572.8 |
| 1024 KiB, full, requests/s | 503.9 | 495.6 | 717.1 |
| 1024 KiB, not-modified, requests/s | 3,287.7 | 4,673.6 | 10,791.0 |

The repeat observed higher small-file/conditional rates; full 1 MiB throughput
was roughly unchanged (495.6 MiB/s versus 503.9). Caddy remained faster in
every workload. These sequential shared-VM runs do not isolate all background
load, so they do not prove that every measured difference is caused by caching.
Both conditional paths avoided the entire representation body. No wrk socket
errors or unexpected response classes were reported. Full 200 bytes and each
server’s 304 behavior were checked before measurement.
[Repeat raw outputs and binary digest](benchmark-2026-10-16-static-cache.json)
preserve all trial rates, RSS observations and generator output.

Reproduce both full and conditional cases with:

```sh
nix develop -c python test/benchmark.py --conditional --lantern ./result/bin/lantern --out benchmark.json
```

## Descriptor I/O profiling

`test/profile_static.py` captures a fixed workload of ten connections, each making
100 verified 4 KiB GETs. The JSON includes all strace output, RTS statistics,
binary digest and platform information. Startup/shutdown and the readiness
connection are included. Compare structural syscall counts, not percentages of
traced time: blocking waits and tracing overhead distort CPU/time attribution.

The original profile showed about three fstat calls, one fcntl, and one failing
ioctl per response. Handle setup and handle-based reads contributed work on every
request even though confinement had already supplied a regular descriptor. Static
streaming now uses that descriptor with bounded POSIX reads and checked seeks,
retaining openat2, metadata checks, independent per-request descriptors and cleanup.
For 1,000 verified responses, fstat counts fell from 3,025 to 2,025, fcntl from
1,023 to 23, and ioctl from 1,003 to 3. Reported heap allocation fell from
68,551,056 to 49,749,008 bytes. Startup/shutdown are included; GC sampling and
scheduler-related call counts are not stable per-request guarantees. Raw profiles:
[before](syscalls-2026-10-16-fd-before.json),
[descriptor I/O](syscalls-2026-10-16-fd-after.json).

The repeated throughput test ran after builds and tracing finished, with the
same two schedulers, 32 connections, one-second warmups and three four-second
trials per case. The baseline is server `7ae95ed`; the candidate changes only the
static descriptor path. This is still a shared VM without CPU affinity isolation.

| Workload, requests/s | Baseline | Descriptor I/O |
| --- | ---: | ---: |
| 4 KiB, full | 4,150.6 | 4,281.1 |
| 4 KiB, not-modified | 5,669.6 | 5,620.1 |
| 1024 KiB, full | 624.6 | 583.6 |
| 1024 KiB, not-modified | 5,683.0 | 5,400.8 |

These results do not establish a throughput win from descriptor I/O alone: small
full responses were slightly higher, conditional rates were similar/lower, and
large-file throughput was lower. The allocation/setup reduction is demonstrated
separately. Caddy remained faster in every workload; its conditional rates also
varied between the sequential runs. Preserve these observations when evaluating
further optimizations rather than attributing combined changes to descriptor I/O.
Raw trials/control measurements: [baseline](benchmark-2026-10-16-fd-before.json)
and [descriptor I/O](benchmark-2026-10-16-fd-after.json).
