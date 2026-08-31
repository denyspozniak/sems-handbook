# 13.2 HEP and packet capture

> [!IMPORTANT]
> **HEP is genuinely absent.** Grepping `core`, `apps` and `doc` for `hep` or `homer` returns
> nothing. This is the one item in this part with no partial implementation — and, because
> `msg_logger` already has the right shape, the one with the clearest path to adding it.

## What exists today

`core/sip/msg_logger.h` is a small, well-factored interface
([9.5](35-siprec-and-recording.md)):

```cpp
class msg_logger
  : public atomic_ref_cnt
{
public:
  virtual int log(const char* buf, int len,
		  sockaddr_storage* src_ip,
		  sockaddr_storage* dst_ip,
		  cstring method, int reply_code=0)=0;
};
```

Look at that signature against what HEP carries: **payload, source address, destination address,
message type, response code.** It is the same tuple. Whoever wrote this interface was solving the
same problem HEP solves, and stopped at writing files.

The implementations:

| Class | Writes |
|---|---|
| `file_msg_logger` | The base for anything file-backed, with `write_file_header()` and `writev()` |
| `pcap_logger` | Standard pcap, readable by Wireshark |
| `cf_msg_logger` | A text format |

Attaching one covers both planes at once ([6.2](22-b2b-media.md)):

```cpp
    void setLogger(msg_logger *logger) { a.setLogger(logger); b.setLogger(logger); }
```

so a single logger captures a call's SIP and its media into one file.

## What HEP is, and why it is missing

HEP — the Homer Encapsulation Protocol — wraps a captured message with metadata (addresses,
timestamp, protocol, correlation id) and sends it over UDP to a collector. Homer stores and
indexes it, so an operator can search across a fleet by Call-ID instead of hunting for pcap files
on individual servers.

Kamailio's `siptrace` does this, and the reason it matters is stated in the Kamailio Handbook:
**wire capture goes blind on TLS/WSS**. A tap inside the process sees decrypted SIP; tcpdump on
the interface does not.

SEMS has the same problem and no answer to it. Today, capturing SIP from SEMS means either a
`pcap_logger` file on the box — per-server, needing collection, no cross-fleet search — or
tcpdump, which fails on TLS.

## What adding it would take

The shape follows directly from the interface:

```cpp
class hep_msg_logger : public msg_logger
{
  // a UDP socket to the collector
  int log(const char* buf, int len,
          sockaddr_storage* src_ip, sockaddr_storage* dst_ip,
          cstring method, int reply_code) override;
};
```

Everything else already works. The logger is reference counted
([2.3](04-memory-and-ownership.md)), it is already attachable to dialogs and to media pairs, and
`setLogger()` needs no change.

Two design constraints from earlier chapters:

> [!WARNING]
> **`log()` must not block.** It is called from the transport threads and, for media, from the
> RTP receiver thread ([5.2](17-rtp-stream.md)) — the same thread that forwards every relayed
> packet on the box. A synchronous `sendto()` to an unreachable collector would stall packet
> forwarding.
>
> The pattern is `async_file_writer` ([2.4](05-lifecycle.md)): queue, return, let another thread
> send, and **drop rather than block** when the queue is full. Capture is diagnostic; losing some
> is always better than delaying calls.

**Correlation needs a call id.** HEP's value is grouping messages by call. `log()` receives the
method and the code but not the Call-ID, so either the signature grows a parameter or the logger
is instantiated per call with the id bound in. The second is less invasive and fits the existing
"attach a logger to a dialog" model.

## The media side

Capturing SIP is one problem; capturing media is another, and the numbers make the difference
clear.

A single call is a handful of SIP messages and **fifty RTP packets per second per direction**.
Shipping media over HEP means multiplying your capture traffic by a factor of hundreds, from the
same thread that relays packets.

Kamailio does not face this, because media never flows through it
([1.1](01-introduction.md)) — it captures signalling and leaves media to rtpengine. SEMS is on
both paths, so it inherits the harder version of the problem.

A realistic design would ship SIP over HEP unconditionally and media only on demand, per call,
switched on by an RPC call ([8.1](28-rpc-architecture.md)) or a call control module
([6.5](23c-sbc-call-control.md)) when something specific is being investigated.

## What you can do today

**Targeted pcap.** Attach a `pcap_logger` for a call under investigation rather than globally.
SIP and media in one file, readable in Wireshark.

**Capture at the proxy.** If Kamailio fronts SEMS ([11.1](40-with-kamailio.md)), its `siptrace`
already ships SIP to Homer — including the leg towards SEMS. You lose SEMS' internal view but you
get fleet-wide search, and that covers most signalling investigations.

**Collect files.** Ship pcap files off the box on a schedule. Crude, and it works.

> [!WARNING]
> Do not enable pcap logging broadly on a busy server. Those files contain call content and
> identifiers, and they fill a disk quickly ([9.5](35-siprec-and-recording.md),
> [10.3](39-security-hardening.md)). Targeted and short-lived.

## Why it is worth doing

Of the four items in this part, HEP has the best ratio of value to effort:

- **The interface already exists** and already receives the right data.
- **One new class**, no changes to callers.
- **A well-specified protocol** with an existing, widely deployed collector.
- **It closes a real operational gap** — the TLS blindness that made `siptrace` necessary on the
  proxy side applies identically here.

The constraints are the familiar ones — do not block the media thread, drop rather than delay —
and they are the same constraints [13.4](50-media-forking-stt-tts.md) runs into for a different
reason.
