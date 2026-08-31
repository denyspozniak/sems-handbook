# 9.6 ZRTP and SRTP

> [!IMPORTANT]
> SEMS can **relay** encrypted media but cannot **terminate** it. There is no SRTP
> implementation in the tree, no DTLS handshake, no `libsrtp`. The one exception is ZRTP, which
> is optional, off by default, and depends on an external SDK. Anyone expecting a media server
> that speaks SRTP natively needs to read this chapter before designing around it.

## What is actually there

Two very different things, easily confused:

| | ZRTP | SRTP / DTLS-SRTP |
|---|---|---|
| Implemented | Yes, via an external SDK | **No** |
| Build flag | `SEMS_USE_ZRTP`, default `OFF` | — |
| SEMS can encrypt/decrypt | Yes, when built with it | No |
| SEMS can relay it | — | **Yes**, as opaque packets |
| Key exchange | In the media path | In SDP or DTLS |

## Relaying SRTP

SEMS recognises the secure transports in SDP:

```cpp
  case TP_RTPSAVP: return "RTP/SAVP";
  case TP_RTPSAVPF: return "RTP/SAVPF";
  case TP_UDPTLSRTPSAVP: return "UDP/TLS/RTP/SAVP";
  case TP_UDPTLSRTPSAVPF: return "UDP/TLS/RTP/SAVPF";
```

and `AmRtpStream` treats them as first-class RTP profiles when matching payloads:

```cpp
  // RFC 3551 §6 reserves PT < 20 for RTP-profile static payloads.
  // They are valid not just for RTP/AVP but for every RTP-based profile
  // we accept (AVPF, SAVP, SAVPF, UDP/TLS/RTP/SAVP[F]). Limiting the
  // check to TP_RTPAVP made SRTP/AVPF sessions fall through to
  // getDynPayload(), which fails for static PT sent without a=rtpmap.
  bool rtp_based_transport =
    (local_media.transport == TP_RTPAVP   ||
     local_media.transport == TP_RTPAVPF  ||
     local_media.transport == TP_RTPSAVP  ||
     local_media.transport == TP_RTPSAVPF ||
     local_media.transport == TP_UDPTLSRTPSAVP ||
     local_media.transport == TP_UDPTLSRTPSAVPF);
```

That comment describes a real bug and its fix, and it tells you exactly how far support goes:
SEMS parses the transport, negotiates payloads correctly, and forwards the packets. It does not
decrypt them.

Which means:

**Relay works.** Two endpoints doing SRTP between themselves, with SEMS relaying
([9.4](34-rtp-mux-and-relay.md)), works fine. The packets are opaque; SEMS moves them.

**Everything else does not.** No transcoding — you cannot decode what you cannot decrypt. No
conferencing, no recording of the audio ([9.5](35-siprec-and-recording.md)), no announcements
into the call, no inband DTMF detection ([5.5](20-dtmf-and-jitter.md)). Even the DTMF filtering
flags are meaningless: you cannot see the payload type of an encrypted packet.

**Bridging is not possible.** SRTP on one leg and plain RTP on the other requires terminating
the encryption. SEMS cannot, so an SBC in front of a WebRTC client — which mandates DTLS-SRTP —
needs something else in the media path.

> [!WARNING]
> A profile that enables transcoding, recording or announcements on a leg negotiating
> `RTP/SAVP` is a configuration that cannot work. The failure is not loud: negotiation succeeds,
> relay works, and the feature silently does nothing useful. Check the transport before assuming
> media features are available.

## ZRTP

ZRTP takes the opposite approach to key exchange, and `doc/ZRTP.txt` explains why that matters
here:

> ZRTP is a key agreement protocol to negotiate the keys for encryption of RTP in phone calls.
> […] Even though it uses public key encryption, a PKI is not needed. Since the keys are
> negotiated in the media path, support for it in signaling is not necessary. ZRTP also offers
> opportunistic encryption, which means that calls between UAs that support it are encrypted, but
> calls to UAs not supporting it are still possible, but unencrypted.

