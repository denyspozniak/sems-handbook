# 5.4 Кодеки і плагіни

> [!NOTE]
> `amci` — **A**udio **M**odule **C**odec **I**nterface — це звичайний C-ABI у `core/amci/`. Він
> старший за систему плагінів на C++ ([7.1](24-plugin-architecture.md)) і навмисно окремий: кодек
> є набором вказівників на функції, а не класом.

## Інтерфейс

Модуль кодека заповнює `struct amci_codec_t` вказівниками на функції:

```c
typedef long (*amci_codec_init_t)(const char* format_parameters,
                                  const char** format_parameters_out, ...);
typedef void (*amci_codec_destroy_t)(long h_codec);

typedef unsigned int (*amci_codec_bytes2samples_t)(long h_codec, unsigned int num_bytes);
typedef unsigned int (*amci_codec_samples2bytes_t)(long h_codec, unsigned int num_samples);

typedef int (*amci_codec_negotiate_fmt_t)(int is_offer, const char* params_in,
                                          char* params_out, unsigned int params_out_len);

typedef int (*amci_converter_t)( unsigned char* out, ... );
typedef int (*amci_plc_t)( unsigned char* out, ... );
```

П'ять можливостей, і кожна заслуговує свого місця:

**`init` / `destroy`** повертають і беруть `long`-хендл, а не вказівник. Кодек тримає власний
стан на потік за непрозорим хендлом — безпечний для C-ABI спосіб бути stateful, якого потребують
кодеки на кшталт Opus та iLBC.

**`bytes2samples` / `samples2bytes`** існують тому, що співвідношення не є сталим. Для G.711 воно
1:1; для фреймового кодека залежить від розміру фрейму й від погоджених параметрів. Ядро це
обчислити не може, тож питає.

**`negotiate_fmt`** дозволяє кодеку брати участь в offer/answer ([4.3](14-offer-answer.md)). У
Opus є `maxplaybackrate`, `stereo`, `useinbandfec`; в AMR — набори режимів. Прапорець `is_offer`
каже кодеку, пропонує він чи відповідає: answer на offer — це не те саме, що offer.

**`amci_plc_t`** — приховування втрат пакетів: маючи стан кодека, синтезувати правдоподібний
фрейм замість того, що не приїхав. Специфічний для кодека, бо правильна здогадка залежить від
кодека ([5.5](20-dtmf-and-jitter.md)).

## Кодеки в комплекті

```
adpcm  codec2  echo   g722  g729  gsm  ilbc  isac
l16    opus    silk   speex wav
```

Плюс модулі, які кодеками не є, але живуть у тій самій теці, бо завантажуються так само:
`session_timer`, `uac_auth`, `stats`.

| Модуль | Зауваження |
|---|---|
| `l16` | Лінійний 16-бітний — без стиснення, внутрішній формат |
| `g722` | Широкосмуговий, 16 кГц. Причина, з якої існує ресемплінг |
| `gsm`, `ilbc`, `speex`, `silk`, `opus`, `codec2`, `isac` | Стиснуті, за зростанням вартості CPU |
| `g729` | Обгортка. Референсна реалізація ліцензована, тож у комплекті інтеграція, а не сам кодек |
| `adpcm` | Сімейство G.726 |
| `wav` | Модуль *формату файлу*, а не кодека — той самий інтерфейс, але `amci_file_open_t` |
| `echo` | Взагалі не кодек: тестовий модуль-петля |

G.711 (`PCMU`/`PCMA`) у списку немає, бо він вбудований у ядро — це єдиний кодек, доступний
завжди.

> [!TIP]
> `exclude_payloads` у `sems.conf` — це чорний список, застосований на етапі завантаження:
> ```
> # only use G711 (exclude everything else):
> # exclude_payloads=iLBC;speex;...
> ```
> Він звужує те, що SEMS пропонує в SDP, і виставити його варто свідомо. Кожен анонсований кодек
> — це кодек, який пір може обрати, а різниця між G.711 та iLBC становить приблизно вчетверо в
> ємності ([2.5](06-sizing-and-tuning.md)).

## Файловий інтерфейс

Той самий заголовок покриває й файли:

```c
struct amci_file_desc_t { ... };

typedef int (*amci_file_open_t)( FILE* fptr, struct amci_file_desc_t* fmt_desc, ... );
typedef int (*amci_file_close_t)( FILE* fptr, struct amci_file_desc_t* fmt_desc, ... );
typedef int (*amci_file_mem_open_t)(unsigned char* mptr, ... );
typedef int (*amci_file_mem_close_t)( unsigned char* mptr, ... );
```

Зверніть увагу на варіанти з `mem`. Файл можна відкрити з пам'яті, а не з `FILE*`, і саме це
робить можливим `AmCachedAudioFile` ([5.3](18-audio-pipeline.md)): промпт читається один раз, а
кожне наступне відтворення відкриває його з кешованого буфера без жодного системного виклику.

`#define AMCI_RDONLY 1` і `#define AMCI_WRONLY 2` — це режими; дескриптор формату несе довжину
фрейму, розмір фрейму й розмір закодованого фрейму:

```c
#define AMCI_FMT_FRAME_LENGTH       1
#define AMCI_FMT_FRAME_SIZE         2
#define AMCI_FMT_ENCODED_FRAME_SIZE 3
```

## Життєвий цикл модуля

```c
typedef int (*amci_codec_module_load_t)(const char* ModConfigPath);
typedef void (*amci_codec_module_destroy_t)(void);
```

Модуль кодека може мати власний конфігураційний файл, що завантажується на старті
([2.4](05-lifecycle.md)). `AmPlugIn` сканує теку плагінів, робить `dlopen` кожного `.so` і
реєструє всі типи payload, які той оголошує. Далі payload доступний для offer/answer.

## Скільки коштує транскодинг

Транскодувати означає: декодувати кодек A-ноги в лінійний, ресемплити на 32 кГц за потреби,
ресемплити на частоту B-ноги, закодувати. Чотири кроки на напрямок, на пакет, на дзвінок,
п'ятдесят разів за секунду.

Власні цифри проєкту з `README.md` дають масштаб — близько 1200 конференц-каналів G.711 на
машині, що тягне 700 на GSM і 280 на iLBC. Те саме залізо, той самий код, різниця вчетверо лише
від вибору кодека.

Два наслідки:

**Уникайте транскодингу, коли можете.** Якщо обидві ноги пропонують спільний кодек — релейте
([5.2](17-rtp-stream.md)). Фільтрація кодеків у SBC значною мірою є інструментом саме для
досягнення цього результату ([6.4](23b-sbc-profiles.md)).

**Рахуйте під найгірший кодек, а не під середній.** Ємність задають дзвінки, що транскодуються, а
саме їх ви й не контролюєте.

## Як додати свій

1. Реалізуйте вказівники на функції `amci_codec_t`.
2. Оголосіть тип payload, ім'я, частоту дискретизації й будь-які параметри формату.
3. Додайте в `core/plug-in/` і в збірку.
4. Якщо кодек stateful — тримайте стан за `long`-хендлом із `init()`.
5. Якщо він уміє приховувати втрати — реалізуйте `amci_plc_t`: без цього втрачений пакет є
   тишею ([5.5](20-dtmf-and-jitter.md)).

Усе решта — узгодження SDP, нумерація payload, аудіо-ланцюжок — дістається задарма, бо ядро
говорить лише з інтерфейсом.
