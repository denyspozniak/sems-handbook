# 9.6 ZRTP і SRTP

> [!IMPORTANT]
> SEMS уміє **релеїти** зашифроване медіа, але не вміє його **термінувати**. У дереві немає
> реалізації SRTP, немає рукостискання DTLS, немає `libsrtp`. Єдиний виняток — ZRTP, який
> опційний, типово вимкнений і залежить від зовнішнього SDK. Кожен, хто очікує медіа-сервер, що
> нативно говорить SRTP, має прочитати цей розділ до того, як проєктувати навколо цього.

## Що там насправді є

Дві дуже різні речі, які легко сплутати:

| | ZRTP | SRTP / DTLS-SRTP |
|---|---|---|
| Реалізовано | Так, через зовнішній SDK | **Ні** |
| Прапорець збірки | `SEMS_USE_ZRTP`, типово `OFF` | — |
| SEMS може шифрувати/дешифрувати | Так, якщо зібрано з ним | Ні |
| SEMS може релеїти | — | **Так**, як непрозорі пакети |
| Обмін ключами | У медіа-шляху | У SDP або через DTLS |

## Релей SRTP

SEMS розпізнає захищені транспорти в SDP:

```cpp
  case TP_RTPSAVP: return "RTP/SAVP";
  case TP_RTPSAVPF: return "RTP/SAVPF";
  case TP_UDPTLSRTPSAVP: return "UDP/TLS/RTP/SAVP";
  case TP_UDPTLSRTPSAVPF: return "UDP/TLS/RTP/SAVPF";
```

а `AmRtpStream` трактує їх як повноцінні RTP-профілі при зіставленні payload'ів:

```cpp
  // RFC 3551 §6 reserves PT < 20 for RTP-profile static payloads.
  // They are valid not just for RTP/AVP but for every RTP-based profile
  // we accept (AVPF, SAVP, SAVPF, UDP/TLS/RTP/SAVP[F]). Limiting the
  // check to TP_RTPAVP made SRTP/AVPF sessions fall through to
  // getDynPayload(), which fails for static PT sent without a=rtpmap.
  bool rtp_based_transport =
    (local_media.transport == TP_RTPAVP   ||
     local_media.transport == TP_RTPAVPF  ||
     local_media.transport == TP_RTPSAVP  ||
     local_media.transport == TP_RTPSAVPF ||
     local_media.transport == TP_UDPTLSRTPSAVP ||
     local_media.transport == TP_UDPTLSRTPSAVPF);
```

Цей коментар описує реальний баг і його виправлення, і він точно каже, наскільки далеко сягає
підтримка: SEMS парсить транспорт, коректно узгоджує payload'и й пересилає пакети. Він їх не
дешифрує.

А отже:

**Релей працює.** Два ендпоінти, що роблять SRTP між собою, з SEMS у ролі релею
([9.4](34-rtp-mux-and-relay.md)), працюють нормально. Пакети непрозорі; SEMS їх переносить.

**Усе інше — ні.** Ні транскодингу — не можна декодувати те, чого не можеш дешифрувати. Ні
конференцій, ні запису аудіо ([9.5](35-siprec-and-recording.md)), ні анонсів у дзвінок, ні
inband-розпізнавання DTMF ([5.5](20-dtmf-and-jitter.md)). Навіть прапорці фільтрації DTMF не
мають сенсу: у зашифрованого пакета не видно типу payload.

**Зшивання неможливе.** SRTP на одній нозі й звичайний RTP на іншій вимагає термінувати
шифрування. SEMS не може, тож SBC перед WebRTC-клієнтом — де DTLS-SRTP обов'язковий — потребує
чогось іншого в медіа-шляху.

> [!WARNING]
> Профіль, що вмикає транскодинг, запис чи анонси на нозі, яка узгоджує `RTP/SAVP`, є
> конфігурацією, що не може працювати. Відмова не гучна: узгодження вдається, релей працює, а
> функція тихо не робить нічого корисного. Перевіряйте транспорт, перш ніж припускати, що
> медіа-функції доступні.

## ZRTP

ZRTP підходить до обміну ключами протилежно, і `doc/ZRTP.txt` пояснює, чому це тут важить:

> ZRTP is a key agreement protocol to negotiate the keys for encryption of RTP in phone calls.
> […] Even though it uses public key encryption, a PKI is not needed. Since the keys are
> negotiated in the media path, support for it in signaling is not necessary. ZRTP also offers
> opportunistic encryption, which means that calls between UAs that support it are encrypted, but
> calls to UAs not supporting it are still possible, but unencrypted.

