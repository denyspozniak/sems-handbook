# 6.4 SBC call profiles and rewriting

> [!IMPORTANT]
> A call profile is not a configuration file read at startup. It is a **template evaluated per
> call**. Nearly every field is a string containing substitutions, resolved against the actual
> INVITE when the call arrives. That is what makes one profile serve thousands of different
> calls, and it is the single idea that explains the SBC's design.

## The string-and-value pattern

Look at these pairs in `SBCCallProfile.h`:

```cpp
  string sst_enabled;
  bool sst_enabled_value;

  string rtprelay_enabled;
  bool rtprelay_enabled_value;

  string force_symmetric_rtp;
  bool force_symmetric_rtp_value;

  string rtprelay_interface;
  int rtprelay_interface_value;
```

Every one is the same shape: a **string** as configured, and a **typed value** after evaluation.
The string may be `yes`, or it may be `$H(P-Enable-Relay)` — take it from a header on this
particular call. `ParamReplacer` resolves it, the result is parsed, and the typed field is what
the code reads from then on.

Once you have seen it, the whole profile reads differently. It is not a settings object; it is a
compiled-per-call decision table.

## The substitution language

`ParamReplacer.cpp` implements a small language. It is worth a full table, because the
documentation for it is thin and the code is 869 lines.

**Message fields:**

| Token | Value |
|---|---|
| `$f` | From |
| `$ft` | From tag |
| `$t` | To |
| `$tt` | To tag |
| `$r` | Request URI |
| `$c` | Call-ID |

**Network coordinates:**

| Token | Value |
|---|---|
| `$si` | Source IP — where the request actually came from |
| `$sp` | Source port |
| `$di` | Destination IP — the remote UAS |
| `$dp` | Destination port |
| `$Ri` | Received: local IP the request arrived on |
| `$Rp` | Received: local port |
| `$Rf` | Received: interface id |
| `$Rn` | Received: interface name |
| `$RI` | Received: interface **public** IP |

**Register cache** ([6.5](23c-sbc-call-control.md)):

| Token | Value |
|---|---|
| `$u` | Cached destination user |
| `$Ua` | Originating AoR |
| `$UA` | Originating alias |

**Lookups:**

