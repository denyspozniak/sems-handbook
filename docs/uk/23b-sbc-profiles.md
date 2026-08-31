# 6.4 Профілі дзвінків SBC і переписування

> [!IMPORTANT]
> Профіль дзвінка — це не конфігураційний файл, прочитаний на старті. Це **шаблон, що
> обчислюється на кожен дзвінок**. Майже кожне поле є рядком із підстановками, які резолвляться
> проти реального INVITE у момент приходу дзвінка. Саме це дозволяє одному профілю
> обслуговувати тисячі різних дзвінків, і саме ця ідея пояснює весь дизайн SBC.

## Патерн «рядок + значення»

Подивіться на ці пари в `SBCCallProfile.h`:

```cpp
  string sst_enabled;
  bool sst_enabled_value;

  string rtprelay_enabled;
  bool rtprelay_enabled_value;

  string force_symmetric_rtp;
  bool force_symmetric_rtp_value;

  string rtprelay_interface;
  int rtprelay_interface_value;
```

Кожна має ту саму форму: **рядок**, як налаштовано, і **типізоване значення** після обчислення.
Рядком може бути `yes`, а може бути `$H(P-Enable-Relay)` — тобто «візьми з заголовка саме цього
дзвінка». `ParamReplacer` це резолвить, результат парситься, і далі код читає вже типізоване
поле.

Побачивши це один раз, весь профіль читаєш інакше. Це не об'єкт налаштувань, а таблиця рішень,
що компілюється на кожен дзвінок.

## Мова підстановок

`ParamReplacer.cpp` реалізує невелику мову. Вона варта повної таблиці, бо документації по ній
мало, а коду 869 рядків.

**Поля повідомлення:**

| Токен | Значення |
|---|---|
| `$f` | From |
| `$ft` | From tag |
| `$t` | To |
| `$tt` | To tag |
| `$r` | Request URI |
| `$c` | Call-ID |

**Мережеві координати:**

| Токен | Значення |
|---|---|
| `$si` | IP джерела — звідки запит справді прийшов |
| `$sp` | Порт джерела |
| `$di` | IP призначення — віддалений UAS |
| `$dp` | Порт призначення |
| `$Ri` | Received: локальний IP, на який приїхав запит |
| `$Rp` | Received: локальний порт |
| `$Rf` | Received: ідентифікатор інтерфейсу |
| `$Rn` | Received: ім'я інтерфейсу |
| `$RI` | Received: **публічний** IP інтерфейсу |

**Кеш реєстрацій** ([6.5](23c-sbc-call-control.md)):

| Токен | Значення |
|---|---|
| `$u` | Кешований користувач призначення |
| `$Ua` | Вихідний AoR |
| `$UA` | Вихідний alias |

**Пошуки:**

| Токен | Значення |
|---|---|
| `$P(name)` | Параметр застосунку |
| `$V(name)` | Змінна, встановлена раніше в цьому дзвінку |
| `$H(name)` | Заголовок із запиту |
| `$M(name)` | Пошук у regex-мапі (`RegexMapper`) |

**Модифікатори URI** — дописуються до токена зі значенням-URI, щоб дістати одну частину:

| Модифікатор | Частина |
|---|---|
| `.u` | Увесь URI |
| `.U` | Користувач |
| `.d` | Домен |
| `.h` | Хост |
| `.p` | Порт |
| `.H` | Заголовки URI |
| `.P` | Параметри URI |
| `.n` | Display name |

Підтримуються екранування `\r`, `\n` і `\t`, що важливо для `append_headers`.

Отже, `$fU` — це користувацька частина викликача; `$rd` — домен request URI; `$H(P-Charge-Info)`
— значення заголовка. Рядок профілю на кшталт

```
RURI=sip:$rU@$M(carriers/$rd)
```

означає «лиши користувача, а хост призначення знайди в regex-мапі `carriers` за ключем домену
request URI».

> [!WARNING]
> `$si` і `$H(...)` — це **вхід, контрольований атакувальником**, на недовіреному інтерфейсі.
> `$si` принаймні є справжньою адресою джерела; заголовок — це те, що пір вирішив надіслати.
> Профіль, який маршрутизує за `$H(...)` без валідації, дозволяє викликачу самому обрати собі
> напрямок. Ставтесь до підстановок із заголовків так само, як до будь-якого параметра запиту
> ([10.1](37-security-surface.md)).

## Поля профілю, згруповано

У профілі значно більше ста полів. Групуються вони так.

### Переписування ідентичності

