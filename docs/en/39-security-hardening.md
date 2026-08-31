# 10.3 Hardening

> [!NOTE]
> This chapter is the practical one: what to configure, what to restrict, and what to test.
> Every item traces to a mechanism covered earlier — the point here is to put them in the order
> you would actually apply them.

## Drop privileges

SEMS can change user and group at startup, and by default **it does not**:

```c
# define DEFAULT_DAEMON_UID         ""
# define DEFAULT_DAEMON_GID         ""
```

An empty string means the step is skipped, so a server started as root stays root unless you say
otherwise:

```
daemon_uid=sems
daemon_gid=sems
```

The implementation in `core/sems.cpp` is the conventional one, and it is strict about failure:

```cpp
      if(setgid(gid)<0){
	ERROR("Cannot change GID to %i: %s.", gid, strerror(errno));
	goto error;
      }
      ...
      if(setuid(uid)<0){
	ERROR("Cannot change UID to %i: %s.", uid, strerror(errno));
	goto error;
      }
```

`goto error` — a failed drop aborts startup rather than continuing with privileges. That is the
right behaviour and worth knowing, because a typo in the username stops the server.

Group first, then user, which is the correct order: after `setuid()` you can no longer change
group.

```cpp
#if defined(__linux__)
    if(!AmConfig::DaemonUid.empty() || !AmConfig::DaemonGid.empty()){
      if (prctl(PR_SET_DUMPABLE, 1, 0, 0, 0) < 0) {
	WARN("unable to set daemon to dump core after setuid/setgid\n");
      }
    }
#endif
```

Linux clears the dumpable flag after a UID change, so cores would be lost. SEMS restores it.

> [!WARNING]
> That means **core files are enabled after privilege drop**, and a core from a media server
> contains call audio, SIP headers, credentials and the ZRTP cache in memory. Useful for
> debugging, and a data-protection problem if cores land somewhere readable. Decide deliberately
> where `kernel.core_pattern` points and who can read it.

Two consequences of dropping privileges:

**Ports below 1024 need help.** Binding 5060 is fine, but if you need a privileged port, use
`CAP_NET_BIND_SERVICE` rather than staying root.

**Raw sockets need `CAP_NET_RAW`** ([3.2](08-transport.md)). The `use_raw_sockets` option is
unavailable to an unprivileged process without it.

Both are capabilities on the binary or in the service unit — not reasons to run as root.

## Bind deliberately

Every listener should be on an interface you chose:

```
#  sip_ip_intern=eth0
#  sip_port_intern=5060
#  media_ip_intern=eth0

#  sip_ip_extern=213.192.59.73
#  sip_port_extern=5060
#  media_ip_extern=213.192.59.73
```

The `intern`/`extern` split in the sample configuration is the shape to copy: signalling and
media on named interfaces, with the untrusted side separated from the trusted one. `sip_ip` also
accepts an interface name rather than an address, which survives address changes.

And the ones that matter most ([10.1](37-security-surface.md)):

- **XML-RPC (8090) and JSON-RPC (7080) on loopback or a management interface.** They have no
  authentication and full control of the process.
- **The `monitoring` UDP port likewise.**

## Set the limits

```
session_limit="1000;503;Server overload"
cps_limit="100;503;Server overload"
options_session_limit="900;503;Warning, server soon overloaded"
```

These are hardening, not tuning ([2.5](06-sizing-and-tuning.md)). Rejecting with `503` costs
nothing — no session, no thread, no dialog — and an overloaded media server that keeps accepting
delivers bad audio to everyone already on it.

`options_session_limit` set slightly below `session_limit` keeps keepalive `OPTIONS` answerable
when the box is full, so an upstream proxy sees a loaded server rather than a dead one and can
drain it gracefully.

## Lower the timeouts

| Setting | Default | Change to | Why |
|---|---|---|---|
| `dead_rtp_time` | **300 s** | 30–60 s | Five minutes per abandoned call ([5.2](17-rtp-stream.md)) |
| `tcp_idle_timeout` | **1 hour** | Minutes | Idle connections accumulate against the fd limit ([3.2](08-transport.md)) |
| `tcp_connect_timeout` | 2 s | Raise for long-haul | Aggressive on congested paths |
| `max_shutdown_time` | 10 s | As your calls need | Drain window ([2.4](05-lifecycle.md)) |

