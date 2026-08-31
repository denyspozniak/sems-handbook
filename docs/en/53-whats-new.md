# 14.2 What's new in 2.x

> [!NOTE]
> This chapter is about the shape of the current tree rather than a release-by-release history.
> `doc/CHANGELOG` carries the older entries and stops well before the current version; what
> follows is what the 2.x tree actually looks like to build and run.

## The version

```
$ cat VERSION
2.1.0
```

`doc/CHANGELOG`'s last detailed entries are from the 1.5/1.6 era. Its 1.5.0 list is worth reading
anyway, because much of it is machinery this book has spent chapters on:

> - configurable SIP timers (global)
> - timer C support (mainly for SBC)
> - SUBSCRIBE/NOTIFY support
> - multi-mime bodies
> - wideband / multiple sample frequency support
> - multiple destinations (faked SRV record)
> - DNS SRV: support for 503 replies
> - multi-threaded RTP receiver
> - complete rework of offer/answer mechanisms

That last line explains why `AmOfferAnswer` is a clean state machine
([4.3](14-offer-answer.md)) rather than accreted logic — it was rewritten. "Multiple destinations
(faked SRV record)" is the ancestor of the failover discussed in
[13.5](51-peer-dispatching.md), and "wideband / multiple sample frequency support" is why the
mixer keeps a `MixerBufferState` per rate ([5.3](18-audio-pipeline.md)).

## The build is CMake

`CMakeLists.txt` is the build, and its options are the honest feature list:

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

Read as a list of defaults, it says a lot:

**On by default:** iLBC (with a bundled fallback), monitoring, IPv6, Python.

**Off by default:** Opus, spandsp, libsamplerate, ZRTP, MP3, G.729, codec2, TTS, OpenSSL.

So a stock build has **no Opus, no high-quality resampler, no TTS, no ZRTP, and no OpenSSL**.
Distribution packages usually enable more; check what yours was built with before assuming a
feature exists ([9.6](36-zrtp-and-srtp.md), [5.3](18-audio-pipeline.md)).

### The three sanitiser options

`SEMS_USE_ASAN`, `SEMS_USE_UBSAN` and `SEMS_USE_TSAN` are a notable addition for a codebase of
this age, and `TSAN` in particular is the right tool for this architecture: a single process with
many threads and no shared-memory allocator ([2.1](02-thread-model.md)) is exactly what
ThreadSanitizer is for. Any patch touching the event system
([2.2](03-event-system.md)), the media processor ([5.1](16-media-processor.md)) or `AmB2BMedia`
([6.2](22-b2b-media.md)) should be run under it.

`SEMS_HARDEN` collects stack protector, `FORTIFY_SOURCE`, RELRO and PIE. **Off by default**, which
is worth knowing given the parser's exposure ([10.3](39-security-hardening.md)) — a distribution
package may or may not enable it.

## Platform coverage

```
Dockerfile-debian11   Dockerfile-ubuntu22.04   Dockerfile-rhel7   Dockerfile-rhel9
Dockerfile-debian12   Dockerfile-ubuntu24.04   Dockerfile-rhel8   Dockerfile-rhel10
Dockerfile-debian13                                               Dockerfile-rhel10-dis-test
```

Three Debian releases, two Ubuntu LTS, four RHEL generations — RHEL 7 through 10 in one tree is
unusually wide, and it constrains what the code can assume about compilers and library versions.

Each image builds and runs the unit tests as part of the build
([11.3](42-lab.md)):

```dockerfile
RUN mkdir -p build && cd build && cmake .. && make sems_tests && ./core/sems_tests
```

so a green image is a green test run on that platform.

`Dockerfile-rhel10-dis-test` is a variant for the DIS module — Distributed Interactive
Simulation, `apps/dis_test`, which generates a 400 Hz tone and sends EntityStatePDU packets. Not a
dispatcher ([13.1](47-gaps-overview.md)).

## Packaging

```
pkg/deb/{jessie,wheezy,buster,bullseye,bookworm,trixie,precise,trusty,debian}
pkg/rpm/{sems.spec,sems.init,sems.sysconfig}
pkg/gentoo/
```

Debian packaging goes back to wheezy and forward to trixie. The RPM side ships an **init script**
rather than a systemd unit, which is a good marker of the project's age and of RHEL 7 still being
in the matrix.

The Debian image builds a real package with a guard worth quoting
([11.3](42-lab.md)):

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

Building a version older than the changelog **fails the build** rather than producing a package
apt will silently refuse to upgrade to. That is a small piece of engineering discipline that
saves a confusing afternoon.

`PKG_VERSION` lets CI stamp a unique version so an apt repository sees an upgrade, with `VERSION`
as the fallback.

## The Rust tools

`apps/monitoring/tools/` is Rust, which is why `cargo` and `rustc` are in the Debian dependency
list ([11.3](42-lab.md)):

```
sems-prometheus-exporter/    sems-list-active-calls/    sems-monitoring-lib/
sems-get-callproperties/     sems-list-calls/           sems-list-finished-calls/
```

with Python equivalents alongside. This is the most recent architectural addition of note, and it
is the out-of-process answer to observability discussed in
[8.2](29-monitoring-and-stats.md) and [13.3](49-metrics-and-observability.md).

## Testing

```
core/tests/
  fct.h              sems_tests.cpp     test_amconfig.cpp
  test_auth.cpp      test_extensions.cpp  test_headers.cpp
```

A unit test harness built on `fct.h`, run by every Docker image. Coverage is focused on parsing
and configuration — which is the right place for it, since the parser is the highest-value
fuzzing target ([10.3](39-security-hardening.md)) and the harness is the natural starting point
for one.

## What to check before deploying

1. **`cat VERSION`**, and confirm what the package was actually built with — most interesting
   options default to `OFF`.
2. **Is `SEMS_HARDEN` on?** It is off by default ([10.3](39-security-hardening.md)).
3. **Is ZRTP compiled in?** Off by default and needs a forked SDK
   ([9.6](36-zrtp-and-srtp.md)).
4. **Which codecs?** Opus, G.729 and codec2 are all off by default
   ([5.4](19-codecs-and-plugins.md)).
5. **Is `libsamplerate` in?** Off by default; the internal resampler is used otherwise
   ([5.3](18-audio-pipeline.md)).
6. **systemd or init?** The RPM packaging ships an init script.
7. **Are the Rust tools packaged?** They are the observability story
   ([8.2](29-monitoring-and-stats.md)).

## Where to look for changes

`doc/CHANGELOG` is stale. The reliable sources are the commit history, `CMakeLists.txt` for
feature flags, the `Dockerfile-*` set for the platform matrix, and `pkg/` for what actually gets
shipped.

For the other branches of the family, their own release notes apply and do not correspond to
these version numbers ([Part 12](43-family-overview.md)).
