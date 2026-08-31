# 14.2 Що нового у 2.x

> [!NOTE]
> Цей розділ про форму поточного дерева, а не про історію релізів. `doc/CHANGELOG` несе старіші
> записи й обривається задовго до поточної версії; далі — те, як дерево 2.x справді виглядає для
> збірки й експлуатації.

## Версія

```
$ cat VERSION
2.1.0
```

Останні детальні записи в `doc/CHANGELOG` — з часів 1.5/1.6. Його список для 1.5.0 усе одно варто
прочитати, бо значна частина — це механіка, на яку ця книга витратила цілі розділи:

> - configurable SIP timers (global)
> - timer C support (mainly for SBC)
> - SUBSCRIBE/NOTIFY support
> - multi-mime bodies
> - wideband / multiple sample frequency support
> - multiple destinations (faked SRV record)
> - DNS SRV: support for 503 replies
> - multi-threaded RTP receiver
> - complete rework of offer/answer mechanisms

Останній рядок пояснює, чому `AmOfferAnswer` є чистою машиною станів
([4.3](14-offer-answer.md)), а не нашарованою логікою: його переписали. «Multiple destinations
(faked SRV record)» — предок того failover, про який ідеться в [13.5](51-peer-dispatching.md), а
«wideband / multiple sample frequency support» — причина, чому мікшер тримає `MixerBufferState` на
кожну частоту ([5.3](18-audio-pipeline.md)).

## Збірка — це CMake

`CMakeLists.txt` і є збіркою, а його опції — чесним переліком функцій:

```cmake
option(SEMS_USE_OPUS "Build with Opus" OFF)
option(SEMS_USE_SPANDSP "Build with spandsp" OFF)
option(SEMS_USE_LIBSAMPLERATE "Build with libsamplerate" OFF)
option(SEMS_USE_ZRTP "Build with ZRTP" OFF)
option(SEMS_USE_MP3 "Build with MP3" OFF)
option(SEMS_USE_ILBC "Build with iLBC library (fallback to bundled)" ON)
option(SEMS_USE_G729 "Build with bcg729 library" OFF)
option(SEMS_USE_CODEC2 "Build with codec2 library" OFF)
option(SEMS_USE_TTS "Build with Text-to-speech support (requires Flite)" OFF)
option(SEMS_USE_OPENSSL "Build with OpenSSL" OFF)
option(SEMS_USE_MONITORING "Build with monitoring support" ON)
option(SEMS_USE_IPV6 "Build with IPv6 support" ON)
option(SEMS_USE_PYTHON "Build with Python modules" ON)
option(SEMS_USE_ASAN "Build with AddressSanitizer (memory error detector)" OFF)
option(SEMS_USE_UBSAN "Build with UndefinedBehaviorSanitizer" OFF)
option(SEMS_USE_TSAN "Build with ThreadSanitizer (data race detector)" OFF)
option(SEMS_HARDEN "Enable compile/link hardening (stack protector, FORTIFY, RELRO, PIE)" OFF)
```

Прочитаний як список дефолтів, він каже багато:

**Увімкнено типово:** iLBC (з вбудованим запасним варіантом), моніторинг, IPv6, Python.

**Вимкнено типово:** Opus, spandsp, libsamplerate, ZRTP, MP3, G.729, codec2, TTS, OpenSSL.

Тобто у стоковій збірці **немає Opus, немає високоякісного ресемплера, немає TTS, немає ZRTP і
немає OpenSSL**. Дистрибутивні пакети зазвичай вмикають більше; перевірте, з чим зібрано ваш,
перш ніж припускати, що функція є ([9.6](36-zrtp-and-srtp.md), [5.3](18-audio-pipeline.md)).

### Три опції санітайзерів

`SEMS_USE_ASAN`, `SEMS_USE_UBSAN` і `SEMS_USE_TSAN` — помітне доповнення для кодової бази такого
віку, а `TSAN` зокрема є правильним інструментом саме для цієї архітектури: один процес із
багатьма потоками й без алокатора спільної пам'яті ([2.1](02-thread-model.md)) — це рівно те, для
чого ThreadSanitizer існує. Будь-який патч, що чіпає систему подій
([2.2](03-event-system.md)), медіа-процесор ([5.1](16-media-processor.md)) чи `AmB2BMedia`
([6.2](22-b2b-media.md)), варто прогнати під ним.

`SEMS_HARDEN` збирає stack protector, `FORTIFY_SOURCE`, RELRO і PIE. **Типово вимкнено**, і про це
варто знати, зважаючи на відкритість парсера ([10.3](39-security-hardening.md)) — дистрибутивний
пакет може вмикати це, а може й ні.

## Покриття платформ

