# 9.2 Conferencing and mixing

> [!NOTE]
> A conference is the one thing a media server does that a proxy cannot even approximate. It is
> also where the media plane's design choices pay off most visibly — the O(N) mixer
> ([5.3](18-audio-pipeline.md)) and callgroups ([5.1](16-media-processor.md)) exist largely for
> this.

## Rooms and channels

```cpp
class AmConferenceStatus
{
  static std::map<string,AmConferenceStatus*> cid2status;
  static AmMutex                              cid2s_mut;
  ...
  std::map<string, unsigned int> sessions;   // session id  → channel id
  std::map<unsigned int, SessInfo*> channels; // channel id → session

  AmConferenceChannel* getChannel(const string& sess_id, int input_sample_rate);
  int releaseChannel(unsigned int ch_id);
  void postConferenceEvent(int event_id, const string& sess_id);

  static AmConferenceChannel* getChannel(const string& cid, ...);
  static void releaseChannel(const string& cid, unsigned int ch_id);
  static void postConferenceEvent(const string& cid, int event_id, ...);
  static size_t getConferenceSize(const string& cid);
};
```

A conference is identified by a string — the **conference id**, usually derived from the dialled
number — and rooms are created on demand: the first participant to ask for a room gets it
created, the last to leave destroys it. There is no configuration file listing rooms.

The two maps are the same relationship in both directions, session id ↔ channel id. Both are
needed: an arriving participant asks by session, and the mixer works in channel numbers.

The static methods hide `cid2status` and its mutex, so a session never touches the room registry
directly.

> [!NOTE]
> `getChannel()` takes an `input_sample_rate`. Participants may arrive at different rates — one
> on G.711 at 8 kHz, another on G.722 at 16 kHz — and the mixer keeps a `MixerBufferState` per
> rate ([5.3](18-audio-pipeline.md)) rather than forcing everyone to a common one.

`AmConferenceChannel` is an `AmAudio` ([5.3](18-audio-pipeline.md)), which is what makes a
conference compose: a participant's audio chain treats the room as just another source and sink.

## The mixing algorithm

The mixer is `AmMultiPartyMixer` and its trick bears repeating, because it is the difference
between a conference of ten and a conference of hundreds:

```cpp
  void mix_add(int* dest,int* src1,short* src2,unsigned int size);
  void mix_sub(int* dest,int* src1,short* src2,unsigned int size);
  void scale(short* buffer,int* tmp_buf,unsigned int size);
```

Naively, each of N participants hears the sum of the other N−1 — that is N−1 additions per
participant, so O(N²) per tick.

Instead: sum **everybody** once, then for each participant subtract their own contribution.
O(N) per tick. Ten participants is 10 subtractions instead of 90 additions; two hundred is 200
instead of 39 800.

The intermediate is `int` because summing many 16-bit samples overflows a `short`, and `scale()`
brings the result back down at the end. Naive summing without headroom is the classic conference
distortion bug.

## Everyone on one thread

Because conference participants share a **callgroup**, they all run on the same media processor
thread ([5.1](16-media-processor.md)). No locking on the audio path, and no cross-thread handoff
per sample.

> [!WARNING]
> The consequence is the one to plan around: **a conference cannot span media threads.** Two
> hundred participants are one callgroup, therefore one thread, no matter how many
> `media_processor_threads` you configure. `getLoad()` lets the processor place a *new* group on
> the least loaded thread, but an existing group cannot be split.
>
> If one room saturates a thread, more threads do not help. The answers are fewer participants
> per room, cheaper codecs to cut the per-participant cost ([5.4](19-codecs-and-plugins.md)), or
> splitting the room across instances and bridging them — which SEMS will not do for you
> ([11.2](41-topologies-and-ha.md)).

## Two applications

**`conference`** is the classic: dial a number, land in a room, hear the others. It also calls
flite for spoken prompts ([7.3](26-ivr-and-python.md)):

```cpp
  flite_text_to_speech(text.c_str(), tts_voice, filename.c_str());
```

with the `// garbage collect tts files - TODO: delete files` comment nearby, which is a fair
indication of how much attention that path has received.

**`webconference`** is the same mixing with an external control interface — a DI interface
([8.1](28-rpc-architecture.md)) for creating rooms, admitting and ejecting participants, muting
and listing. The conference logic is identical; what differs is who decides.

`postConferenceEvent()` is how that control reaches participants: an external system calls in,
the room posts an event, and each participant's session handles it on its own thread
([2.2](03-event-system.md)) — no locks, no reaching into other sessions.

## Sizing a conference box

The numbers from the project's own `README.md` are for exactly this workload — roughly 1200
G.711 conference channels on a quad-core 2 GHz Xeon, 700 with GSM, 280 with iLBC, and up to 5000
on a dual quad-core at 2.9 GHz.

Read them as three lessons:

1. **Codec choice moves capacity by a factor of four.** In a conference, every participant is
   decoded and re-encoded every tick, so the codec cost is paid N times, not once
   ([5.4](19-codecs-and-plugins.md)).
2. **"Channels" is not "rooms".** 1200 channels could be one impossible room or 120 rooms of ten.
   The thread ceiling applies per room; the total applies per box.
3. **They are old numbers.** The ratios still hold; the absolute values are conservative on
   modern hardware.

## What to watch

| Signal | Meaning |
|---|---|
| Media tick overrun on one thread | A room outgrew its thread ([5.1](16-media-processor.md)) |
| `getConferenceSize()` growing without bound | Participants not releasing channels |
| Rooms that never disappear | `releaseChannel()` not reached on some teardown path |

That last one is the common leak. A room is destroyed when the last participant leaves, so a
single session that fails to release its channel keeps the room — and its mixer buffers — alive
indefinitely. It is the conference-shaped version of the general rule that failure paths matter
more than success paths ([4.1](12-amsession.md)).
