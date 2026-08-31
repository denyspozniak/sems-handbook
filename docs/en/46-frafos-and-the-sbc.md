# 12.4 FRAFOS and the SBC

> [!IMPORTANT]
> This chapter is shaped differently from the other two, because FRAFOS is not a fork. There is
> no public `frafos/sems` repository to point at. FRAFOS' contribution lives **inside the
> upstream tree**, and their product is built on top of it. Understanding that explains both the
> `apps/sbc` framework and the upstream's licensing.

## The two facts

**Stefan Sayer, named in the upstream `README.md` as "the lead developer", was FRAFOS' CTO**, and
presented "SIP Express Media Server SBC" at KamailioWorld 2014.

**The upstream is dual-licensed, and FRAFOS holds the commercial side:**

> SEMS is free (speech+beer) software. It is licensed under dual license terms, the GPL (v2+)
> and proprietary license. […] For a license to use SEMS under non-GPL terms, please contact
> FRAFOS GmbH at info@frafos.com .

Those two facts together explain a great deal about the code.

## Why `apps/sbc` looks the way it does

`apps/sbc` is roughly 14 000 lines and the largest application in the tree
([6.3](23-sbc.md)) — larger than several parts of the core. It is not organised like an
application. It is organised like a **product platform**:

- **Behaviour lives in data, not code.** `SBCCallProfile` is a template evaluated per call, with
  a substitution language behind it ([6.4](23b-sbc-profiles.md)). Policy changes without a
  rebuild.
- **Two extension interfaces**, one of them reachable over RPC so a module can be written in
  another language and live outside the process ([6.5](23c-sbc-call-control.md)).
- **Twelve shipped call control modules** covering blacklisting, call limits, prepaid billing,
  CDRs, recording and REST integration — the feature list of a commercial SBC.
- **Registration caching** as a substantial subsystem in its own right, 1700 lines across
  `RegisterCache` and `RegisterDialog` ([6.5](23c-sbc-call-control.md)).
- **Every status change carries a reason**, with nine distinct causes
  ([6.3](23-sbc.md)) — which is what a product needs for CDRs and support tickets, and more than
  an application needs for itself.

None of that is what you build for one deployment. It is what you build when the same code has to
serve many customers with different policies, and when someone else's operations team has to
diagnose it.

> [!TIP]
> Reading `apps/sbc` as "a company's SBC product, with the policy engine included" makes its
> structure obvious. Reading it as "an example application" makes it look wildly over-engineered.

## What is open and what is not

This is the part worth being precise about.

| | Open, in the upstream tree | Proprietary |
|---|---|---|
| The `apps/sbc` framework | ✅ GPL, in `sems-server/sems` | |
| `CallLeg`, `SBCCallLeg`, `SBCCallProfile` | ✅ | |
| The twelve `call_control/` modules | ✅ | |
| `ExtendedCCInterface`, `SBCCallControlAPI.h` | ✅ | |
| Registration caching | ✅ | |
| FRAFOS ABC SBC — the product | | ✅ |
| Its management interface, provisioning, support | | ✅ |

So `apps/sbc` is not a stripped-down teaser. It is a working, complete SBC framework, and
everything Parts 6.3 through 6.5 describe is available under the GPL.

What FRAFOS sells is the product around it: management, provisioning, certification, support and
whatever their own additions are. That is a conventional and honest arrangement — the engine is
open, the operations are the product.

## Why the dual licence

Dual licensing exists so a customer who cannot ship GPL code can pay for a proprietary licence
instead. It only works if the project can relicense what it accepts, which is why the upstream
`README.md` points contributors at `doc/COPYING` before anything else.

Two consequences for anyone building on SEMS:

**You can use it commercially under the GPL**, provided you meet the GPL's terms. Most
deployments — running SEMS as a server — do.

**If you cannot ship GPL code**, there is a route: contact FRAFOS. That option existing is
unusual and worth knowing about.

And this is precisely what Sipwise stepped out of ([12.2](44-fork-sipwise.md)) — "fully GPL
license compatible implementation" is a licensing statement, and this is the arrangement it
refers to.

## What to take from it

**The SBC framework is the best code in the tree to learn from.** It is the most complete example
of building on SEMS' primitives: sessions ([4.1](12-amsession.md)), B2B
([6.1](21-b2b-session.md)), media ([6.2](22-b2b-media.md)), the event system
([2.2](03-event-system.md)). If you are writing a serious application, read it before you design
yours.

**`CallLeg` is reusable.** It is the generic B2B state machine, deliberately separate from the
profile-aware `SBCCallLeg` ([6.3](23-sbc.md)). Any B2BUA that finds `AmB2BSession` too raw should
start there.

**Data-driven design has a real cost**, stated honestly in [6.4](23b-sbc-profiles.md): behaviour
in configuration means a bug can be a misplaced `$`, there is no type checking until the call
arrives, and understanding a live system means reading its profiles. For a product shipped to
many customers that trade is right. For one deployment with one policy, a plain application may
be simpler.

## The name in the room

`apps/sbc` exists because a company needed to build a product and chose to build it in the open.
The upstream got a complete SBC framework out of that, and it got a dual-licensing arrangement
that some found reason to fork away from.

Both are true, and both are visible in the code. It is a good illustration of what commercial
sponsorship does to an open-source project — the acknowledgements in
[1.1](01-introduction.md) name FRAFOS alongside sipwise, IPTEGO, iptelorg and TelTech for exactly
this reason.
