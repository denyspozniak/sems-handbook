# 10.2 Media-plane security

> [!IMPORTANT]
> The RTP ports are the largest unauthenticated surface SEMS exposes. Tens of thousands of UDP
> ports, no credentials, and a stream that will learn its destination from whatever packet
> arrives. Everything in this chapter follows from those three facts.

## RTP bleed

The attack is simple enough to state in a sentence: **send RTP to a port and see what comes
back.**

Symmetric RTP is what makes it work ([5.2](17-rtp-stream.md)):

```cpp
  /** symmetric RTP & RTCP */
  bool           passive;
  bool           passive_rtcp;

  /** handle symmetric RTP/RTCP - if in passive mode, update raddr from rp */
  void handleSymmetricRtp(struct sockaddr_storage* recv_addr, bool rtcp);
```

In `passive` mode the stream takes its remote address from the source of arriving packets rather
than from the negotiated SDP. That is exactly right for NAT — the address in SDP is private and
the packets carry the public one — and it is exactly the property an attacker uses.

Two outcomes:

**Eavesdropping.** Send a packet to an active port pair from your own address. If the stream
accepts it, it starts sending the other party's audio to you.

**Injection.** Once accepted as the remote, your audio goes to the far party.

The search space is the RTP range. The sample configuration's 10000–60000 is 25 000 port pairs —
scannable in seconds. Ports are also allocated sequentially:

```cpp
    next_rtp_port = RtpLowPort;
    ...
  if(next_rtp_port >= RtpHighPort){
    next_rtp_port = RtpLowPort;
  }
```

so having found one active stream, the next is very likely nearby.

## What limits it

`handleSymmetricRtp()` only acts while the stream is `passive`. The address is learned and, once
learned, later packets from elsewhere do not silently re-point it — the window is around stream
setup, not the whole call.

There is also SSRC tracking:

```cpp
  bool r_ssrc_i;
```

An initialised remote SSRC gives the stream an expectation about who is sending. A packet with a
different SSRC is a signal that something is wrong, and a stream that has settled is less
credulous than one that has not.

The `sbc` profile exposes the policy knob ([6.4](23b-sbc-profiles.md)):

```cpp
  string force_symmetric_rtp;
  string aleg_force_symmetric_rtp;
  bool msgflags_symmetric_rtp;
```

`msgflags_symmetric_rtp` is the better default of the three: enable symmetric RTP based on
indications in the message that NAT is present, rather than unconditionally. Symmetric RTP where
it is not needed is a risk taken for nothing.

> [!TIP]
> **Do not enable symmetric RTP on interfaces that do not face NAT.** A trunk to a carrier over a
> known network path does not need it, and turning it off there removes the attack entirely for
> those calls. Per-leg configuration exists precisely so the access side and the trunk side can
> differ.

## Narrow the port range

The single most effective mitigation, and the most neglected:

```
rtp_low_port=10000
rtp_high_port=60000
```

50 000 ports is 25 000 concurrent streams. If the box will carry 500 calls, it needs about 1000
pairs, not 25 000.

Narrowing does three things at once: shrinks the scan space by an order of magnitude or more,
makes the firewall rule tight enough to be meaningful, and makes unexpected traffic in the range
easier to spot. There is no downside beyond having to size it — and sizing it is
[2.5](06-sizing-and-tuning.md).

## Resource exhaustion through media

**Port exhaustion.** Every stream takes a pair; enough concurrent calls and allocation fails.
`session_limit` is the real control, because a session that never gets created never asks for a
port ([2.5](06-sizing-and-tuning.md)).

**Media thread saturation.** Media is a fixed 10 ms budget shared by every session on the thread
([5.1](16-media-processor.md)). Calls that force the full media path — anything with an input,
anything transcoding ([6.2](22-b2b-media.md)) — cost far more than relayed ones. An attacker who
can pick a codec you must transcode chooses your cost.

> [!WARNING]
> Codec choice is an amplification factor of roughly four
> ([5.4](19-codecs-and-plugins.md)). `exclude_payloads` and SBC codec filtering are therefore
> capacity controls as well as interoperability ones — refusing to offer expensive codecs takes
> the choice away from the caller.

**Held sessions.** A call abandoned without a `BYE` holds a session, a thread and a port pair
until `dead_rtp_time`, **300 seconds** by default. Lower it. Five minutes per abandoned call is
generous to an attacker and to nobody else ([5.2](17-rtp-stream.md)).

## What encryption does and does not give you

Covered fully in [9.6](36-zrtp-and-srtp.md); the security summary is short.

**SRTP end to end, relayed by SEMS, defeats RTP bleed for the payload** — an attacker who
redirects the stream receives ciphertext. It does not stop the redirection itself, so the call
can still be disrupted.

**SEMS cannot terminate SRTP.** No transcoding, recording, announcements or conferencing on an
encrypted leg. Encryption and media processing are mutually exclusive here.

**ZRTP is opportunistic and off by default**, needs a forked SDK, and its cache is a persistent
security-relevant file ([10.3](39-security-hardening.md)).

If media must be both encrypted to your infrastructure and processed, that needs a component
SEMS is not.

## Watch for

| Signal | Suggests |
|---|---|
| RTP from unexpected sources | Scanning, or a bleed attempt in progress |
| SSRC changes mid-stream | Injection, or a legitimate re-INVITE — check which |
| Streams with traffic but no matching session | Ports still open after teardown |
| Media tick overrun without a load increase | Transcoding forced by codec choice ([5.1](16-media-processor.md)) |
| Sessions hitting `dead_rtp_time` in numbers | Abandoned calls, deliberate or otherwise |

`pcap_logger` ([9.5](35-siprec-and-recording.md)) is the tool for the first two — capture on the
suspect stream and look at where the packets are actually from.

## The short version

1. Narrow the RTP range to your real concurrency.
2. Firewall exactly that range, from exactly the peers that should reach it.
3. Enable symmetric RTP only where NAT requires it, per leg.
4. Lower `dead_rtp_time` from 300 seconds.
5. Set `session_limit` and `cps_limit` ([2.5](06-sizing-and-tuning.md)).
6. Restrict offered codecs with `exclude_payloads` and SDP filtering
   ([6.4](23b-sbc-profiles.md)).
7. Do not rely on SEMS for media encryption. It relays; it does not terminate.
