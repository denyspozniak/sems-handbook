# 12.3 yeti-switch/sems

> [!WARNING]
> **The configuration format is deliberately incompatible with mainline SEMS.** The Yeti
> documentation says so explicitly. A `sems.conf` from this book will not work here, and this
> chapter exists partly to stop you trying.

## What it is

The repository describes itself in one line:

> SEMS core forked from https://github.com/sems-server/sems

and adds that it is part of project Yeti, pointing at `yeti-switch.org`.

So this is not SEMS with additions. It is **the media and signalling engine of a larger system**.
Yeti is an open-source platform that is simultaneously a SIP Session Border Controller, a
class-4 softswitch and a real-time VoIP billing system, aimed at carrier interconnection and
wholesale transit. Around the SEMS core it adds LCR and load-aware routing, real-time billing for
wholesale and retail, a REST API, a customer portal, and features like STIR/SHAKEN and Microsoft
Teams Direct Routing.

That framing explains everything else about the fork. SEMS here is a component, not a product.

## Why the configuration diverged

Yeti's documentation states it plainly: the fork "has multiple changes" making it incompatible
with mainline, and users should follow Yeti-specific installation and configuration procedures.

This is the pattern noted in [12.1](43-family-overview.md) — configuration is the surface users
touch, so it is the first thing a fork reshapes.

For Yeti the reason is structural. In upstream SEMS, an application is selected per call by a
strategy over the request ([4.2](13-session-container-and-factories.md)), and policy lives in
SBC profiles that are templates evaluated per call
([6.4](23b-sbc-profiles.md)). In Yeti, routing and policy come from Yeti's own database and REST
API. Configuring a call the SEMS way would mean two systems owning the same decision.

So the fork reshaped configuration around Yeti's model and stopped pretending the two were
interchangeable. That is more honest than a compatibility layer that works until it does not.

## What it adds

The documentation lists seven areas, and each is worth reading against the upstream:

| Yeti module | Upstream equivalent |
|---|---|
| **SEMS Configuration** | Reshaped; not compatible ([2.5](06-sizing-and-tuning.md)) |
| **Yeti module** (with an Internals section) | No equivalent — routing, billing, the switch itself |
| **Prometheus module** | **None.** Upstream uses a Rust sidecar ([8.2](29-monitoring-and-stats.md)) |
| **JsonRPC module** | `apps/jsonrpc` exists upstream ([8.1](28-rpc-architecture.md)) |
| **Codecs modules** | `core/plug-in/` ([5.4](19-codecs-and-plugins.md)) |
| **File Formats modules** | The `amci` file interface ([5.4](19-codecs-and-plugins.md)) |
| **DI Log module** | Related to the DI interface ([8.1](28-rpc-architecture.md)) |

Two of those matter beyond the list.

### The native Prometheus module

This is the clearest divergence in the whole family, because both branches solved the same
problem in opposite ways ([8.2](29-monitoring-and-stats.md)):

| | Upstream | Yeti |
|---|---|---|
| Where | Out of process — a Rust exporter polling XML-RPC | **In process** — a native module |
| Freshness | A poll interval behind | Live |
| Metric set | Whatever `monitoring` exposes | Whatever the module chooses |
| Deployment | Two processes | One |
| Risk | None to SEMS | A metrics library inside a process where a crash is an outage ([2.1](02-thread-model.md)) |

Neither is wrong. Upstream optimised for not touching a single-process server; Yeti optimised for
operating a switch, where a poll interval and a second moving part are real costs. It is the
standing question of [13.1](47-gaps-overview.md) with two documented answers.

### That there is a documented "Internals" section

The Yeti module's documentation has one, which is unusual and tells you the module is substantial
— routing, billing and call handling deep enough that operators need to understand it, not just
configure it.

## Packaging and installation

Yeti recommends installing from its own **Debian repositories** rather than building from source.
Combined with the incompatible configuration, that makes the fork a complete distribution channel
of its own: its own packages, its own configuration, its own documentation.

Practically: you install Yeti, and Yeti brings this SEMS. You do not install this SEMS and then
add Yeti.

## What is still the same

The internals in Parts 2–11 largely apply, because this is still SEMS at the core:

- **The thread model** — one process, threads, no shared memory
  ([2.1](02-thread-model.md), [2.3](04-memory-and-ownership.md)).
- **The event system** — `AmEvent`, `AmEventQueue`, the sharded dispatcher
  ([2.2](03-event-system.md)).
- **The SIP stack** — `core/sip/`, `cstring`, the transaction table, the wheel timer
  ([Part 3](07-sip-stack-overview.md)).
- **The session core** — `AmSession`, offer/answer ([Part 4](12-amsession.md)).
- **The media plane** — the 10 ms tick, `AmRtpStream`, the audio chain
  ([Part 5](16-media-processor.md)).
- **B2BUA** — `AmB2BSession`, `AmB2BMedia` ([Part 6](21-b2b-session.md)).

So this book is still a reasonable guide to *how it works*. It is not a guide to *how to
configure it*.

> [!TIP]
> If you operate Yeti and want to understand what the process is actually doing — why one media
> thread saturates ([5.1](16-media-processor.md)), why sessions linger after a call ends
> ([2.3](04-memory-and-ownership.md)), why a peer that stops answering costs 32 seconds
> ([3.4](10-transaction-layer.md)) — the mechanisms are the ones described here. Take the
> concepts, take the configuration from Yeti.

## What it says about upstream

Yeti is the strongest evidence for the gaps in [Part 13](47-gaps-overview.md). A team building a
production carrier switch on SEMS needed, and wrote, a native metrics module — because the
upstream's observability story is a sidecar polling an unauthenticated XML-RPC port
([8.1](28-rpc-architecture.md), [8.2](29-monitoring-and-stats.md)).

It is also evidence for the peer-dispatching gap ([13.5](51-peer-dispatching.md)). Yeti's
headline features are LCR, load control and number portability — a routing engine, built above
SEMS because SEMS has no peer list, no health state and no routing model of its own
([1.1](01-introduction.md)).

## Who should care

**Run it** if you are deploying Yeti. That is the audience.

**Read about it** if you are evaluating whether to build a switch on SEMS — Yeti is the existence
proof that it works, and its module list is a good inventory of what you would have to write.

**Do not** take configuration from here to mainline or the reverse. The documentation warns about
this, and so does this chapter.
