# 14.1 Мапа термінів

> [!TIP]
> Якщо ви прийшли з Kamailio — читайте спершу другу таблицю. Більшість плутанини навколо SEMS є
> словниковою, а не архітектурною: та сама ідея в іншому одязі.

## Терміни SEMS

| Термін | Значення | Живе в |
|---|---|---|
| **`AmSession`** | Дзвінок. Водночас потік, черга подій, діалог і медіа-сесія | `core/AmSession.*` ([4.1](12-amsession.md)) |
| **Local tag** | Ідентичність сесії і адреса її поштової скриньки. Ключ, за яким індексує диспатчер подій | `AmBasicSipDialog` ([3.5](11-dialog-layer.md)) |
| **Черга подій** | Поштова скринька сесії: черга, м'ютекс, condition variable, із підрахунком посилань | `core/AmEventQueue.*` ([2.2](03-event-system.md)) |
| **Usage** | Посилання на діалог, утримане чимось, що не є сесією — підпискою, реєстрацією. Сесія з живим usage не вийде | `AmBasicSipDialog` ([4.1](12-amsession.md)) |
| **Callgroup** | Набір сесій, прибитих до одного потоку медіа-процесора. Конференції і пари ніг B2B є однією групою | `core/AmMediaProcessor.*` ([5.1](16-media-processor.md)) |
| **Медіа-сесія** | Усе, що можна причепити до медіа-процесора: `AmSession` або `AmB2BMedia` на дві ноги | `AmMediaSession` ([5.1](16-media-processor.md)) |
| **Тик** | Фіксований цикл медіа-процесора у 10 мс. Не інтервал пакетизації RTP, який 20 мс | `WC_INC_MS` ([5.1](16-media-processor.md)) |
| **Релей** | Пересилання RTP без декодування, з потоку приймача. Дешевий шлях | `AmRtpStream::relay_enabled` ([9.4](34-rtp-mux-and-relay.md)) |
| **Транскодинг** | Декодування й перекодування, щоб зшити два кодеки. Приблизно вчетверо дорожче | ([5.4](19-codecs-and-plugins.md)) |
| **Нога (leg)** | Один діалог із пари B2BUA. A-нога дивиться на викликача, B-нога на викликаного. **Ролі можуть мінятись** | `AmB2BSession::a_leg` ([6.1](21-b2b-session.md)) |
| **DI** | Dynamic invocation. Єдина внутрішня конвенція викликів: ім'я методу, `AmArg` усередину, `AmArg` назовні | `AmDynInvoke` ([8.1](28-rpc-architecture.md)) |
| **`AmArg`** | Динамічно типізоване значення, що перетинає кожну межу між модулями | `core/AmArg.*` ([7.1](24-plugin-architecture.md)) |
| **Профіль дзвінка** | Шаблон політики SBC, що обчислюється на кожен дзвінок через `ParamReplacer` | `SBCCallProfile` ([6.4](23b-sbc-profiles.md)) |
| **Модуль call control** | Розширення SBC, що вирішує політику поза самим запитом | ([6.5](23c-sbc-call-control.md)) |
| **DSM** | Мова машин станів для потоків дзвінка, перевіряється на завантаженні | `apps/dsm/` ([7.2](25-dsm.md)) |
| **`amci`** | C-ABI для кодеків і форматів файлів. Старший і окремий від системи плагінів на C++ | `core/amci/` ([5.4](19-codecs-and-plugins.md)) |
| **`cstring`** | Вказівник і довжина в чужий буфер. Ніколи його не переживає | `core/sip/cstring.h` ([3.3](09-parser.md)) |
| **Обробник подій сесії** | Перехоплювач, що бачить SIP сесії раніше за застосунок | ([4.4](15-session-event-handlers.md)) |
| **Селектор застосунку** | Стратегія, що обирає, який застосунок виконається для INVITE | `AmConfig::AppSelect` ([4.2](13-session-container-and-factories.md)) |

## Kamailio ↔ SEMS

Таблиця перекладу. Там, де еквівалента немає, ця відсутність зазвичай і є найцікавішим.

