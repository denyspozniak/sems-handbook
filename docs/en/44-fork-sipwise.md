# 12.2 sipwise/sems

> [!NOTE]
> **What it is:** SEMS re-licensed and re-purposed as the B2B component of the Sipwise NGCP
> platform. It began as a fork and, in its maintainers' own words, went a long way from the
> original.

## What Sipwise say about it

The fork's README is direct:

> Sipwise SEMS stands for SIP Express Media Server […] a drop-in replacement for B2B (SIP/media)
> components.

> [it] is originally a fork of a well known SEMS open source project […] over the course of time
> we went far away from it realizing our own ideas.

> a fully GPL license compatible implementation

Three claims, and the third is the load-bearing one.

## Why it was forked: the licence

The upstream is dual-licensed — GPLv2+ **or** a proprietary licence from FRAFOS
([12.1](43-family-overview.md)). That arrangement has consequences for anyone building on it:
contributions must be acceptable under both licences, which means contributors give the project
the ability to relicense their work.

"Fully GPL license compatible" is Sipwise saying they do not carry that. Plain GPL, one licence,
no relicensing question, and no dependency on FRAFOS' commercial position for their own product's
foundation.

For a company shipping a platform, that is a strategic decision, not a technical one — and it is
the reason this is a permanent fork rather than a downstream that merges upstream changes.

## What it is for

Sipwise NGCP is a full-stack VoIP platform, and SEMS is its B2B and media component. The README
lists the same capabilities the upstream has:

- a full-fledged B2B user agent, described as its main purpose
  ([6.1](21-b2b-session.md)),
- media processing — RTP relay and media generation ([5.1](16-media-processor.md)),
- transcoding ([5.4](19-codecs-and-plugins.md)),
- custom PBX applications,
- support for other languages, e.g. Python ([7.3](26-ivr-and-python.md)),
- **Redis and MySQL support**.

It also states the integration model in the same terms this book has used throughout:

> Kamailio- or OpenSIPS- SIP proxy servers, but also any other SIP Proxy services supporting
> RFC3261 and RFC8866 standards.

That is [11.1](40-with-kamailio.md): the media server complements a proxy, and the proxy owns
routing and registration.

The explicit mention of **RFC 8866** is a small but real signal. RFC 8866 is the 2021 revision of
SDP, replacing RFC 4566 — naming it rather than the older number suggests attention to the SDP
layer that the upstream documentation does not advertise.

## What it emphasises

The README's framing of the architecture is the same contrast this book opens with
([1.1](01-introduction.md)):

> designed to work based on the event processing model, which makes it efficient in combination
> with threading

— set against traditional SIP projects that fork processes. Both branches share that design; the
Sipwise documentation simply leads with it.

**Redis and MySQL as headline features** is the most visible divergence in emphasis. The upstream
has database access through DSM modules and application modules ([7.2](25-dsm.md)); Sipwise
treats backend integration as core, which follows from being one component of a platform whose
other parts own the data.

## Documentation

The other visible difference is that Sipwise wrote proper narrative documentation:

**`sems.readthedocs.io`** — an overview, configuration, module reference, per-application pages.
The upstream has in-tree `doc/Readme.*.txt` files and doxygen output, which are accurate and
scattered.

> [!TIP]
> The readthedocs site is genuinely useful even if you run the upstream, because much of the
> conceptual material applies to both. Read it for the *ideas* and verify specifics against the
> tree you actually run — the configuration is where the two have drifted, and it is exactly
> where an assumption will cost you.

That is why this book lists it as a priority-3 source: narrative documentation, not the source of
truth ([1.1](01-introduction.md)).

## How far it has diverged

The README's own "we went far away from it" is the most reliable statement anyone has made about
this, and it has a practical consequence:

> [!WARNING]
> **Upstream patches do not apply cleanly, and neither do configurations.** Do not assume a fix
> from one tree lands in the other, and do not carry a `sems.conf` across. If you need something
> from the other branch, port it deliberately.

The shared ancestry means the concepts in Parts 2–11 still describe both — the thread model, the
event system, `AmSession`, the media processor, the SIP stack. Class names and file layout are
recognisable. Specific defaults, options and module sets are not.

## Who should care

**Run it** if you are running Sipwise NGCP — it is the supported component, and running anything
else there is unsupported by definition.

**Consider it** if plain GPL matters to your organisation and the dual-licensing arrangement does
not fit.

**Read its documentation** regardless. It is the best narrative material about SEMS that exists.

**Otherwise, stay on the upstream.** Outside NGCP, this branch's audience is small, its
documentation covers its own configuration rather than yours, and the packaging you will find in
general distributions descends from `sems-server/sems`.
