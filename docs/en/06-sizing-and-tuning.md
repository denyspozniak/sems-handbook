# 2.5 Sizing and tuning

> [!IMPORTANT]
> Two defaults surprise nearly everyone: **`media_processor_threads` is `1`**, and in a stock
> build there is **one OS thread per call**. Neither is wrong, but both are load-bearing, and
> neither is what people assume when they first size a box.

## The knobs that matter

Compile-time defaults live in `core/sems.h`; the shipped `core/etc/sems.conf.sample` sometimes
overrides them, and the two disagree in places worth knowing about.

| Setting | Compile default | In `sems.conf.sample` | What it controls |
|---|---|---|---|
| `media_processor_threads` | `NUM_MEDIA_PROCESSORS` = **1** | `1` (commented) | Threads running the 10 ms media tick |
| `session_processor_threads` | `NUM_SESSION_PROCESSORS` = 10 | `50` (commented) | **Only used in a `SESSION_THREADPOOL` build** — inactive by default |
| `rtp_low_port` | `RTP_LOWPORT` = 1024 | `10000` | Bottom of the RTP port range |
| `rtp_high_port` | `RTP_HIGHPORT` = 65535 | `60000` | Top of the RTP port range |
| `dead_rtp_time` | `DEAD_RTP_TIME` = **300** s | `0` or `10` in examples | Silence before a stream is declared dead. `0` disables |
| `max_shutdown_time` | `DEFAULT_MAX_SHUTDOWN_TIME` = **10** s | `10` (commented) | Ceiling on graceful drain ([2.4](05-lifecycle.md)) |
| `session_limit` | `0` = unlimited | `"1000;503;Server overload"` | Concurrent session cap, plus the reply when hit |
| `cps_limit` | unset | `"100;503;Server overload"` | Calls per second cap, plus the reply |
| `options_session_limit` | `0` | — | Separate cap so `OPTIONS` keepalives cannot be starved out |

> [!WARNING]
> `session_processor_threads` is the single most commonly mis-tuned option in SEMS, because it
> looks like the main concurrency knob and in a stock build it does **nothing**.
> `SESSION_THREADPOOL` is commented out in `CMakeLists.txt`, so the pooled model is not
> compiled in ([2.1](02-thread-model.md)). Setting it to 200 changes nothing at all.

## The media tick

The media processor is not event-driven. Each thread runs a fixed clock:

```cpp
#define WC_INC_MS 10LL /* 10 ms */
```

```cpp
  while(!stop_requested.get()){

    gettimeofday(&now,NULL);

    if(timercmp(&now,&next_tick,<)){
      struct timespec sdiff,rem;
      timersub(&next_tick,&now,&diff);
      sdiff.tv_sec  = diff.tv_sec;
      sdiff.tv_nsec = diff.tv_usec * 1000;

      if(sdiff.tv_nsec > 2000000) // 2 ms
        nanosleep(&sdiff,&rem);
    }

    processAudio(ts);
    events.processEvents();
    processDtmfEvents();

    ts = (ts + WC_INC) & WALLCLOCK_MASK;
    timeradd(&tick,&next_tick,&next_tick);
  }
```

Read this carefully, because the tuning story falls out of it:

- **The budget is 10 ms.** `processAudio()` must service *every* media session attached to this
  thread within one tick. Note that this is the internal processing tick, not the RTP
  packetisation interval — G.711 still emits a packet every 20 ms
  ([1.2](01b-sip-media-primer.md)).
- **`next_tick` advances unconditionally.** If a tick overruns, the loop does not sleep on the
  next pass and tries to catch up. Sustained overrun means audio is late, and late audio is
  audible.
- **It will not sleep for less than 2 ms.** Below that it spins through, on the reasoning that a
  `nanosleep` of under 2 ms costs more in scheduling jitter than it saves.
- **DTMF and events share the budget.** Slow event handling in a media thread eats the same
  10 ms as the audio.

Because the default is a single media thread, **one busy media session delays every other one on
the box**. Raising `media_processor_threads` is the first thing to do when you go beyond a
handful of concurrent media sessions; sessions are distributed across the threads at attach
time.

## What actually caps a box

In rough order of which ceiling you hit first:

**1. Threads and their stacks.** One thread per call, default stack usually 8 MB of virtual
address space (`ulimit -s`) with RSS growing only as touched. Virtual size is rarely the real
constraint, but `threads-max` and cgroup `pids.max` are — a container capped at 4096 PIDs caps
you at roughly that many calls regardless of CPU. Check `ps -L -p $(pgrep -x sems) | wc -l`
against your limit before blaming anything else.

**2. Media tick headroom.** Watch for tick overrun before watching CPU percentage: a media
thread at 60% average can still be missing deadlines in bursts. More threads, or fewer sessions
per box.

**3. RTP ports.** Each stream takes a port pair from `[rtp_low_port, rtp_high_port]`. The
sample's 10000–60000 gives 25 000 pairs — generous, but the range is also the firewall rule and
the attack surface, so narrow it to what you actually need ([10.2](38-security-media.md)).

**4. File descriptors.** Sockets, plus audio files, plus plug-in connections. `set_fd_limit()`
raises the soft limit at startup, but it cannot exceed the hard limit — set that in the unit
file, not in the config.

**5. Transcoding CPU.** Relay is nearly free; transcoding is not. The README's own figures make
the point: roughly 1200 G.711 conference channels on a machine that manages 700 with GSM and 280
with iLBC. Codec choice moves capacity by a factor of four
([5.4](19-codecs-and-plugins.md)).

## Admission control

`session_limit` and `cps_limit` are the two levers that keep an overloaded box answering rather
than collapsing. Both take a triple — limit, SIP code, reason:

```
session_limit="1000;503;Server overload"
cps_limit="100;503;Server overload"
```

`AmSessionContainer::check_and_add_cps()` enforces the rate; there is also
`setCPSSoftLimit(percent)` for a warning threshold below the hard one.

> [!TIP]
> Set these even when you think you are far from the limit. A rejected `503` is a call the
> upstream proxy can route elsewhere; an accepted call on a box that is out of media headroom is
> bad audio for everyone already on it. Failing fast is the correct behaviour for a media
> server, and it composes with a proxy's `dispatcher` on the other side.

`options_session_limit` exists so that keepalive `OPTIONS` traffic gets its own budget — without
it, a full box stops answering keepalives and gets marked down by the proxy exactly when you
least want it removed abruptly.

## `dead_rtp_time`

Default **300 seconds**: a stream that has heard nothing for five minutes is declared dead. That
is a long time to hold a session, a thread and a port pair for a call that is already gone —
typically the result of a NAT binding expiring or an endpoint disappearing without a `BYE`. The
sample configuration suggests much lower values, and `0` disables the check entirely.

Lower it if you are leaking sessions after network events; raise or disable it only if you
genuinely expect long one-way silence.

## A sizing checklist

1. Set `media_processor_threads` above 1 as soon as you have real media load.
2. Confirm your thread ceiling: `ulimit -u`, cgroup `pids.max`, `threads-max`.
3. Narrow the RTP range to the concurrency you plan for, then open exactly that in the firewall.
4. Raise the fd hard limit in the service unit.
5. Set `session_limit` and `cps_limit` deliberately, plus `options_session_limit`.
6. Lower `dead_rtp_time` from the 300 s default.
7. Size for your *worst* codec, not your best.
8. Remember the dead-session queue holds finished calls for at least five seconds, so measured
   memory lags active calls ([2.3](04-memory-and-ownership.md)).
