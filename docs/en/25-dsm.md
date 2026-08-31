# 7.2 DSM

> [!IMPORTANT]
> DSM is a **domain-specific language for call flows**, compiled at load time into a state
> machine that the SEMS core drives. It is not a general-purpose scripting language and does not
> try to be. Everything it does well follows from being exactly one thing: states, transitions,
> conditions, actions.

## A whole application

Here is a complete DSM script, from `apps/dsm/lib/`:

```text
-- another nonsensical fsm...
initial state start;
transition "just an example" start - / { playPrompt(1); playPrompt(2); playPrompt(3); } -> end;
state end;
transition "stop it" end - noAudioTest() / stop(true) -> end;
transition "bye recvd" (start, end) - hangup() / stop(false) -> end;
```

Five lines, and the grammar is visible in them:

```
transition "<name>" <from-state> - <conditions> / <actions> -> <to-state>;
```

- **`-`** introduces the conditions. Empty means unconditional.
- **`/`** introduces the actions, in braces if there is more than one.
- **`->`** names the destination state.
- A from-state can be a **list** — `(start, end)` — so one transition covers several states.
  That last line is the idiom for "handle hangup wherever we are".

Comments are `--`. That is the whole surface syntax.

## The event vocabulary

Conditions match against an event type, and the enum is the honest list of everything a call
flow can react to:

```cpp
  enum EventType {
    Any,
    Start,
    Invite,
    SessionStart,
    Ringing,
    EarlySession,
    FailedCall,
    SipRequest,
    SipReply,
    BeforeDestroy,
    Hangup,
    Hold,
    UnHold,
    B2BOtherRequest,
    B2BOtherReply,
    B2BOtherBye,
    SessionTimeout,
    RtpTimeout,
    RemoteDisappeared,
    Key,
    Timer,
    NoAudio,
    PlaylistSeparator,
    DSMEvent,
    B2BEvent,
    DSMException,
    XmlrpcResponse,
    JsonRpcResponse,
    JsonRpcRequest,
    Startup,
    Reload,
    System,
    SIPSubscription,
    RTPTimeout,
    // SBC related
    LegStateChange,
    BLegRefused,
    PutOnHold,
    ResumeHeld,
    CreateHoldRequest,
    HandleHoldReply,
    RelayInit,
    RelayInitUAC,
    RelayInitUAS,
    RelayFinalize,
    RelayOnSipRequest,
    RelayOnSipReply,
    RelayOnB2BRequest,
    RelayOnB2BReply
#ifdef WITH_ZRTP
    , ZRTPProtocolEvent,
    ZRTPSecurityEvent
#endif
  };
```

Read that list as a summary of the whole book. `SessionStart` and `EarlySession` are
[3.5](11-dialog-layer.md); `Key` is DTMF ([5.5](20-dtmf-and-jitter.md)); `PlaylistSeparator` is
the audio chain ([5.3](18-audio-pipeline.md)); `RtpTimeout` is `dead_rtp_time`
([5.2](17-rtp-stream.md)); the `B2BOther*` family is [6.1](21-b2b-session.md); and the entire
`// SBC related` block is [6.5](23c-sbc-call-control.md) — which is how `cc_dsm` lets an SBC
call control policy be written as a script.

`JsonRpcRequest` and `XmlrpcResponse` are worth noticing: a DSM script can be driven by, and can
call out to, RPC ([8.1](28-rpc-architecture.md)). A call flow can consult an external service
mid-call without a line of C++.

`invert` on the condition is the `!` operator — negation is a property of the condition object,
not a separate node.

## Actions that steer the engine

Most actions just do something. A few change the engine's control flow, and they say so through
a second method:

```cpp
class DSMAction : public DSMElement {
 public:
  /** modifies State Engine operation */
  enum SEAction {
    None,   // no modification
    Repost, // repost current event
    Jump,   // jump FSM
    Call,   // call FSM
    Return, // return from FSM call
    Break   // break execution of current action list
  };

  virtual bool execute(...) = 0;
  virtual SEAction getSEAction(string& param, ...) { return None; }
};
```

`Jump`, `Call` and `Return` make DSM more than a flat state machine — diagrams can call other
diagrams and return, so a "collect a PIN" flow is written once and reused:

```cpp
  bool callDiag(const string& diag_name, ...);
  bool jumpDiag(const string& diag_name, ...);
  bool returnDiag(...);
```

with a call stack of `DSMStackElement`s behind it.

`Repost` is the subtle one. An action can re-deliver the current event after a state change, so
a transition can switch states and then let the *new* state handle the same event. It is how you
avoid duplicating handling across states.

`Break` stops the remaining actions in the current list without leaving the transition.

## Beyond a flat FSM

The language has grown control flow that a pure state machine does not have:

```cpp
class DSMFunction { ... };

class DSMArrayFor
{
  enum DSMForType { ... };
  string array_struct; // array or struct name, or range upper bound
  ...
};

class DSMConditionTree
{
  vector<DSMCondition*> conditions;
  ...
  bool is_exception;
};
```

