# 7.3 IVR and Python

> [!IMPORTANT]
> SEMS embeds CPython in-process, which means it also embeds CPython's **global interpreter
> lock**. In a server whose whole concurrency model is threads ([2.1](02-thread-model.md)), that
> is not a footnote — it is the defining constraint of every Python application you will write
> here.

## Two Python applications

| Application | What it is |
|---|---|
| `apps/ivr` | The original: a Python-scripted `AmSession` with a hand-written C++ binding layer |
| `apps/py_sems` | The later one, SIP-generated bindings, exposing more of the C++ object model |
| `apps/ivr-python2` | The Python 2 remnant — present, historical, not where new work goes |

Both do the same job: let a call flow be written in Python instead of C++.

`py_sems` exposes more — `PySemsDialog`, `PySemsB2BDialog`, `PySemsB2ABDialog`, `PySemsAudio` —
including the B2BUA variants ([6.1](21-b2b-session.md)), so it can script a two-legged call and
not only a media session. Its bindings are generated from `sip` definitions rather than written
by hand, which is why its surface is wider and its build has an extra dependency.

## The `ivr` object model

`doc/Readme.ivr.txt` documents it, and it is small enough to quote in full:

```python
class IvrDialogBase:

    # Event handlers
    def onStart(self): # SIP dialog start
        pass

    def onBye(self): # SIP dialog is BYEd
        pass

    def onSessionStart(self): # audio session start
        pass

    def onEmptyQueue(self): # audio queue is empty
        pass

    def onDtmf(self,key,duration): # received DTMF
        pass

    def onSipReply(IvrSipReply r):
    	pass

    def onSipRequest(IvrSipRequest r):
    	pass

    # Session control
    def stopSession(self): # stop everything
        pass

    def bye(self): # BYEs (or CANCELs) the SIP dialog
        pass

    # Media control
    def enqueue(self,audio_play,audio_rec): # add something to the playlist
        pass

    def flush(self): # flushes playlist
        pass

    dialog
```

Every one of these maps onto something already covered:

- `onStart` / `onSessionStart` are the dialog's two start hooks — SIP established versus media
  established ([3.5](11-dialog-layer.md)). Confusing them is the classic beginner mistake:
  playing audio in `onStart` plays it before there is anywhere to play it to.
- `onDtmf(key, duration)` is `AmSession::onDtmf()` ([5.5](20-dtmf-and-jitter.md)), already
  normalised across RFC 2833, INFO and inband.
- `enqueue(audio_play, audio_rec)` is `AmPlaylist::addToPlaylist()`
  ([5.3](18-audio-pipeline.md)) — one call takes both a playback and a record item, because a
  playlist entry is a pair.
- `onEmptyQueue()` is the playlist running dry — the event-driven answer to "has the prompt
  finished", instead of polling.
- `dialog` is a read-only view of `AmSipDialog` ([3.5](11-dialog-layer.md)), with the header
  noting that "only its properties should be exposed".

A minimal application is a class with two or three of these implemented. That is genuinely the
whole learning curve, and it is why IVR work in SEMS is usually Python work.

## Threads, and the note in the docs

```
createThread(Callable thread)
    create a thread. Only to be used in module
    initialization code (no effect afterwards)
```

Read that restriction carefully — it is the GIL showing through the API.

Each call is a C++ thread ([2.1](02-thread-model.md)). Each of those threads runs Python code.
Python's interpreter lock means **only one of them executes Python bytecode at a time**.

The consequences:

**Python call flows do not scale on cores.** A hundred concurrent calls running Python are a
hundred threads contending for one lock. C++ sessions on the same box scale across cores; Python
ones do not.

**But call flows are not CPU-bound.** A typical script does a few dozen operations per call:
decide, enqueue a prompt, wait for a key. The audio itself is handled entirely in C++ by the
media processor ([5.1](16-media-processor.md)), which never touches the GIL. So the GIL is
usually not the bottleneck for what these scripts actually do.

**Until someone does real work in it.** Parse a large XML document, run a regex over a big
string, do arithmetic in a loop — and every other call on the box waits.

> [!WARNING]
> A **blocking** call in Python is worse than a slow one. `urllib` against a slow endpoint, or a
> database driver that does not release the GIL, stalls every Python call on the server for the
> duration. If a script must call out, prefer a library that releases the GIL around I/O, keep
> timeouts short, and consider whether the work belongs in a DI module reached over RPC instead
> ([8.1](28-rpc-architecture.md)).

## Selecting the script

Which script runs is decided the same way the application is, one level down
([4.2](13-session-container-and-factories.md)):

> Depending on the sems.conf file this is the way how Python scrips gets selected

So `application=ivr` picks the IVR plug-in, and the IVR plug-in's own configuration picks the
script — by R-URI user, by a parameter, or fixed. The same security note applies: if the
selector reads something the caller controls, the caller chooses which script runs
([10.1](37-security-surface.md)).

## Text to speech

```cpp
  flite_text_to_speech(text.c_str(), tts_voice, filename.c_str());
```

`IvrAudio.cpp` and `apps/conference/Conference.cpp` both call flite. It synthesises **to a
file**, and the file is then played through the ordinary audio chain
([5.3](18-audio-pipeline.md)).

That is worth stating plainly because it sets expectations. TTS in SEMS today is:

- **File-based**, not streaming. Synthesis completes, then playback starts.
- **Local**, via flite — small, fast, and audibly a 2005-era synthesiser.
- Fine for "your PIN is 1234"; not what anyone means in 2026 by a voice agent.

The `Conference.cpp` code even carries a `// garbage collect tts files - TODO: delete files`
comment, which tells you how much attention the path has had.

Streaming synthesis, and streaming recognition in the other direction, do not exist in the tree.
What that would take is [13.4](50-media-forking-stt-tts.md).

## When Python is the right answer

**Yes:** IVR flows with real logic, prototypes, anything an ops team must be able to change
without a build, integrations where a Python library already exists.

**No:** anything on the media path, anything CPU-bound, anything at very high call rates, and
anything where a stack trace mid-call is unacceptable.

Between Python and DSM specifically: DSM is checked at load time
([7.2](25-dsm.md)) and cannot take the process down; Python is more expressive and has a library
for everything. The trade is set out in [7.4](27-app-tradeoffs.md).
