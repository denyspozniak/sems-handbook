# 7.2 DSM

> [!IMPORTANT]
> DSM — це **предметна мова для потоків дзвінка**, що на етапі завантаження компілюється в
> машину станів, яку крутить ядро SEMS. Це не мова загального призначення, і вона не намагається
> нею бути. Усе, що вона робить добре, випливає з того, що вона є рівно однією річчю: стани,
> переходи, умови, дії.

## Цілий застосунок

Ось повний DSM-скрипт із `apps/dsm/lib/`:

```text
-- another nonsensical fsm...
initial state start;
transition "just an example" start - / { playPrompt(1); playPrompt(2); playPrompt(3); } -> end;
state end;
transition "stop it" end - noAudioTest() / stop(true) -> end;
transition "bye recvd" (start, end) - hangup() / stop(false) -> end;
```

П'ять рядків, і граматика в них уся видна:

```
transition "<ім'я>" <стан-звідки> - <умови> / <дії> -> <стан-куди>;
```

- **`-`** вводить умови. Порожньо означає безумовно.
- **`/`** вводить дії, у фігурних дужках, якщо їх більше однієї.
- **`->`** називає стан призначення.
- Стан-звідки може бути **списком** — `(start, end)` — тож один перехід покриває кілька станів.
  Останній рядок — це ідіома «обробити hangup, де б ми не були».

Коментарі — `--`. Це весь поверхневий синтаксис.

## Словник подій

Умови зіставляються з типом події, і цей enum є чесним переліком усього, на що потік дзвінка
може реагувати:

```cpp
  enum EventType {
    Any,
    Start,
    Invite,
    SessionStart,
    Ringing,
    EarlySession,
    FailedCall,
    SipRequest,
    SipReply,
    BeforeDestroy,
    Hangup,
    Hold,
    UnHold,
    B2BOtherRequest,
    B2BOtherReply,
    B2BOtherBye,
    SessionTimeout,
    RtpTimeout,
    RemoteDisappeared,
    Key,
    Timer,
    NoAudio,
    PlaylistSeparator,
    DSMEvent,
    B2BEvent,
    DSMException,
    XmlrpcResponse,
    JsonRpcResponse,
    JsonRpcRequest,
    Startup,
    Reload,
    System,
    SIPSubscription,
    RTPTimeout,
    // SBC related
    LegStateChange,
    BLegRefused,
    PutOnHold,
    ResumeHeld,
    CreateHoldRequest,
    HandleHoldReply,
    RelayInit,
    RelayInitUAC,
    RelayInitUAS,
    RelayFinalize,
    RelayOnSipRequest,
    RelayOnSipReply,
    RelayOnB2BRequest,
    RelayOnB2BReply
#ifdef WITH_ZRTP
    , ZRTPProtocolEvent,
    ZRTPSecurityEvent
#endif
  };
```

Прочитайте цей список як конспект усієї книги. `SessionStart` і `EarlySession` — це
[3.5](11-dialog-layer.md); `Key` — це DTMF ([5.5](20-dtmf-and-jitter.md));
`PlaylistSeparator` — аудіо-ланцюжок ([5.3](18-audio-pipeline.md)); `RtpTimeout` — це
`dead_rtp_time` ([5.2](17-rtp-stream.md)); родина `B2BOther*` — це [6.1](21-b2b-session.md); а
весь блок `// SBC related` — це [6.5](23c-sbc-call-control.md), і саме так `cc_dsm` дозволяє
писати політику call control у SBC скриптом.

`JsonRpcRequest` і `XmlrpcResponse` варті уваги: DSM-скриптом можна керувати по RPC, і він сам
може викликати назовні ([8.1](28-rpc-architecture.md)). Потік дзвінка може порадитись із
зовнішнім сервісом посеред дзвінка без жодного рядка C++.

`invert` в умові — це оператор `!`: заперечення є властивістю об'єкта умови, а не окремим вузлом.

## Дії, що керують движком

Більшість дій просто щось роблять. Кілька змінюють потік керування самого движка, і кажуть про
це другим методом:

```cpp
class DSMAction : public DSMElement {
 public:
  /** modifies State Engine operation */
  enum SEAction {
    None,   // no modification
    Repost, // repost current event
    Jump,   // jump FSM
    Call,   // call FSM
    Return, // return from FSM call
    Break   // break execution of current action list
  };

  virtual bool execute(...) = 0;
  virtual SEAction getSEAction(string& param, ...) { return None; }
};
```

`Jump`, `Call` і `Return` роблять DSM більшим за пласку машину станів — діаграми можуть кликати
інші діаграми й повертатись, тож потік «зібрати PIN» пишеться один раз і перевикористовується:

```cpp
  bool callDiag(const string& diag_name, ...);
  bool jumpDiag(const string& diag_name, ...);
  bool returnDiag(...);
```

зі стеком викликів із `DSMStackElement` під капотом.

`Repost` — найтонше. Дія може перевидати поточну подію після зміни стану, тож перехід може
змінити стан і дати *новому* стану обробити ту саму подію. Саме так уникають дублювання обробки
між станами.

`Break` зупиняє решту дій у поточному списку, не покидаючи переходу.

## Більше, ніж пласка FSM

Мова обросла керуванням потоком, якого в чистої машини станів немає:

```cpp
class DSMFunction { ... };

class DSMArrayFor
{
  enum DSMForType { ... };
  string array_struct; // array or struct name, or range upper bound
  ...
};

class DSMConditionTree
{
  vector<DSMCondition*> conditions;
  ...
  bool is_exception;
};
```

Функції, ітерація по масиву, структурі чи числовому діапазону, і дерева умов із прапорцем
`is_if` у рідері — тож умови можна групувати, а не лише з'єднувати через AND.

