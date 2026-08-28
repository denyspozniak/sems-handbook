# 5.4 Codecs and plug-ins

> [!NOTE]
> `amci` — the **A**udio **M**odule **C**odec **I**nterface — is a plain C ABI in
> `core/amci/`. It predates the C++ plug-in system ([7.1](24-plugin-architecture.md)) and is
> deliberately separate: a codec is a set of function pointers, not a class.

## The interface

A codec module fills in a `struct amci_codec_t` with function pointers:

```c
typedef long (*amci_codec_init_t)(const char* format_parameters,
                                  const char** format_parameters_out, ...);
typedef void (*amci_codec_destroy_t)(long h_codec);

typedef unsigned int (*amci_codec_bytes2samples_t)(long h_codec, unsigned int num_bytes);
typedef unsigned int (*amci_codec_samples2bytes_t)(long h_codec, unsigned int num_samples);

typedef int (*amci_codec_negotiate_fmt_t)(int is_offer, const char* params_in,
                                          char* params_out, unsigned int params_out_len);

typedef int (*amci_converter_t)( unsigned char* out, ... );
typedef int (*amci_plc_t)( unsigned char* out, ... );
```

Five capabilities, and each earns its place:

**`init` / `destroy`** return and take a `long` handle, not a pointer. The codec keeps its own
per-stream state behind an opaque handle — a C-ABI-safe way to be stateful, which codecs like
Opus and iLBC need.

**`bytes2samples` / `samples2bytes`** exist because the relationship is not a constant. For
G.711 it is 1:1; for a frame-based codec it depends on frame size and on the negotiated
parameters. The core cannot compute it, so it asks.

**`negotiate_fmt`** lets a codec take part in offer/answer ([4.3](14-offer-answer.md)). Opus has
`maxplaybackrate`, `stereo`, `useinbandfec`; AMR has mode sets. The `is_offer` flag tells the
codec whether it is proposing or responding — the answer to an offer is not the same as an
offer.

**`amci_plc_t`** is packet loss concealment: given the codec's state, synthesise a plausible
frame for one that never arrived. Codec-specific because the right guess depends on the codec
([5.5](20-dtmf-and-jitter.md)).

## Shipped codecs

```
adpcm  codec2  echo   g722  g729  gsm  ilbc  isac
l16    opus    silk   speex wav
```

Plus non-codec modules that live in the same directory because they are loaded the same way:
`session_timer`, `uac_auth`, `stats`.

| Module | Note |
|---|---|
| `l16` | Linear 16-bit — no compression, the internal format |
| `g722` | Wideband, 16 kHz. The reason resampling exists |
| `gsm`, `ilbc`, `speex`, `silk`, `opus`, `codec2`, `isac` | Compressed, ascending in CPU cost |
| `g729` | A wrapper. The reference implementation is licensed, so what ships is the integration, not the codec |
| `adpcm` | G.726 family |
| `wav` | A *file format* module, not a codec — same interface, `amci_file_open_t` instead |
| `echo` | Not a codec at all: a loopback test module |

G.711 (`PCMU`/`PCMA`) is not in the list because it is built into the core — it is the one codec
that is always available.

> [!TIP]
> `exclude_payloads` in `sems.conf` is a blacklist applied at load time:
> ```
> # only use G711 (exclude everything else):
> # exclude_payloads=iLBC;speex;...
> ```
> It narrows what SEMS offers in SDP, and it is worth setting deliberately. Every codec you
> advertise is a codec a peer may pick, and the difference between G.711 and iLBC is roughly a
> factor of four in capacity ([2.5](06-sizing-and-tuning.md)).

## The file interface

The same header covers files:

```c
struct amci_file_desc_t { ... };

typedef int (*amci_file_open_t)( FILE* fptr, struct amci_file_desc_t* fmt_desc, ... );
typedef int (*amci_file_close_t)( FILE* fptr, struct amci_file_desc_t* fmt_desc, ... );
typedef int (*amci_file_mem_open_t)(unsigned char* mptr, ... );
typedef int (*amci_file_mem_close_t)( unsigned char* mptr, ... );
```

Note the `mem` variants. A file can be opened from memory rather than from a `FILE*`, which is
what makes `AmCachedAudioFile` possible ([5.3](18-audio-pipeline.md)): read the prompt once, and
every subsequent playback opens it from the cached buffer with no syscall at all.

`#define AMCI_RDONLY 1` and `#define AMCI_WRONLY 2` are the modes; the format descriptor carries
frame length, frame size and encoded frame size:

```c
#define AMCI_FMT_FRAME_LENGTH       1
#define AMCI_FMT_FRAME_SIZE         2
#define AMCI_FMT_ENCODED_FRAME_SIZE 3
```

## Module lifecycle

```c
typedef int (*amci_codec_module_load_t)(const char* ModConfigPath);
typedef void (*amci_codec_module_destroy_t)(void);
```

A codec module can have its own configuration file, loaded at startup ([2.4](05-lifecycle.md)).
`AmPlugIn` scans the plug-in directory, `dlopen`s each `.so`, and registers whatever payload
types it declares. From then on the payload is available to offer/answer.

## What transcoding costs

Transcoding means: decode the A-leg codec to linear, resample to 32 kHz if needed, resample to
the B-leg rate, encode. Four steps per direction, per packet, per call, fifty times a second.

The project's own figures from `README.md` put numbers on it — around 1200 G.711 conference
channels on a machine that manages 700 with GSM and 280 with iLBC. Same hardware, same code, a
factor of four from codec choice alone.

Two consequences:

**Avoid transcoding when you can.** If both legs offer a common codec, relay instead
([5.2](17-rtp-stream.md)). The SBC's codec filtering is largely a tool for engineering that
outcome ([6.4](23b-sbc-profiles.md)).

**Size for your worst codec, not your average.** Capacity is set by the calls that transcode,
and those are the ones you cannot control.

## Adding one

1. Implement the `amci_codec_t` function pointers.
2. Declare the payload type, name, sample rate and any format parameters.
3. Add it to `core/plug-in/` and to the build.
4. If it is stateful, keep state behind the `long` handle from `init()`.
5. If it can conceal loss, implement `amci_plc_t` — without it, a lost packet is silence
   ([5.5](20-dtmf-and-jitter.md)).

Everything else — SDP negotiation, payload numbering, the audio chain — comes for free, because
the core only ever talks to the interface.