Functions, iteration over an array, a struct or a numeric range, and condition trees with an
`is_if` flag in the reader — so conditions can be grouped rather than only ANDed.

Exceptions are first class:

```cpp
class DSMException { ... };
```

with `is_exception` on both transitions and condition trees. A transition can be marked as the
handler for exceptions raised in a state, which for a call flow talking to a database or an HTTP
API is the difference between a clean error prompt and a dropped call.

## The reader, and load-time checking

```cpp
class DSMChartReader {
  bool is_wsp(const char c);
  bool is_snt(const char c);
  ...
  DSMCondition* conditionFromToken(const string& str, bool invert);
  bool forFromToken(DSMArrayFor& af, const string& token);
  bool importModule(const string& mod_cmd, const string& mod_path);

  vector<DSMModule*> mods;
  vector<DSMFunction*> funcs;

  bool decode(DSMStateDiagram* e, const string& chart, ..., vector<DSMModule*>& out_mods);
};
```

A hand-written tokeniser and parser — no lexer generator — producing a `DSMStateDiagram`.

The valuable part is what happens next:

```cpp
class DSMStateDiagram  {
  bool checkInitialState(string& report);
  bool checkDestinationStates(string& report);
  bool checkHangupHandled(string& report);
  ...
  bool checkConsistency(string& report);
};
```

Three static checks at load time, each returning a human-readable report:

| Check | Catches |
|---|---|
| `checkInitialState` | No initial state, or more than one |
| `checkDestinationStates` | A transition pointing at a state that does not exist |
| `checkHangupHandled` | **A state with no path out on hangup** |

That third one is the good idea. The most common bug in a hand-written call flow is a state that
does not handle the caller hanging up — and it does not fail, it leaks a session until
`dead_rtp_time` five minutes later ([5.2](17-rtp-stream.md)). DSM refuses to load a diagram with
that hole.

> [!TIP]
> A typo'd state name is a load error with a report naming the state, not a runtime surprise.
> That is a genuine advantage over the Python applications ([7.3](26-ivr-and-python.md)), where
> the equivalent mistake is an exception on the call that hits it.

## Modules

DSM by itself can play prompts, collect keys and manipulate variables. Everything else is a
module, loaded by `importModule()`:

```
mod_aws  mod_conference  mod_curl  mod_dlg    mod_groups  mod_monitoring
mod_mysql  mod_py  mod_redis  mod_regex  mod_sbc  mod_subscription
mod_sys  mod_uri  mod_utils  mod_xml  mod_zrtp
```

| Module | Gives a script |
|---|---|
| `mod_mysql`, `mod_redis` | Database and cache access |
| `mod_curl` | HTTP requests |
| `mod_aws` | AWS services |
| `mod_conference` | Conference control ([9.2](32-conference-and-mixing.md)) |
| `mod_dlg` | Dialog manipulation — send requests, replies, re-INVITEs |
| `mod_sbc` | SBC integration, for `cc_dsm` ([6.5](23c-sbc-call-control.md)) |
| `mod_subscription` | SUBSCRIBE/NOTIFY |
| `mod_regex`, `mod_uri`, `mod_utils`, `mod_xml` | String, URI, XML manipulation |
| `mod_groups`, `mod_monitoring`, `mod_sys` | Grouping, statistics, system access |
| `mod_py` | **Embedded Python inside a DSM script** |
| `mod_zrtp` | ZRTP events ([9.6](36-zrtp-and-srtp.md)) |

`mod_py` is the escape hatch, and it is worth being explicit about what it means: a DSM script
that uses it inherits Python's costs ([7.3](26-ivr-and-python.md)) for that part of the flow.
Reach for it when the alternative is a new C++ module, not as a default.

> [!WARNING]
> `mod_mysql` and `mod_curl` do **blocking** I/O. A DSM script runs on the session's thread
> ([2.1](02-thread-model.md)), so a slow query blocks that call — which is survivable — but in a
> `SESSION_THREADPOOL` build it would block every session sharing the worker, and in a call
> control module it blocks inside the SBC's call setup path ([6.5](23c-sbc-call-control.md)).
> Keep queries fast and set timeouts.

## Where the state lives

```cpp
class DSMSession { ... };
class DSMCall { ... };
class SystemDSM { ... };
```

`DSMSession` is the script-visible session state — the variables a script sets and reads.
`DSMCall` is a call running a diagram. `SystemDSM` is a diagram running with **no call at all**,
driven by `Startup`, `Reload` and `System` events — which is how DSM does background work:
periodic tasks, cache warming, reacting to RPC.

## When DSM is the right answer

**Yes:** call flows — IVR menus, announcements, voicemail front ends, prompt-and-collect,
SBC policy that changes often. Anything where the logic is "in this state, on this event, do
this and go there".

**No:** anything CPU-bound, anything needing a data structure more complex than a struct,
anything where you want real testing infrastructure. And it is a poor fit for algorithms — the
control flow is deliberately limited, and fighting it produces scripts nobody can read.

The comparison against C++ and Python is [7.4](27-app-tradeoffs.md).
