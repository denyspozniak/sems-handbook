# 6.5 Модулі call control у SBC

> [!NOTE]
> Профілі вирішують політику з самого запиту ([6.4](23b-sbc-profiles.md)). Модулі call control
> вирішують її з **будь-чого іншого** — бази даних, балансу, лічильника одночасних дзвінків,
> REST API. Це точка розширення SBC, і тут поруч живуть два покоління інтерфейсу.

## Два інтерфейси, одна мета

| | Старий | Сучасний |
|---|---|---|
| Заголовок | `SBCCallControlAPI.h` | `ExtendedCCInterface.h` |
| Механізм | Виклики DI з `AmArg` ([8.1](28-rpc-architecture.md)) | Віртуальні методи C++ |
| Аргументи | Позиційні цілочисельні константи | Типізовані параметри |
| Повернення | Масив дій | `CCChainProcessing` |
| Досяжність | Події життєвого циклу дзвінка | Життєвий цикл **плюс** медіа, DTMF, утримання, на пакет |

Обидва живі. Старий — це те, як працюють старіші модулі в комплекті, і єдиний спосіб для
модуля іншою мовою взагалі брати участь, бо DI досяжний по RPC. Сучасним користуються нові
C++-модулі.

## Старий інтерфейс

Усе позиційне:

```c
#define CC_INTERFACE_MAND_VALUES_METHOD "getMandatoryValues"

#define CC_API_PARAMS_CC_NAMESPACE      0
#define CC_API_PARAMS_LTAG              1
#define CC_API_PARAMS_CALL_PROFILE      2
#define CC_API_PARAMS_SIP_MSG           3
#define CC_API_PARAMS_TIMESTAMPS        4
#define CC_API_PARAMS_CFGVALUES         5
#define CC_API_PARAMS_TIMERID           6
#define CC_API_PARAMS_OTHERID           5
```

Модуль отримує масив `AmArg` і індексує в нього константами. Зверніть увагу: `_CFGVALUES` і
`_OTHERID` **обидва дорівнюють 5** — значення слота залежить від того, який це виклик. Це і є
ціна позиційних аргументів, і добра причина віддавати перевагу сучасному інтерфейсу для всього
нового.

Мітки часу теж позиційні:

```c
#define CC_API_TS_START_SEC             0
#define CC_API_TS_START_USEC            1
#define CC_API_TS_CONNECT_SEC           2
#define CC_API_TS_CONNECT_USEC          3
#define CC_API_TS_END_SEC               4
#define CC_API_TS_END_USEC              5
```

Старт, з'єднання і кінець, із мікросекундною роздільністю — три мітки, потрібні CDR, і причина,
чому `syslog_cdr` може бути таким маленьким.

Модуль відповідає діями:

```c
#define SBC_CC_DROP_ACTION              0
#define SBC_CC_REFUSE_ACTION            1
#define SBC_CC_SET_CALL_TIMER_ACTION    2
#define SBC_CC_REPL_SET_GLOBAL_ACTION        10
#define SBC_CC_REPL_REMOVE_GLOBAL_ACTION     11

#define SBC_CC_ACTION              0
#define SBC_CC_REFUSE_CODE         1
#define SBC_CC_REFUSE_REASON       2
#define SBC_CC_REFUSE_HEADERS      3
#define SBC_CC_TIMER_TIMEOUT       1
#define SBC_CC_REPL_SET_GLOBAL_SCOPE 1
#define SBC_CC_REPL_SET_GLOBAL_NAME  2
#define SBC_CC_REPL_SET_GLOBAL_VALUE 3
```

П'ять речей, яких модуль може попросити:

- **Drop** — тихо відкинути. Жодної відповіді, і це правильне поводження з трафіком, який ви не
  хочете підтверджувати ([10.3](39-security-hardening.md)).
- **Refuse** — відхилити з кодом, причиною і необов'язковими заголовками.
- **Set call timer** — завершити дзвінок через N секунд. Це і є весь `call_timer`.
- **Set / remove global** — записати змінну, яку `ParamReplacer` потім прочитає як `$V(...)`
  ([6.4](23b-sbc-profiles.md)). Модуль щось обчислює, а профіль цим користується: саме ця
  передача дозволяє будувати маршрутизацію з бази, не навчаючи профіль баз даних.

Таймери повертаються подією:

```c
#define SBCCallTimerEvent_ID -563

struct SBCCallTimerEvent : public AmEvent {
  enum TimerAction {
    Remove = 0,
    Set,
    Reset
  };
  TimerAction timer_action;
  double timeout;
  int timer_id;
  ...
};
```

`getMandatoryValues` дозволяє модулю оголосити, які конфігураційні значення йому потрібні, тож
помилка конфігурації валить завантаження, а не перший дзвінок.

