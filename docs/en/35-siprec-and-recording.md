# 9.5 SIPREC and recording

> [!NOTE]
> There are two unrelated kinds of recording in SEMS: **packet capture** for debugging, and
> **call recording** for business reasons. They use different code, produce different artefacts,
> and answer to different rules. This chapter covers both, and is careful to keep them apart.

## Packet capture: `msg_logger`

The debugging side is a small, well-factored interface in `core/sip/`:

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

class file_msg_logger
  : public msg_logger
{
protected:
  exclusive_file* excl_fp;
  int write(const void *buf, int len);
  int writev(const struct iovec *iov, int iovcnt);
  virtual int write_file_header() = 0;
public:
  int open(const char* filename);
  ...
};
```

One method: here are bytes, here is where they came from and went, here is what they were.
Everything else is an implementation.

Three things to notice.

**It is reference counted** (`atomic_ref_cnt`, [2.3](04-memory-and-ownership.md)), because a
logger is shared — the same one may be attached to a dialog and to both media streams of a B2B
pair ([6.2](22-b2b-media.md)).

**`write_file_header()` is pure virtual on the file variant**, which is what makes `pcap_logger`
work: pcap needs a global header before the first packet, and the base class calls this once on
open.

**It uses `writev()` and an `exclusive_file`.** Scatter-gather writing avoids assembling a buffer
per packet, and the exclusive file handles concurrent writers — several sessions can log to one
file without interleaving corruption.

Implementations: `pcap_logger` writes standard pcap, readable by Wireshark; `cf_msg_logger`
writes a text format.

Attaching a logger is one call, and it works at both layers:

```cpp
    void setLogger(msg_logger *logger) { a.setLogger(logger); b.setLogger(logger); }
```

on `AudioStreamPair` and `RelayStreamPair` ([6.2](22-b2b-media.md)), so one call's SIP **and**
media land in one pcap.

> [!IMPORTANT]
> This is the extension point for HEP. Homer's protocol is a transport for exactly the tuple
> `msg_logger::log()` already receives — payload, source, destination, message type. An HEP
> implementation would be a new `msg_logger` subclass sending UDP instead of writing a file, and
> would need no changes anywhere else. That, and what is missing today, is
> [13.2](48-hep-and-capture.md).

## Call recording: SIPREC

SIPREC (RFC 7865 and 7866) is the standard way to record calls without teaching every endpoint
about recording. A **Session Recording Client** forks media to a **Session Recording Server**,
with metadata describing who is who.

SEMS ships both halves:

| Component | Role |
|---|---|
| `apps/sbc/call_control/siprec` | The **client** — an SBC forking media to a recorder |
| `apps/siprec_srs` | The **server** — receives forked media and metadata |

That is unusual and useful. You can record with SEMS in the path, or use SEMS as the recorder
for someone else's SBC, or both.

### The client side

`cc_siprec` is a call control module ([6.5](23c-sbc-call-control.md)), and it hangs off the
per-packet hook:

```cpp
    virtual void onAfterRTPRelay(SBCCallLeg *call, AmRtpPacket* p, ...);
```

This is the only place in the SBC where a module sees individual RTP packets, and it is exactly
what forking needs: take the packet that was just relayed and send a copy elsewhere. Note that it
therefore works in **relay mode** — recording does not force the call onto the full media path
([9.4](34-rtp-mux-and-relay.md)), which is what makes recording an SBC's traffic affordable.

> [!WARNING]
> `onAfterRTPRelay()` runs on the RTP receiver thread ([5.2](17-rtp-stream.md)). A blocking send
> there stalls packet forwarding for every relayed call on that thread. Copy, queue, return.

Being a call control module also means the *decision* to record is policy: a profile or another
module can enable it per call ([6.4](23b-sbc-profiles.md)).

### The server side

```
apps/siprec_srs/
  SiprecSrs.cpp
  RtpReceiver.cpp
  Readme.siprec_srs.txt
```

An application that accepts recording sessions and writes the received streams. Its own
`RtpReceiver` is separate from the core's ([5.2](17-rtp-stream.md)) because a recording server's
job is narrower: receive many streams, correlate them with metadata, write them down.

The correlation is the interesting part. A recorded call is at least two streams that must be
identified as the two directions of one conversation and, usually, mixed or stored as a stereo
pair. SIPREC carries metadata for exactly that — which participant, which stream, which call.

## Choosing

| Need | Use |
|---|---|
| Debug a signalling problem | `pcap_logger` on the dialog, read in Wireshark |
| Debug audio | `pcap_logger` on the media streams |
| Record calls for business reasons | SIPREC — `cc_siprec` plus a recorder |
| Record on the media path anyway | The audio chain ([9.3](33-msg-storage-and-voicemail.md)) |
| Ship signalling to Homer | Not available today ([13.2](48-hep-and-capture.md)) |

## Two cautions

**Capture is a disk-space and privacy problem.** Enabling pcap logging broadly on a busy server
fills a disk quickly, and those files contain call content and identifiers. Debug capture should
be targeted and short-lived.

**Recording is a legal question before it is a technical one.** Consent, retention, encryption
and access control differ by jurisdiction, and SEMS provides none of them — it gives you the
mechanism and nothing else. Whatever your obligations are, they live in the recorder and the
storage, not here ([10.1](37-security-surface.md)).
