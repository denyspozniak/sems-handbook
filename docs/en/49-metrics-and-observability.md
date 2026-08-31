# 13.3 Metrics and observability

> [!NOTE]
> This one is **partly solved**, and the interesting question is not the exporter. A Rust sidecar
> already serves Prometheus metrics ([8.2](29-monitoring-and-stats.md)). The gap is *which
> numbers* — four of the seven signals that actually predict trouble are not exposed by anything
> today.

## What exists

```
apps/monitoring/tools/
  sems-prometheus-exporter/     # polls XML-RPC, serves /metrics on 0.0.0.0:9090
  sems-list-active-calls/
  sems-list-calls/
  sems-list-finished-calls/
  sems-get-callproperties/
  sems-monitoring-lib/
  sems_*.py                     # Python equivalents
```

The chain is `monitoring` plug-in → `xmlrpc2di` → the exporter → Prometheus
([8.2](29-monitoring-and-stats.md)). Nothing is linked into SEMS.

That is a defensible design, and the reasons are the ones from
[13.1](47-gaps-overview.md): no metrics library inside a process where a crash is an outage
([2.1](02-thread-model.md)), no C++ changes, and the exporter ships independently.

Its limits are equally clear: a poll interval between reality and the dashboard, a second process
to run, and — the real constraint — **the exporter can only export what `monitoring` exposes.**

## The numbers that are missing

From what this book has covered, the signals that predict trouble:

| Signal | Exposed today | Why it matters |
|---|---|---|
| Active sessions | ✅ `monitoring` | Against `session_limit` ([2.5](06-sizing-and-tuning.md)) |
| Calls per second | ✅ via `check_and_add_cps()` | Against `cps_limit` |
| Thread count | ⚠️ `ps -L`, not SEMS | One thread per call ([2.1](02-thread-model.md)) |
| **Media tick overrun** | ❌ | The earliest sign of media trouble ([5.1](16-media-processor.md)) |
| **RTP ports in use** | ❌ | Against the configured range ([10.2](38-security-media.md)) |
| Transactions by state | ⚠️ only at shutdown | Growth in `TS_COMPLETED` means a peer stopped answering ([3.4](10-transaction-layer.md)) |
| **Sessions awaiting reaping** | ❌ | The `sleep(5)` queue ([2.3](04-memory-and-ownership.md)) |
| **Relay vs full media ratio** | ❌ | `requiresProcessing()` flipping ([6.2](22-b2b-media.md)) |
| Transcoding sessions | ❌ | Codec cost is a factor of four ([5.4](19-codecs-and-plugins.md)) |

### Media tick overrun is the important one

The media processor advances `next_tick` unconditionally
([5.1](16-media-processor.md)):

```cpp
    ts = (ts + WC_INC) & WALLCLOCK_MASK;
    timeradd(&tick,&next_tick,&next_tick);
```

A thread that misses its deadline simply stops sleeping and runs continuously. Average CPU can
look comfortable while bursts are already late — and late audio is audible.

Nothing counts those misses. The loop knows when `now > next_tick`; it just does not say so. A
counter of missed ticks, and the distribution of how late, would be the single highest-value
metric SEMS could export, because it is the only leading indicator of audio degradation.

### The others

**RTP ports in use** is checkable from outside (`ss -unlp`) but not exported. Against a configured
range it is a straightforward capacity signal.

**Sessions awaiting reaping** explains the `sleep(5)` gap between calls ending and memory
returning ([2.3](04-memory-and-ownership.md)). Growth here means the reaper is falling behind.

**Relay versus full media** is the difference between an SBC doing almost nothing and one doing a
great deal ([9.4](34-rtp-mux-and-relay.md)). A single ratio would predict CPU better than CPU
does.

**Transactions by state** already exists — `dumps_transactions()` prints the whole table
([3.4](10-transaction-layer.md)) — but only at shutdown. Exposing the counts continuously is a
small change to code that already walks the table.

## Two ways to close it

### Extend `monitoring`

Keep the sidecar; teach the core to report more into `monitoring`
([8.2](29-monitoring-and-stats.md)).

- **For:** no new dependency, no risk to the process, the exporter picks it up for free.
- **Against:** `monitoring` is per-call oriented — `LogBucket` keyed by Call-ID — and these are
  process-wide gauges. They fit the `inc`/`dec`/`addCount`/`addSample` API awkwardly, and the
  poll interval remains.

### A native exporter

What Yeti did ([12.3](45-fork-yeti-switch.md)).

- **For:** live values, no poll interval, one process, direct access to counters the RPC layer
  never sees.
- **Against:** an HTTP server and a metrics library linked into a process where a crash is an
  outage ([2.1](02-thread-model.md)). It is a plug-in, so it can be left out — but on the boxes
  that load it, the risk is real.

> [!TIP]
> The pragmatic split: **counters through `monitoring`, because they are cheap and the sidecar
> already reads them; a native exporter only if you need sub-poll-interval freshness.** For
> capacity planning a 15-second poll is fine. For catching a media thread going over budget in a
> traffic burst, it is not.

## Beyond metrics

**Structured logging.** The most useful diagnostic in the codebase is a grep — `vv S [` and
`^^ S [` bracketing every pass through a session's event loop
([4.1](12-amsession.md)), carrying the Call-ID, local tag, dialog status, pending transactions
and usage count. That is excellent information in an inconvenient format. Emitting it as
structured JSON would make it queryable without changing what is logged.

**Tracing.** SEMS has no trace context propagation, and a call crossing a proxy, an SBC and a
media server is exactly the shape distributed tracing was invented for. The Call-ID is already a
correlation id; what is missing is carrying a trace id across the B2BUA boundary, where the
dialog identifiers deliberately do not cross ([6.1](21-b2b-session.md)).

**Events, not just gauges.** `SBCEventLog` ([6.5](23c-sbc-call-control.md)) and the nine-valued
`StatusChangeCause` ([6.3](23-sbc.md)) already carry *why* a call changed state. Shipping those as
events would answer questions no gauge can — "why did the failure rate rise at 14:02" rather than
"the failure rate rose".

## If you are building one

1. **Start with `monitoring`.** The sidecar is already there; adding to what it reports is the
   smallest useful step.
2. **Instrument the media tick first.** It is the only leading indicator, and nothing else
   provides it.
3. **Export gauges, not just counters.** Sessions awaiting reaping, ports in use and relay ratio
   are all point-in-time values.
4. **Do not block anything.** A metrics path on the media thread must be lock-free or
   thread-local ([5.1](16-media-processor.md)).
5. **Protect the port.** The XML-RPC endpoint the sidecar polls is unauthenticated
   ([8.1](28-rpc-architecture.md), [10.1](37-security-surface.md)); a native `/metrics` endpoint
   would be one more listener to bind carefully.
