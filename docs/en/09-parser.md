# 3.3 The parser

> [!IMPORTANT]
> The parser never copies. A parsed `sip_msg` is a set of pointers into the buffer the transport
> just filled. That is what makes it fast, and it is also the source of the single most
> dangerous rule in `core/sip/`: **nothing derived from a `sip_msg` may outlive it.**

## `cstring`

Everything rests on a two-field struct:

```cpp
struct cstring
{
    const char*  s;
    unsigned int len;
    ...
};
```

A pointer and a length. No allocation, no ownership, no terminator. `To`, `From`, `Call-ID`,
the R-URI, every header value — all of them are `cstring`s pointing into the same receive
buffer. Parsing a message is mostly a matter of walking that buffer once and recording offsets.

Crossing into the C++ world is explicit, and it is where copying happens:

```cpp
#define c2stlstr(str) \
          string((str).s,(str).len)
#define stl2cstr(str) \
          cstring((char*)(str).c_str(),(str).length())
```

When you see `c2stlstr()`, a copy is being made — usually because the value is about to be
handed to a session on another thread, where the receive buffer is no longer valid
([3.1](07-sip-stack-overview.md)).

> [!WARNING]
> `cstring::operator==` compares only up to the **shorter** of the two lengths:
> ```cpp
> bool operator == (const char* rhs_str) {
>   unsigned int rhs_len = strlen(rhs_str);
>   return memcmp(rhs_str,s,len <= rhs_len ? len : rhs_len) == 0;
> }
> ```
> It never compares the lengths themselves. A `cstring` holding `"INVITEX"` therefore compares
> equal to `"INVITE"`, and one holding `"INV"` does too. Any code that uses `==` for a security
> or routing decision must check `len` itself. This is a prefix match wearing the costume of an
> equality operator, and it has bitten people.

## `sip_msg`

```cpp
struct sip_msg
{
    char*   buf;
    int     len;
    // Request or Reply?
    int     type;
    ...
};
```

The message owns exactly one thing: `buf`. Everything else is a view into it. `type` is
`SIP_UNKNOWN`, `SIP_REQUEST` or `SIP_REPLY`, and the union of interest hangs off that:

```cpp
struct sip_request
{
    enum {
	OTHER_METHOD=0,
	INVITE,
	ACK,
        PRACK,
	OPTIONS,
	BYE,
	CANCEL,
	REGISTER
    };
    cstring  method_str;
    int      method;
    cstring  ruri_str;
    sip_uri  ruri;
};

struct sip_reply
{
    int     code;
    cstring reason;
};
```

Note that the method is stored **twice**: as an integer for the hot path and as a `cstring` for
everything else. `OTHER_METHOD` covers everything not in the enum — `INFO`, `UPDATE`, `REFER`,
`SUBSCRIBE`, `NOTIFY`, `MESSAGE` — which is why those are dispatched by string comparison and
are marginally more expensive to handle.

The enum is worth reading as a statement of intent: these seven methods are what the stack
itself has opinions about. Everything else is transported faithfully and left to the layers
above.

## Lazy header parsing

Headers are identified before they are parsed. `parse_header.h` declares the ones the stack
cares about:

```cpp
	H_UNPARSED=0,
	H_TO,
	H_VIA,
	H_FROM,
	H_CSEQ,
        H_RSEQ,
        H_RACK,
	H_ROUTE,
	H_CALL_ID,
	H_CONTACT,
        H_REQUIRE,
	H_RECORD_ROUTE,
	H_CONTENT_TYPE,
	H_CONTENT_LENGTH,
	H_MAX_FORWARDS,
	...
```

`H_UNPARSED` is the default, and most headers stay that way. A header the stack has no business
in — `User-Agent`, `P-Asserted-Identity`, any `X-` header — is recorded as a name/value pair and
never structurally parsed. The dedicated `parse_*.cpp` files (`parse_from_to`, `parse_via`,
`parse_cseq`, `parse_route`, `parse_uri`, `parse_nameaddr`, `parse_100rel`, …) run only for the
headers that need structure, and only when that structure is required.

This is the same instinct as Kamailio's lazy parsing, and for the same reason: a proxy or B2BUA
touches a handful of headers per message and should not pay to understand the other twenty.

## The async parser

Datagram transports get a whole message per read. Stream transports do not, so `tcp_trsp` needs
to know where a message ends before it can hand anything to `sip_parser`. That is
`sip_parser_async.*`:

```cpp
struct parser_state
{
  char* orig_buf;
  char* c;         // cursor
  char* beg;       // last marker for field start
  int stage;
  int st;          // parser state (within stage)
  int saved_st;    // saved parser state (within stage)
  sip_header hdr;  // temporary header struct
  int content_len; // detected body content-length
  ...
  int get_msg_len() {
    return c - orig_buf + content_len;
  }
};

int skip_sip_msg_async(parser_state* pst, char* end);
```

`skip_sip_msg_async()` advances as far as the data allows and returns; the state survives in
`parser_state` so the next chunk resumes exactly where the last one stopped. `stage` tracks
which part of the message we are in, `st`/`saved_st` the position inside the current header.

The function's job is deliberately minimal — find the end of the message. It reads far enough to
extract `Content-Length`, then `get_msg_len()` gives the total. Once that many bytes have
arrived, the buffer is handed to the real parser.

> [!NOTE]
> `Content-Length` is therefore load-bearing on stream transports in a way it is not on UDP: a
> peer that lies about it desynchronises the stream. This is a well-known SIP-over-TCP attack
> surface and part of why the parser is worth fuzzing ([10.3](39-security-hardening.md)).

## Malformed messages

A message that fails to parse is dropped at the transport layer, before any transaction exists,
and is logged. It never reaches a session, so no application code can be tricked by it — the
attack surface for a malformed message is the parser itself, not the application.

That is the right design, and it is also why the parser is the highest-value fuzzing target in
the tree: it is reachable by an unauthenticated packet, written in C against raw pointers, and
everything downstream trusts its output.

## Rules for working with parsed messages

- **A `cstring` is only valid while its `sip_msg` is.** Copy with `c2stlstr()` if it must
  outlive the call.
- **Do not `==` a `cstring` for a decision that matters.** Compare `len` too.
- **`method` for the seven known methods, `method_str` for everything else.** Do not test
  `method == OTHER_METHOD` and then assume anything.
- **Adding a structurally-parsed header means a new `parse_*.cpp` and a new `H_` id.** Recording
  a header you only need to read or forward requires neither.
