# 4.1 AmSession

> [!IMPORTANT]
> `AmSession` is where every subsystem in this book meets. It is simultaneously a thread, an
> event queue, an event handler, a dialog event handler, a media session and a DTMF sink. If
> you only understand one class in SEMS, make it this one.

## Six base classes

```cpp
class AmSession :
  public AmEventQueue,
  public AmThread,
  public AmEventHandler,
  public AmSipDialogEventHandler,
  public AmMediaSession,
  public AmDtmfSink
```

Read that list as a map of the rest of the book:

| Base | Gives the session | Chapter |
|---|---|---|
| `AmEventQueue` | Its mailbox, and a refcounted lifetime | [2.2](03-event-system.md) |
| `AmThread` | Its own thread of execution | [2.1](02-thread-model.md) |
| `AmEventHandler` | `process(AmEvent*)` — the consumer end of the queue | [2.2](03-event-system.md) |
| `AmSipDialogEventHandler` | `onSessionStart` / `onEarlySessionStart` from the dialog | [3.5](11-dialog-layer.md) |
| `AmMediaSession` | The right to be attached to the media processor | [5.1](16-media-processor.md) |
| `AmDtmfSink` | Somewhere for detected digits to land | [5.5](20-dtmf-and-jitter.md) |

Multiple inheritance is unfashionable, but here it is doing real work: the session is genuinely
all six of those things at once, and every subsystem holds it by a different base pointer. The
media processor sees an `AmMediaSession`; the dispatcher sees an `AmEventQueueInterface`; the
dialog sees an `AmSipDialogEventHandler`. None of them needs to know about `AmSession` itself.

## The processing cycle

In the default build the session runs its own thread ([2.1](02-thread-model.md)):

```cpp
void AmSession::run() {
  ...
  if (!startup())
    return;

  while (...) {
    if (!processingCycle())
      break;
  }
  ...
}
```

`processingCycle()` is a state machine over three values:

```cpp
  enum ProcessingStatus {
    SESSION_PROCESSING_EVENTS = 0,
    SESSION_WAITING_DISCONNECTED,
    SESSION_ENDED_DISCONNECTED
  };
```

- **`SESSION_PROCESSING_EVENTS`** — the normal state. Drain the queue, run the application.
- **`SESSION_WAITING_DISCONNECTED`** — the application is done but the dialog is not. A `BYE` is
  still in flight, or a transaction has not settled. The session stays alive to finish the SIP
  conversation properly.
- **`SESSION_ENDED_DISCONNECTED`** — terminal. The session hands itself to the reaper
  ([2.3](04-memory-and-ownership.md)).

That middle state is why a call that has "ended" from the application's point of view is still
in the process list for a while. Ending is not one event; it is the application stopping *and*
the dialog settling, and those are independent.

The condition that keeps it alive is worth reading exactly:

```cpp
      // session running?
      if (!s_stopped || (dlg_status == AmSipDialog::Disconnecting)
	  || dlg->getUsages())
```

Three ways to still be running: the application has not stopped, or the dialog is
disconnecting, or something still holds a **usage** on the dialog. Usages are references taken
by things like subscriptions and registrations that share a dialog without owning it
([3.5](11-dialog-layer.md)) — a session with a live usage will not exit even if the application
called `setStopped()`.

## The debug markers

`processingCycle()` opens and closes with a pair of log lines that are among the most useful
things in the codebase:

```cpp
  DBG("vv S [%s|%s] %s, %s, %i UACTransPending, %i usages vv\n",
      dlg->getCallid().c_str(),getLocalTag().c_str(),
      dlg->getStatusStr(),
      sess_stopped.get()?"stopped":"running",
      dlg->getUACTransPending(),
      dlg->getUsages());
```

> [!TIP]
> `vv S [` and `^^ S [` bracket every pass through a session's event loop, and each line carries
> the Call-ID, the local tag, the dialog status, whether the session is stopped, the pending UAC
> transaction count and the usage count. Grepping for `^^ S \[<local-tag>` gives you the complete
> life of one call in order. A session that will not die shows up immediately: the usage count or
> the pending-transaction count never reaches zero.

## Exceptions

```cpp
  virtual bool processEventsCatchExceptions();
```

Event processing is wrapped. An exception escaping application code does not unwind through the
thread and take the process down — it moves the session straight to
`SESSION_ENDED_DISCONNECTED` and returns `false`:

```cpp
      if (!processEventsCatchExceptions()) {
	// exception occured, stop processing
	processing_status = SESSION_ENDED_DISCONNECTED;
	return false;
      }
```

