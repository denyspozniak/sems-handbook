# 14.1 Term map

> [!TIP]
> If you came from Kamailio, read the second table first. Most confusion about SEMS is
> vocabulary, not architecture — the same idea wearing a different name.

## SEMS terms

| Term | Meaning | Lives in |
|---|---|---|
| **`AmSession`** | A call. A thread, an event queue, a dialog and a media session at once | `core/AmSession.*` ([4.1](12-amsession.md)) |
| **Local tag** | A session's identity and its mailbox address. The key the event dispatcher indexes on | `AmBasicSipDialog` ([3.5](11-dialog-layer.md)) |
| **Event queue** | A session's mailbox: a queue, a mutex, a condition variable, reference counted | `core/AmEventQueue.*` ([2.2](03-event-system.md)) |
| **Usage** | A reference held on a dialog by something that is not the session — a subscription, a registration. A session with a live usage will not exit | `AmBasicSipDialog` ([4.1](12-amsession.md)) |
| **Callgroup** | A set of sessions pinned to the same media processor thread. Conferences and B2B leg pairs are one group | `core/AmMediaProcessor.*` ([5.1](16-media-processor.md)) |
| **Media session** | Anything attachable to the media processor: an `AmSession`, or an `AmB2BMedia` serving two legs | `AmMediaSession` ([5.1](16-media-processor.md)) |
| **The tick** | The media processor's fixed 10 ms cycle. Not the RTP packetisation interval, which is 20 ms | `WC_INC_MS` ([5.1](16-media-processor.md)) |
| **Relay** | Forwarding RTP without decoding it, from the receiver thread. The cheap path | `AmRtpStream::relay_enabled` ([9.4](34-rtp-mux-and-relay.md)) |
| **Transcoding** | Decoding and re-encoding to bridge two codecs. Roughly four times the cost | ([5.4](19-codecs-and-plugins.md)) |
| **Leg** | One dialog of a B2BUA pair. A-leg faces the caller, B-leg the callee. **Roles can swap** | `AmB2BSession::a_leg` ([6.1](21-b2b-session.md)) |
| **DI** | Dynamic invocation. The single internal calling convention: a method name, an `AmArg` in, an `AmArg` out | `AmDynInvoke` ([8.1](28-rpc-architecture.md)) |
| **`AmArg`** | The dynamically typed value that crosses every module boundary | `core/AmArg.*` ([7.1](24-plugin-architecture.md)) |
| **Call profile** | An SBC policy template, evaluated per call through `ParamReplacer` | `SBCCallProfile` ([6.4](23b-sbc-profiles.md)) |
| **Call control module** | An SBC extension deciding policy from outside the request | ([6.5](23c-sbc-call-control.md)) |
| **DSM** | The state machine language for call flows, checked at load time | `apps/dsm/` ([7.2](25-dsm.md)) |
| **`amci`** | The C ABI for codecs and file formats. Older and separate from the C++ plug-in system | `core/amci/` ([5.4](19-codecs-and-plugins.md)) |
| **`cstring`** | A pointer and a length into a buffer someone else owns. Never outlives it | `core/sip/cstring.h` ([3.3](09-parser.md)) |
| **Session event handler** | An interceptor seeing a session's SIP before the application does | ([4.4](15-session-event-handlers.md)) |
| **Application selector** | The strategy choosing which application runs for an INVITE | `AmConfig::AppSelect` ([4.2](13-session-container-and-factories.md)) |

## Kamailio ↔ SEMS

The translation table. Where there is no equivalent, that absence is usually the interesting part.