```cpp
  string ruri;       /* updated if set */
  string ruri_host;  /* updated if set */
  string from;       /* updated if set */
  string to;         /* updated if set */
```

Плюс вкладена структура для тоншого контролю і для приховування:

```cpp
    string displayname;
    string user;
    string host;
    string port;

    bool   hiding;
    string hiding_prefix;
    string hiding_vars;
```

`hiding` — це приховування топології на рівні ідентичності: заміна значення непрозорим токеном,
щоб дальній бік не прочитав вашу внутрішню адресацію, а `hiding_prefix` позначає закодовану
форму, щоб її можна було впізнати й розгорнути. Це найближчий у SEMS аналог `topoh` із Kamailio
([11.1](40-with-kamailio.md)) — але зауважте: B2BUA вже приховує *діалог*, а це приховує *URI*
всередині нього.

### Поведінка діалогу

```cpp
  string callid;
  string dlg_contact_params;
  bool transparent_dlg_id;
  bool dlg_nat_handling;
  bool keep_vias;
  bool bleg_keep_vias;
```

`transparent_dlg_id` копіює ідентифікатори діалогу в B-ногу замість генерувати нові — тобто
**вимикає** те приховування топології, яке B2BUA дає задарма. Воно існує для пірів, що корелюють
ноги за Call-ID, і обрати його означає свідомо проміняти приватність на сумісність.

`keep_vias` і `bleg_keep_vias` так само зберігають стек `Via` через B2BUA, що взагалі не є
нормальною поведінкою B2BUA.

### Маршрутизація

```cpp
  string outbound_proxy;
  bool force_outbound_proxy;
  string aleg_outbound_proxy;
  bool aleg_force_outbound_proxy;

  string next_hop;
  bool next_hop_1st_req;
  bool patch_ruri_next_hop;
  bool next_hop_fixed;
  string aleg_next_hop;
```

Та сама ручка `next_hop` із чотирьох частин, що й на рівні діалогу ([3.5](11-dialog-layer.md)),
тепер з окремими варіантами для A-ноги. Префікс `aleg_` проходить через увесь профіль: майже
кожну політику можна задати окремо на ногу, бо дві ноги дивляться в різні мережі.

Це ж і весь вибір напрямку. Один next hop або те, у що резолвиться R-URI. Ні списку, ні ваг, ні
стану здоров'я ([13.5](51-peer-dispatching.md)).

### Автентифікація

```cpp
  bool auth_enabled;
  bool auth_aleg_enabled;
  bool uas_auth_bleg_enabled;
```

Три, бо ситуацій три: автентифікуватись *як* UAC у бік B-ноги, автентифікуватись на A-нозі й
челенджити B-ногу *як* UAS. Усе це врешті йде через `uac_auth` як обробник подій сесії
([4.4](15-session-event-handlers.md)).

### Заголовки й відмова

```cpp
  string append_headers;
  string append_headers_req;
  string aleg_append_headers_req;
  string refuse_with;
```

`refuse_with` — ранній вихід: виставте його, і дзвінок відхиляється з цим кодом і причиною ще до
всього іншого. У поєднанні з підстановкою профіль може відмовляти за умовою взагалі без модуля
call control.

### Медіа

```cpp
  bool anonymize_sdp;
  bool have_aleg_sdpfilter;

  string rtprelay_enabled;
  string force_symmetric_rtp;
  string aleg_force_symmetric_rtp;
  bool msgflags_symmetric_rtp;
  bool rtprelay_transparent_seqno;
  bool rtprelay_transparent_ssrc;
  bool rtprelay_dtmf_filtering;
  bool rtprelay_dtmf_detection;
  string rtprelay_interface;
  string aleg_rtprelay_interface;
```

Це прямо лягає на прапорці з [6.1](21-b2b-session.md) і [5.2](17-rtp-stream.md). Пара
`rtprelay_interface` — важіль мультихомінгу: прийняти дзвінок на одному інтерфейсі, а віддати
на іншому. Саме так SBC розділяє недовірений абонентський бік і довірене ядро.

`msgflags_symmetric_rtp` вмикає симетричний RTP за прапорцями, виявленими в повідомленні, а не
статичною конфігурацією — це NAT-евристика, а не політика.

### Session timers і Replaces

```cpp
  string sst_enabled;
  string sst_aleg_enabled;
  string fix_replaces_inv;
  string fix_replaces_ref;
  bool allow_subless_notify;
```