| Kamailio | SEMS | Зауваження |
|---|---|---|
| Воркер-процес | **Потік сесії** | Один потік на дзвінок, а не пул ([2.1](02-thread-model.md)) |
| `children` / `tcp_children` | — | Пулу воркерів немає. `media_processor_threads` найближчий, і означає інше ([2.5](06-sizing-and-tuning.md)) |
| `shm` (спільна пам'ять) | — | **Еквівалента немає.** Один процес, одна звичайна купа ([2.3](04-memory-and-ownership.md)) |
| `pkg` (приватна пам'ять) | Купа C++ | Просто `new` |
| `shm_malloc` / `pkg_malloc` | `new` | Без власного алокатора, без пулу, який треба розмірювати чи вичерпувати |
| RPC дампу пам'яті | — | Вживайте `valgrind`, ASan, `massif` |
| Блок `route` | **Колбек сесії** | `onInvite()`, `onSipRequest()` ([4.1](12-amsession.md)) |
| `kamailio.cfg` | `sems.conf` + плагін | Поведінка є кодом або DSM-скриптом, а не конфігураційним DSL |
| Модуль | **Плагін** | `.so`, `dlopen` на старті ([7.1](24-plugin-architecture.md)) |
| `modparam` | Конфіг-файл на плагін у `plugin_config_path` | Читається під час `onLoad()` |
| Псевдозмінні `$ru`, `$fu` | `$r`, `$f` у `ParamReplacer` | Лише всередині профілів SBC ([6.4](23b-sbc-profiles.md)) |
| Транзакція `tm` | `sip_trans` у `trans_table` | 1024 бакети, ключ Call-ID + CSeq ([3.4](10-transaction-layer.md)) |
| Таймери `tm` | `sip_timers.h`, колесо таймерів | 4 колеса × 256 слотів по 20 мс |
| Модуль `dialog` | `AmSipDialog` | Не опційно — медіа-сервер завжди тримає стан діалогу ([3.5](11-dialog-layer.md)) |
| `usrloc` / `registrar` | — | **Еквівалента немає.** SEMS є *клієнтом* реєстрації ([9.1](31-registrar-client.md)) |
| `dispatcher` | — | **Еквівалента немає.** DNS SRV плюс таймер M, і паралельний форкінг у SBC ([13.5](51-peer-dispatching.md)) |
| `topoh` / `topos` | Термінування як B2BUA | Задарма, якщо ви й так термінуєте; дорого, якщо це все, що було потрібно ([11.1](40-with-kamailio.md)) |
| Керування `rtpengine` | Сама медіа-площина | SEMS *і є* медіа-релеєм ([частина 5](16-media-processor.md)) |
| `siptrace` із HEP | `pcap_logger` | Лише локальні файли; **HEP немає** ([13.2](48-hep-and-capture.md)) |
| `htable` | — | Спільної таблиці немає. Стан у модулі або зовнішнє сховище |
| `dmq` | — | **Еквівалента немає.** Інстанси не ділять нічого ([11.2](41-topologies-and-ha.md)) |
| `jsonrpcs` / `kamcmd` | `jsonrpc`, `xmlrpc2di` | Обидва без автентифікації ([8.1](28-rpc-architecture.md)) |
| `event_route` | Колбеки сесії, типи подій DSM | ([7.2](25-dsm.md)) |
| KEMI (Lua, Python, JS) | DSM, `ivr`, `py_sems` | Інші компроміси ([7.4](27-app-tradeoffs.md)) |
| `pike`, `permissions` | — | Обмеження швидкості й блоклисти належать проксі ([10.1](37-security-surface.md)) |
| Stateless-відповідь `sl` | `compute_sl_to_tag()` | Stateless-відповіді існують; statelessness як режим — ні |

## Числа, які варто пам'ятати

| Значення | Типово | Де |
|---|---|---|
| Медіа-тик | **10 мс** | `WC_INC_MS` ([5.1](16-media-processor.md)) |
| Wallclock rate | 102 400 Гц, 48 біт | Ділиться на кожну частоту дискретизації ([5.1](16-media-processor.md)) |
| Внутрішня частота | 32 000 Гц | `SYSTEM_SAMPLECLOCK_RATE` ([5.3](18-audio-pipeline.md)) |
| Потоків медіа-процесора | **1** | `NUM_MEDIA_PROCESSORS` ([2.5](06-sizing-and-tuning.md)) |
| Потоків RTP-приймача | 1 | `NUM_RTP_RECEIVERS`; libevent, тож зазвичай досить ([5.2](17-rtp-stream.md)) |
| Потоків процесора сесій | 10 | **Неактивно** — `SESSION_THREADPOOL` не скомпільований ([2.1](02-thread-model.md)) |
| Колесо таймерів | 4 колеса × 256 слотів × 20 мс | ([3.4](10-transaction-layer.md)) |
| Таблиця транзакцій | 1024 бакети | ([3.4](10-transaction-layer.md)) |
| Диспатчер подій | 1024 бакети | ([2.2](03-event-system.md)) |
| T1 | 500 мс | ([3.4](10-transaction-layer.md)) |
| Таймер B | 64·T1 = **32 с** | Тримає сесію й потік |
| Таймер M | B/4 = 8 с | Failover DNS; **щонайбільше чотири адреси** |
| `dead_rtp_time` | **300 с** | Зменшіть ([5.2](17-rtp-stream.md)) |
| `max_shutdown_time` | 10 с | ([2.4](05-lifecycle.md)) |
| Пауза прибиральника сесій | `sleep(5)` | Чому пам'ять відстає від активних дзвінків ([2.3](04-memory-and-ownership.md)) |
| TCP connect timeout | 2 с | Агресивно для далеких шляхів ([3.2](08-transport.md)) |
| TCP idle timeout | 1 година | Щедро; накопичує fd |
| RTP-порти (зразок) | 10000–60000 | 25 000 пар — звузьте ([10.2](38-security-media.md)) |
| XML-RPC / JSON-RPC | 8090 / 7080 | **Без автентифікації** ([10.1](37-security-surface.md)) |
| Сайдкар Prometheus | 0.0.0.0:9090 | ([8.2](29-monitoring-and-stats.md)) |

## Рецепти грепу

| Щоб знайти | Команда |
|---|---|
| Усе життя одного дзвінка | `grep '\^\^ S \[<local-tag>' sems.log` |
| Сесії, що не хочуть умирати | `grep '\^\^ S \[' sems.log \| grep -v '0 usages'` |
| Що було в польоті при зупинці | `grep -A50 'Transaction table dump' sems.log` |
| Чи воно справді стартувало | `grep 'started' sems.log` ([2.4](05-lifecycle.md)) |
| Кількість потоків | `ps -L -p "$(pgrep -x sems)" \| wc -l` |
| RTP-сокети | `ss -unlp \| grep sems \| wc -l` |