Keys are negotiated **in the media path**, so signalling — and anything in the signalling path —
needs to know nothing. Opportunistic encryption means a ZRTP-capable pair encrypts and a mixed
pair still connects.

### Building it

```cmake
option(SEMS_USE_ZRTP "Build with ZRTP" OFF)
```

```
mkdir -p build && cd build
cmake .. -DSEMS_USE_ZRTP=yes
make
```

**Off by default**, and it needs the Zfone SDK. `doc/ZRTP.txt` names the working fork:

> Currrently, the newest version of the ZRTP SDK, and the one that works with SEMS, is available
> at https://github.com/juha-h/libzrtp

An external, forked dependency for an optional feature is a good indication of how much use this
path sees. Check whether your distribution's package was built with it before planning on it.

### The integration

```cpp
class AmZRTP
{
  static int zrtp_cache_save_cntr;
  static std::string cache_path;
  static std::string entropy_path;
  static AmMutex zrtp_cache_mut;

  static int init();
  static int shut_down();
  static zrtp_global_t* zrtp_global;
  static zrtp_config_t zrtp_config;
  static zrtp_zid_t zrtp_instance_zid;

  static int on_send_packet(const zrtp_stream_t *stream, char *packet, unsigned int length);
  static void on_zrtp_secure(zrtp_stream_t *stream);
  static void on_zrtp_security_event(zrtp_stream_t *stream, zrtp_security_event_t event);
  static void on_zrtp_protocol_event(zrtp_stream_t *stream, zrtp_protocol_event_t event);

  void freeSession();
  zrtp_session_t* zrtp_session;
};
```

Four callbacks from the SDK, two of which surface as SEMS events:

```cpp
class AmZRTPSecurityEvent { zrtp_stream_t* stream_ctx; ... };
class AmZRTPProtocolEvent { zrtp_stream_t* stream_ctx; ... };
```

which DSM exposes to scripts ([7.2](25-dsm.md)):

```cpp
#ifdef WITH_ZRTP
    , ZRTPProtocolEvent,
    ZRTPSecurityEvent
#endif
```

So a call flow can react to encryption being established or to a security warning — reachable
through `mod_zrtp` without any C++.

`AmZRTP::init()` runs in `main()` before anything else starts
([2.4](05-lifecycle.md)), because the ZRTP global context must exist before any stream can use
it.

**`cache_path` and `entropy_path`** are the two files ZRTP needs: a cache of retained secrets
(what makes "verified once, trusted after" work) and an entropy source. `zrtp_cache_mut` guards
the cache because every session touches it.

> [!IMPORTANT]
> The ZRTP cache is a persistent security-relevant file. It survives restarts by design — that
> is the point of retained secrets — so it is part of what you back up, protect and consider
> when moving a server. Its permissions matter as much as any credential file
> ([10.3](39-security-hardening.md)).

### The SAS, and why the conference application says it aloud

ZRTP's protection against a man in the middle is the **Short Authentication String**: both ends
derive the same short phrase, and the humans read it to each other. If it matches, no one is in
the middle.

That only works if the endpoints can show it — and a media server has no screen. Hence:

> The conference application can tell the caller the SAS phrase if SEMS is compiled with
> text-to-speech support.

```
cmake .. -DSEMS_USE_ZRTP=yes -DSEMS_USE_TTS=yes
```

flite speaks the SAS into the call ([7.3](26-ivr-and-python.md)). It is a neat solution to a real
problem, and it is also a reminder of how far this feature is from mainstream use.

## Where that leaves you

**Media security exists, in a narrow form.** ZRTP is real but optional, off by default, needs a
forked SDK, and works end to end rather than to SEMS.

**SRTP is a relay-only story.** SEMS carries encrypted media without understanding it, which
covers the SBC case and nothing else.

**Nothing here helps with WebRTC.** DTLS-SRTP is mandatory there and unimplemented here.

If media must be encrypted *to* SEMS and processed, the honest answer today is another component
in the media path — the same conclusion the security chapters reach from a different direction
([10.2](38-security-media.md)).