`fix_replaces_inv` і `fix_replaces_ref` лагодять заголовки `Replaces` в INVITE і REFER.
`Replaces` називає діалог за його ідентифікаторами — а B2BUA їх переписав, — тож переведення
дзвінка через SBC ламається, якщо ідентифікатори не перекласти назад. Цей мапінг тримає
`ReplacesMapper.cpp`. Це одна з тих речей, які невидимі, доки не перестане працювати attended
transfer.

`allow_subless_notify` дозволяє `NOTIFY` без підписки, що потрібно багатьом реалізаціям
індикації повідомлень і що не подобається RFC 6665.

### Виявлення перезавантаження

```cpp
  string md5hash;
  string profile_file;
```

Профіль знає файл, з якого прийшов, і хеш його вмісту, тож перезавантаження може сказати, що
саме змінилось, замість перебудовувати все.

## Фільтри

```cpp
enum FilterType { Transparent=0, Whitelist, Blacklist, Undefined };

FilterType String2FilterType(const char* ft);
bool isActiveFilter(FilterType ft);
const char* FilterType2String(FilterType ft);
```

Той самий тип із чотирьох значень керує і фільтрацією заголовків, і фільтрацією SDP.

`Transparent` пропускає все. `Whitelist` пропускає лише перелічене — безпечно за замовчуванням,
нудно в супроводі й правильно на недовіреному краю. `Blacklist` прибирає перелічене — зручно і
завжди за один невідомий заголовок від витоку. `Undefined` — ненастроєний стан, який
`isActiveFilter()` існує, щоб відрізняти від настроєного `Transparent`.

У фільтрації SDP чотири точки входу:

```cpp
int filterSDP(AmSdp& sdp, const vector<FilterEntry>& filter_list);
int filterSDPalines(AmSdp& sdp, const vector<FilterEntry>& filter_list);
int filterMedia(AmSdp& sdp, const vector<FilterEntry>& filter_list);

int normalizeSDP(AmSdp& sdp, bool anonymize_sdp, const string &advertised_ip);
```

Три рівні гранулярності — цілі медіа-описи, окремі рядки `a=` і фільтрація payload'ів — плюс
`normalizeSDP()`, який переписує анонсовану адресу і за потреби зрізає ідентифікуючі поля рівня
сесії (рядки `o=` несуть імена користувачів і адреси частіше, ніж прийнято думати).

**Фільтрація payload'ів — це той важіль, що дозволяє уникнути транскодингу.** Звужувати те, що
бачить кожен бік, доки вони не перетнуться на дешевому кодеку, — це різниця між релеєм і
чотирикроковим транскодингом на кожен пакет ([6.2](22-b2b-media.md),
[5.4](19-codecs-and-plugins.md)).

## Допоміжні класи

| Файл | Рядків | Роль |
|---|---|---|
| `ParamReplacer.cpp` | 869 | Мова підстановок вище |
| `SBCCallProfile.cpp` | 1831 | Парсинг, обчислення, резолюція на дзвінок |
| `HeaderFilter.cpp` | — | Whitelist/blacklist над заголовками |
| `SDPFilter.cpp` | 245 | Чотири функції SDP |
| `RegexMapper.cpp` | — | Іменовані regex-мапи за `$M(...)` |
| `ReplacesMapper.cpp` | — | Переклад ідентифікаторів діалогу для переведень |
| `RTPParameters.cpp` | — | Налаштування RTP на профіль |
| `RateLimit.cpp` | — | Обмеження за принципом token bucket |
| `SessionUpdate.cpp` | — | Керування re-INVITE / UPDATE з політики |
| `arg_conversion.cpp` | — | `AmArg` ↔ профіль, для межі з call control |

### `RegexMapper`

Іменовані мапи regex → значення, адресовані як `$M(mapname/input)`. Саме тут живуть маршрутні
таблиці, коли профілю потрібна така, і це настільки близько до пошуку, наскільки SBC взагалі
доходить: статично, з конфігурації, без рантайм-стану ([13.5](51-peer-dispatching.md)).

## Чому кероване даними

Альтернативою був застосунок на кожну політику. Натомість є один застосунок і профіль на
політику — текстові файли, які перезавантажуються, дифляться й розкочуються без перезбірки.

Ціна реальна, і її варто проговорити. Поведінка живе в конфігурації, тож багом може бути
загублений `$`, а не помилка компіляції; перевірки типів немає до приходу дзвінка; а зрозуміти
живу систему означає читати її профілі, а не її код. Натомість змінити політику не означає
випустити бінарник — а для SBC, де політика змінюється щотижня, це правильний обмін.