## Сучасний інтерфейс

```cpp
enum CCChainProcessing { ContinueProcessing, StopProcessing };

class ExtendedCCInterface
{
    virtual bool init(SBCCallLeg *call, const map<string, string> &values) { return true; }
    virtual void onStateChange(SBCCallLeg *call, const CallLeg::StatusChangeCause &cause) { }
    virtual void onDestroyLeg(SBCCallLeg *call) { }

    virtual CCChainProcessing onBLegRefused(SBCCallLeg *call, const AmSipReply& reply) { return ContinueProcessing; }
    virtual CCChainProcessing onInitialInvite(SBCCallLeg *call, InitialInviteHandlerParams &params) { return ContinueProcessing; }
    virtual CCChainProcessing onInDialogRequest(SBCCallLeg *call, const AmSipRequest &req) { return ContinueProcessing; }
    virtual CCChainProcessing onInDialogReply(SBCCallLeg *call, const AmSipReply &reply) { return ContinueProcessing; }
    virtual CCChainProcessing onEvent(SBCCallLeg *call, AmEvent *e) { return ContinueProcessing; }
    virtual CCChainProcessing onDtmf(SBCCallLeg *call, int event, int duration) { return ContinueProcessing; }

    virtual void holdRequested(SBCCallLeg *call) { }
    virtual void holdAccepted(SBCCallLeg *call) { }
    virtual void holdRejected(SBCCallLeg *call) { }
    virtual void resumeRequested(SBCCallLeg *call) { }
    virtual void resumeAccepted(SBCCallLeg *call) { }
    virtual void resumeRejected(SBCCallLeg *call) { }

    virtual void onAfterRTPRelay(SBCCallLeg *call, AmRtpPacket* p, ...);
    virtual int relayEvent(SBCCallLeg *call, AmEvent *e) { return 0; }
    ...
};
```

`CCChainProcessing` — та сама ідея «зупинити ланцюжок», що й в обробників подій сесії
([4.4](15-session-event-handlers.md)), але названа й типізована, а не голий `bool`. Це справжнє
покращення: `return StopProcessing` каже, що робить, а `return true` не казав.

Три групи гачків варті окремої згадки.

**`onStateChange()` отримує `StatusChangeCause`** із [6.3](23-sbc.md), тож модуль знає не лише
що дзвінок зрушив, а й чому — SIP-відповідь, таймаут RTP, відсутній ACK, session timeout. Саме
це перетворює CDR із запису на діагноз.

**Шість гачків утримання** існують тому, що утримання можна запросити, прийняти або відхилити в
будь-якому напрямку, і модулю політики може знадобитись втрутитись у будь-якій із цих точок.

**`onAfterRTPRelay()` — це гачок на кожен пакет медіа.**

> [!IMPORTANT]
> Це єдине місце в SBC, де модуль бачить окремі RTP-пакети. Саме ним користується `cc_siprec`,
> щоб форкати медіа на рекордер, і саме це є природною точкою врізки для всього, що хоче копію
> аудіо — включно зі стрімінгом у ASR-движок ([13.4](50-media-forking-stt-tts.md)).
>
> Він виконується на потоці RTP-приймача в режимі релею ([5.2](17-rtp-stream.md)), тож обмеження
> абсолютне: **він не має права блокуватись.** Ні синхронного мережевого запису, ні лока, який
> інший потік тримає довго. Покласти в чергу й повернутись.

Другий, менший набір гачків обслуговує `SBCSimpleRelay` ([6.3](23-sbc.md)):

```cpp
    virtual bool init(SBCCallProfile &profile, SimpleRelayDialog *relay, void *&user_data) { return true; }
    virtual void initUAC(const AmSipRequest &req, void *user_data) { }
    virtual void initUAS(const AmSipRequest &req, void *user_data) { }
    virtual void finalize(void *user_data) { }
    virtual void onSipRequest(const AmSipRequest& req, void *user_data) { }
    virtual void onSipReply(const AmSipRequest& req, ...);
    virtual void onB2BRequest(const AmSipRequest& req, void *user_data) { }
    virtual void onB2BReply(const AmSipReply& reply, void *user_data) { }
```

Зверніть увагу на `void *user_data`, що проходить крізь усе: у простого релею немає
`SBCCallLeg`, на який можна повісити стан, тож модуль отримує непрозорий слот.

## Модулі в комплекті

```
bl_redis  call_timer  ctl       dsm       parallel_calls  prepaid
prepaid_xmlrpc        registrar rest      siprec          syslog_cdr  template
```

Згруповано за тим, що вони справді роблять:

**Допуск і ліміти**

