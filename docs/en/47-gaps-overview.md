# 13.1 Gaps and directions

> [!NOTE]
> This part is forward-looking, and it tries to be honest in both directions. For each capability
> it states **what the tree already has** — which is usually more than people assume — what is
> genuinely missing, and what adding it would involve. Every "SEMS does not have X" here is
> backed by a grep that came up empty, re-run on 2026-08-29.

## The scorecard

| Capability | Present in `sems-server/sems` | Absent |
|---|---|---|
| **Packet capture** | `core/sip/msg_logger.*`, `pcap_logger.*` — writes pcap locally, attachable to SIP and to both media streams | **No HEP/Homer transport.** Zero hits for `hep` or `homer` across `core`, `apps` and `doc` |
| **Metrics** | `apps/monitoring` plus a **Rust sidecar**, `sems-prometheus-exporter`, polling XML-RPC and serving `/metrics` on `0.0.0.0:9090` | No in-process exporter. The metric set is bounded by what `monitoring` exposes. `yeti-switch/sems` ships a native `prometheus` module ([12.3](45-fork-yeti-switch.md)) |
| **STT / TTS** | `flite_text_to_speech()` in `apps/ivr` and `apps/conference` — synthesis **to a file**. Media forking outward via SIPREC (`cc_siprec`, `apps/siprec_srs`). The `AmAudio` chain and `onAfterRTPRelay()` as tap points | **No real-time streaming.** Zero hits for websocket, gRPC or any ASR vendor |
| **Peer dispatching** | `SBCCallProfile::next_hop`, `outbound_proxy`, R-URI rewriting, DNS SRV/NAPTR in `core/sip/resolver.*`, timer M for address failover, parallel forking via `CallLeg::other_legs`, and a documented serial-fork hook at `apps/sbc/CallLeg.h:211` | **No `dispatcher` equivalent.** No peer list, no active health probing, no failover policy, no runtime peer state |

Three of the four are partial rather than absent. That matters: the work in each case is
extending something that exists, not building from nothing.

> [!WARNING]
> `apps/dis_test` is **DIS** — Distributed Interactive Simulation, a module that generates a
> 400 Hz test tone and sends EntityStatePDU packets. It is not a dispatcher. The name has misled
> people.

## The standing question

Every item here runs into the same decision, and it is worth naming once:

**Does this belong in the SEMS process, in the proxy, or in a sidecar?**

The constraints that make it a real question are all from earlier in this book:

- **One process, one blast radius.** A crash in any linked library takes every call on the box
  ([2.1](02-thread-model.md)). Adding a metrics library, an HTTP client or an ASR SDK to the
  process is taking on that risk.
- **The media tick is 10 ms and shared** ([5.1](16-media-processor.md)). Anything on the media
  path must not block. `async_file_writer` is the pattern ([2.4](05-lifecycle.md)).
- **The proxy already exists and is cheap** ([11.1](40-with-kamailio.md)). Routing, rate
  limiting, blocklisting and topology hiding all cost less there.

### The worked example: Prometheus

Upstream and Yeti answered it in opposite directions, and both answers are defensible
([8.2](29-monitoring-and-stats.md), [12.3](45-fork-yeti-switch.md)):

| | Upstream: sidecar | Yeti: native module |
|---|---|---|
| Risk to SEMS | None | A library in a single-process server |
| Freshness | A poll interval behind | Live |
| Deployment | Two processes | One |
| Metric set | Whatever `monitoring` exposes | Whatever the module chooses |
| Effort | Rust tool, no C++ changes | A module, and its maintenance |

The sidecar is the conservative choice and the right default for anything that only needs to
*read* state. It stops being enough when the numbers you want are not exposed at all — which is
exactly the position [13.3](49-metrics-and-observability.md) describes.

### A rule of thumb

**In the proxy** if it is about *which* call goes *where*: routing, peer selection, rate
limiting, blocklisting, per-source policy.

**In a sidecar** if it only reads state, or can tolerate a poll interval: metrics, inventory,
reporting.

**In the process** only if it needs data the process holds and nothing else can see: individual
RTP packets, decoded audio, per-message SIP. That is a short list, and it is where the remaining
chapters of this part concentrate.

## What the forks tell us

Reading [Part 12](43-family-overview.md) as commentary on these gaps:

- **Yeti wrote a native Prometheus module.** A team operating a carrier switch found the sidecar
  insufficient. That is the strongest evidence any of these gaps is real.
- **Yeti built its routing engine above SEMS**, not inside it — LCR, load control, number
  portability. Evidence that the peer-dispatching gap ([13.5](51-peer-dispatching.md)) is
  correctly located outside SEMS, even though it is a gap.
- **Nobody added SRTP or HEP.** Three independent teams, three deployments, and neither appeared.
  Either both are genuinely low priority, or both are consistently solved by another component in
  the path.

## What each remaining chapter argues

**[13.2](48-hep-and-capture.md) — HEP.** A genuine absence with an obvious shape: `msg_logger`
already receives exactly the tuple HEP transports. A new subclass sending UDP, and nothing else
changes. The cleanest of the four.

**[13.3](49-metrics-and-observability.md) — metrics.** Partly solved. The interesting question is
not the exporter but *which numbers*: four of the seven signals worth watching are not exposed by
anything today.

**[13.4](50-media-forking-stt-tts.md) — STT/TTS streaming.** The most demanded and the most
constrained. Tap points exist; the 10 ms tick and the single-process risk shape everything about
how one could be used.

**[13.5](51-peer-dispatching.md) — peer dispatching.** The one where the honest answer is usually
"put it in the proxy" — with a clear statement of the cases where it is not.

## How to read this part

Nothing here is a roadmap. There is no plan to implement any of it, and this book does not speak
for the project.

What it is: an assessment of where the code stands, what it would take to move it, and what to
weigh before trying. If you are considering building one of these, the value is in the
constraints — most of them are already documented in Parts 2 through 11, and violating them is
how a well-intentioned patch turns into an outage.
