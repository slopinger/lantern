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

## Whole-response deadline follow-up

Normal dispatch already had an absolute deadline, so nested timers around each
header/chunk write were redundant. Those writes now share the dispatch deadline.
Error responses and HTTP-01 responses have their own complete-response deadlines;
interim 100-continue output remains bounded. The slow-reader regression checks
that continuing body progress cannot retain an open file past the absolute budget.

[The combined syscall profile](syscalls-2026-10-16-response-deadline.json) reported
48,053,904 allocated bytes for the same 1,000 requests, compared with 68,551,056
at baseline. Its write syscall count was essentially unchanged, so these data do
not attribute runtime wakeups to the removed timers.

The [first combined throughput run](benchmark-2026-10-16-response-deadline.json)
had markedly lower request rates, but Caddy's control rates also dropped by about
one third relative to the earlier run. This host is shared; those sequential
throughput measurements cannot isolate the code's contribution.

The benchmark now records Linux process user+system CPU ticks before/after each
trial and divides by wrk's reported request count. These include all server threads,
exclude client/generator CPU, and have the kernel's clock-tick precision. See
[proc_pid_stat](https://man7.org/linux/man-pages/man5/proc_pid_stat.5.html). CPU cost
is an additional observation, not a latency, availability or throughput guarantee.

Both original full-response workloads were repeated with three three-second
trials and one-second warmups, two schedulers and 32 connections. The baseline
executable is `7ae95ed`; the candidate combines descriptor I/O with the deadline
changes. All trial values are preserved; no trials were filtered.

| Server/workload | Before req/s | Combined req/s | Before CPU µs/req | Combined CPU µs/req |
| --- | ---: | ---: | ---: | ---: |
| lantern, 4 KiB | 2,722.5 | 3,358.0 | 346.2 | 279.9 |
| lantern, 1024 KiB | 314.0 | 564.9 | 2,715.5 | 1,964.6 |
| caddy, 4 KiB | 5,211.6 | 5,090.4 | 291.3 | 294.6 |
| caddy, 1024 KiB | 525.7 | 551.2 | 2,704.0 | 2,535.5 |

In this repeat, Lantern used about 19% less server CPU per 4 KiB response and
28% less per 1 MiB response. Its observed request rates increased; Caddy's control
rates were comparatively close between these two runs. That supports lower work
per request in these workloads, but does not prove every throughput difference is
caused by the change or establish general superiority to Caddy. The tests still
exclude TLS, cold files, ranges, WAN transport, long-duration load and adversarial
clients. Raw data: [before](benchmark-2026-10-16-cpu-before.json),
[combined](benchmark-2026-10-16-cpu-after.json).

A separate conditional-only repeat checks 304 responses without preceding
bulk-transfer load trials. It uses the same three three-second trials, warmups,
thread/connection limits, byte preflight and each server's own verified ETag.
The initial 200 response is still verified before measuring 304 responses.

| Server/workload | Before req/s | Combined req/s | Before CPU µs/req | Combined CPU µs/req |
| --- | ---: | ---: | ---: | ---: |
| lantern, 4 KiB 304 | 2,871.4 | 3,676.4 | 292.9 | 241.6 |
| lantern, 1024 KiB 304 | 2,475.3 | 2,970.3 | 291.5 | 259.2 |
| caddy, 4 KiB 304 | 7,899.1 | 9,347.4 | 173.8 | 162.2 |
| caddy, 1024 KiB 304 | 8,852.1 | 8,674.0 | 168.1 | 170.5 |

Lantern's observed CPU cost was about 18% lower for the small-file 304 and 11%
lower for the large-file 304. Caddy remained considerably faster on these
metadata-only workloads. Controls and request rates still vary; this repeat does
not isolate every environmental effect. A worker-thread sanity check also compared
the new process-tick reader against Python process_time: 0.200 versus 0.202 CPU
seconds for two worker threads, within the kernel tick resolution.
[Conditional baseline](benchmark-2026-10-16-conditional-cpu-before.json) and
[combined](benchmark-2026-10-16-conditional-cpu-after.json) preserve all trials.
Use `test/benchmark.py --conditional-only` to reproduce that workload selection.

## HTTP line fragmentation, 2026-10-16

The independent HTTP library now avoids repeated copying and rescanning of a
pending line. Its [parser experiment](https://github.com/slopinger/lantern-http/blob/main/docs/fragmentation.md)
uses a verified 8135-byte request with one-byte, 128-byte and whole-buffer
receives. Three alternating revision pairs show about 95% lower allocation and
a large CPU reduction for single-byte fragmentation; the coalesced long-line
control used about 2.4% more CPU and 48 additional allocated bytes/request.
All initial, prototype and final trials are retained in that report's JSON.
This is parser work without sockets/TLS/files, not a new Lantern/Caddy throughput
comparison or a peak-memory measurement. Fragment metadata remains bounded by
the line's byte limit; absolute deadlines/admission remain necessary.

## Request-target scan, 2026-10-16

The [HTTP library's target-scan report](https://github.com/slopinger/lantern-http/blob/main/docs/target-scan.md)
compares the indexed scan against `c9a0b57` using the unchanged long-request
helper. Three alternating pairs of coalesced 8135-byte requests (10000 parses)
used 3,292,484,144 -> 13,204,144 allocated bytes and median process CPU
1.038380 -> 0.737323 seconds. All trials and source/helper hashes are public.
These are roughly 99.6% less allocation and 29% less CPU in this unusually long
target parser case, not measurements of ordinary server throughput, peak memory,
TLS/files or Caddy performance. The earlier fragmentation report remains dated
evidence of its earlier revision; this change retains that line algorithm.