| Модуль | Робить |
|---|---|
| `bl_redis` | Пошук у блоклисті в Redis. Відповідає дією drop або refuse |
| `parallel_calls` | Обмеження одночасних дзвінків на користувача — порахувати, звірити, відмовити |
| `call_timer` | Максимальна тривалість дзвінка, реалізована чисто як `SBC_CC_SET_CALL_TIMER_ACTION` |

**Білінг**

| Модуль | Робить |
|---|---|
| `prepaid` | Локальний контроль за кредитом: перевірити баланс, поставити таймер на доступну тривалість, списати в кінці |
| `prepaid_xmlrpc` | Те саме проти зовнішнього білінг-сервера по XML-RPC |

Патерн prepaid варто зрозуміти як дизайн: кредит перетворюється на *таймер дзвінка*, тож механізм
енфорсменту той самий, яким користується `call_timer`. Модуль не пильнує дзвінок посекундно — він
обчислює, наскільки вистачить грошей, і віддає роботу таймеру.

**Маршрутизація й ідентичність**

| Модуль | Робить |
|---|---|
| `registrar` | Кешування REGISTER і переспрямування — див. нижче |
| `ctl` | Керування профілем через SIP-заголовки: дати самому запиту керувати політикою |
| `rest` | Call control через REST API — запасний вихід до будь-якої зовнішньої системи |

> [!WARNING]
> `ctl` дозволяє заголовку змінювати поведінку SBC. На недовіреному інтерфейсі це рівно та
> проблема, що описана в [6.4](23b-sbc-profiles.md) і [10.1](37-security-surface.md).
> Вживайте лише там, де відправник довірений.

**Запис і звітність**

| Модуль | Робить |
|---|---|
| `siprec` | Запис за SIPREC (RFC 7865/7866), керований `onAfterRTPRelay()` ([9.5](35-siprec-and-recording.md)) |
| `syslog_cdr` | Записи про дзвінки в syslog, з трьох міток часу й причини зміни статусу |

**Скриптинг і скелет**

| Модуль | Робить |
|---|---|
| `dsm` | Виконує машину станів DSM як call control ([7.2](25-dsm.md)) — політика в скрипті замість C++ |
| `template` | Порожній скелет. Правильна точка старту для власного модуля |

`cc_dsm` вартий наголосу: він означає, що call control у SBC можна писати мовою DSM, а не
компільованим C++, і для політики, що часто змінюється, це значно кращий обмін — без перезбірки,
без рестарту, і падіння скрипта не забирає з собою процес ([7.4](27-app-tradeoffs.md)).

## Кешування реєстрацій

`RegisterCache.cpp` (1116 рядків) і `RegisterDialog.cpp` (659 рядків) — солідна підсистема, що
стоїть за модулем `registrar`.

Проблема: ендпоінти перереєструються щохвилини-дві. Пропускати все це до реєстратора за SBC
марнотратно, і при цьому SBC не має уявлення, де хто перебуває, коли для нього приходить дзвінок.

Кеш поглинає реєстрації, тримає власну таблицю прив'язок і освіжає апстрім рідше. Далі він знає,
як дістати зареєстрованого користувача напряму — і саме це робить можливими підстановки `$u`,
`$Ua` і `$UA` у профілях ([6.4](23b-sbc-profiles.md)):

| Токен | Значення |
|---|---|
| `$u` | Кешований користувач призначення для цього дзвінка |
| `$Ua` | Вихідна адреса запису (AoR) |
| `$UA` | Вихідний alias — ідентичність із боку SBC |

Alias — найцікавіше: SBC дає кожній реєстрації локальну ідентичність, тож усередині мережі ніколи
не видно адресації ззовні, а NAT-прив'язки лишаються прив'язаними до того, чим SBC керує.

`SBCCallRegistry.cpp` веде поруч реєстр на рівні дзвінків, а `SBCEventLog.cpp` дає структуроване
логування подій, у яке модулі можуть писати.

## Як писати модуль

1. Почніть із `call_control/template`.
2. Реалізуйте `ExtendedCCInterface`; повертайте `ContinueProcessing` з усього, чого не обробляєте.
3. Оголосіть потрібну конфігурацію, щоб помилка вилазила на завантаженні, а не на дзвінку.
4. Назвіть модуль у полях `cc_name` / `cc_module` профілю ([6.4](23b-sbc-profiles.md)).
5. Передавайте результати в профіль через встановлення глобальних змінних, які читаються назад
   як `$V(...)`.

> [!WARNING]
> Модуль call control виконується **всередині процесу** ([2.1](02-thread-model.md)). Блокуючий
> запит до бази всередині `onInitialInvite()` стопорить потік сесії; segfault забирає весь сервер
> і всі дзвінки на ньому. Якщо логіці треба говорити з чимось повільним чи ненадійним — робіть це
> асинхронно або сховайте за `rest` і дайте мережевій межі локалізувати відмову.
