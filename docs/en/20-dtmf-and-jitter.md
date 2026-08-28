# 5.5 DTMF and jitter

> [!IMPORTANT]
> Two problems that look unrelated share a chapter because they share a cause: the network
> delivers audio late, out of order, or not at all, and a caller's keypress has three different
> ways of arriving. Both are the media plane compensating for things it does not control.

## Three ways a digit arrives

```cpp
  enum EventSource { SOURCE_RTP, SOURCE_SIP, SOURCE_INBAND, SOURCE_DETECTOR };
```

| Source | Mechanism | Detector |
|---|---|---|
| `SOURCE_RTP` | RFC 2833/4733 named events in the RTP stream | `AmRtpDtmfDetector` |
| `SOURCE_SIP` | A SIP `INFO` request on the signalling path | `AmSipDtmfDetector` |
| `SOURCE_INBAND` | Actual DTMF tones mixed into the audio | `AmInbandDtmfDetector` |
| `SOURCE_DETECTOR` | The tag on the event finally delivered to the application | — |

A media server cannot choose which its callers use, so it implements all three and normalises
them. That normalisation is `AmDtmfDetector`, and it is more than a switch statement.

## Why detection needs a state machine

```cpp
class AmKeyPressSink {
  ...
  virtual void registerKeyPressed(int event, Dtmf::EventSource source,
                                  bool has_eventid=false, unsigned int event_id=0) = 0;
  virtual void registerKeyReleased(int event, Dtmf::EventSource source, ...) = 0;
  virtual void flushKey(unsigned int event_id) = 0;
};
```

Press and release are separate, because a digit has a duration and applications care about it —
"press and hold 5 to record" is a real requirement.

The hard part is that the three sources overlap. An endpoint may send RFC 2833 *and* leave the
tones in the audio, so the same keypress arrives twice. RFC 2833 events are also sent
redundantly by design — the same event repeats in several packets so a loss does not swallow it.
Without deduplication, one keypress becomes three or four.

`event_id` and `flushKey()` are the deduplication. Events carrying an id are correlated, and
`flushKey()` closes one out once it is definitively over. `AmDtmfDetector` declares the three
per-source detectors as friends, so they can feed it directly:

```cpp
  friend class AmSipDtmfDetector;
  friend class AmRtpDtmfDetector;
  friend class AmInbandDtmfDetector;
```

The result reaches the application as one clean callback ([4.1](12-amsession.md)):

```cpp
  virtual void onDtmf(int event, int duration);
```

## Inband detection

```cpp
  enum InbandDetectorType { SEMSInternal, SpanDSP };

class AmSemsInbandDtmfDetector { ... };
class AmSpanDSPInbandDtmfDetector { ... };
```

Two implementations, chosen by `setInbandDetector()`. The internal one is a Goertzel-style tone
detector — cheap and adequate. SpanDSP is a mature, far more accurate DSP library, at the cost
of a dependency and more CPU.

> [!WARNING]
> Inband detection only works on audio SEMS actually decodes. In relay mode
> ([5.2](17-rtp-stream.md)) packets never reach the audio chain, so inband DTMF is invisible —
> and a compressed codec may have mangled the tones beyond recognition anyway. If DTMF matters
> and you cannot mandate RFC 2833, you cannot use pure relay.

## The playout buffer

Received audio does not arrive on the 10 ms tick that wants to consume it
([5.1](16-media-processor.md)). The playout buffer is what bridges the two clocks:

```cpp
class AmPlayoutBuffer
{
  unsigned int last_ts;
  unsigned int sample_rate;
  unsigned int recv_offset;
  ...
  void buffer_put(unsigned int ts, ShortSample* buf, unsigned int len);
  void buffer_get(unsigned int ts, ShortSample* buf, unsigned int len);
  virtual void write(u_int32_t ref_ts, u_int32_t ts, int16_t* buf, u_int32_t len, bool begin_talk);
};
```

Packets go in with their RTP timestamps; the media processor takes samples out by system
timestamp. `recv_offset` is the mapping between the two clocks, and `begin_talk` — the RTP
marker bit ([5.2](17-rtp-stream.md)) — tells it to resynchronise, because a new talkspurt may
start after an arbitrary gap.

Three implementations:

| Class | Strategy |
|---|---|
| `AmPlayoutBuffer` | Fixed. Simple, predictable latency |
| `AmAdaptivePlayout` | Adjusts to measured jitter, trading latency against loss |
| `AmJbPlayout` | A conventional jitter buffer |

The adaptive one is where the interesting constants live:

```cpp
#define ORDER_STAT_WIN_SIZE  35
#define ORDER_STAT_LOSS_RATE 0.1

#define EXP_THRESHOLD 20
#define SHR_THRESHOLD 180

#define WSOLA_START_OFF  10 * sample_rate / 1000
#define WSOLA_SCALED_WIN 50

#define TEMPLATE_SEG   10 * sample_rate / 1000
```

It keeps an **order statistic** over a 35-packet window and targets a 0.1 loss rate — that is,
it sizes the buffer so roughly 10% of packets would be considered late, deliberately trading a
little loss for lower latency. `EXP_THRESHOLD` and `SHR_THRESHOLD` are the hysteresis: grow
quickly (20), shrink slowly (180), because growing late costs audible dropouts while shrinking
early costs nothing much.

**WSOLA** — Waveform Similarity Overlap-Add — is how it changes buffer depth without a click.
Naively dropping or repeating 10 ms of audio is audible; WSOLA finds a similar waveform segment
and splices there, so the adjustment is inaudible. That is what `TEMPLATE_SEG` and
`WSOLA_SCALED_WIN` parameterise.

## Concealing loss

```cpp
#define PLC_MAX_SAMPLES (4*20*sample_rate / 1000)
```

Four packets' worth — 80 ms — is the cap on how long concealment will keep synthesising. Beyond
that the connection is not suffering loss, it is broken, and inventing a second of audio would
be worse than silence.

Concealment happens at two levels. A codec may implement `amci_plc_t` and conceal in its own
domain, which is always better ([5.4](19-codecs-and-plugins.md)). Failing that, `LowcFE.cpp` is
a generic low-complexity frame erasure concealer that works on linear samples for any codec.

## Tuning

**Fixed buffer for predictable networks, adaptive for the internet.** Inside a datacentre,
adaptive machinery adds complexity for jitter that is not there.

**A deeper buffer trades latency for quality**, and there is no setting that avoids the trade —
only the choice of where to sit on it. The 0.1 target loss rate is the code's opinion about
where that is; a recording leg might reasonably want a very different one.

**Prefer RFC 2833 DTMF** and negotiate `telephone-event` in SDP. Inband detection costs CPU on
every stream, is unreliable through compressed codecs, and does not work at all in relay mode.

**Watch loss and concealment together.** Sustained concealment means loss the buffer is hiding
from your users but not from your call quality — and RTCP is where the numbers are
([1.2](01b-sip-media-primer.md)).