```
Dockerfile-debian11   Dockerfile-ubuntu22.04   Dockerfile-rhel7   Dockerfile-rhel9
Dockerfile-debian12   Dockerfile-ubuntu24.04   Dockerfile-rhel8   Dockerfile-rhel10
Dockerfile-debian13                                               Dockerfile-rhel10-dis-test
```

Три релізи Debian, два LTS Ubuntu, чотири покоління RHEL — RHEL 7 і RHEL 10 в одному дереві
незвично широко, і це обмежує те, що код може припускати про компілятори й версії бібліотек.

Кожен образ збирає й проганяє юніт-тести як частину збірки ([11.3](42-lab.md)):

```dockerfile
RUN mkdir -p build && cd build && cmake .. && make sems_tests && ./core/sems_tests
```

тож зелений образ означає зелений прогін тестів на цій платформі.

`Dockerfile-rhel10-dis-test` — варіант для модуля DIS, Distributed Interactive Simulation
(`apps/dis_test`), який генерує тон 400 Гц і шле пакети EntityStatePDU. Не диспатчер
([13.1](47-gaps-overview.md)).

## Пакування

```
pkg/deb/{jessie,wheezy,buster,bullseye,bookworm,trixie,precise,trusty,debian}
pkg/rpm/{sems.spec,sems.init,sems.sysconfig}
pkg/gentoo/
```

Пакування Debian сягає назад до wheezy і вперед до trixie. Бік RPM постачає **init-скрипт**, а не
systemd-юніт — добрий маркер віку проєкту й того, що RHEL 7 усе ще в матриці.

Образ Debian збирає справжній пакет із перевіркою, яку варто процитувати ([11.3](42-lab.md)):

```dockerfile
ARG PKG_VERSION=
RUN set -eu; \
    v="${PKG_VERSION:-$(cat VERSION)}"; \
    changelog="$(dpkg-parsechangelog -S Version)"; \
    if ! dpkg --compare-versions "$v" ge "$changelog"; then \
        echo "refusing to build $v: older than debian/changelog $changelog" >&2; \
        exit 1; \
    fi; \
```

Спроба зібрати версію, старішу за changelog, **валить збірку**, а не породжує пакет, який apt тихо
відмовиться ставити як оновлення. Це маленька інженерна дисципліна, що economить заплутаний день.

`PKG_VERSION` дозволяє CI штампувати унікальну версію, щоб apt-репозиторій побачив оновлення, а
`VERSION` є запасним варіантом.

## Інструменти на Rust

`apps/monitoring/tools/` — це Rust, і саме тому `cargo` і `rustc` є у списку залежностей Debian
([11.3](42-lab.md)):

```
sems-prometheus-exporter/    sems-list-active-calls/    sems-monitoring-lib/
sems-get-callproperties/     sems-list-calls/           sems-list-finished-calls/
```

із еквівалентами на Python поруч. Це найсвіжіше помітне архітектурне доповнення, і воно є
позапроцесною відповіддю на спостережуваність, обговореною в
[8.2](29-monitoring-and-stats.md) і [13.3](49-metrics-and-observability.md).

## Тестування

```
core/tests/
  fct.h              sems_tests.cpp     test_amconfig.cpp
  test_auth.cpp      test_extensions.cpp  test_headers.cpp
```

Каркас юніт-тестів на `fct.h`, який проганяє кожен Docker-образ. Покриття сфокусоване на парсингу
й конфігурації — і це правильне місце, бо парсер є найціннішою мішенню для фазингу
([10.3](39-security-hardening.md)), а цей каркас є природною точкою старту для нього.

## Що перевірити перед розгортанням

1. **`cat VERSION`** і з'ясувати, з чим пакет справді зібрано — більшість цікавих опцій типово
   `OFF`.
2. **Чи ввімкнено `SEMS_HARDEN`?** Типово ні ([10.3](39-security-hardening.md)).
3. **Чи скомпільований ZRTP?** Типово ні, і потрібен форкнутий SDK
   ([9.6](36-zrtp-and-srtp.md)).
4. **Які кодеки?** Opus, G.729 і codec2 усі типово вимкнені
   ([5.4](19-codecs-and-plugins.md)).
5. **Чи є `libsamplerate`?** Типово ні; інакше вживається внутрішній ресемплер
   ([5.3](18-audio-pipeline.md)).
6. **systemd чи init?** Пакування RPM постачає init-скрипт.
7. **Чи запаковані Rust-інструменти?** Вони і є історією спостережуваності
   ([8.2](29-monitoring-and-stats.md)).

## Де шукати зміни

`doc/CHANGELOG` застарілий. Надійні джерела — історія комітів, `CMakeLists.txt` для прапорців
функцій, набір `Dockerfile-*` для матриці платформ і `pkg/` для того, що справді постачається.

Для інших гілок родини діють їхні власні release notes, і вони не відповідають цим номерам версій
([частина 12](43-family-overview.md)).
