# 6.5 SBC call control modules

> [!NOTE]
> Profiles decide policy from the request itself ([6.4](23b-sbc-profiles.md)). Call control
> modules decide it from **anything else** — a database, a credit balance, a concurrent-call
> count, a REST API. They are the SBC's extension point, and there are two generations of the
> interface living side by side.

## Two interfaces, one purpose

| | Legacy | Modern |
|---|---|---|
| Header | `SBCCallControlAPI.h` | `ExtendedCCInterface.h` |
| Mechanism | DI calls with `AmArg` ([8.1](28-rpc-architecture.md)) | C++ virtual methods |
| Arguments | Positional integer constants | Typed parameters |
| Return | An action array | `CCChainProcessing` |
| Reach | Call lifecycle events | Lifecycle **plus** media, DTMF, hold, per-packet |

Both are live. The legacy one is how the older shipped modules work and how a module written in
another language can participate at all, since DI is reachable over RPC. The modern one is what
new C++ modules use.

## The legacy interface

Everything is positional:

```c
#define CC_INTERFACE_MAND_VALUES_METHOD "getMandatoryValues"

#define CC_API_PARAMS_CC_NAMESPACE      0
#define CC_API_PARAMS_LTAG              1
#define CC_API_PARAMS_CALL_PROFILE      2
#define CC_API_PARAMS_SIP_MSG           3
#define CC_API_PARAMS_TIMESTAMPS        4
#define CC_API_PARAMS_CFGVALUES         5
#define CC_API_PARAMS_TIMERID           6
#define CC_API_PARAMS_OTHERID           5
```

A module receives an `AmArg` array and indexes into it by constant. Note that `_CFGVALUES` and
`_OTHERID` are **both 5** — the meaning of a slot depends on which call it is. That is the cost
of positional arguments, and it is a good reason to prefer the modern interface for anything new.

Timestamps are positional too:

```c
#define CC_API_TS_START_SEC             0
#define CC_API_TS_START_USEC            1
#define CC_API_TS_CONNECT_SEC           2
#define CC_API_TS_CONNECT_USEC          3
#define CC_API_TS_END_SEC               4
#define CC_API_TS_END_USEC              5
```

Start, connect and end, at microsecond resolution — the three timestamps a CDR needs, and the
reason `syslog_cdr` can be as small as it is.

The module answers with actions:

```c
#define SBC_CC_DROP_ACTION              0
#define SBC_CC_REFUSE_ACTION            1
#define SBC_CC_SET_CALL_TIMER_ACTION    2
#define SBC_CC_REPL_SET_GLOBAL_ACTION        10
#define SBC_CC_REPL_REMOVE_GLOBAL_ACTION     11

#define SBC_CC_ACTION              0
#define SBC_CC_REFUSE_CODE         1
#define SBC_CC_REFUSE_REASON       2
#define SBC_CC_REFUSE_HEADERS      3
#define SBC_CC_TIMER_TIMEOUT       1
#define SBC_CC_REPL_SET_GLOBAL_SCOPE 1
#define SBC_CC_REPL_SET_GLOBAL_NAME  2
#define SBC_CC_REPL_SET_GLOBAL_VALUE 3
```

Five things a module can ask for:

- **Drop** — silently discard. No response at all, which is the correct treatment for traffic
  you do not want to acknowledge ([10.3](39-security-hardening.md)).
- **Refuse** — reject with a code, reason and optional headers.
- **Set call timer** — end the call after N seconds. This is the whole of `call_timer`.
- **Set / remove a global** — write a variable that `ParamReplacer` can later read as `$V(...)`
  ([6.4](23b-sbc-profiles.md)). A module computes something and the profile uses it: that
  hand-off is how database-driven routing is built without teaching the profile about databases.

Timers arrive back as an event:

```c
#define SBCCallTimerEvent_ID -563

struct SBCCallTimerEvent : public AmEvent {
  enum TimerAction {
    Remove = 0,
    Set,
    Reset
  };
  TimerAction timer_action;
  double timeout;
  int timer_id;
  ...
};
```

`getMandatoryValues` lets a module declare which configuration values it requires, so a
misconfiguration fails at load rather than on the first call.

