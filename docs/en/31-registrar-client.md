# 9.1 The registrar client

> [!NOTE]
> SEMS has no registrar. It is a registrar *client* — it registers itself, the way a phone does,
> so that a proxy knows where to send calls for it. That inversion catches people out
> ([1.1](01-introduction.md)): the media server is a subscriber, not a server, in this exchange.

## Why a media server registers at all

Three situations:

**No proxy at all.** `doc/Howtostart_noproxy.txt` describes registering SEMS to a public SIP
service exactly as a softphone would. Enough to try a service; not enough for anything needing
subscriber data.

**Outbound trunks.** SEMS places calls towards a carrier that expects a registration before it
will accept them.

**Gateways behind NAT.** Registration keeps a binding open so the far side can reach in.

## `AmSIPRegistration`

```cpp
struct SIPRegistrationInfo {
  string domain;
  string user;
  string name;
  string auth_user;
  string pwd;
  string proxy;
  string contact;
};
```

Note that `user` and `auth_user` are separate fields. The identity you register and the identity
you authenticate as are frequently different — a trunk registered as a pilot number but
authenticated with an account name — and conflating them is a classic first-day failure.

The registration object itself is a small state machine wrapped around a dialog:

```cpp
class AmSIPRegistration
{
  string sess_link;
  ...
  void setRegistrationInfo(const SIPRegistrationInfo& _info);
  void setSessionEventHandler(AmSessionEventHandler* new_seh);
  void setExpiresInterval(unsigned int desired_expires);

  bool doRegistration();
  bool doUnregister();

  bool timeToReregister(time_t now_sec);
  bool registerExpired(time_t now_sec);
  void onRegisterExpired();
  void onRegisterSendTimeout();
  bool registerSendTimeout(time_t now_sec);

  void onSendRequest(AmSipRequest& req, int& flags);
  void onSendReply(const AmSipRequest& req, AmSipReply& reply, int& flags);
  void onSipReply(const AmSipRequest& req, ...);

  bool active;
  bool remove;
  bool waiting_result;
  bool unregistering;

  enum RegistrationState { ... };
  RegistrationState getState();
  bool getUnregistering();
};
```

Three details worth extracting.

**`setSessionEventHandler()` is how authentication happens.** A registrar almost always
challenges with a `401`, and rather than implementing digest here, the registration attaches
`uac_auth` as a session event handler ([4.4](15-session-event-handlers.md)). The challenge is
answered by code that knows nothing about registration, and `AmSIPRegistration` never sees the
`401` — the handler returns `true` and swallows it.

**There are two distinct timeouts.** `registerExpired()` is "the binding we hold has run out";
`registerSendTimeout()` is "we sent a REGISTER and got no answer". A registrar that goes away
silently is a different failure from one that answers and lets the binding lapse, and the object
tracks them separately.

**`timeToReregister()` fires before expiry, not at it.** A refresh sent at the deadline arriving
late means a window with no binding. The standard practice is to refresh at some fraction of the
interval, and `setExpiresInterval()` is *desired* expiry — the registrar can grant less, and the
granted value is what the timers use.

`sess_link` is the local tag of a session to notify ([2.2](03-event-system.md)), so an
application can be told when its registration goes up or down rather than polling.

Registrations use dialogs without being calls, which is exactly why the dialog layer splits
`AmBasicSipDialog` from `AmSipDialog` ([3.5](11-dialog-layer.md)).

## Three applications

| Application | Registrations come from | Use |
|---|---|---|
| `reg_agent` | A configuration file | A fixed set of trunks |
| `db_reg_agent` | A database | Thousands, changing at runtime |
| `registrar_client` | RPC / other modules | Programmatic control |

`db_reg_agent` is the one that scales, and its problems are the interesting ones. Ten thousand
registrations with a one-minute interval is 167 REGISTERs per second forever, and if they were
all loaded at once they would land in the same second every minute. Any serious deployment of it
is an exercise in spreading that load — which is a scheduling problem, not a SIP problem.

`registrar_client` exposes a DI interface ([8.1](28-rpc-architecture.md)), so registrations can
be added and removed at runtime by an external system. It appears in the `xmlrpc2di` sample
configuration as a `direct_export` candidate:

```
# direct_export=di_dial;registrar_client
```

> [!WARNING]
> That means an unauthenticated RPC client can add registrations — telling a carrier that this
> box is now the destination for a number — and remove them, silently taking a trunk offline.
> The RPC ports have no authentication ([8.1](28-rpc-architecture.md)); this is one of the
> concrete reasons that matters ([10.1](37-security-surface.md)).

## Registration caching, in contrast

The SBC's `RegisterCache` ([6.5](23c-sbc-call-control.md)) is the mirror image and worth naming
here so the two are not confused:

| | `AmSipRegistration` | `RegisterCache` |
|---|---|---|
| Direction | SEMS registers **outward** | SEMS absorbs registrations **inward** |
| Role | Client | Server-ish, in front of a real registrar |
| State | Our bindings elsewhere | Other people's bindings with us |
| Used by | `reg_agent`, `db_reg_agent`, `registrar_client` | `cc_registrar` |

A single SBC often runs both: absorbing subscriber registrations on the access side while
registering itself to a carrier on the trunk side.

## Operating it

**Watch for flapping.** A registration that expires and re-registers repeatedly usually means
the granted expiry is shorter than assumed, or `timeToReregister()` is racing the network.

**A silent registrar is worse than a rejecting one.** `registerSendTimeout()` is the path that
detects it; without a session linked through `sess_link`, nothing may notice until calls fail.

**Credentials are in configuration.** `SIPRegistrationInfo::pwd` is a plain string, read from a
file or a database. That file's permissions are part of your security posture
([10.3](39-security-hardening.md)).
