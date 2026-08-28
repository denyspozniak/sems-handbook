# 5.2 The RTP stream

> [!NOTE]
> `AmRtpStream` is the largest and most option-laden class in the media plane, because it has
> to satisfy two very different customers: a media server that decodes audio, and an SBC that
> forwards packets untouched. Both live in the same class, distinguished by `relay_enabled`.

## Receiving: libevent, not a blocking loop

The RTP receiver is not the "one thread per socket in a `recvfrom` loop" design you might
expect. It is an event loop:

```cpp
#include <event2/event.h>

class AmRtpReceiverThread
  : public AmThread
{
  struct StreamInfo
  {
    AmRtpStream* stream;
    struct event* ev_read;
    AmRtpReceiverThread* thread;
    ...
  };
  ...
};
```

Each stream registers a read event on its socket; libevent multiplexes thousands of sockets onto
one thread. This is why `rtp_receiver_threads` defaults to **1** (`NUM_RTP_RECEIVERS`) and that
default is usually fine — the thread does almost no work per packet. It reads, identifies the
owning stream, and either queues the packet for the media processor or relays it immediately.

> [!IMPORTANT]
> The comment on `relay_stream` says it plainly:
> ```cpp
>   /** pointer to relay stream.
>       ... or by the AmRtpReceiver thread while relaying!  */
> ```
> **In relay mode the packet never reaches the media processor.** It is forwarded from the
> receiver thread itself. That is why RTP relay in SEMS is cheap: no decode, no jitter buffer,
> no 10 ms tick, no per-tick copy — a read and a write on the same thread
> ([9.4](34-rtp-mux-and-relay.md)).

## Addresses, ports and hold

```cpp
  unsigned short     r_port;
  unsigned short     r_rtcp_port;
  unsigned short     l_port;

  bool           r_ssrc_i;

  /** symmetric RTP & RTCP */
  bool           passive;
  bool           passive_rtcp;

  /** mute && port == 0 */
  bool           hold;
  bool           remotehold;

  bool           begin_talk;
  bool           monitor_rtp_timeout;
  bool           receiving;
  bool           mute;
  bool           force_receive_dtmf;
  bool           active;
```

Local port comes from the configured range ([2.5](06-sizing-and-tuning.md)); remote address and
port come out of the negotiated SDP ([4.3](14-offer-answer.md)).

The comment on `hold` — `/** mute && port == 0 */` — is a precise definition. Hold is not a
mode; it is muting plus advertising a zero port, which is exactly what the SDP says.
`remotehold` is the mirror: the far end put *us* on hold.

`mute`, `receiving` and `force_receive_dtmf` are the three switches `AmSession` exposes directly
([4.1](12-amsession.md)). They are independent: a muted stream still receives, and
`force_receive_dtmf` keeps RFC 2833 events flowing even when audio is otherwise ignored — which
is what makes "press a key to speak" work while the channel is muted.

## Symmetric RTP

```cpp
  /** handle symmetric RTP/RTCP - if in passive mode, update raddr from rp */
  void handleSymmetricRtp(struct sockaddr_storage* recv_addr, bool rtcp);
```

In `passive` mode, the stream learns the remote address from the first packet that arrives
rather than trusting the SDP. This is the standard NAT workaround: an endpoint behind NAT
advertises its private address in SDP, but the packets that reach you carry the public one, and
that is where replies must go.

```cpp
  /** ping the remote side, to open NATs and enable symmetric RTP */
```

The companion is sending a packet early so the NAT binding exists before the far end tries to
reach you. Between them these two behaviours are most of what makes SEMS work behind NAT
without an external helper.

> [!WARNING]
> Symmetric RTP is also an attack surface. A stream in `passive` mode redirects its outbound
> audio to whatever address a packet appeared to come from — so an attacker who can guess a
> port pair and spoof a source can hijack the audio direction. This is the RTP-bleed family of
> problems; the mitigations, and what `r_ssrc_i` has to do with them, are
> [10.2](38-security-media.md).

## Relay mode

The relay configuration is a small language of its own:

```cpp
  /** if relay_stream is initialized, received RTP is relayed there */
  bool            relay_enabled;
  bool            relay_raw;
  AmRtpStream*    relay_stream;
  /** control transparency for RTP seqno in RTP relay mode */
  bool            relay_transparent_seqno;
  /** control transparency for RTP ssrc in RTP relay mode */
  bool            relay_transparent_ssrc;
  /** filter RTP DTMF (2833 / 4733) in relaying */
  bool            relay_filter_dtmf;
  ...
  PayloadMask     relay_payloads;
```

| Flag | Effect |
|---|---|
| `relay_enabled` | Forward received RTP to `relay_stream` instead of decoding it |
| `relay_raw` | Forward the datagram untouched, headers and all |
| `relay_transparent_seqno` | Preserve the original sequence numbers rather than renumbering |
| `relay_transparent_ssrc` | Preserve the original SSRC rather than substituting our own |
| `relay_filter_dtmf` | Drop RFC 2833/4733 payloads from the relayed stream |
| `relay_payloads` | A 128-bit mask of which payload types may be relayed |

The two transparency flags are a real interoperability decision. Transparent SSRC and sequence
numbers make the relay invisible, which some endpoints require; rewriting them makes the two
legs independent, which is what you want if the legs can be re-established separately. There is
no universally right answer, which is why both exist as switches.

`PayloadMask` is a 128-bit bitmap with a range check that logs a bug rather than trusting the
caller:

```cpp
    bool get(unsigned char payload_id) {
      if (payload_id > 127) { ERROR("BUG: payload_id out of range\n"); return false; }
      return (bits[payload_id / 8] & (1 << (payload_id % 8)));
    }
```

It decides, per payload type, whether a packet is forwarded — so an SBC can relay audio while
terminating DTMF, or pass a codec it does not understand while blocking one it refuses to carry
([6.2](22-b2b-media.md)).

## Sending

```cpp
  int send( unsigned int ts, ... );
  int send_raw( char* packet, unsigned int length );
  int compile_and_send( const int payload, bool marker, ... );
```

Three levels. `compile_and_send()` builds an RTP header around a payload — the normal path from
the audio chain. `send()` is the encoded path. `send_raw()` writes bytes as given, which is what
`relay_raw` uses.

The `marker` parameter on `compile_and_send()` is the RTP marker bit: set on the first packet of
a talkspurt, which is how `begin_talk` reaches the wire and how a receiver's playout buffer
knows to resynchronise ([5.5](20-dtmf-and-jitter.md)).

## Timeouts and liveness

```cpp
  bool monitor_rtp_timeout;
```

Per-stream, so a stream that legitimately expects silence — a recording leg, a stream on hold —
can opt out. The threshold is `dead_rtp_time`, **300 seconds** by default
([2.5](06-sizing-and-tuning.md)).

This is the only mechanism that reclaims a call whose far end vanished without a `BYE`. Five
minutes is a long time to hold a session, a thread and a port pair for a call that is already
gone; lowering it is usually the right call.

## Ports as a resource

Each stream takes a port pair — RTP on an even port, RTCP on the next. With the sample range of
10000–60000 that is 25 000 pairs, so ports are rarely the first ceiling
([2.5](06-sizing-and-tuning.md)).

They matter for a different reason: the range is your firewall rule and your exposed surface. A
range far wider than your real concurrency is 50 000 open UDP ports advertising themselves to
anyone who scans. Narrow it to what you actually need ([10.2](38-security-media.md)).