Ключі узгоджуються **в медіа-шляху**, тож сигналізації — і всьому, що є в її шляху — знати про це
не треба. Опортуністичне шифрування означає, що пара з підтримкою шифрує, а змішана пара все одно
з'єднується.

### Як це зібрати

```cmake
option(SEMS_USE_ZRTP "Build with ZRTP" OFF)
```

```
mkdir -p build && cd build
cmake .. -DSEMS_USE_ZRTP=yes
make
```

**Типово вимкнено**, і потрібен Zfone SDK. `doc/ZRTP.txt` називає робочий форк:

> Currrently, the newest version of the ZRTP SDK, and the one that works with SEMS, is available
> at https://github.com/juha-h/libzrtp

Зовнішня форкнута залежність для опційної функції добре показує, наскільки цим шляхом ходять.
Перевірте, чи ваш дистрибутивний пакет зібрано з нею, перш ніж на це розраховувати.

### Інтеграція

```cpp
class AmZRTP
{
  static int zrtp_cache_save_cntr;
  static std::string cache_path;
  static std::string entropy_path;
  static AmMutex zrtp_cache_mut;

  static int init();
  static int shut_down();
  static zrtp_global_t* zrtp_global;
  static zrtp_config_t zrtp_config;
  static zrtp_zid_t zrtp_instance_zid;

  static int on_send_packet(const zrtp_stream_t *stream, char *packet, unsigned int length);
  static void on_zrtp_secure(zrtp_stream_t *stream);
  static void on_zrtp_security_event(zrtp_stream_t *stream, zrtp_security_event_t event);
  static void on_zrtp_protocol_event(zrtp_stream_t *stream, zrtp_protocol_event_t event);

  void freeSession();
  zrtp_session_t* zrtp_session;
};
```

Чотири колбеки з SDK, два з яких стають подіями SEMS:

```cpp
class AmZRTPSecurityEvent { zrtp_stream_t* stream_ctx; ... };
class AmZRTPProtocolEvent { zrtp_stream_t* stream_ctx; ... };
```

які DSM відкриває скриптам ([7.2](25-dsm.md)):

```cpp
#ifdef WITH_ZRTP
    , ZRTPProtocolEvent,
    ZRTPSecurityEvent
#endif
```

Тож потік дзвінка може реагувати на встановлення шифрування або на попередження безпеки —
доступно через `mod_zrtp` взагалі без C++.

`AmZRTP::init()` виконується в `main()` раніше за все інше ([2.4](05-lifecycle.md)), бо глобальний
контекст ZRTP мусить існувати до того, як ним скористається бодай один потік.

**`cache_path` і `entropy_path`** — два файли, потрібні ZRTP: кеш збережених секретів (те, що
робить робочим «перевірив один раз — довіряю далі») і джерело ентропії. `zrtp_cache_mut` захищає
кеш, бо його чіпає кожна сесія.

> [!IMPORTANT]
> Кеш ZRTP — це постійний файл, значущий для безпеки. Він переживає рестарти за задумом — у цьому
> й сенс збережених секретів — тож він є частиною того, що ви бекапите, захищаєте й враховуєте
> при переїзді сервера. Права на нього важать не менше, ніж на будь-який файл із обліковими
> даними ([10.3](39-security-hardening.md)).

### SAS і чому конференція промовляє його вголос

Захистом ZRTP від людини посередині є **Short Authentication String**: обидва кінці виводять ту
саму коротку фразу, а люди зачитують її одне одному. Якщо збіглось — посередині нікого немає.

Це працює, лише якщо ендпоінти можуть її показати — а в медіа-сервера немає екрана. Звідси:

> The conference application can tell the caller the SAS phrase if SEMS is compiled with
> text-to-speech support.

```
cmake .. -DSEMS_USE_ZRTP=yes -DSEMS_USE_TTS=yes
```

flite промовляє SAS у дзвінок ([7.3](26-ivr-and-python.md)). Це елегантне розв'язання реальної
проблеми — і водночас нагадування, наскільки ця функція далека від масового вжитку.

## Що з цього виходить

**Безпека медіа існує, у вузькій формі.** ZRTP реальний, але опційний, типово вимкнений, потребує
форкнутого SDK і працює end-to-end, а не до SEMS.

**SRTP — це історія лише про релей.** SEMS переносить зашифроване медіа, не розуміючи його, і це
покриває випадок SBC та більше нічого.

**Ніщо з цього не допомагає з WebRTC.** Там DTLS-SRTP обов'язковий, а тут не реалізований.

Якщо медіа мусить бути зашифроване *до* SEMS і оброблене, чесна відповідь сьогодні — ще один
компонент у медіа-шляху. Того самого висновку доходять безпекові розділи з іншого боку
([10.2](38-security-media.md)).