## Blacklisting

`core/sip/tr_blacklist.*` holds destinations that recently failed:

```cpp
struct bl_addr: public sockaddr_storage
{
  unsigned int hash();
};

class blacklist_bucket
  : public bl_bucket_base
{
public:
  bool insert(const bl_addr& addr, unsigned int duration /* ms */, const char* reason);
  bool remove(const bl_addr& addr);
};
```

A hash table of addresses with a duration and a reason, expired by the wheel timer
([3.4](10-transaction-layer.md)) and reached from the transaction layer through `STIMER_BL`.

Understand what it is: **reactive, and about destinations.** It stops SEMS hammering a peer that
is not answering. It is not an inbound blocklist and does nothing about attackers — blocking
sources is the proxy's job ([11.1](40-with-kamailio.md)) or the firewall's.

## File permissions

Everything sensitive is a file, and permissions are the entire control
([10.1](37-security-surface.md)):

| Path | Contains |
|---|---|
| `sems.conf` and `plugin_config_path` | Registration passwords, database credentials |
| The plug-in directory | Code that runs in-process ([7.1](24-plugin-architecture.md)) |
| ZRTP `cache_path`, `entropy_path` | Persistent key material ([9.6](36-zrtp-and-srtp.md)) |
| Recordings and voicemail | Call content ([9.3](33-msg-storage-and-voicemail.md)) |
| pcap captures | Call content and identifiers ([9.5](35-siprec-and-recording.md)) |
| Core dumps | All of the above, from memory |

Configuration readable only by the daemon user; the plug-in directory writable only by root.
A writable plug-in directory is remote code execution with extra steps.

## Fuzzing

The parser is the target that matters ([3.3](09-parser.md)): C over raw pointers, reachable by a
single unauthenticated datagram, and trusted by everything downstream.

`core/tests/` already has a unit test harness (`fct.h`, `test_headers.cpp`,
`test_extensions.cpp`, `test_auth.cpp`, `test_amconfig.cpp`), which is a starting point for
harnessing the parser rather than the whole server.

In priority order:

1. **`sip_parser`** — a whole datagram, malformed every way.
2. **`skip_sip_msg_async`** — stream framing, especially lying `Content-Length`
   ([3.3](09-parser.md)).
3. **`parse_uri`, `parse_from_to`, `parse_via`, `parse_cseq`** — the structured parsers.
4. **`AmSdp`** — reachable by anyone who can establish a call ([4.3](14-offer-answer.md)).
5. **`ParamReplacer`** — reachable if a profile substitutes attacker-controlled input
   ([6.4](23b-sbc-profiles.md)).

Two specific things to look for, both already noted in this book: `cstring::operator==` compares
only the shorter length and never the lengths themselves ([3.3](09-parser.md)), and stream
framing trusts `Content-Length`.

## A checklist

**Process**

- [ ] `daemon_uid` / `daemon_gid` set; confirm with `ps -o user`
- [ ] Capabilities on the binary instead of root, if needed
- [ ] `kernel.core_pattern` points somewhere protected

**Network**

- [ ] SIP bound to a chosen interface, not `0.0.0.0`
- [ ] RTP range narrowed to real concurrency ([10.2](38-security-media.md))
- [ ] Firewall matches that range and those peers
- [ ] RPC ports on loopback or management only
- [ ] `monitoring` UDP port likewise

**Configuration**

- [ ] `session_limit`, `cps_limit`, `options_session_limit` set
- [ ] `dead_rtp_time` lowered from 300 s
- [ ] `tcp_idle_timeout` lowered from an hour
- [ ] `exclude_payloads` narrowed to codecs you accept
- [ ] `application=` not caller-controlled on an untrusted interface
  ([4.2](13-session-container-and-factories.md))
- [ ] SBC profiles do not route on unvalidated `$H(...)` ([6.4](23b-sbc-profiles.md))

**Files**

- [ ] Configuration readable only by the daemon user
- [ ] Plug-in directory not writable by the daemon user
- [ ] Recordings, voicemail and captures on protected storage
- [ ] ZRTP cache protected, if in use

**Architecture**

- [ ] A proxy in front doing authentication, rate limiting and blocklisting
  ([11.1](40-with-kamailio.md))
- [ ] SEMS not directly reachable from the internet