Винятки — першокласні:

```cpp
class DSMException { ... };
```

з `is_exception` і на переходах, і на деревах умов. Перехід можна позначити як обробник винятків,
піднятих у стані, і для потоку дзвінка, що говорить із базою чи HTTP API, це різниця між чистим
промптом про помилку і обірваним дзвінком.

## Рідер і перевірки на завантаженні

```cpp
class DSMChartReader {
  bool is_wsp(const char c);
  bool is_snt(const char c);
  ...
  DSMCondition* conditionFromToken(const string& str, bool invert);
  bool forFromToken(DSMArrayFor& af, const string& token);
  bool importModule(const string& mod_cmd, const string& mod_path);

  vector<DSMModule*> mods;
  vector<DSMFunction*> funcs;

  bool decode(DSMStateDiagram* e, const string& chart, ..., vector<DSMModule*>& out_mods);
};
```

Написані вручну токенізатор і парсер — без генератора лексерів — що дають `DSMStateDiagram`.

Цінне починається далі:

```cpp
class DSMStateDiagram  {
  bool checkInitialState(string& report);
  bool checkDestinationStates(string& report);
  bool checkHangupHandled(string& report);
  ...
  bool checkConsistency(string& report);
};
```

Три статичні перевірки на завантаженні, кожна повертає людиночитаний звіт:

| Перевірка | Ловить |
|---|---|
| `checkInitialState` | Немає початкового стану або їх більше одного |
| `checkDestinationStates` | Перехід вказує на стан, якого не існує |
| `checkHangupHandled` | **Стан без виходу на hangup** |

Третя — і є доброю ідеєю. Найпоширеніший баг у написаному вручну потоці дзвінка — стан, який не
обробляє покладену слухавку, — не падає, а тече сесією до `dead_rtp_time` через п'ять хвилин
([5.2](17-rtp-stream.md)). DSM просто відмовляється завантажувати діаграму з такою діркою.

> [!TIP]
> Одруківка в імені стану — це помилка завантаження зі звітом, що називає стан, а не рантайм-сюрприз.
> Це справжня перевага перед застосунками на Python ([7.3](26-ivr-and-python.md)), де еквівалентна
> помилка — це виняток на тому дзвінку, який у неї потрапив.

## Модулі

DSM сам по собі вміє грати промпти, збирати клавіші й маніпулювати змінними. Усе решта — модулі,
що завантажуються через `importModule()`:

```
mod_aws  mod_conference  mod_curl  mod_dlg    mod_groups  mod_monitoring
mod_mysql  mod_py  mod_redis  mod_regex  mod_sbc  mod_subscription
mod_sys  mod_uri  mod_utils  mod_xml  mod_zrtp
```

| Модуль | Дає скрипту |
|---|---|
| `mod_mysql`, `mod_redis` | Доступ до бази й кешу |
| `mod_curl` | HTTP-запити |
| `mod_aws` | Сервіси AWS |
| `mod_conference` | Керування конференцією ([9.2](32-conference-and-mixing.md)) |
| `mod_dlg` | Маніпуляції діалогом — слати запити, відповіді, re-INVITE |
| `mod_sbc` | Інтеграція з SBC, для `cc_dsm` ([6.5](23c-sbc-call-control.md)) |
| `mod_subscription` | SUBSCRIBE/NOTIFY |
| `mod_regex`, `mod_uri`, `mod_utils`, `mod_xml` | Робота з рядками, URI, XML |
| `mod_groups`, `mod_monitoring`, `mod_sys` | Групування, статистика, доступ до системи |
| `mod_py` | **Вбудований Python усередині DSM-скрипта** |
| `mod_zrtp` | Події ZRTP ([9.6](36-zrtp-and-srtp.md)) |

`mod_py` — це запасний вихід, і варто чітко сказати, що він означає: DSM-скрипт, який ним
користується, успадковує витрати Python ([7.3](26-ivr-and-python.md)) для цієї частини потоку.
Тягніться по нього тоді, коли альтернативою є новий C++-модуль, а не за замовчуванням.

> [!WARNING]
> `mod_mysql` і `mod_curl` роблять **блокуючий** ввід-вивід. DSM-скрипт виконується на потоці
> сесії ([2.1](02-thread-model.md)), тож повільний запит блокує цей дзвінок — що переживно — але
> у збірці з `SESSION_THREADPOOL` він блокував би всі сесії, що ділять воркер, а в модулі call
> control він блокує всередині шляху встановлення дзвінка в SBC
> ([6.5](23c-sbc-call-control.md)). Тримайте запити швидкими й ставте таймаути.

## Де живе стан

```cpp
class DSMSession { ... };
class DSMCall { ... };
class SystemDSM { ... };
```

`DSMSession` — видимий скрипту стан сесії: змінні, які скрипт ставить і читає. `DSMCall` — дзвінок,
що виконує діаграму. `SystemDSM` — діаграма, що виконується **без жодного дзвінка**, керована
подіями `Startup`, `Reload` і `System`. Саме так DSM робить фонову роботу: періодичні задачі,
прогрів кешу, реакція на RPC.

## Коли DSM — правильна відповідь

**Так:** потоки дзвінка — меню IVR, анонси, фронтенди голосової пошти, «зіграти й зібрати»,
політика SBC, що часто змінюється. Усе, де логіка звучить як «у цьому стані, на цю подію, зробити
це й піти туди».

**Ні:** усе, що впирається в CPU, усе, що потребує структури даних складнішої за структуру, усе,
де потрібна справжня інфраструктура тестування. І це поганий вибір для алгоритмів — керування
потоком свідомо обмежене, а боротьба з ним породжує скрипти, яких ніхто не може читати.

Порівняння з C++ і Python — [7.4](27-app-tradeoffs.md).
