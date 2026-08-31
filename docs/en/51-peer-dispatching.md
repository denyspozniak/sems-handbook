# 13.5 Dispatching to a peer group

> [!IMPORTANT]
> This is the gap where the honest answer is usually **"put it in the proxy"**. SEMS has more
> destination selection than people assume — including genuine parallel forking — and still no
> peer list with health state. This chapter sets out both, and the cases where the proxy answer
> is wrong.

## What exists, which is more than you think

### Static next hop

`SBCCallProfile` ([6.4](23b-sbc-profiles.md)) carries the same four-way knob as the dialog layer
([3.5](11-dialog-layer.md)):

```cpp
  string next_hop;
  bool next_hop_1st_req;
  bool patch_ruri_next_hop;
  bool next_hop_fixed;
  string aleg_next_hop;

  string outbound_proxy;
  bool force_outbound_proxy;
```

Because profile fields are templates evaluated per call
([6.4](23b-sbc-profiles.md)), `next_hop` can be computed — from a header, from a variable a call
control module set, or from a regex map:

```
next_hop=$M(carriers/$rd)
```

That is a lookup table. Static, from configuration, no runtime state.

### DNS SRV and NAPTR

`core/sip/resolver.*` is a full RFC 3263 resolver ([3.2](08-transport.md)):

| Type | Record | Gives |
|---|---|---|
| `dns_srv_entry` | SRV | **Priority and weight** |
| `dns_naptr_entry` | NAPTR | Transport preference |
| `dns_handle` | — | A cursor through the result list |

So an R-URI resolving via SRV already yields an ordered, weighted list of targets. That is a peer
group, expressed in DNS.

### Failover across resolved addresses

```cpp
    // Transport address failover timer:
    // - used to cycle throught multiple addresses
    //   in case the R-URI resolves to multiple addresses
    STIMER_M,
```

Timer M, defaulting to `B/4` = **8 seconds** ([3.4](10-transaction-layer.md)), advances the
`dns_handle` cursor when a target fails to answer.

> [!NOTE]
> Timer B is 32 seconds and timer M is 8, so **at most four addresses are tried** before the
> transaction gives up. If you were expecting SRV to give you a large pool with graceful
> traversal, it does not.

### Parallel forking

The one most people miss ([6.3](23-sbc.md)):

```cpp
    /** List of legs which can be connected to this leg, it is valid for A leg until first
     * 2xx response which moves the A leg to Connected state and terminates all
     * other B legs. */
    std::vector<OtherLegInfo> other_legs;
```

An SBC A leg can have **many B legs at once**. Call three destinations in parallel; the first
`2xx` wins and the others are terminated. `addCallee()` is called once per candidate
([6.3](23-sbc.md)).

It is not free: each candidate carries its own `AmB2BMedia` and its own port pair
([6.2](22-b2b-media.md)), released when the winner answers.

### Serial forking, as a hook

```cpp
     * Redefine to implement serial fork or handle redirect. */
```

`apps/sbc/CallLeg.h:211`. Serial forking is not implemented; the extension point for implementing
it is documented.

## What is missing

| | Kamailio `dispatcher` | SEMS |
|---|---|---|
| Peer list | Sets, loaded and reloadable | Only what DNS returns, or one `next_hop` |
| Health probing | Active `OPTIONS` to each peer | **None** |
| Runtime state | Up / down / probing, per peer | **None** |
| Algorithms | Hash, round-robin, weighted, load-based | DNS priority and weight only |
| Admin control | Enable/disable a peer at runtime via RPC | **None** |
| Failure detection | Before trying — the peer is already known down | After trying, at 8 or 32 seconds |

That last row is the substantive difference. `dispatcher` **knows** a peer is down before sending
anything; SEMS finds out by waiting for a timeout. On a peer that fails silently, that costs 32
seconds of a session and a thread per call ([2.5](06-sizing-and-tuning.md)).

`tr_blacklist` ([10.3](39-security-hardening.md)) is the nearest thing, and it is reactive:
destinations that recently failed are avoided for a while. It learns from failures rather than
preventing them.

## Why the proxy is usually right

Peer selection is a **routing** decision, and routing is what the proxy is for
([1.1](01-introduction.md), [11.1](40-with-kamailio.md)):

**It is cheap there.** The proxy examines a request without creating a session
([2.1](02-thread-model.md)). SEMS pays a session and a thread before it can decide anything.

**Probing costs the same for everyone.** One proxy sending `OPTIONS` to twenty carriers is twenty
transactions. Twenty SEMS instances each probing twenty carriers is four hundred, and each
instance holds an independent and possibly conflicting opinion.

**State wants to be shared.** "Carrier 3 is down" should be known once, not rediscovered by every
instance. SEMS instances share nothing ([11.2](41-topologies-and-ha.md)), so there is nowhere to
put that.

**Yeti agrees.** Yeti built LCR, load control and number portability *above* SEMS rather than
inside it ([12.3](45-fork-yeti-switch.md)) — a team building a carrier switch on this code put
routing outside, and that is the strongest available evidence.

## When it is not right

**Post-answer decisions.** Choosing the next candidate based on something learned *after* the
call was answered — media quality, a DTMF response, a recogniser's output — is not available to a
proxy that stepped out of the path. Only the B2BUA sees that.

**Per-leg policy that depends on the candidate.** Different codecs, headers or authentication per
destination ([6.4](23b-sbc-profiles.md)) is profile work, and profiles live in SEMS.

**Parallel forking with media.** Ringing three destinations while playing early media to the
caller is a B2BUA behaviour, and SEMS already has the mechanism.

**No proxy in the deployment.** If SEMS is standalone ([1.1](01-introduction.md)), there is
nowhere else for the logic to go.

## If you build it anyway

The shape that fits the existing code:

**A call control module, not a core change** ([6.5](23c-sbc-call-control.md)). `onInitialInvite()`
is where the destination is chosen, and a module can set a global that the profile reads back as
`$V(...)` ([6.4](23b-sbc-profiles.md)). No core patches, and it can be disabled per profile.

**Probing on `AmPeriodicThread`** ([8.3](30-app-timers-and-events.md)), sending `OPTIONS` via
`AmUAC::dialout()` ([4.2](13-session-container-and-factories.md)), with results in a structure
the selection path reads.

**State exposed over DI** ([8.1](28-rpc-architecture.md)) so peers can be enabled and disabled at
runtime and the state can be inspected — mirroring what `dispatcher` offers.

**Parallel forking through `addCallee()`** when you want candidates raced rather than tried in
sequence ([6.3](23-sbc.md)).

> [!WARNING]
> Probing is a background thread doing network I/O in a single-process server
> ([2.1](02-thread-model.md)). It must not block the selection path, and a probe storm at startup
> — twenty peers, all probed at once, every instance — is a good way to be rate-limited by your
> own carriers. Stagger it.

## The recommendation

**Use Kamailio's `dispatcher`** for peer selection, health probing and failover
([11.1](40-with-kamailio.md)). It is the right component, it already exists, and the state lives
in one place.

**Use SEMS' parallel forking** for the cases only a B2BUA can serve — racing candidates with
media, or deciding after answer.

**Use `$M(...)` regex maps** for static routing tables that do not need health state
([6.4](23b-sbc-profiles.md)).

**Lower `dead_rtp_time` and set the session limits** so a peer that fails silently costs you less
while the timers run out ([2.5](06-sizing-and-tuning.md)).

Of the four gaps in this part, this is the one where the missing feature is most clearly missing
*on purpose*. SEMS is a media server ([1.1](01-introduction.md)); routing belongs next door.
