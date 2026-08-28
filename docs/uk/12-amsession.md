# 4.1 AmSession

> [!IMPORTANT]
> `AmSession` — це місце, де сходяться всі підсистеми цієї книги. Він одночасно є потоком,
> чергою подій, обробником подій, обробником подій діалогу, медіа-сесією і приймачем DTMF. Якщо
> ви зрозумієте лише один клас у SEMS — хай це буде цей.

## Шість базових класів

```cpp
class AmSession :
  public AmEventQueue,
  public AmThread,
  public AmEventHandler,
  public AmSipDialogEventHandler,
  public AmMediaSession,
  public AmDtmfSink
```

Читайте цей перелік як карту решти книги:

| База | Дає сесії | Розділ |
|---|---|---|
| `AmEventQueue` | Поштову скриньку і час життя з підрахунком посилань | [2.2](03-event-system.md) |
| `AmThread` | Власний потік виконання | [2.1](02-thread-model.md) |
| `AmEventHandler` | `process(AmEvent*)` — споживацький кінець черги | [2.2](03-event-system.md) |
| `AmSipDialogEventHandler` | `onSessionStart` / `onEarlySessionStart` від діалогу | [3.5](11-dialog-layer.md) |
| `AmMediaSession` | Право бути прикріпленою до медіа-процесора | [5.1](16-media-processor.md) |
| `AmDtmfSink` | Місце, куди падають розпізнані цифри | [5.5](20-dtmf-and-jitter.md) |

Множинне успадкування зараз не в моді, але тут воно виконує справжню роботу: сесія дійсно є
всіма шістьма речами одночасно, і кожна підсистема тримає її за інший базовий вказівник.
Медіа-процесор бачить `AmMediaSession`; диспатчер — `AmEventQueueInterface`; діалог —
`AmSipDialogEventHandler`. Жодному з них не треба знати про сам `AmSession`.

## Цикл обробки

У типовій збірці сесія крутить власний потік ([2.1](02-thread-model.md)):

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

`processingCycle()` — машина станів на три значення:

```cpp
  enum ProcessingStatus {
    SESSION_PROCESSING_EVENTS = 0,
    SESSION_WAITING_DISCONNECTED,
    SESSION_ENDED_DISCONNECTED
  };
```

- **`SESSION_PROCESSING_EVENTS`** — нормальний стан. Вичерпувати чергу, виконувати застосунок.
- **`SESSION_WAITING_DISCONNECTED`** — застосунок закінчив, а діалог ні. `BYE` ще в польоті або
  транзакція ще не влягалась. Сесія лишається живою, щоб коректно договорити SIP-розмову.
- **`SESSION_ENDED_DISCONNECTED`** — термінальний. Сесія віддає себе прибиральнику
  ([2.3](04-memory-and-ownership.md)).

Саме через цей середній стан дзвінок, який із погляду застосунку «завершився», ще певний час
висить у списку. Завершення — це не одна подія, а зупинка застосунку **і** влягання діалогу, і
це незалежні речі.

Умову, що тримає сесію живою, варто прочитати дослівно:

```cpp
      // session running?
      if (!s_stopped || (dlg_status == AmSipDialog::Disconnecting)
	  || dlg->getUsages())
```

Три способи все ще працювати: застосунок не зупинився, або діалог від'єднується, або щось усе
ще тримає **usage** на діалозі. Usages — це посилання, які беруть підписки й реєстрації, що
ділять діалог, не володіючи ним ([3.5](11-dialog-layer.md)). Сесія з живим usage не вийде, навіть
якщо застосунок викликав `setStopped()`.

## Дебажні маркери

`processingCycle()` відкривається й закривається парою рядків логу, які є одними з
найкорисніших у всій кодовій базі:

```cpp
  DBG("vv S [%s|%s] %s, %s, %i UACTransPending, %i usages vv\n",
      dlg->getCallid().c_str(),getLocalTag().c_str(),
      dlg->getStatusStr(),
      sess_stopped.get()?"stopped":"running",
      dlg->getUACTransPending(),
      dlg->getUsages());
```

> [!TIP]
> `vv S [` і `^^ S [` обрамляють кожен прохід циклу подій сесії, і кожен рядок несе Call-ID,
> local tag, статус діалогу, чи зупинена сесія, кількість незавершених UAC-транзакцій і
> кількість usages. Грепнувши `^^ S \[<local-tag>`, ви отримаєте повне життя одного дзвінка по
> порядку. Сесія, яка не хоче вмирати, видно одразу: лічильник usages або незавершених
> транзакцій ніколи не доходить до нуля.

## Винятки

```cpp
  virtual bool processEventsCatchExceptions();
```

Обробка подій обгорнута. Виняток, що вилетів із коду застосунку, не розмотує потік і не кладе
процес — він переводить сесію одразу в `SESSION_ENDED_DISCONNECTED` і повертає `false`:

```cpp
      if (!processEventsCatchExceptions()) {
	// exception occured, stop processing
	processing_status = SESSION_ENDED_DISCONNECTED;
	return false;
      }
```