## The modern interface

```cpp
enum CCChainProcessing { ContinueProcessing, StopProcessing };

class ExtendedCCInterface
{
    virtual bool init(SBCCallLeg *call, const map<string, string> &values) { return true; }
    virtual void onStateChange(SBCCallLeg *call, const CallLeg::StatusChangeCause &cause) { }
    virtual void onDestroyLeg(SBCCallLeg *call) { }

    virtual CCChainProcessing onBLegRefused(SBCCallLeg *call, const AmSipReply& reply) { return ContinueProcessing; }
    virtual CCChainProcessing onInitialInvite(SBCCallLeg *call, InitialInviteHandlerParams &params) { return ContinueProcessing; }
    virtual CCChainProcessing onInDialogRequest(SBCCallLeg *call, const AmSipRequest &req) { return ContinueProcessing; }
    virtual CCChainProcessing onInDialogReply(SBCCallLeg *call, const AmSipReply &reply) { return ContinueProcessing; }
    virtual CCChainProcessing onEvent(SBCCallLeg *call, AmEvent *e) { return ContinueProcessing; }
    virtual CCChainProcessing onDtmf(SBCCallLeg *call, int event, int duration) { return ContinueProcessing; }

    virtual void holdRequested(SBCCallLeg *call) { }
    virtual void holdAccepted(SBCCallLeg *call) { }
    virtual void holdRejected(SBCCallLeg *call) { }
    virtual void resumeRequested(SBCCallLeg *call) { }
    virtual void resumeAccepted(SBCCallLeg *call) { }
    virtual void resumeRejected(SBCCallLeg *call) { }

    virtual void onAfterRTPRelay(SBCCallLeg *call, AmRtpPacket* p, ...);
    virtual int relayEvent(SBCCallLeg *call, AmEvent *e) { return 0; }
    ...
};
```

`CCChainProcessing` is the same "stop the chain" idea as the session event handlers
([4.4](15-session-event-handlers.md)), but named and typed rather than a bare `bool`. That is a
real improvement: `return StopProcessing` says what it does, where `return true` did not.

Three groups of hooks are worth calling out.

**`onStateChange()` receives the `StatusChangeCause`** from [6.3](23-sbc.md), so a module knows
not just that the call moved but why — SIP reply, RTP timeout, no ACK, session timeout. That is
what turns a CDR from a record into a diagnosis.

**Six hold hooks** exist because hold is a negotiation that can be requested, accepted or
rejected on either direction, and a policy module may need to intervene at any of those points.

**`onAfterRTPRelay()` is a per-packet media hook.**

> [!IMPORTANT]
> This is the only place in the SBC where a module sees individual RTP packets. It is what
> `cc_siprec` uses to fork media to a recorder, and it is the natural tap point for anything
> that wants a copy of the audio — including streaming to an ASR engine
> ([13.4](50-media-forking-stt-tts.md)).
>
> It runs on the RTP receiver thread in relay mode ([5.2](17-rtp-stream.md)), so the constraint
> is absolute: **it must not block.** No synchronous network write, no lock that another thread
> holds for long. Queue and return.

A second, smaller hook set serves `SBCSimpleRelay` ([6.3](23-sbc.md)):

```cpp
    virtual bool init(SBCCallProfile &profile, SimpleRelayDialog *relay, void *&user_data) { return true; }
    virtual void initUAC(const AmSipRequest &req, void *user_data) { }
    virtual void initUAS(const AmSipRequest &req, void *user_data) { }
    virtual void finalize(void *user_data) { }
    virtual void onSipRequest(const AmSipRequest& req, void *user_data) { }
    virtual void onSipReply(const AmSipRequest& req, ...);
    virtual void onB2BRequest(const AmSipRequest& req, void *user_data) { }
    virtual void onB2BReply(const AmSipReply& reply, void *user_data) { }
```

Note the `void *user_data` running through it: the simple relay has no `SBCCallLeg` to hang
state on, so a module gets an opaque slot instead.

## The shipped modules

