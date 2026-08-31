# 9.3 Message storage and voicemail

> [!NOTE]
> Voicemail is the oldest reason to run a media server, and SEMS' implementation is a good study
> in separating concerns: recording, storage and retrieval are three different modules, and you
> can replace any one of them.

## The split

| Application | Does |
|---|---|
| `voicemail` | Records a message and delivers it — by email, to a box, or both |
| `msg_storage` | The storage back end. A DI interface, not an application |
| `voicebox` | The retrieval side: users dial in and listen |
| `mailbox` | An IMAP-backed variant — messages become emails on an IMAP server |
| `annrecorder` | Lets a user record their own greeting |

The important line is between `voicemail` and `msg_storage`. Recording knows nothing about where
messages live; storage knows nothing about calls. They meet over a DI interface
([8.1](28-rpc-architecture.md)), which means replacing storage — filesystem, database, object
store — needs no change to the recording side.

`annrecorder` exists because a personal greeting is a *recording* application, not a voicemail
one: same audio path, entirely different flow.

## Recording, mechanically

Recording is the `AmAudio` chain used in the input direction
([5.3](18-audio-pipeline.md)). `enqueue(audio_play, audio_rec)` takes both a playback and a
record item precisely because prompt-then-record is one operation
([7.3](26-ivr-and-python.md)): play the greeting, then capture until silence, a key or a hangup.

Two mechanisms make this work without stalling the media tick:

**`async_file_writer`.** Started in `main()` ([2.4](05-lifecycle.md)), it exists so a session
never blocks on disk I/O. The 10 ms media tick ([5.1](16-media-processor.md)) cannot wait for a
write to complete, so samples are queued and written on another thread.

**Format conversion is `amci`'s job.** The `wav` module is a file-format module using the same
interface as codecs ([5.4](19-codecs-and-plugins.md)), so recording to a different container is
a module, not a change to the recorder.

> [!IMPORTANT]
> `async_file_writer` is the pattern to copy for anything that must get data out of the media
> path — including a future streaming sink for speech recognition
> ([13.4](50-media-forking-stt-tts.md)). Queue and return; never write synchronously from
> anything the media processor drives.

## Detecting the end of a message

The hard part of voicemail is not recording, it is knowing when to stop. Three signals, all
already covered:

| Signal | Source |
|---|---|
| The caller hangs up | `onBye()` ([4.1](12-amsession.md)) |
| The caller presses a key | `onDtmf()` ([5.5](20-dtmf-and-jitter.md)) |
| Silence | the `NoAudio` condition ([7.2](25-dsm.md)) |

Plus a maximum duration, which is an application timer
([8.3](30-app-timers-and-events.md)) — and which you want, because the first two can both fail
to arrive.

Silence detection deserves a caution: it operates on decoded audio, so it does not work in relay
mode ([5.2](17-rtp-stream.md)), and a noisy line never goes silent. Never rely on it alone.

## Retrieval

`voicebox` is a straightforward IVR ([7.3](26-ivr-and-python.md)): authenticate, list, play,
delete. The audio work is `AmPlaylist` ([5.3](18-audio-pipeline.md)) and DTMF collection; the
interesting part is the flow, which is exactly the shape DSM was built for
([7.2](25-dsm.md)).

`mailbox` takes the different route of storing messages on an **IMAP server**, so voicemail
arrives as email and any mail client is a client. Fewer moving parts if you already run mail;
one more external dependency in the call path if you do not.

## Where storage actually goes

`msg_storage` is a DI interface, so the calls are `AmArg` in and `AmArg` out
([7.1](24-plugin-architecture.md)) — store, retrieve, list, delete, keyed by user and message
id. What sits behind it is the implementation's business.

That indirection is the design's real value. Filesystem for a small deployment, a database for a
cluster, an object store for scale — and the recording application is untouched, because it only
ever talks to the interface.

> [!WARNING]
> Voicemail is recorded audio of people's conversations. Wherever it lands is subject to the
> retention and access rules of wherever you operate. This is not a SEMS concern and SEMS gives
> you nothing for it: no encryption at rest, no retention policy, no access log. Whatever your
> obligations are, they are yours to implement around the storage module
> ([10.1](37-security-surface.md)).

## Notifying the user

Message-waiting indication needs `NOTIFY` towards the subscriber, and SEMS supports it via
`SUBSCRIBE`/`NOTIFY` dialogs ([3.5](11-dialog-layer.md)) — which is one of the reasons the
dialog layer is split into `AmBasicSipDialog` and `AmSipDialog` in the first place.

The SBC profile flag `allow_subless_notify` ([6.4](23b-sbc-profiles.md)) exists because many MWI
implementations send `NOTIFY` without a subscription — technically wrong, extremely common, and
something an SBC in the path has to tolerate.