This is a genuine containment boundary — a C++ exception in one call kills that call and no
others. Note carefully what it does *not* contain: a segfault, an abort, or a deadlock. Those
still take the whole process ([2.1](02-thread-model.md)).

## The callbacks

Writing an application means overriding these. They divide into three groups.

**Lifecycle:**

```cpp
  virtual void onStart() {}
  virtual void onStop() {}
```

Empty by default; `onStart()` runs on the session's own thread before the first event.

**Incoming SIP** — the ones you will actually use:

| Callback | Fires on |
|---|---|
| `onInvite(const AmSipRequest&)` | The initial INVITE. Where an application decides to accept |
| `onSipRequest(const AmSipRequest&)` | Any request; the generic hook beneath the specific ones |
| `onSipReply(req, reply, old_dlg_status)` | Any reply, with the dialog status *before* it applied |
| `onInvite2xx(const AmSipReply&)` | Our outgoing INVITE succeeded |
| `onRinging(const AmSipReply&)` | A 180 arrived |
| `onCancel(const AmSipRequest&)` | The caller gave up |
| `onBye(const AmSipRequest&)` | Normal teardown |
| `onInvite1xxRel` / `onPrack2xx` | Reliable provisionals ([3.5](11-dialog-layer.md)) |
| `onDtmf(int event, int duration)` | A digit was detected ([5.5](20-dtmf-and-jitter.md)) |

**Failure** — the group people forget to implement:

| Callback | Fires when |
|---|---|
| `onFailure()` | A request failed |
| `onNoAck(unsigned int cseq)` | We sent a 2xx and the ACK never came |
| `onRemoteDisappeared(const AmSipReply&)` | The far end stopped responding — the timeout path from `sip_ua::handle_reply_timeout()` ([3.1](07-sip-stack-overview.md)) |

> [!WARNING]
> `onNoAck` and `onRemoteDisappeared` are the difference between an application that cleans up
> and one that leaks sessions. A peer that vanishes mid-dialog never sends a `BYE`; if you only
> implement `onBye`, that call lives until `dead_rtp_time` — 300 seconds by default
> ([2.5](06-sizing-and-tuning.md)).

Note that `onSipReply` receives `old_dlg_status`, the dialog state *before* the reply was
applied. Transitions matter more than states — "we just became Connected" is a different event
from "we are Connected".

## Ending a session

```cpp
  virtual void setStopped(bool wakeup = false);
  bool getStopped() { return sess_stopped.get(); }
```

`setStopped()` sets a flag; it does not tear anything down. The next `processingCycle()` sees
it, checks the dialog, and moves to `SESSION_WAITING_DISCONNECTED` or straight to the end. The
`wakeup` parameter forces the thread out of its wait so the decision happens now rather than at
the next event.

This indirection is deliberate. A session must not delete itself from inside a callback that its
own thread is executing, and a caller from another thread has no business freeing it either
([2.3](04-memory-and-ownership.md)).

## Timers and media control

Convenience wrappers, both leaning on subsystems covered later:

```cpp
  static bool timersSupported();
  virtual bool setTimer(int timer_id, double timeout);
  virtual bool removeTimer(int timer_id);
  virtual bool removeTimers();
```

Timers fire as an `AmTimeoutEvent` into the session's own queue ([2.2](03-event-system.md)), so
the callback runs on the session's thread like everything else. `timersSupported()` is a runtime
check because the timer facility lives in a plug-in ([8.3](30-app-timers-and-events.md)).

```cpp
  void setMute(bool mute)              { RTPStream()->mute = mute; }
  void setReceiving(bool receive)      { RTPStream()->setReceiving(receive); }
  void setForceDtmfReceiving(bool r)   { RTPStream()->force_receive_dtmf = r; }
  bool hasRtpStream()                  { return _rtp_str.get() != NULL; }
  virtual void setOnHold(bool hold);
  virtual void setRemoteHold(bool remote_hold);
  virtual int sendReinvite(bool updateSDP = true, const string& headers = "", ...);
```

`setOnHold()` and `sendReinvite()` are the two that trigger a new offer/answer exchange
([4.3](14-offer-answer.md)); the rest act directly on the RTP stream
([5.2](17-rtp-stream.md)).

## The friends

```cpp
  friend class AmSessionContainer;
  friend class AmSessionFactory;
  friend class AmSessionProcessorThread;
```

Three, and they map exactly to who is allowed to manipulate a session from outside: the thing
that creates it, the thing that owns its lifetime, and the thing that runs it in a pooled build.
Everything else must go through the event queue.