```
bl_redis  call_timer  ctl       dsm       parallel_calls  prepaid
prepaid_xmlrpc        registrar rest      siprec          syslog_cdr  template
```

Grouped by what they actually do:

**Admission and limits**

| Module | Does |
|---|---|
| `bl_redis` | Blacklist lookups in Redis. Answers with a drop or refuse action |
| `parallel_calls` | Concurrent-call limiting per user — count, compare, refuse |
| `call_timer` | Maximum call duration, implemented purely as `SBC_CC_SET_CALL_TIMER_ACTION` |

**Billing**

| Module | Does |
|---|---|
| `prepaid` | Local credit-based control: check balance, set a timer for the affordable duration, debit at the end |
| `prepaid_xmlrpc` | The same against an external XML-RPC billing server |

The prepaid pattern is worth understanding as a design: credit becomes a *call timer*, so the
enforcement mechanism is the same one `call_timer` uses. The module does not police the call
second by second; it computes how long the money lasts and lets the timer do the work.

**Routing and identity**

| Module | Does |
|---|---|
| `registrar` | REGISTER caching and retargeting — see below |
| `ctl` | Profile control via SIP headers: let the request itself steer policy |
| `rest` | Call control over a REST API — the escape hatch to any external system |

> [!WARNING]
> `ctl` lets a header change SBC behaviour. On an untrusted interface that is precisely the
> problem described in [6.4](23b-sbc-profiles.md) and [10.1](37-security-surface.md). Use it
> only where the sender is trusted.

**Recording and reporting**

| Module | Does |
|---|---|
| `siprec` | SIPREC (RFC 7865/7866) recording, driven by `onAfterRTPRelay()` ([9.5](35-siprec-and-recording.md)) |
| `syslog_cdr` | Call detail records to syslog, using the three timestamps and the status-change cause |

**Scripting and scaffolding**

| Module | Does |
|---|---|
| `dsm` | Runs a DSM state machine as call control ([7.2](25-dsm.md)) — policy in a script instead of C++ |
| `template` | An empty skeleton. The right starting point for your own |

`cc_dsm` deserves emphasis: it means SBC call control can be written in the DSM scripting
language rather than compiled C++, which for a policy that changes often is a much better
trade — no rebuild, no restart, and a crash in a script does not take the process with it
([7.4](27-app-tradeoffs.md)).

## Registration caching

`RegisterCache.cpp` (1116 lines) and `RegisterDialog.cpp` (659 lines) are a substantial
subsystem sitting behind the `registrar` module.

The problem: endpoints re-REGISTER every minute or two. Passing all of that to a registrar
behind the SBC is wasteful, and it means the SBC has no idea where anyone is when a call arrives
for them.

The cache absorbs registrations, maintains its own binding table, and refreshes upstream on a
longer interval. It then knows how to reach a registered user directly — which is what makes the
`$u`, `$Ua` and `$UA` substitutions possible in profiles ([6.4](23b-sbc-profiles.md)):

| Token | Meaning |
|---|---|
| `$u` | The cached destination user for this call |
| `$Ua` | The originating address of record |
| `$UA` | The originating alias — the SBC-side identity |

The alias is the interesting one: the SBC gives each registration a local identity, so the
inside of the network never sees the outside's addressing, and NAT bindings stay attached to
something the SBC controls.

`SBCCallRegistry.cpp` maintains the call-level registry alongside it, and `SBCEventLog.cpp`
provides structured event logging that modules can write into.

## Writing a module

1. Start from `call_control/template`.
2. Implement `ExtendedCCInterface`; return `ContinueProcessing` from anything you do not handle.
3. Declare required configuration so it fails at load, not at call time.
4. Name it in the profile's `cc_name` / `cc_module` fields ([6.4](23b-sbc-profiles.md)).
5. Communicate results to the profile by setting globals, read back as `$V(...)`.

> [!WARNING]
> A call control module runs **in-process** ([2.1](02-thread-model.md)). A blocking database
> call inside `onInitialInvite()` stalls a session thread; a segfault takes the whole server and
> every call on it. If the logic needs to talk to something slow or unreliable, either do it
> asynchronously or put it behind `rest` and let the network boundary contain the failure.