Це справжня межа локалізації: виняток C++ в одному дзвінку вбиває цей дзвінок і жодного іншого.
Уважно зауважте, чого вона **не** локалізує: segfault, abort і дедлок. Ці й далі забирають увесь
процес ([2.1](02-thread-model.md)).

## Колбеки

Писати застосунок означає перевизначати їх. Вони діляться на три групи.

**Життєвий цикл:**

```cpp
  virtual void onStart() {}
  virtual void onStop() {}
```

Порожні за замовчуванням; `onStart()` виконується на власному потоці сесії перед першою подією.

**Вхідний SIP** — те, чим ви користуватиметесь насправді:

| Колбек | Спрацьовує на |
|---|---|
| `onInvite(const AmSipRequest&)` | Початковий INVITE. Місце, де застосунок вирішує прийняти |
| `onSipRequest(const AmSipRequest&)` | Будь-який запит; загальний гачок під специфічними |
| `onSipReply(req, reply, old_dlg_status)` | Будь-яка відповідь, зі статусом діалогу *до* її застосування |
| `onInvite2xx(const AmSipReply&)` | Наш вихідний INVITE вдався |
| `onRinging(const AmSipReply&)` | Приїхав 180 |
| `onCancel(const AmSipRequest&)` | Викликач передумав |
| `onBye(const AmSipRequest&)` | Нормальне завершення |
| `onInvite1xxRel` / `onPrack2xx` | Надійні provisional-відповіді ([3.5](11-dialog-layer.md)) |
| `onDtmf(int event, int duration)` | Розпізнано цифру ([5.5](20-dtmf-and-jitter.md)) |

**Відмови** — група, яку забувають реалізувати:

| Колбек | Спрацьовує, коли |
|---|---|
| `onFailure()` | Запит відмовив |
| `onNoAck(unsigned int cseq)` | Ми надіслали 2xx, а ACK так і не приїхав |
| `onRemoteDisappeared(const AmSipReply&)` | Дальній бік перестав відповідати — шлях таймауту з `sip_ua::handle_reply_timeout()` ([3.1](07-sip-stack-overview.md)) |

> [!WARNING]
> `onNoAck` і `onRemoteDisappeared` — це різниця між застосунком, який прибирає за собою, і тим,
> що тече сесіями. Пір, який зник посеред діалогу, ніколи не надсилає `BYE`; якщо ви реалізували
> лише `onBye`, цей дзвінок живе до `dead_rtp_time` — типово 300 секунд
> ([2.5](06-sizing-and-tuning.md)).

Зверніть увагу, що `onSipReply` отримує `old_dlg_status` — стан діалогу *до* застосування
відповіді. Переходи важать більше за стани: «ми щойно стали Connected» — це інша подія, ніж «ми
Connected».

## Завершення сесії

```cpp
  virtual void setStopped(bool wakeup = false);
  bool getStopped() { return sess_stopped.get(); }
```

`setStopped()` виставляє прапорець; він нічого не розбирає. Наступний `processingCycle()` бачить
його, перевіряє діалог і переходить у `SESSION_WAITING_DISCONNECTED` або одразу в кінець.
Параметр `wakeup` виштовхує потік з очікування, щоб рішення сталося зараз, а не на наступній
події.

Ця непрямість навмисна. Сесія не має права видалити себе зсередини колбека, який виконує її ж
потік, а той, хто кличе з іншого потоку, теж не має права її звільняти
([2.3](04-memory-and-ownership.md)).

## Таймери й керування медіа

Зручні обгортки, обидві спираються на підсистеми з наступних частин:

```cpp
  static bool timersSupported();
  virtual bool setTimer(int timer_id, double timeout);
  virtual bool removeTimer(int timer_id);
  virtual bool removeTimers();
```

Таймери спрацьовують як `AmTimeoutEvent` у власну чергу сесії ([2.2](03-event-system.md)), тож
колбек виконується на потоці сесії, як і все інше. `timersSupported()` — перевірка в рантаймі,
бо сама служба таймерів живе в плагіні ([8.3](30-app-timers-and-events.md)).

```cpp
  void setMute(bool mute)              { RTPStream()->mute = mute; }
  void setReceiving(bool receive)      { RTPStream()->setReceiving(receive); }
  void setForceDtmfReceiving(bool r)   { RTPStream()->force_receive_dtmf = r; }
  bool hasRtpStream()                  { return _rtp_str.get() != NULL; }
  virtual void setOnHold(bool hold);
  virtual void setRemoteHold(bool remote_hold);
  virtual int sendReinvite(bool updateSDP = true, const string& headers = "", ...);
```

`setOnHold()` і `sendReinvite()` — ті двоє, що запускають новий обмін offer/answer
([4.3](14-offer-answer.md)); решта діють прямо на RTP-потік ([5.2](17-rtp-stream.md)).

## Друзі класу

```cpp
  friend class AmSessionContainer;
  friend class AmSessionFactory;
  friend class AmSessionProcessorThread;
```

Троє, і вони точно відповідають тому, кому дозволено маніпулювати сесією ззовні: той, хто її
створює, той, хто володіє її часом життя, і той, хто виконує її в пуловій збірці. Усе решта
мусить іти через чергу подій.