| Kamailio | SEMS | Note |
|---|---|---|
| Worker process | **Session thread** | One thread per call, not a pool ([2.1](02-thread-model.md)) |
| `children` / `tcp_children` | — | No worker pool. `media_processor_threads` is the nearest knob, and it means something else ([2.5](06-sizing-and-tuning.md)) |
| `shm` (shared memory) | — | **No equivalent.** One process, one ordinary heap ([2.3](04-memory-and-ownership.md)) |
| `pkg` (private memory) | The C++ heap | Just `new` |
| `shm_malloc` / `pkg_malloc` | `new` | No custom allocator, no pool to size or exhaust |
| Memory dump RPC | — | Use `valgrind`, ASan, `massif` |
| `route` block | **Session callback** | `onInvite()`, `onSipRequest()` ([4.1](12-amsession.md)) |
| `kamailio.cfg` | `sems.conf` + a plug-in | Behaviour is code or a DSM script, not a config DSL |
| Module | **Plug-in** | `.so`, `dlopen`ed at startup ([7.1](24-plugin-architecture.md)) |
| `modparam` | Per-plug-in config file under `plugin_config_path` | Read during `onLoad()` |
| Pseudo-variable `$ru`, `$fu` | `ParamReplacer` `$r`, `$f` | Only inside SBC profiles ([6.4](23b-sbc-profiles.md)) |
| `tm` transaction | `sip_trans` in `trans_table` | 1024 buckets, keyed on Call-ID + CSeq ([3.4](10-transaction-layer.md)) |
| `tm` timers | `sip_timers.h`, the wheel timer | 4 wheels × 256 slots at 20 ms |
| `dialog` module | `AmSipDialog` | Not optional — a media server always has dialog state ([3.5](11-dialog-layer.md)) |
| `usrloc` / `registrar` | — | **No equivalent.** SEMS is a registration *client* ([9.1](31-registrar-client.md)) |
| `dispatcher` | — | **No equivalent.** DNS SRV plus timer M, and SBC parallel forking ([13.5](51-peer-dispatching.md)) |
| `topoh` / `topos` | Terminating as a B2BUA | Free once you terminate; expensive if that is all you wanted ([11.1](40-with-kamailio.md)) |
| `rtpengine` control | The media plane itself | SEMS *is* the media relay ([Part 5](16-media-processor.md)) |
| `siptrace` with HEP | `pcap_logger` | Local files only; **no HEP** ([13.2](48-hep-and-capture.md)) |
| `htable` | — | No shared table. Module-local state, or an external store |
| `dmq` | — | **No equivalent.** Instances share nothing ([11.2](41-topologies-and-ha.md)) |
| `jsonrpcs` / `kamcmd` | `jsonrpc`, `xmlrpc2di` | Both unauthenticated ([8.1](28-rpc-architecture.md)) |
| `event_route` | Session callbacks, DSM event types | ([7.2](25-dsm.md)) |
| KEMI (Lua, Python, JS) | DSM, `ivr`, `py_sems` | Different trade-offs ([7.4](27-app-tradeoffs.md)) |
| `pike`, `permissions` | — | Rate limiting and blocklisting belong in the proxy ([10.1](37-security-surface.md)) |
| `sl` stateless reply | `compute_sl_to_tag()` | Stateless replies exist; statelessness as a mode does not |

## Numbers worth remembering

| Value | Default | Where |
|---|---|---|
| Media tick | **10 ms** | `WC_INC_MS` ([5.1](16-media-processor.md)) |
| Wallclock rate | 102 400 Hz, 48-bit | Divisible by every sample rate ([5.1](16-media-processor.md)) |
| Internal sample rate | 32 000 Hz | `SYSTEM_SAMPLECLOCK_RATE` ([5.3](18-audio-pipeline.md)) |
| Media processor threads | **1** | `NUM_MEDIA_PROCESSORS` ([2.5](06-sizing-and-tuning.md)) |
| RTP receiver threads | 1 | `NUM_RTP_RECEIVERS`; libevent, so usually enough ([5.2](17-rtp-stream.md)) |
| Session processor threads | 10 | **Inactive** — `SESSION_THREADPOOL` is not compiled in ([2.1](02-thread-model.md)) |
| Timer wheel | 4 wheels × 256 slots × 20 ms | ([3.4](10-transaction-layer.md)) |
| Transaction table | 1024 buckets | ([3.4](10-transaction-layer.md)) |
| Event dispatcher | 1024 buckets | ([2.2](03-event-system.md)) |
| T1 | 500 ms | ([3.4](10-transaction-layer.md)) |
| Timer B | 64·T1 = **32 s** | Holds a session and a thread |
| Timer M | B/4 = 8 s | DNS failover; **at most four addresses tried** |
| `dead_rtp_time` | **300 s** | Lower it ([5.2](17-rtp-stream.md)) |
| `max_shutdown_time` | 10 s | ([2.4](05-lifecycle.md)) |
| Session reaper grace | `sleep(5)` | Why memory lags active calls ([2.3](04-memory-and-ownership.md)) |
| TCP connect timeout | 2 s | Aggressive on long-haul ([3.2](08-transport.md)) |
| TCP idle timeout | 1 hour | Generous; accumulates fds |
| RTP ports (sample) | 10000–60000 | 25 000 pairs — narrow it ([10.2](38-security-media.md)) |
| XML-RPC / JSON-RPC | 8090 / 7080 | **Unauthenticated** ([10.1](37-security-surface.md)) |
| Prometheus sidecar | 0.0.0.0:9090 | ([8.2](29-monitoring-and-stats.md)) |

## Grep recipes

| To find | Command |
|---|---|
| One call's whole life | `grep '\^\^ S \[<local-tag>' sems.log` |
| Sessions that will not die | `grep '\^\^ S \[' sems.log \| grep -v '0 usages'` |
| What was in flight at shutdown | `grep -A50 'Transaction table dump' sems.log` |
| Whether it actually started | `grep 'started' sems.log` ([2.4](05-lifecycle.md)) |
| Thread count | `ps -L -p "$(pgrep -x sems)" \| wc -l` |
| RTP sockets | `ss -unlp \| grep sems \| wc -l` |