| Token | Value |
|---|---|
| `$P(name)` | Application parameter |
| `$V(name)` | Variable set earlier in this call |
| `$H(name)` | Header from the request |
| `$M(name)` | Regex map lookup ([`RegexMapper`](#regexmapper)) |

**URI modifiers** — appended to a URI-valued token to extract one part:

| Modifier | Part |
|---|---|
| `.u` | Whole URI |
| `.U` | User |
| `.d` | Domain |
| `.h` | Host |
| `.p` | Port |
| `.H` | URI headers |
| `.P` | URI parameters |
| `.n` | Display name |

Escapes `\r`, `\n` and `\t` are supported, which matters for `append_headers`.

So `$fU` is the caller's user part; `$rd` is the request URI's domain; `$H(P-Charge-Info)` is a
header value. A profile line like

```
RURI=sip:$rU@$M(carriers/$rd)
```

means "keep the user, but look the destination host up in the `carriers` regex map, keyed by the
request URI's domain".

> [!WARNING]
> `$si` and `$H(...)` are **attacker-controlled input** on an untrusted interface. `$si` is at
> least the real source address; a header is whatever the peer chose to send. A profile that
> routes on `$H(...)` without validation lets the caller pick their own destination. Treat
> header substitutions the way you would treat any request parameter
> ([10.1](37-security-surface.md)).

## The `_value` fields, grouped

The profile has well over a hundred fields. They group like this.

### Identity rewriting

```cpp
  string ruri;       /* updated if set */
  string ruri_host;  /* updated if set */
  string from;       /* updated if set */
  string to;         /* updated if set */
```

Plus a nested structure for finer control and for hiding:

```cpp
    string displayname;
    string user;
    string host;
    string port;

    bool   hiding;
    string hiding_prefix;
    string hiding_vars;
```

`hiding` is topology hiding at the identity level — replacing a value with an opaque token so
the far end cannot read your internal addressing, with `hiding_prefix` marking the encoded form
so it can be recognised and reversed. This is the closest analogue in SEMS to Kamailio's `topoh`
([11.1](40-with-kamailio.md)) — but note that a B2BUA already hides the *dialog*; this hides the
*URIs* inside it.

### Dialog behaviour

```cpp
  string callid;
  string dlg_contact_params;
  bool transparent_dlg_id;
  bool dlg_nat_handling;
  bool keep_vias;
  bool bleg_keep_vias;
```

`transparent_dlg_id` copies the dialog identifiers to the B leg instead of generating fresh
ones — which **switches off** the topology hiding a B2BUA gives for free. It exists for peers
that correlate legs by Call-ID, and choosing it is a deliberate trade of privacy for
interoperability.

`keep_vias` and `bleg_keep_vias` similarly preserve the `Via` stack across the B2BUA, which is
not normal B2BUA behaviour at all.

### Routing

```cpp
  string outbound_proxy;
  bool force_outbound_proxy;
  string aleg_outbound_proxy;
  bool aleg_force_outbound_proxy;

  string next_hop;
  bool next_hop_1st_req;
  bool patch_ruri_next_hop;
  bool next_hop_fixed;
  string aleg_next_hop;
```

The same four-way `next_hop` knob as the dialog layer ([3.5](11-dialog-layer.md)), now with
separate A-leg variants. The `aleg_` prefix runs through the whole profile: almost every policy
can differ per leg, because the two legs face different networks.

This is also the whole of destination selection. One next hop, or whatever the R-URI resolves
to. There is no list, no weighting, no health state ([13.5](51-peer-dispatching.md)).

### Authentication

```cpp
  bool auth_enabled;
  bool auth_aleg_enabled;
  bool uas_auth_bleg_enabled;
```

Three, because there are three distinct situations: authenticating *as* a UAC towards the B leg,
authenticating on the A leg, and challenging the B leg *as* a UAS. All of them ultimately run
through `uac_auth` as a session event handler ([4.4](15-session-event-handlers.md)).

### Headers and rejection

```cpp
  string append_headers;
  string append_headers_req;
  string aleg_append_headers_req;
  string refuse_with;
```

`refuse_with` is the early exit: set it and the call is rejected with that code and reason before
anything else happens. Combined with a substitution, a profile can reject on a condition without
any call control module at all.

### Media

```cpp
  bool anonymize_sdp;
  bool have_aleg_sdpfilter;

  string rtprelay_enabled;
  string force_symmetric_rtp;
  string aleg_force_symmetric_rtp;
  bool msgflags_symmetric_rtp;
  bool rtprelay_transparent_seqno;
  bool rtprelay_transparent_ssrc;
  bool rtprelay_dtmf_filtering;
  bool rtprelay_dtmf_detection;
  string rtprelay_interface;
  string aleg_rtprelay_interface;
```

These map directly onto the flags in [6.1](21-b2b-session.md) and [5.2](17-rtp-stream.md). The
`rtprelay_interface` pair is the multihoming lever: relay a call in on one interface and out on
another, which is how an SBC separates an untrusted access side from a trusted core side.

`msgflags_symmetric_rtp` enables symmetric RTP based on flags detected in the message rather
than by static configuration — a NAT heuristic rather than a policy.

### Session timers and Replaces

```cpp
  string sst_enabled;
  string sst_aleg_enabled;
  string fix_replaces_inv;
  string fix_replaces_ref;
  bool allow_subless_notify;
```

`fix_replaces_inv` and `fix_replaces_ref` repair `Replaces` headers in INVITE and REFER. A
`Replaces` header names a dialog by its identifiers — which the B2BUA rewrote — so a transfer
across an SBC breaks unless the identifiers are translated back. `ReplacesMapper.cpp` keeps that
mapping. This is one of those things that is invisible until attended transfer stops working.

`allow_subless_notify` permits `NOTIFY` without a subscription, which many message-waiting
implementations need and RFC 6665 dislikes.

### Reload detection

```cpp
  string md5hash;
  string profile_file;
```

The profile knows the file it came from and the hash of its contents, so a reload can tell what
actually changed instead of rebuilding everything.

## The filters

```cpp
enum FilterType { Transparent=0, Whitelist, Blacklist, Undefined };

FilterType String2FilterType(const char* ft);
bool isActiveFilter(FilterType ft);
const char* FilterType2String(FilterType ft);
```

The same four-value type governs header filtering and SDP filtering.

`Transparent` passes everything. `Whitelist` passes only what is listed — safe by default,
tedious to maintain, and the right choice on an untrusted edge. `Blacklist` removes what is
listed — convenient, and always one unknown header away from a leak. `Undefined` is the
unconfigured state, which `isActiveFilter()` exists to distinguish from a configured
`Transparent`.

SDP filtering has four entry points:

```cpp
int filterSDP(AmSdp& sdp, const vector<FilterEntry>& filter_list);
int filterSDPalines(AmSdp& sdp, const vector<FilterEntry>& filter_list);
int filterMedia(AmSdp& sdp, const vector<FilterEntry>& filter_list);

int normalizeSDP(AmSdp& sdp, bool anonymize_sdp, const string &advertised_ip);
```

Three levels of granularity — whole media descriptions, individual `a=` lines, and payload
filtering — plus `normalizeSDP()`, which rewrites the advertised address and optionally strips
identifying session-level fields (`o=` lines carry usernames and addresses more often than
people realise).

**Payload filtering is the lever that avoids transcoding.** Narrowing what each side sees until
the two overlap on a cheap codec is the difference between a relay and a four-step transcode per
packet ([6.2](22-b2b-media.md), [5.4](19-codecs-and-plugins.md)).

## The supporting classes

| File | Lines | Role |
|---|---|---|
| `ParamReplacer.cpp` | 869 | The substitution language above |
| `SBCCallProfile.cpp` | 1831 | Parsing, evaluation, per-call resolution |
| `HeaderFilter.cpp` | — | Whitelist/blacklist over headers |
| `SDPFilter.cpp` | 245 | The four SDP functions |
| `RegexMapper.cpp` | — | Named regex maps behind `$M(...)` |
| `ReplacesMapper.cpp` | — | Dialog identifier translation for transfers |
| `RTPParameters.cpp` | — | Per-profile RTP settings |
| `RateLimit.cpp` | — | Token-bucket limiting |
| `SessionUpdate.cpp` | — | Driving re-INVITE / UPDATE from policy |
| `arg_conversion.cpp` | — | `AmArg` ↔ profile, for the call-control boundary |

### `RegexMapper`

Named maps of regex → value, addressed as `$M(mapname/input)`. This is where routing tables
live when the profile needs one, and it is as close as the SBC gets to a lookup — static, loaded
from configuration, with no runtime state ([13.5](51-peer-dispatching.md)).

## Why data-driven

The alternative was an application per policy. Instead there is one application and a profile
per policy — text files, reloadable, diffable, deployable without a rebuild.

The cost is real and worth stating. Behaviour lives in configuration, so a bug can be a
misplaced `$` rather than a compile error; there is no type checking until the call arrives; and
understanding a live system means reading its profiles, not its code. In exchange, changing
policy does not mean shipping a binary — which for an SBC, where policy changes weekly, is the
right trade.
