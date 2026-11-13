# Core and Harness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the portable protocol core for the RM520N-GL QMI driver, its unit tests, and a command-line harness that proves the core against the real modem.

**Architecture:** Core is plain C++ with no OS dependencies and no I/O: callers hand it bytes and timestamps and it hands back bytes and events. The harness wires Core to the modem's USB interface 4 from userspace. The DriverKit driver and the host app are separate, later plans that reuse Core unchanged.

**Tech Stack:** C++17 (Apple clang, macOS 27), a Makefile, a small in-repo test runner, Objective-C++ with IOUSBHost.framework for the harness.

**Spec:** `docs/superpowers/specs/2026-11-13-rmnet-driver-design.md`

## Global Constraints

- Core (`core/`) is plain C++17: no exceptions, no RTTI, no heap allocation, no STL containers or `<functional>`. Allowed headers: `<stdint.h>`, `<stddef.h>`, `<string.h>`. Compile flags: `-std=c++17 -Wall -Wextra -Werror -fno-exceptions -fno-rtti`.
- Core must compile for DriverKit. `make check-driverkit` must pass after every task that touches `core/`.
- Everything in Core lives in namespace `rmnet`; public headers are `core/include/rmnet/*.h`.
- Tests (`tests/`) and the harness (`harness/`) may use the STL. Tests need no hardware: `make test` must pass with no modem attached.
- No code copied from qmi-darwin. The files in `tests/fixtures/` are byte traces recorded from the modem; they are data and are the authority for wire formats. If a constant in this plan disagrees with a fixture, the fixture wins; say so in the report.
- Every QMI message and TLV constant carries a comment with the name libqmi gives it (for example `// libqmi: WDS "Start Network"`), so it can be checked against upstream.
- No persistent modem changes. The only QMI messages sent are: CTL Sync, Get Client ID, Release Client ID; WDA Set Data Format; WDS Bind Mux Data Port, Set IP Family, Start Network, Stop Network, Get Current Settings.
- Only USB interface 4 of device `2c7c:0801` (class, subclass, protocol all `0xff`) is opened. Never the AT, NMEA or diagnostic interfaces.
- No root, no private macOS interfaces, and the harness creates no network interface.
- Fixed values: mux ID `0x81`; profile `1`; downlink aggregation `32` datagrams and `31744` bytes; uplink aggregation `32` datagrams and `16384` bytes; USB bulk packet size `1024`.
- Commit at the end of every task, on the working branch, with the message given in the task.

## Review Focus

1. Truncated or corrupt bytes from the modem (a QMUX frame shorter than its length field, a TLV running past the frame, a QMAP length past the buffer) are rejected without reading out of bounds. Tests: Task 2 `decode_rejects_truncated`, Task 3 `parsers_reject_short_values`, Task 4 `parse_truncated` and `parse_bad_pad`.
2. A QMI response with an unexpected transaction ID, such as one left over from a crashed process, does not advance the connection. Test: Task 5 `ignores_response_with_wrong_txid`.
3. One IP family failing still gives a working link on the other, and the emulation stays silent for the missing family. Tests: Task 5 `v6_failure_still_links_up_v4_only`, Task 9 `rs_without_ipv6_link_dropped`.
4. An uplink transfer that lands on an exact multiple of 1024 bytes is padded so no zero-length packet is needed. Test: Task 4 `aggregator_avoids_usb_packet_multiple`.
5. macOS asks for an address it held on another network, or sends frames before the link is up. Tests: Task 8 `request_for_other_address_gets_nak` and `dhcp_while_link_down_dropped`, Task 7 `arp_while_link_down_dropped`.

---

## File Structure

| Path | Responsibility |
|---|---|
| `Makefile` | `test`, `harness`, `check-driverkit`, `clean`. Picks up `core/src/*.cpp` and `tests/test_*.cpp` by wildcard, so adding a file needs no Makefile edit |
| `scripts/check-driverkit-compile.sh` | Syntax-checks every Core source against the DriverKit SDK |
| `core/include/rmnet/bytes.h`, `core/src/bytes.cpp` | Bounds-checked byte cursors |
| `core/include/rmnet/qmi.h`, `core/src/qmi.cpp` | QMUX frame and TLV encode and decode |
| `core/include/rmnet/qmi_msgs.h`, `core/src/qmi_msgs.cpp` | Builders and parsers for the ten messages used |
| `core/include/rmnet/qmap.h`, `core/src/qmap.cpp` | QMAP parse, header write, uplink aggregator, command replies |
| `core/include/rmnet/session.h`, `core/src/session.cpp` | Connection state machine |
| `core/include/rmnet/ip.h`, `core/src/ip.cpp` | Checksums and IPv4, IPv6, ICMP builders |
| `core/include/rmnet/ethernet.h`, `core/src/ethernet.cpp`, `core/src/dhcp.cpp`, `core/src/ndp.cpp` | Ethernet emulation: wrap, unwrap, ARP, DHCP, IPv6 neighbour discovery |
| `tests/minitest.h`, `tests/test_main.cpp` | Test runner |
| `tests/captures.h` | The recorded frames as named hex strings |
| `tests/test_*.cpp` | One test file per Core unit |
| `tests/fixtures/capture-dryrun.txt`, `capture-probe.txt` | Raw traces from the modem (already present) |
| `harness/usb_transport.h`, `harness/usb_transport.mm` | IOUSBHost wrapper for interface 4 |
| `harness/main.mm` | `probe`, `connect`, `ping` commands |

---

### Task 1: Scaffold, byte cursors, test runner, DriverKit check

**Files:**
- Create: `Makefile`, `.gitignore`, `README.md`, `scripts/check-driverkit-compile.sh`, `core/include/rmnet/bytes.h`, `core/src/bytes.cpp`, `tests/minitest.h`, `tests/test_main.cpp`, `tests/test_bytes.cpp`
- Add to git: `tests/fixtures/capture-dryrun.txt`, `tests/fixtures/capture-probe.txt`

**Interfaces:**
- Produces, in `rmnet/bytes.h`:

```cpp
namespace rmnet {
struct Span { const uint8_t* data; size_t len; };
class Reader {                       // never reads past the end; a failed read is sticky
 public:
  Reader(const uint8_t* data, size_t len);
  bool ok() const;                   // false once any read ran short
  size_t remaining() const;          // 0 once !ok()
  uint8_t u8(); uint16_t u16le(); uint32_t u32le(); uint16_t u16be(); uint32_t u32be();  // 0 when short
  Span take(size_t n);               // {nullptr, 0} when short
  void skip(size_t n);
};
class Writer {                       // writes into the caller's buffer; overflow is sticky and writes nothing
 public:
  Writer(uint8_t* buf, size_t cap);
  bool ok() const; size_t size() const;
  void u8(uint8_t v); void u16le(uint16_t v); void u32le(uint32_t v); void u16be(uint16_t v); void u32be(uint32_t v);
  void bytes(const uint8_t* p, size_t n);
  void patch_u16le(size_t offset, uint16_t v);   // offset + 2 must be <= size()
};
}
```

- Produces, in `tests/minitest.h`: `TEST(name) { ... }` (self-registering), `CHECK(cond)`, `CHECK_EQ(a, b)` (prints both values on failure), `std::vector<uint8_t> hex(const char* text)` (parses `"01 0b 00"`), `CHECK_BYTES(vec_or_ptr_len, "01 0b 00")`. `tests/test_main.cpp` runs every registered test, or only those whose name contains `argv[1]`, prints `N tests, M failed`, and exits non-zero on any failure.
- Produces: `make test` builds `build/tests` and runs it. `make check-driverkit` runs the script. `.gitignore` lists `build/` and `.superpowers/`.

- [ ] **Step 1: Write the failing tests** in `tests/test_bytes.cpp`

```cpp
TEST(reader_reads_little_and_big_endian) {
  auto b = hex("01 02 03 04 05 06 07 08 09 0a 0b");
  rmnet::Reader r(b.data(), b.size());
  CHECK_EQ(r.u8(), 0x01); CHECK_EQ(r.u16le(), 0x0302); CHECK_EQ(r.u32le(), 0x07060504u);
  CHECK_EQ(r.u16be(), 0x0809); CHECK_EQ(r.remaining(), 2u); CHECK(r.ok());
}
TEST(reader_short_read_is_sticky) {
  auto b = hex("01 02");
  rmnet::Reader r(b.data(), b.size());
  CHECK_EQ(r.u32le(), 0u); CHECK(!r.ok()); CHECK_EQ(r.u8(), 0); CHECK_EQ(r.remaining(), 0u);
  CHECK(r.take(1).data == nullptr);
}
TEST(reader_take_returns_view) {
  auto b = hex("aa bb cc dd");
  rmnet::Reader r(b.data(), b.size()); r.skip(1);
  rmnet::Span s = r.take(2);
  CHECK(s.data == b.data() + 1); CHECK_EQ(s.len, 2u); CHECK_EQ(r.remaining(), 1u);
}
TEST(writer_writes_and_patches) {
  uint8_t buf[8];
  rmnet::Writer w(buf, sizeof buf);
  w.u8(0x01); w.u16le(0); w.u32be(0x0a0b0c0d); w.patch_u16le(1, 0x1234);
  CHECK(w.ok()); CHECK_EQ(w.size(), 7u); CHECK_BYTES(buf, 7, "01 34 12 0a 0b 0c 0d");
}
TEST(writer_overflow_is_sticky) {
  uint8_t buf[2];
  rmnet::Writer w(buf, sizeof buf);
  w.u32le(1); CHECK(!w.ok()); CHECK_EQ(w.size(), 0u);
  w.u8(1); CHECK(!w.ok()); CHECK_EQ(w.size(), 0u);
}
```

- [ ] **Step 2: Write the Makefile and test runner, run `make test`.** Expected: compile failure, `rmnet/bytes.h` not found.
- [ ] **Step 3: Implement `bytes.h` and `bytes.cpp`.**
- [ ] **Step 4: Run `make test`.** Expected: `5 tests, 0 failed`.
- [ ] **Step 5: Write `scripts/check-driverkit-compile.sh`.** For each `core/src/*.cpp` it runs `xcrun --sdk driverkit clang++` with `-target arm64-apple-driverkit<SDK version>`, the Core flags from Global Constraints, `-Icore/include` and `-fsyntax-only`. It prints `driverkit check: N files ok` and exits non-zero on any error. Run `make check-driverkit`. Expected: `driverkit check: 1 files ok`.
- [ ] **Step 6: Write `README.md`**: what the repository is in two sentences, the three make targets, and a pointer to the spec.
- [ ] **Step 7: Commit**

```bash
git add -A && git commit -m "feat: scaffold core, test runner and DriverKit compile check"
```

---

### Task 2: QMUX frames and TLVs

**Files:**
- Create: `core/include/rmnet/qmi.h`, `core/src/qmi.cpp`, `tests/captures.h`, `tests/test_qmi.cpp`

**Interfaces:**
- Consumes: `Span`, `Reader`, `Writer` from Task 1.
- Produces, in `rmnet/qmi.h`:

```cpp
namespace rmnet {
enum class QmiService : uint8_t { CTL = 0x00, WDS = 0x01, WDA = 0x1A };
enum class QmiKind : uint8_t { Request, Response, Indication };
struct QmiHeader { QmiService service; uint8_t client; QmiKind kind; uint16_t txid; uint16_t msg_id; };
struct QmiMessage { QmiHeader hdr; Span tlvs; };        // tlvs points into the decoded frame
bool qmi_decode(Span frame, QmiMessage* out);           // false if malformed, truncated, or the TLV chain overruns
bool qmi_find_tlv(Span tlvs, uint8_t type, Span* value);// first TLV of that type
struct QmiResult { bool present; bool ok; uint16_t error; };
QmiResult qmi_result(const QmiMessage& m);              // TLV 0x02 of a response: u16 status, u16 error
class QmiBuilder {
 public:
  QmiBuilder(uint8_t* buf, size_t cap, const QmiHeader& hdr);
  void tlv(uint8_t type, const uint8_t* value, size_t n);
  void tlv_u8(uint8_t type, uint8_t v);
  void tlv_u32(uint8_t type, uint32_t v);
  size_t finish();                                      // total frame length; 0 on overflow
};
}
```

- Produces, in `tests/captures.h`: one `inline const char*` per frame in `tests/fixtures/capture-dryrun.txt`, hex copied exactly, in capture order, named:
  `kCtlSyncReq`, `kCtlSyncResp`, `kCtlGetWdaReq`, `kCtlGetWdaResp`, `kWdaSetFormatReq`, `kWdaSetFormatResp`, `kCtlGetWds4Req`, `kCtlGetWds4Resp`, `kWdsBind4Req`, `kWdsBind4Resp`, `kWdsFamily4Req`, `kWdsFamily4Resp`, `kWdsStart4Req`, `kWdsStart4Resp`, `kWdsConnected4Ind`, `kWdsSettings4Req`, `kWdsSettings4Resp`, `kCtlGetWds6Req`, `kCtlGetWds6Resp`, `kWdsBind6Req`, `kWdsBind6Resp`, `kWdsFamily6Req`, `kWdsFamily6Resp`, `kWdsStart6Req`, `kWdsStart6Resp`, `kWdsSettings6Req`, `kWdsConnected6Ind`, `kWdsSettings6Resp`, `kWdsStop6Req`, `kWdsStop6Resp`, `kCtlRelease6Req`, `kWdsDisconnected6Ind`, `kCtlRelease6Resp`, `kWdsStop4Req`, `kWdsStop4Resp`, `kCtlRelease4Req`, `kWdsDisconnected4Ind`, `kCtlRelease4Resp`, `kCtlReleaseWdaReq`, `kCtlReleaseWdaResp`. In the capture, client 15 is the IPv4 WDS client and client 16 is the IPv6 one.

Wire format, for reference: byte `0x01`; u16le length of everything after that byte; flags (`0x00` from the host, `0x80` from the modem); service; client. Then for CTL: kind byte (`0` request, `1` response, `2` indication), u8 transaction ID. For other services: kind byte (`0`, `2`, `4`), u16le transaction ID. Then u16le message ID, u16le TLV length, then TLVs as type u8, length u16le, value.

- [ ] **Step 1: Write the failing tests** in `tests/test_qmi.cpp`

```cpp
TEST(decode_ctl_sync_response) {
  auto f = hex(kCtlSyncResp); rmnet::QmiMessage m;
  CHECK(rmnet::qmi_decode({f.data(), f.size()}, &m));
  CHECK(m.hdr.service == rmnet::QmiService::CTL); CHECK_EQ(m.hdr.client, 0);
  CHECK(m.hdr.kind == rmnet::QmiKind::Response); CHECK_EQ(m.hdr.txid, 1); CHECK_EQ(m.hdr.msg_id, 0x0027);
  CHECK_EQ(m.tlvs.len, 7u);
  auto r = rmnet::qmi_result(m); CHECK(r.present); CHECK(r.ok); CHECK_EQ(r.error, 0);
}
TEST(decode_wds_indication) {
  auto f = hex(kWdsConnected4Ind); rmnet::QmiMessage m;
  CHECK(rmnet::qmi_decode({f.data(), f.size()}, &m));
  CHECK(m.hdr.service == rmnet::QmiService::WDS); CHECK_EQ(m.hdr.client, 15);
  CHECK(m.hdr.kind == rmnet::QmiKind::Indication); CHECK_EQ(m.hdr.txid, 1); CHECK_EQ(m.hdr.msg_id, 0x0022);
  rmnet::Span v; CHECK(rmnet::qmi_find_tlv(m.tlvs, 0x12, &v)); CHECK_EQ(v.len, 1u); CHECK_EQ(v.data[0], 4);
  CHECK(!rmnet::qmi_find_tlv(m.tlvs, 0x99, &v));
  CHECK(!rmnet::qmi_result(m).present);
}
TEST(decode_rejects_truncated) {
  auto f = hex(kCtlSyncResp); rmnet::QmiMessage m;
  CHECK(!rmnet::qmi_decode({f.data(), f.size() - 1}, &m));           // shorter than its length field
  auto g = f; g[0] = 0x02; CHECK(!rmnet::qmi_decode({g.data(), g.size()}, &m));   // wrong marker
  auto h = f; h[13] = 0x09; CHECK(!rmnet::qmi_decode({h.data(), h.size()}, &m));  // TLV length 9 overruns
  CHECK(!rmnet::qmi_decode({f.data(), 3}, &m));
}
TEST(build_matches_capture_ctl) {
  uint8_t buf[64]; uint8_t svc = 0x1a;
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::CTL, 0, rmnet::QmiKind::Request, 2, 0x0022});
  b.tlv(0x01, &svc, 1);
  size_t n = b.finish(); CHECK_BYTES(buf, n, kCtlGetWdaReq);
}
TEST(build_matches_capture_service) {
  uint8_t buf[64];
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::WDS, 15, rmnet::QmiKind::Request, 3, 0x004D});
  b.tlv_u8(0x01, 4);
  size_t n = b.finish(); CHECK_BYTES(buf, n, kWdsFamily4Req);
}
TEST(builder_overflow_returns_zero) {
  uint8_t buf[10];
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::WDS, 1, rmnet::QmiKind::Request, 1, 0x0020});
  b.tlv_u32(0x10, 1); CHECK_EQ(b.finish(), 0u);
}
TEST(result_reports_error) {
  uint8_t buf[64]; const uint8_t res[4] = {0x01, 0x00, 0x1a, 0x00};
  rmnet::QmiBuilder b(buf, sizeof buf, {rmnet::QmiService::WDS, 15, rmnet::QmiKind::Response, 4, 0x0020});
  b.tlv(0x02, res, 4); size_t n = b.finish();
  rmnet::QmiMessage m; CHECK(rmnet::qmi_decode({buf, n}, &m));
  auto r = rmnet::qmi_result(m); CHECK(r.present); CHECK(!r.ok); CHECK_EQ(r.error, 0x001a);
}
```

- [ ] **Step 2: Create `tests/captures.h`, run `make test`.** Expected: compile failure, `rmnet/qmi.h` not found.
- [ ] **Step 3: Implement `qmi.h` and `qmi.cpp`.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `12 tests, 0 failed`; `driverkit check: 2 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: QMUX frame and TLV codec"
```

---

### Task 3: The QMI messages used

**Files:**
- Create: `core/include/rmnet/qmi_msgs.h`, `core/src/qmi_msgs.cpp`, `tests/test_qmi_msgs.cpp`

**Interfaces:**
- Consumes: Task 2's `QmiBuilder`, `QmiMessage`, `qmi_find_tlv`, `qmi_result`; `tests/captures.h`.
- Produces, in `rmnet/qmi_msgs.h`. Every builder returns the frame length, or 0 on overflow:

```cpp
namespace rmnet {
enum : uint16_t {
  kCtlGetClientId = 0x0022, kCtlReleaseClientId = 0x0023, kCtlSync = 0x0027,
  kWdaSetDataFormat = 0x0020,
  kWdsStartNetwork = 0x0020, kWdsStopNetwork = 0x0021, kWdsPacketServiceStatus = 0x0022,
  kWdsGetCurrentSettings = 0x002D, kWdsSetIpFamily = 0x004D, kWdsBindMuxDataPort = 0x00A2,
};
enum : uint16_t { kQmiErrCallFailed = 0x000E, kQmiErrNoEffect = 0x001A };

size_t build_ctl_sync(uint8_t* buf, size_t cap, uint8_t txid);
size_t build_ctl_get_client_id(uint8_t* buf, size_t cap, uint8_t txid, QmiService service);
bool   parse_ctl_get_client_id(const QmiMessage& m, QmiService* service, uint8_t* client);
size_t build_ctl_release_client_id(uint8_t* buf, size_t cap, uint8_t txid, QmiService service, uint8_t client);

struct DataFormat { uint32_t link_layer, ul_agg, dl_agg, dl_max_datagrams, dl_max_size, ul_max_datagrams, ul_max_size; };
size_t build_wda_set_data_format(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid, uint32_t iface_number);
bool   parse_wda_data_format(const QmiMessage& m, DataFormat* out);
bool   data_format_usable(const DataFormat& f);    // raw IP (2), QMAP (5) both ways, dl_max_size >= 2048

size_t build_wds_bind_mux(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid, uint32_t iface_number, uint8_t mux_id);
size_t build_wds_set_ip_family(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid, uint8_t family);
size_t build_wds_start_network(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid, uint8_t profile, uint8_t family);
struct CallEnd { uint16_t reason; uint16_t verbose_type; uint16_t verbose_reason; };
bool   parse_wds_start_network(const QmiMessage& m, uint32_t* handle, CallEnd* end);  // false on failure; *end filled when present
size_t build_wds_stop_network(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid, uint32_t handle);
size_t build_wds_get_current_settings(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid);

struct RuntimeSettings {            // all addresses in network byte order
  bool has_v4; uint8_t v4_addr[4], v4_gateway[4], v4_mask[4]; uint8_t v4_dns[2][4]; uint8_t v4_dns_count;
  bool has_v6; uint8_t v6_addr[16]; uint8_t v6_prefix_len; uint8_t v6_gateway[16]; uint8_t v6_dns[2][16]; uint8_t v6_dns_count;
  uint32_t mtu;
};
bool parse_wds_current_settings(const QmiMessage& m, RuntimeSettings* out);   // merges into *out, so IPv4 and IPv6 replies combine
struct PacketStatus { uint8_t status; bool reconfigure; uint8_t family; };    // status 1 disconnected, 2 connected; family 0 if absent
bool parse_wds_packet_status(const QmiMessage& m, PacketStatus* out);
}
```

TLV numbers, all confirmed by the capture. Set Data Format request: `0x10` u8 0, `0x11` link layer 2, `0x12` uplink aggregation 5, `0x13` downlink aggregation 5, `0x15` 32, `0x16` 31744, `0x17` endpoint (u32 type 2, u32 interface), `0x1B` 32, `0x1C` 16384. Its response: `0x11` to `0x16` the same, `0x17` uplink datagrams, `0x18` uplink size. Bind Mux: `0x10` endpoint, `0x11` mux ID, `0x13` u32 1. Set IP Family: `0x01`. Start Network: `0x19` family, then `0x31` profile; response `0x01` u32 handle, and on failure `0x10` u16 reason, `0x11` u16 type and u16 reason. Stop Network: `0x01` handle. Get Current Settings: `0x10` u32 `0x0000AF1D`; response `0x15` and `0x16` IPv4 DNS, `0x1E` address, `0x20` gateway, `0x21` mask (each a u32le, so the bytes are reversed), `0x25` IPv6 address plus prefix length, `0x26` IPv6 gateway plus prefix length, `0x27` and `0x28` IPv6 DNS, `0x29` MTU. Packet Service Status: `0x01` status and reconfigure flag, `0x12` family.

- [ ] **Step 1: Write the failing tests** in `tests/test_qmi_msgs.cpp`

```cpp
TEST(builders_match_capture) {
  uint8_t b[128]; size_t n;
  n = rmnet::build_ctl_sync(b, sizeof b, 1);                                   CHECK_BYTES(b, n, kCtlSyncReq);
  n = rmnet::build_ctl_get_client_id(b, sizeof b, 2, rmnet::QmiService::WDA);  CHECK_BYTES(b, n, kCtlGetWdaReq);
  n = rmnet::build_ctl_release_client_id(b, sizeof b, 5, rmnet::QmiService::WDS, 16); CHECK_BYTES(b, n, kCtlRelease6Req);
  n = rmnet::build_wda_set_data_format(b, sizeof b, 1, 1, 4);                  CHECK_BYTES(b, n, kWdaSetFormatReq);
  n = rmnet::build_wds_bind_mux(b, sizeof b, 15, 2, 4, 0x81);                  CHECK_BYTES(b, n, kWdsBind4Req);
  n = rmnet::build_wds_set_ip_family(b, sizeof b, 15, 3, 4);                   CHECK_BYTES(b, n, kWdsFamily4Req);
  n = rmnet::build_wds_start_network(b, sizeof b, 15, 4, 1, 4);                CHECK_BYTES(b, n, kWdsStart4Req);
  n = rmnet::build_wds_get_current_settings(b, sizeof b, 15, 5);               CHECK_BYTES(b, n, kWdsSettings4Req);
  n = rmnet::build_wds_stop_network(b, sizeof b, 16, 10, 0xe2b3f370);          CHECK_BYTES(b, n, kWdsStop6Req);
}
TEST(parse_client_id) {            // decode() is a test helper: hex + qmi_decode
  rmnet::QmiService s; uint8_t c;
  CHECK(rmnet::parse_ctl_get_client_id(decode(kCtlGetWds4Resp), &s, &c));
  CHECK(s == rmnet::QmiService::WDS); CHECK_EQ(c, 15);
}
TEST(parse_data_format) {
  rmnet::DataFormat f{};
  CHECK(rmnet::parse_wda_data_format(decode(kWdaSetFormatResp), &f));
  CHECK_EQ(f.link_layer, 2u); CHECK_EQ(f.ul_agg, 5u); CHECK_EQ(f.dl_agg, 5u);
  CHECK_EQ(f.dl_max_datagrams, 32u); CHECK_EQ(f.dl_max_size, 31744u);
  CHECK_EQ(f.ul_max_datagrams, 32u); CHECK_EQ(f.ul_max_size, 16384u);
  CHECK(rmnet::data_format_usable(f));
  f.link_layer = 1; CHECK(!rmnet::data_format_usable(f));
}
TEST(parse_start_network_handle) {
  uint32_t h = 0; rmnet::CallEnd e{};
  CHECK(rmnet::parse_wds_start_network(decode(kWdsStart4Resp), &h, &e)); CHECK_EQ(h, 0xe2b29ac0u);
}
TEST(parse_start_network_failure) {  // built in the test: result 01 00 0e 00, TLV 0x10 = 02 00, TLV 0x11 = 03 00 d0 07
  uint32_t h = 0; rmnet::CallEnd e{};
  CHECK(!rmnet::parse_wds_start_network(failed_start_frame(), &h, &e));
  CHECK_EQ(e.reason, 2); CHECK_EQ(e.verbose_type, 3); CHECK_EQ(e.verbose_reason, 2000);
}
TEST(parse_settings_ipv4) {
  rmnet::RuntimeSettings s{};
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings4Resp), &s));
  CHECK(s.has_v4); CHECK(!s.has_v6);
  CHECK_BYTES(s.v4_addr, 4, "0a 66 f6 e6"); CHECK_BYTES(s.v4_gateway, 4, "0a 66 f6 e5"); CHECK_BYTES(s.v4_mask, 4, "ff ff ff fc");
  CHECK_EQ(s.v4_dns_count, 2); CHECK_BYTES(s.v4_dns[0], 4, "cb 00 71 c1"); CHECK_BYTES(s.v4_dns[1], 4, "cb 00 71 d1");
  CHECK_EQ(s.mtu, 1500u);
}
TEST(parse_settings_ipv6_merges) {
  rmnet::RuntimeSettings s{};
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings4Resp), &s));
  CHECK(rmnet::parse_wds_current_settings(decode(kWdsSettings6Resp), &s));
  CHECK(s.has_v4); CHECK(s.has_v6); CHECK_EQ(s.v6_prefix_len, 64);
  CHECK_BYTES(s.v6_addr, 16, "20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 08");
  CHECK_BYTES(s.v6_gateway, 16, "20 01 0d b8 8a f4 b2 60 a0 89 88 dc 13 7d 62 53");
  CHECK_EQ(s.v6_dns_count, 2); CHECK_BYTES(s.v6_dns[0], 16, "20 01 0d b8 20 00 00 00 02 70 00 00 00 00 00 01");
}
TEST(parse_packet_status) {
  rmnet::PacketStatus p{};
  CHECK(rmnet::parse_wds_packet_status(decode(kWdsConnected4Ind), &p));
  CHECK_EQ(p.status, 2); CHECK(!p.reconfigure); CHECK_EQ(p.family, 4);
  CHECK(rmnet::parse_wds_packet_status(decode(kWdsDisconnected6Ind), &p));
  CHECK_EQ(p.status, 1); CHECK_EQ(p.family, 6);
}
TEST(parsers_reject_short_values) {  // frames built in the test with a 2-byte TLV 0x1E, a 1-byte TLV 0x01
  rmnet::RuntimeSettings s{}; CHECK(!rmnet::parse_wds_current_settings(short_address_frame(), &s)); CHECK(!s.has_v4);
  rmnet::PacketStatus p{};    CHECK(!rmnet::parse_wds_packet_status(short_status_frame(), &p));
  uint32_t h; rmnet::CallEnd e{}; CHECK(!rmnet::parse_wds_start_network(decode(kWdsBind4Resp), &h, &e));  // success but no handle TLV
}
```

- [ ] **Step 2: Run `make test`.** Expected: compile failure, `rmnet/qmi_msgs.h` not found.
- [ ] **Step 3: Implement `qmi_msgs.h` and `qmi_msgs.cpp`**, with the libqmi name beside each constant.
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `21 tests, 0 failed`; `driverkit check: 3 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: builders and parsers for the QMI messages used"
```

---

### Task 4: QMAP framing and uplink aggregation

**Files:**
- Create: `core/include/rmnet/qmap.h`, `core/src/qmap.cpp`, `tests/test_qmap.cpp`

**Interfaces:**
- Consumes: `Span` from Task 1.
- Produces, in `rmnet/qmap.h`:

```cpp
namespace rmnet {
struct QmapFrame { uint8_t mux_id; bool is_command; Span payload; };   // padding already removed
enum class QmapStatus : uint8_t { Ok, End, Truncated, Bad };
QmapStatus qmap_next(Span buf, size_t* offset, QmapFrame* out);        // End at buffer end or at all-zero filler
uint8_t qmap_write_header(uint8_t hdr[4], bool command, uint8_t mux_id, size_t payload_len);  // returns pad, 0..3

class QmapAggregator {               // packs uplink packets into one USB transfer
 public:
  QmapAggregator(uint8_t* buf, size_t cap, size_t max_datagrams, size_t usb_packet_size);
  bool add(uint8_t mux_id, const uint8_t* ip, size_t len);   // false if it will not fit; the caller sends finish() first
  size_t count() const;
  size_t finish();                   // transfer length, 0 if empty; then empty again
};

enum : uint8_t { kQmapFlowDisable = 1, kQmapFlowEnable = 2 };
enum : uint8_t { kQmapCmdRequest = 0, kQmapCmdAck = 1, kQmapCmdUnsupported = 2 };
struct QmapCommand { uint8_t name; uint8_t type; };
bool   qmap_parse_command(Span payload, QmapCommand* out);              // payload must be at least 8 bytes
size_t qmap_build_command_reply(uint8_t* out, size_t cap, uint8_t mux_id, Span request_payload);
}
```

The header is four bytes: bit 7 of byte 0 is the command flag and its low six bits are the pad length; byte 1 is the mux ID; bytes 2 and 3 are the big-endian length of payload plus padding. Frames are padded to a multiple of four. In a command payload, byte 0 is the command name and the low two bits of byte 1 are the type. A reply is the request's payload with the type set to ACK for flow disable and flow enable, and to UNSUPPORTED otherwise. `finish()` never returns an exact multiple of `usb_packet_size`: when it would, it grows the last frame's padding and length by four. `add` therefore always keeps four spare bytes.

- [ ] **Step 1: Write the failing tests** in `tests/test_qmap.cpp`

```cpp
TEST(parse_single_frame) {
  auto b = hex("00 81 00 08 45 00 00 08 aa bb cc dd"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok);
  CHECK_EQ(f.mux_id, 0x81); CHECK(!f.is_command); CHECK_EQ(f.payload.len, 8u); CHECK(f.payload.data == b.data() + 4);
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::End);
}
TEST(parse_strips_padding) {
  auto b = hex("03 81 00 08 45 00 00 05 aa 00 00 00"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.payload.len, 5u);
}
TEST(parse_two_frames_then_zero_filler) {
  auto b = hex("00 81 00 04 45 00 00 04  00 82 00 04 60 00 00 00  00 00 00 00"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.mux_id, 0x81);
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.mux_id, 0x82);
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::End);
}
TEST(parse_truncated) {
  auto b = hex("00 81 00 08 45 00 00 08 aa bb"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Truncated);
  auto c = hex("00 81 00"); off = 0;
  CHECK(rmnet::qmap_next({c.data(), c.size()}, &off, &f) == rmnet::QmapStatus::Truncated);
}
TEST(parse_bad_pad) {
  auto b = hex("09 81 00 08 45 00 00 08 aa bb cc dd"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Bad);
}
TEST(write_header_pads_to_four) {
  uint8_t h[4]; CHECK_EQ(rmnet::qmap_write_header(h, false, 0x81, 1401), 3); CHECK_BYTES(h, 4, "03 81 05 7c");
  CHECK_EQ(rmnet::qmap_write_header(h, true, 0x81, 8), 0);                  CHECK_BYTES(h, 4, "80 81 00 08");
}
TEST(command_frame_and_reply) {
  auto b = hex("80 81 00 08 01 00 00 00 00 00 00 2a"); size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({b.data(), b.size()}, &off, &f) == rmnet::QmapStatus::Ok); CHECK(f.is_command);
  rmnet::QmapCommand c; CHECK(rmnet::qmap_parse_command(f.payload, &c));
  CHECK_EQ(c.name, rmnet::kQmapFlowDisable); CHECK_EQ(c.type, rmnet::kQmapCmdRequest);
  uint8_t out[32]; size_t n = rmnet::qmap_build_command_reply(out, sizeof out, 0x81, f.payload);
  CHECK_BYTES(out, n, "80 81 00 08 01 01 00 00 00 00 00 2a");
  auto u = hex("07 00 00 00 00 00 00 2a");
  n = rmnet::qmap_build_command_reply(out, sizeof out, 0x81, {u.data(), u.size()});
  CHECK_BYTES(out, n, "80 81 00 08 07 02 00 00 00 00 00 2a");
  CHECK(!rmnet::qmap_parse_command({u.data(), 4}, &c));
}
TEST(aggregator_packs_and_round_trips) {
  uint8_t buf[16384]; std::vector<uint8_t> pkt(100, 0x45);
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 1024);
  for (int i = 0; i < 3; i++) CHECK(a.add(0x81, pkt.data(), pkt.size()));
  CHECK_EQ(a.count(), 3u); size_t n = a.finish(); CHECK_EQ(n, 312u); CHECK_EQ(a.count(), 0u); CHECK_EQ(a.finish(), 0u);
  size_t off = 0; rmnet::QmapFrame f; int frames = 0;
  while (rmnet::qmap_next({buf, n}, &off, &f) == rmnet::QmapStatus::Ok) { CHECK_EQ(f.payload.len, 100u); frames++; }
  CHECK_EQ(frames, 3);
}
TEST(aggregator_rejects_when_full) {
  uint8_t buf[256]; std::vector<uint8_t> pkt(200, 0x45);
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 1024);
  CHECK(a.add(0x81, pkt.data(), pkt.size())); CHECK(!a.add(0x81, pkt.data(), pkt.size()));
  uint8_t big[4096]; rmnet::QmapAggregator c(big, sizeof big, 2, 1024);
  CHECK(c.add(0x81, pkt.data(), 10)); CHECK(c.add(0x81, pkt.data(), 10)); CHECK(!c.add(0x81, pkt.data(), 10));
}
TEST(aggregator_avoids_usb_packet_multiple) {
  uint8_t buf[4096]; std::vector<uint8_t> pkt(1020, 0x45);
  rmnet::QmapAggregator a(buf, sizeof buf, 32, 1024);
  CHECK(a.add(0x81, pkt.data(), pkt.size()));
  size_t n = a.finish(); CHECK_EQ(n, 1028u); CHECK_BYTES(buf, 4, "04 81 04 00");
  size_t off = 0; rmnet::QmapFrame f;
  CHECK(rmnet::qmap_next({buf, n}, &off, &f) == rmnet::QmapStatus::Ok); CHECK_EQ(f.payload.len, 1020u);
}
```

- [ ] **Step 2: Run `make test`.** Expected: compile failure, `rmnet/qmap.h` not found.
- [ ] **Step 3: Implement `qmap.h` and `qmap.cpp`.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `31 tests, 0 failed`; `driverkit check: 4 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: QMAP framing, uplink aggregation and command replies"
```

---

### Task 5: Connection state machine

**Files:**
- Create: `core/include/rmnet/session.h`, `core/src/session.cpp`, `tests/test_session.cpp`

**Interfaces:**
- Consumes: everything in `rmnet/qmi.h` and `rmnet/qmi_msgs.h`; `tests/captures.h`.
- Produces, in `rmnet/session.h`:

```cpp
namespace rmnet {
struct SessionConfig { uint32_t iface_number = 4; uint8_t mux_id = 0x81; uint8_t profile = 1; };
struct LinkConfig { RuntimeSettings settings; DataFormat format; };
class SessionDelegate {
 public:
  virtual void send_qmi(const uint8_t* data, size_t len) = 0;
  virtual void link_up(const LinkConfig& cfg) = 0;
  virtual void link_down() = 0;
 protected:
  ~SessionDelegate() = default;
};
enum class SessionState : uint8_t { Idle, Syncing, Configuring, Connecting, Up, Refreshing, Backoff };
enum : uint32_t { kSyncResendMs = 2000, kSyncGiveUpMs = 60000, kRequestTimeoutMs = 10000, kStartNetworkTimeoutMs = 60000 };
class Session {
 public:
  Session(const SessionConfig& cfg, SessionDelegate& delegate);
  void start(uint64_t now_ms);                                  // Idle -> Syncing
  void stop();                                                  // stops calls, releases clients, -> Idle
  void on_qmi(const uint8_t* data, size_t len, uint64_t now_ms);
  void tick(uint64_t now_ms);                                   // the host calls this at least every 250 ms
  SessionState state() const;
};
}
```

Behaviour the tests pin:

- Transaction IDs: CTL has its own 8-bit counter starting at 1. All other services share one 16-bit counter starting at 1. Neither ever uses 0.
- Bring-up sends exactly the capture's request sequence: sync, get WDA client, set data format, then for IPv4 and then IPv6: get WDS client, bind mux, set IP family, start network, get current settings. One request is outstanding at a time. A response is accepted only if its service, client, transaction ID and message ID match the outstanding request; anything else is ignored.
- `link_up` is called once, after the last family finishes, if at least one family has settings. An unusable data format, or both families failing, goes to Backoff.
- Start Network answering NoEffect (`0x001A`) counts as success with no handle.
- In Syncing, the sync request is resent every `kSyncResendMs` with a new transaction ID, and after `kSyncGiveUpMs` the state becomes Backoff. Any other request unanswered for `kRequestTimeoutMs` (Start Network: `kStartNetworkTimeoutMs`) goes to Backoff.
- Backoff waits 2000, 4000, 8000, 16000, 32000 and then 60000 ms, then starts again from sync with fresh client state. A successful `link_up` resets the delay to 2000.
- In Up, a Packet Service Status indication with status 1 from either WDS client calls `link_down` once and goes to Backoff. One with status 2 and the reconfigure flag calls `link_down`, re-reads that client's settings (state Refreshing), then calls `link_up` with the new settings.
- `stop()` in Up sends, in this order: stop network and release client for IPv6, stop network and release client for IPv4, release the WDA client. It does not wait for answers, calls `link_down` once, and goes to Idle. In any other state it releases whatever clients exist and goes to Idle without calling `link_down`.

- States: Syncing while the sync is outstanding; Configuring from the WDA client request until the data format is accepted; Connecting from the first WDS client request until `link_up`.

- [ ] **Step 1: Write the failing tests** in `tests/test_session.cpp`. `FakeModem` is a test helper implementing `SessionDelegate`: it records each sent frame (`sent`, `last()`, `last_txid()`), counts `link_up` and `link_down` (`ups`, `downs`), and keeps the last `LinkConfig` (`cfg`). Other helpers, all local to this file: `feed(session, hexText, now)` and `feed_frame(session, bytes, now)` call `on_qmi`; `bring_up_to(session, modem, lastResponse)` starts at time 0 and replays the capture's responses at time 100 up to and including the named one; `bring_up_fully` replays all of them; `failed_start_frame(client, txid)` and `no_effect_start_frame(client, txid)` build Start Network responses with errors `0x000E` and `0x001A`; `fail_v6_too` answers the IPv6 client, bind and family requests from the capture and then fails its start; `settings4_response_with_txid(txid)` is `kWdsSettings4Resp` with its transaction ID replaced.

```cpp
TEST(happy_path_brings_link_up_dual_stack) {
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  const char* script[][2] = {
    {kCtlSyncReq, kCtlSyncResp}, {kCtlGetWdaReq, kCtlGetWdaResp}, {kWdaSetFormatReq, kWdaSetFormatResp},
    {kCtlGetWds4Req, kCtlGetWds4Resp}, {kWdsBind4Req, kWdsBind4Resp}, {kWdsFamily4Req, kWdsFamily4Resp},
    {kWdsStart4Req, kWdsStart4Resp}, {kWdsSettings4Req, kWdsSettings4Resp},
    {kCtlGetWds6Req, kCtlGetWds6Resp}, {kWdsBind6Req, kWdsBind6Resp}, {kWdsFamily6Req, kWdsFamily6Resp},
    {kWdsStart6Req, kWdsStart6Resp}, {kWdsSettings6Req, kWdsSettings6Resp}};
  for (auto& step : script) { CHECK_BYTES(m.last(), step[0]); feed(s, step[1], 100); }
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1); CHECK_EQ(m.downs, 0);
  CHECK(m.cfg.settings.has_v4); CHECK(m.cfg.settings.has_v6);
  CHECK_BYTES(m.cfg.settings.v4_addr, 4, "0a 66 f6 e6"); CHECK_EQ(m.cfg.settings.mtu, 1500u);
  CHECK_EQ(m.cfg.format.dl_max_size, 31744u);
}
TEST(connected_indication_during_bring_up_is_harmless) {   // the capture has one between start and settings
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsStart4Resp);
  size_t sent = m.sent.size(); feed(s, kWdsConnected4Ind, 100);
  CHECK_EQ(m.sent.size(), sent); CHECK_EQ(m.downs, 0);
}
TEST(sync_is_resent_until_answered_then_gives_up) {
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  s.tick(1999); CHECK_EQ(m.sent.size(), 1u);
  s.tick(2000); CHECK_EQ(m.sent.size(), 2u); CHECK_EQ(m.sent[1][7], 2);      // CTL transaction ID 2
  for (uint64_t t = 4000; t <= 60000; t += 2000) s.tick(t);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.ups, 0);
}
TEST(ignores_response_with_wrong_txid) {
  FakeModem m; rmnet::Session s({}, m); s.start(0);
  auto stale = hex(kCtlSyncResp); stale[7] = 9;
  s.on_qmi(stale.data(), stale.size(), 10);
  CHECK(s.state() == rmnet::SessionState::Syncing); CHECK_EQ(m.sent.size(), 1u);
}
TEST(v6_failure_still_links_up_v4_only) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily6Resp);
  feed_frame(s, failed_start_frame(16, 8), 100);                              // client 16, transaction 8, CallFailed
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 1);
  CHECK(m.cfg.settings.has_v4); CHECK(!m.cfg.settings.has_v6);
}
TEST(start_network_no_effect_is_adopted) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily4Resp);
  feed_frame(s, no_effect_start_frame(15, 4), 100);
  CHECK_BYTES(m.last(), kWdsSettings4Req);
}
TEST(both_families_fail_backs_off_and_redials) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kWdsFamily4Resp);
  feed_frame(s, failed_start_frame(15, 4), 100);
  /* IPv6 attempt: answer client, bind, family from the capture, then fail the start */
  fail_v6_too(s, m, 100);
  CHECK(s.state() == rmnet::SessionState::Backoff); CHECK_EQ(m.ups, 0);
  size_t sent = m.sent.size(); s.tick(2099); CHECK_EQ(m.sent.size(), sent);
  s.tick(2100); CHECK(s.state() == rmnet::SessionState::Syncing);
  CHECK_EQ(m.last()[8], 0x27);                                               // a sync request went out
}
TEST(unusable_data_format_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kCtlGetWdaResp);
  auto f = hex(kWdaSetFormatResp); f[27] = 0x01;                              // link layer 1 instead of 2
  s.on_qmi(f.data(), f.size(), 100);
  CHECK(s.state() == rmnet::SessionState::Backoff);
}
TEST(request_timeout_backs_off) {
  FakeModem m; rmnet::Session s({}, m); bring_up_to(s, m, kCtlGetWdaResp);    // set data format now outstanding at t=100
  s.tick(10099); CHECK(s.state() == rmnet::SessionState::Configuring);
  s.tick(10100); CHECK(s.state() == rmnet::SessionState::Backoff);
}
TEST(disconnect_indication_takes_link_down_and_redials) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  feed(s, kWdsDisconnected4Ind, 5000);
  CHECK_EQ(m.downs, 1); CHECK(s.state() == rmnet::SessionState::Backoff);
  feed(s, kWdsDisconnected6Ind, 5001); CHECK_EQ(m.downs, 1);
}
TEST(reconfigure_indication_refreshes_settings) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m);
  auto ind = hex(kWdsConnected4Ind); ind[17] = 0x01;                          // reconfigure flag
  s.on_qmi(ind.data(), ind.size(), 5000);
  CHECK_EQ(m.downs, 1); CHECK(s.state() == rmnet::SessionState::Refreshing);
  CHECK_EQ(m.last()[9], 0x2d);                                               // get current settings on client 15
  feed_frame(s, settings4_response_with_txid(m.last_txid()), 5010);
  CHECK(s.state() == rmnet::SessionState::Up); CHECK_EQ(m.ups, 2);
}
TEST(stop_tears_down_in_capture_order) {
  FakeModem m; rmnet::Session s({}, m); bring_up_fully(s, m); size_t before = m.sent.size();
  s.stop();
  CHECK_EQ(m.sent.size(), before + 5); CHECK_EQ(m.downs, 1); CHECK(s.state() == rmnet::SessionState::Idle);
  CHECK_BYTES(m.sent[before + 0], kWdsStop6Req);    CHECK_BYTES(m.sent[before + 1], kCtlRelease6Req);
  CHECK_BYTES(m.sent[before + 2], kWdsStop4Req);    CHECK_BYTES(m.sent[before + 3], kCtlRelease4Req);
  CHECK_BYTES(m.sent[before + 4], kCtlReleaseWdaReq);
}
```

- [ ] **Step 2: Run `make test`.** Expected: compile failure, `rmnet/session.h` not found.
- [ ] **Step 3: Implement `session.h` and `session.cpp`.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `43 tests, 0 failed`; `driverkit check: 5 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: connection state machine"
```

---

### Task 6: Checksums and packet builders

**Files:**
- Create: `core/include/rmnet/ip.h`, `core/src/ip.cpp`, `tests/test_ip.cpp`

**Interfaces:**
- Consumes: nothing beyond Task 1.
- Produces, in `rmnet/ip.h`:

```cpp
namespace rmnet {
uint32_t sum16(const uint8_t* data, size_t len, uint32_t acc = 0);     // running sum of big-endian 16-bit words; an odd last byte is the high byte
uint16_t fold_checksum(uint32_t acc);                                  // ones-complement of the folded sum
uint16_t udp4_checksum(const uint8_t src[4], const uint8_t dst[4], const uint8_t* udp, size_t len);
uint16_t icmp6_checksum(const uint8_t src[16], const uint8_t dst[16], const uint8_t* icmp, size_t len);
size_t build_ipv4_header(uint8_t* out, size_t cap, uint8_t proto, const uint8_t src[4], const uint8_t dst[4], size_t payload_len, uint8_t ttl);       // 20 bytes, checksum filled, DF set, ID 0
size_t build_ipv6_header(uint8_t* out, size_t cap, uint8_t next, const uint8_t src[16], const uint8_t dst[16], size_t payload_len, uint8_t hop_limit); // 40 bytes
size_t build_icmp4_echo(uint8_t* out, size_t cap, const uint8_t src[4], const uint8_t dst[4], uint16_t id, uint16_t seq, const uint8_t* data, size_t n);   // whole IPv4 packet, TTL 64
size_t build_icmp6_echo(uint8_t* out, size_t cap, const uint8_t src[16], const uint8_t dst[16], uint16_t id, uint16_t seq, const uint8_t* data, size_t n); // whole IPv6 packet, hop limit 64
}
```

All builders return the length written, or 0 if `cap` is too small.

- [ ] **Step 1: Write the failing tests** in `tests/test_ip.cpp`

```cpp
TEST(checksum_rfc1071_example) {
  auto b = hex("00 01 f2 03 f4 f5 f6 f7");
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(b.data(), b.size())), 0x220d);
}
TEST(checksum_odd_length) {
  auto b = hex("01 02 03");                       // words 0x0102 + 0x0300 = 0x0402
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(b.data(), b.size())), 0xfbfd);
}
TEST(ipv4_header_matches_known_checksum) {         // 192.168.0.1 -> 192.168.0.199, UDP, 95 payload bytes, TTL 64
  uint8_t h[20]; const uint8_t s[4] = {192, 168, 0, 1}, d[4] = {192, 168, 0, 199};
  CHECK_EQ(rmnet::build_ipv4_header(h, sizeof h, 17, s, d, 95, 64), 20u);
  CHECK_BYTES(h, 20, "45 00 00 73 00 00 40 00 40 11 b8 61 c0 a8 00 01 c0 a8 00 c7");
  CHECK_EQ(rmnet::build_ipv4_header(h, 19, 17, s, d, 95, 64), 0u);
}
TEST(icmp4_echo_is_well_formed) {
  uint8_t p[64]; const uint8_t s[4] = {10, 102, 246, 230}, d[4] = {223, 5, 5, 5}; const uint8_t data[8] = {1,2,3,4,5,6,7,8};
  size_t n = rmnet::build_icmp4_echo(p, sizeof p, s, d, 0x1234, 7, data, 8);
  CHECK_EQ(n, 36u); CHECK_EQ(p[9], 1); CHECK_EQ(p[20], 8); CHECK_EQ(p[21], 0);
  CHECK_BYTES(p + 24, 4, "12 34 00 07");
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(p, 20)), 0);        // a valid header sums to zero
  CHECK_EQ(rmnet::fold_checksum(rmnet::sum16(p + 20, 16)), 0);
}
TEST(icmp6_echo_is_well_formed) {
  uint8_t p[96]; auto s = hex("20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 08"); auto d = hex("24 00 32 00 00 00 00 00 00 00 00 00 00 00 00 01");
  const uint8_t data[8] = {1,2,3,4,5,6,7,8};
  size_t n = rmnet::build_icmp6_echo(p, sizeof p, s.data(), d.data(), 0x1234, 7, data, 8);
  CHECK_EQ(n, 56u); CHECK_EQ(p[0] >> 4, 6); CHECK_EQ(p[6], 58); CHECK_EQ(p[7], 64); CHECK_EQ(p[40], 128);
  CHECK_BYTES(p + 4, 2, "00 10");
  uint16_t stored = (uint16_t)((p[42] << 8) | p[43]); p[42] = p[43] = 0;
  CHECK_EQ(rmnet::icmp6_checksum(s.data(), d.data(), p + 40, 16), stored);
}
TEST(udp4_checksum_validates) {                    // a UDP datagram with the checksum filled in sums, with its pseudo-header, to zero
  uint8_t u[12] = {0x00, 0x43, 0x00, 0x44, 0x00, 0x0c, 0, 0, 0xde, 0xad, 0xbe, 0xef};
  const uint8_t s[4] = {10, 0, 0, 1}, d[4] = {255, 255, 255, 255};
  uint16_t c = rmnet::udp4_checksum(s, d, u, sizeof u); u[6] = (uint8_t)(c >> 8); u[7] = (uint8_t)c;
  CHECK_EQ(rmnet::udp4_checksum(s, d, u, sizeof u), 0);
}
```

- [ ] **Step 2: Run `make test`.** Expected: compile failure, `rmnet/ip.h` not found.
- [ ] **Step 3: Implement `ip.h` and `ip.cpp`.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `49 tests, 0 failed`; `driverkit check: 6 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: checksums and IPv4, IPv6 and ICMP builders"
```

---

### Task 7: Ethernet emulation: addresses, wrapping, ARP

**Files:**
- Create: `core/include/rmnet/ethernet.h`, `core/src/ethernet.cpp`, `tests/test_ethernet.cpp`, `tests/frames.h`

**Interfaces:**
- Consumes: `Span` (Task 1), `RuntimeSettings` (Task 3).
- Produces, in `rmnet/ethernet.h`:

```cpp
namespace rmnet {
struct MacPair { uint8_t host[6]; uint8_t router[6]; };
MacPair derive_macs(const char* usb_serial);
enum class TxAction : uint8_t { Forward, Reply, Drop };
struct TxResult { TxAction action; Span ip; size_t reply_len; };   // Forward: ip is the packet inside the frame. Reply: reply_len bytes were written
class EthernetEmulator {
 public:
  explicit EthernetEmulator(const MacPair& macs);
  void set_link(const RuntimeSettings* settings);                  // copies; nullptr means the link is down
  size_t wrap_rx(const uint8_t* ip, size_t len, uint8_t* out, size_t cap);              // frame length; 0 means drop
  TxResult handle_tx(const uint8_t* frame, size_t len, uint8_t* reply, size_t reply_cap);
  size_t make_router_advert(uint8_t* out, size_t cap);             // Task 9 implements it; until then it returns 0
};
}
```

- Produces, in `tests/frames.h`: helpers that build test frames: `eth(dst, src, ethertype, payload)`, `arp_request(sender_mac, sender_ip, target_ip)`, `ipv4_udp(src, dst, sport, dport, payload)`, and `link_settings()` returning the `RuntimeSettings` parsed from `kWdsSettings4Resp` and `kWdsSettings6Resp`. Tasks 8 and 9 add to this file.

Rules:

- `derive_macs`: FNV-1a 64-bit over the serial's bytes (offset `0xcbf29ce484222325`, prime `0x100000001b3`). With hash `h`, host is `02, h>>32, h>>24, h>>16, h>>8, h & 0xfe` and router is the same with the last byte's low bit set.
- `wrap_rx`: the first nibble selects EtherType `0x0800` or `0x86DD`; anything else is dropped. Destination is the host MAC, source the router MAC.
- `handle_tx`: frames shorter than 14 bytes, or with an EtherType other than `0x0800`, `0x86DD`, `0x0806`, are dropped. With the link down, everything is dropped. A frame whose reply would not fit in the reply buffer is dropped.
- IPv4: destinations `255.255.255.255` and `224.0.0.0/4` are dropped. Task 8 adds DHCP ahead of this rule. Everything else is forwarded.
- IPv6: forwarded in this task. Task 9 adds neighbour discovery and the multicast rule.
- ARP: an Ethernet/IPv4 request gets a reply giving the router MAC for the requested address, whatever that address is. No reply if the sender IP is `0.0.0.0` (a probe), if sender and target IP are equal (an announcement), or if the link has no IPv4 address.

- [ ] **Step 1: Write the failing tests** in `tests/test_ethernet.cpp`

```cpp
TEST(macs_are_stable_local_and_distinct) {
  auto m = rmnet::derive_macs("bfeed1a5");
  CHECK_BYTES(m.host, 6, "02 68 7a 43 12 f6"); CHECK_BYTES(m.router, 6, "02 68 7a 43 12 f7");
  CHECK_BYTES(rmnet::derive_macs("other").host, 6, "02 61 c2 56 2a 54");
}
TEST(wrap_rx_adds_header) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  auto p4 = hex("45 00 00 14 00 00 40 00 40 01 00 00 df 05 05 05 0a 66 f6 e6"); uint8_t out[64];
  CHECK_EQ(e.wrap_rx(p4.data(), p4.size(), out, sizeof out), 34u);
  CHECK_BYTES(out, 14, "02 68 7a 43 12 f6 02 68 7a 43 12 f7 08 00"); CHECK_BYTES(out + 14, 20, "45 00 00 14 00 00 40 00 40 01 00 00 df 05 05 05 0a 66 f6 e6");
  std::vector<uint8_t> p6(40, 0); p6[0] = 0x60; p6[6] = 17;
  CHECK_EQ(e.wrap_rx(p6.data(), p6.size(), out, sizeof out), 54u); CHECK_BYTES(out + 12, 2, "86 dd");
}
TEST(wrap_rx_drops_garbage) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  uint8_t out[64]; auto bad = hex("30 00 00 00");
  CHECK_EQ(e.wrap_rx(bad.data(), bad.size(), out, sizeof out), 0u);
  CHECK_EQ(e.wrap_rx(bad.data(), 0, out, sizeof out), 0u);
  auto p4 = hex("45 00 00 14 00 00 40 00 40 01 00 00 df 05 05 05 0a 66 f6 e6");
  CHECK_EQ(e.wrap_rx(p4.data(), p4.size(), out, 20), 0u);
}
TEST(tx_ipv4_unicast_is_forwarded) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s);
  auto f = ipv4_udp("10.102.246.230", "1.1.1.1", 5000, 53, hex("aa bb")); uint8_t r[128];
  auto t = e.handle_tx(f.data(), f.size(), r, sizeof r);
  CHECK(t.action == rmnet::TxAction::Forward); CHECK(t.ip.data == f.data() + 14); CHECK_EQ(t.ip.len, f.size() - 14);
}
TEST(tx_drops_what_cannot_go_upstream) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto lldp = eth("01 80 c2 00 00 0e", "02 68 7a 43 12 f6", 0x88cc, hex("00 00"));
  CHECK(e.handle_tx(lldp.data(), lldp.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(lldp.data(), 10, r, sizeof r).action == rmnet::TxAction::Drop);
  auto bcast = ipv4_udp("10.102.246.230", "255.255.255.255", 5000, 9999, hex("aa"));
  CHECK(e.handle_tx(bcast.data(), bcast.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto mdns = ipv4_udp("10.102.246.230", "224.0.0.251", 5353, 5353, hex("aa"));
  CHECK(e.handle_tx(mdns.data(), mdns.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(arp_request_gets_router_mac) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  for (const char* target : {"10.102.246.229", "8.8.8.8"}) {
    auto q = arp_request("02 68 7a 43 12 f6", "10.102.246.230", target);
    auto t = e.handle_tx(q.data(), q.size(), r, sizeof r);
    CHECK(t.action == rmnet::TxAction::Reply); CHECK_EQ(t.reply_len, 42u);
    CHECK_BYTES(r, 14, "02 68 7a 43 12 f6 02 68 7a 43 12 f7 08 06");
    CHECK_BYTES(r + 14, 8, "00 01 08 00 06 04 00 02");
    CHECK_BYTES(r + 22, 6, "02 68 7a 43 12 f7"); CHECK(memcmp(r + 28, q.data() + 38, 4) == 0);   // sender IP = requested IP
    CHECK_BYTES(r + 32, 6, "02 68 7a 43 12 f6"); CHECK_BYTES(r + 38, 4, "0a 66 f6 e6");
  }
}
TEST(arp_probe_and_announcement_get_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[128];
  auto probe = arp_request("02 68 7a 43 12 f6", "0.0.0.0", "10.102.246.230");
  CHECK(e.handle_tx(probe.data(), probe.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto announce = arp_request("02 68 7a 43 12 f6", "10.102.246.230", "10.102.246.230");
  CHECK(e.handle_tx(announce.data(), announce.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(arp_while_link_down_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); uint8_t r[128];
  auto q = arp_request("02 68 7a 43 12 f6", "10.102.246.230", "10.102.246.229");
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto s = link_settings(); e.set_link(&s); e.set_link(nullptr);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
```

- [ ] **Step 2: Run `make test`.** Expected: compile failure, `rmnet/ethernet.h` not found.
- [ ] **Step 3: Implement `ethernet.h` and `ethernet.cpp`.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `57 tests, 0 failed`; `driverkit check: 7 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: Ethernet emulation with address derivation, wrapping and ARP"
```

---

### Task 8: DHCP answers

**Files:**
- Create: `core/src/dhcp.cpp`, `tests/test_dhcp.cpp`
- Modify: `core/src/ethernet.cpp` (call the DHCP handler before the IPv4 broadcast rule), `core/include/rmnet/ethernet.h` (private declarations only), `tests/frames.h`

**Interfaces:**
- Consumes: `EthernetEmulator` (Task 7), `ip.h` builders and checksums (Task 6).
- Produces: no new public API. `handle_tx` now returns `Reply` for DHCP. `tests/frames.h` gains `dhcp_client(type, xid, requested_ip_or_empty, ciaddr_or_empty)` building a full Ethernet frame from the host MAC to broadcast, UDP 68 to 67, and `struct DhcpReply` plus `parse_dhcp_reply(bytes, len)` exposing `op`, `xid`, `yiaddr`, `chaddr`, `type`, `server_id`, `lease`, `mask`, `router`, `dns` (vector), `mtu`, `ip_src`, `ip_dst`, and `checksums_ok`.

Rules:

- A DHCP frame is IPv4 UDP from port 68 to port 67 with BOOTP op 1 and the magic cookie `63 82 53 63`. Anything malformed, or without option 53, is dropped.
- With the link down, or with no IPv4 address, DHCP frames are dropped.
- DISCOVER gets OFFER. REQUEST gets ACK when option 50 equals our address, or when option 50 is absent and `ciaddr` equals our address; otherwise NAK. INFORM gets ACK with `yiaddr` zero and no lease option. Other types are dropped.
- Every reply: Ethernet from the router MAC to the host MAC; IPv4 from the gateway address to `255.255.255.255`, TTL 64; UDP 67 to 68 with a valid checksum; BOOTP op 2, the request's `xid` and `chaddr`, `yiaddr` our address (zero in a NAK).
- Options in OFFER and ACK, in this order: 53 type, 54 server ID (the gateway), 51 lease `3600`, 1 mask, 3 router (the gateway), 6 DNS servers, 26 MTU, 255. A NAK carries only 53, 54 and 255.

- [ ] **Step 1: Write the failing tests** in `tests/test_dhcp.cpp`

```cpp
TEST(discover_gets_offer_with_modem_settings) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(1, 0x12345678, "", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK(t.action == rmnet::TxAction::Reply);
  CHECK_BYTES(r, 14, "02 68 7a 43 12 f6 02 68 7a 43 12 f7 08 00");
  auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK(d.checksums_ok); CHECK_EQ(d.ip_src, "10.102.246.229"); CHECK_EQ(d.ip_dst, "255.255.255.255");
  CHECK_EQ(d.op, 2); CHECK_EQ(d.xid, 0x12345678u); CHECK_EQ(d.type, 2); CHECK_EQ(d.yiaddr, "10.102.246.230");
  CHECK_BYTES(d.chaddr, 6, "02 68 7a 43 12 f6");
  CHECK_EQ(d.server_id, "10.102.246.229"); CHECK_EQ(d.lease, 3600u); CHECK_EQ(d.mask, "255.255.255.252");
  CHECK_EQ(d.router, "10.102.246.229"); CHECK_EQ(d.dns.size(), 2u); CHECK_EQ(d.dns[0], "203.0.113.193"); CHECK_EQ(d.mtu, 1500);
}
TEST(request_for_our_address_gets_ack) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 7, "10.102.246.230", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "10.102.246.230"); CHECK_EQ(d.lease, 3600u);
}
TEST(renewal_with_ciaddr_gets_ack) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 8, "", "10.102.246.230");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK_EQ(parse_dhcp_reply(r, t.reply_len).type, 5);
}
TEST(request_for_other_address_gets_nak) {          // macOS re-asking for its old ECM lease
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(3, 9, "192.168.225.141", "");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 6); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.lease, 0u); CHECK_EQ(d.server_id, "10.102.246.229");
}
TEST(inform_gets_ack_without_lease) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(8, 10, "", "10.102.246.230");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); auto d = parse_dhcp_reply(r, t.reply_len);
  CHECK_EQ(d.type, 5); CHECK_EQ(d.yiaddr, "0.0.0.0"); CHECK_EQ(d.lease, 0u); CHECK_EQ(d.dns.size(), 2u);
}
TEST(dhcp_while_link_down_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); uint8_t r[600];
  auto q = dhcp_client(1, 1, "", "");
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto s = link_settings(); s.has_v4 = false; e.set_link(&s);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(malformed_dhcp_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[600];
  auto q = dhcp_client(1, 1, "", "");
  auto no_cookie = q; no_cookie[14 + 20 + 8 + 236] ^= 0xff;
  CHECK(e.handle_tx(no_cookie.data(), no_cookie.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  CHECK(e.handle_tx(q.data(), 14 + 20 + 8 + 100, r, sizeof r).action == rmnet::TxAction::Drop);      // cut inside BOOTP
  auto release = dhcp_client(7, 1, "", "10.102.246.230");
  CHECK(e.handle_tx(release.data(), release.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  uint8_t small[100]; CHECK(e.handle_tx(q.data(), q.size(), small, sizeof small).action == rmnet::TxAction::Drop);  // reply buffer too small
}
```

- [ ] **Step 2: Run `make test`.** Expected: the seven new tests fail (broadcast frames are dropped).
- [ ] **Step 3: Implement `dhcp.cpp` and wire it into `handle_tx`.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `64 tests, 0 failed`; `driverkit check: 8 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: answer DHCP from the modem's runtime settings"
```

---

### Task 9: IPv6 neighbour discovery

**Files:**
- Create: `core/src/ndp.cpp`, `tests/test_ndp.cpp`
- Modify: `core/src/ethernet.cpp` (IPv6 handling in `handle_tx` and `wrap_rx`, `make_router_advert`), `core/include/rmnet/ethernet.h` (private declarations only), `tests/frames.h`

**Interfaces:**
- Consumes: `EthernetEmulator` (Task 7), `ip.h` (Task 6).
- Produces: `make_router_advert` now works. `tests/frames.h` gains `router_solicit(src_ip)`, `neighbour_solicit(src_ip, target_ip)`, `icmp6(src, dst, type, body)`, and `struct NdReply` plus `parse_nd_reply(bytes, len)` exposing `eth_dst`, `ip_src`, `ip_dst`, `hop_limit`, `type`, `checksum_ok`, and for adverts `cur_hop_limit`, `flags`, `router_lifetime`, `source_lla`, `mtu`, `prefix`, `prefix_len`, `prefix_flags`, `valid_lifetime`, `preferred_lifetime`, `rdnss` (vector), `rdnss_lifetime`, `target`, `na_flags`, `target_lla`.

Rules:

- The router's address is `fe80::1`. Every message the emulator sends has hop limit 255 and a valid ICMPv6 checksum.
- Router solicitation (type 133) from the host, when the link has IPv6: reply with a router advertisement (type 134). IPv6 source `fe80::1`; destination the solicitation's source, or `ff02::1` if that source is `::`. Ethernet destination is the host MAC. Fields: current hop limit 64, flags 0, router lifetime 1800, reachable and retransmit timers 0. Options in this order: source link-layer address (router MAC); MTU; prefix information with length 64, flags `0xC0` (on-link and autonomous), valid lifetime 7200, preferred lifetime 3600, and the first 64 bits of the modem's address; RDNSS (type 25) with lifetime 1800 and the modem's IPv6 DNS servers, omitted if there are none.
- `make_router_advert` builds the same advertisement, unsolicited: IPv6 destination `ff02::1`, Ethernet destination `33:33:00:00:00:01`. It returns 0 when the link is down or has no IPv6.
- Neighbour solicitation (type 135): if its IPv6 source is `::` it is a duplicate-address check and is dropped. Otherwise reply with a neighbour advertisement (type 136) to the solicitation's source: target copied from the solicitation, flags `0xE0`, target link-layer address option with the router MAC, IPv6 source equal to the target.
- Any other packet to a multicast destination (`ff00::/8`) is dropped. Everything else is forwarded.
- With the link down, or with no IPv6, all IPv6 frames from the host are dropped.
- `wrap_rx` drops router advertisements arriving from the network (next header 58, type 134).

- [ ] **Step 1: Write the failing tests** in `tests/test_ndp.cpp`

```cpp
static const char* kHostLL = "fe80::1839:e0b6:5dbb:6797";
static const char* kHostGlobal = "2001:db8:8af4:b260:1111:2222:3333:4444";

TEST(router_solicit_gets_router_advert) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = router_solicit(kHostLL);
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK(t.action == rmnet::TxAction::Reply);
  auto d = parse_nd_reply(r, t.reply_len);
  CHECK(d.checksum_ok); CHECK_EQ(d.type, 134); CHECK_EQ(d.hop_limit, 255);
  CHECK_BYTES(d.eth_dst, 6, "02 68 7a 43 12 f6"); CHECK_EQ(d.ip_src, "fe80::1"); CHECK_EQ(d.ip_dst, kHostLL);
  CHECK_EQ(d.cur_hop_limit, 64); CHECK_EQ(d.flags, 0); CHECK_EQ(d.router_lifetime, 1800);
  CHECK_BYTES(d.source_lla, 6, "02 68 7a 43 12 f7"); CHECK_EQ(d.mtu, 1500u);
  CHECK_EQ(d.prefix, "2001:db8:8af4:b260::"); CHECK_EQ(d.prefix_len, 64); CHECK_EQ(d.prefix_flags, 0xc0);
  CHECK_EQ(d.valid_lifetime, 7200u); CHECK_EQ(d.preferred_lifetime, 3600u);
  CHECK_EQ(d.rdnss.size(), 2u); CHECK_EQ(d.rdnss[0], "2001:db8:2000:0:270::1"); CHECK_EQ(d.rdnss_lifetime, 1800u);
}
TEST(router_solicit_from_unspecified_goes_to_all_nodes) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = router_solicit("::");
  auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK_EQ(parse_nd_reply(r, t.reply_len).ip_dst, "ff02::1");
}
TEST(unsolicited_router_advert) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); uint8_t r[256];
  CHECK_EQ(e.make_router_advert(r, sizeof r), 0u);
  auto s = link_settings(); e.set_link(&s);
  size_t n = e.make_router_advert(r, sizeof r); auto d = parse_nd_reply(r, n);
  CHECK(d.checksum_ok); CHECK_EQ(d.type, 134); CHECK_EQ(d.ip_dst, "ff02::1"); CHECK_BYTES(d.eth_dst, 6, "33 33 00 00 00 01");
  s.has_v6 = false; e.set_link(&s); CHECK_EQ(e.make_router_advert(r, sizeof r), 0u);
}
TEST(neighbour_solicit_gets_advert_with_router_mac) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  for (const char* target : {"fe80::1", "2001:db8:8af4:b260:a089:88dc:137d:6253"}) {
    auto q = neighbour_solicit(kHostGlobal, target);
    auto t = e.handle_tx(q.data(), q.size(), r, sizeof r); CHECK(t.action == rmnet::TxAction::Reply);
    auto d = parse_nd_reply(r, t.reply_len);
    CHECK(d.checksum_ok); CHECK_EQ(d.type, 136); CHECK_EQ(d.hop_limit, 255); CHECK_EQ(d.na_flags, 0xe0);
    CHECK_EQ(d.target, target); CHECK_EQ(d.ip_src, target); CHECK_EQ(d.ip_dst, kHostGlobal);
    CHECK_BYTES(d.target_lla, 6, "02 68 7a 43 12 f7"); CHECK_BYTES(d.eth_dst, 6, "02 68 7a 43 12 f6");
  }
}
TEST(dad_solicit_gets_no_answer) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = neighbour_solicit("::", kHostGlobal);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(rs_without_ipv6_link_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); s.has_v6 = false; e.set_link(&s); uint8_t r[256];
  auto q = router_solicit(kHostLL);
  CHECK(e.handle_tx(q.data(), q.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto ns = neighbour_solicit(kHostGlobal, "fe80::1");
  CHECK(e.handle_tx(ns.data(), ns.size(), r, sizeof r).action == rmnet::TxAction::Drop);
}
TEST(ipv6_multicast_dropped_unicast_forwarded) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto mld = icmp6(kHostLL, "ff02::16", 143, hex("00 00 00 00"));
  CHECK(e.handle_tx(mld.data(), mld.size(), r, sizeof r).action == rmnet::TxAction::Drop);
  auto echo = icmp6(kHostGlobal, "2400:3200::1", 128, hex("12 34 00 01"));
  auto t = e.handle_tx(echo.data(), echo.size(), r, sizeof r);
  CHECK(t.action == rmnet::TxAction::Forward); CHECK_EQ(t.ip.len, echo.size() - 14);
}
TEST(truncated_nd_dropped) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t r[256];
  auto q = neighbour_solicit(kHostGlobal, "fe80::1");
  CHECK(e.handle_tx(q.data(), 14 + 40 + 10, r, sizeof r).action == rmnet::TxAction::Drop);          // cut inside the solicitation
  uint8_t tiny[40]; auto rs = router_solicit(kHostLL);
  CHECK(e.handle_tx(rs.data(), rs.size(), tiny, sizeof tiny).action == rmnet::TxAction::Drop);      // reply buffer too small
}
TEST(router_advert_from_network_dropped_on_rx) {
  rmnet::EthernetEmulator e(rmnet::derive_macs("bfeed1a5")); auto s = link_settings(); e.set_link(&s); uint8_t out[256];
  auto ra = icmp6("fe80::a089:88dc:137d:6253", "ff02::1", 134, hex("40 00 07 08 00 00 00 00 00 00 00 00"));
  CHECK_EQ(e.wrap_rx(ra.data() + 14, ra.size() - 14, out, sizeof out), 0u);
  auto echo = icmp6("2400:3200::1", kHostGlobal, 129, hex("12 34 00 01"));
  CHECK_EQ(e.wrap_rx(echo.data() + 14, echo.size() - 14, out, sizeof out), echo.size());
}
```

- [ ] **Step 2: Run `make test`.** Expected: the nine new tests fail.
- [ ] **Step 3: Implement `ndp.cpp` and wire it into `ethernet.cpp`.**
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: `73 tests, 0 failed`; `driverkit check: 9 files ok`.
- [ ] **Step 5: Commit**

```bash
git add -A && git commit -m "feat: answer IPv6 router and neighbour solicitations"
```

---

### Task 10: Harness USB transport and probe

This task needs the modem attached in QMI mode and nothing else holding interface 4. It has no unit tests; its check is a run against the modem.

**Files:**
- Create: `harness/usb_transport.h`, `harness/usb_transport.mm`, `harness/main.mm`
- Modify: `Makefile` (target `harness` building `build/rmnet-harness` from `harness/*.mm` and the Core objects, linking `IOUSBHost`, `IOKit`, `Foundation`), `README.md`

**Interfaces:**
- Consumes: `build_ctl_sync`, `qmi_decode`, `qmi_result` from Core.
- Produces, in `harness/usb_transport.h`:

```cpp
class UsbTransport {
 public:
  using Handler = std::function<void(const uint8_t* data, size_t len)>;
  bool open(std::string* error);            // device 2c7c:0801, the interface with class, subclass and protocol 0xff
  uint8_t interface_number() const; uint8_t bulk_in() const; uint8_t bulk_out() const; uint8_t interrupt_in() const;
  size_t bulk_packet_size() const;
  std::string serial() const;               // the USB serial number string
  bool send_control(const uint8_t* data, size_t len);     // CDC SEND_ENCAPSULATED_COMMAND
  void start_control(Handler on_message);   // one call per QMUX message, on the main queue
  void start_bulk(size_t read_size, Handler on_transfer);  // keeps 8 reads posted; one call per completed transfer, on the main queue
  bool write_bulk(const uint8_t* data, size_t len);        // returns when the transfer completes
  void close();
};
```

Behaviour of the transport:

- `open` finds the interface by its descriptor and never opens another interface. It sends `SET_CONTROL_LINE_STATE` (request type `0x21`, request `0x22`, value 1, index the interface number), then reads and discards encapsulated responses until none is left, 64 at most.
- Control messages go out with request type `0x21`, request `0x00`; responses are read with `0xA1`, `0x01`, length 16384; both use the interface number as index.
- A completed interrupt read whose first two bytes are `A1 01` means a response is waiting. The transport then reads responses until one read returns nothing, and re-arms the interrupt read. The interrupt read buffer is exactly the endpoint's packet size.
- IOUSBHost raises Objective-C exceptions from some failing calls. Every IOUSBHost call is wrapped so a failure is returned, never thrown.
- Produces the command `rmnet-harness probe [-v]`. It prints `interface 4, bulk in 0x8e, bulk out 0x0f, interrupt 0x88, packet size 1024, serial bfeed1a5`, sends one sync, and prints `sync ok` and exits 0 on a successful response, or prints `sync: no answer` and exits 1 after 10 seconds. With `-v` it prints every control message as hex, prefixed `>>` or `<<`.

- [ ] **Step 1: Implement the transport, the `probe` command and the Makefile target.**
- [ ] **Step 2: Run `make harness && ./build/rmnet-harness probe -v`.** Expected: the interface line above, `>> 01 0b 00 00 00 00 00 01 27 00 00 00`, a `<<` line beginning `01 12 00 80 00 00 01 01 27 00`, then `sync ok`, exit 0, with no `sudo`.
- [ ] **Step 3: Run it twice more in a row.** Expected: `sync ok` each time; a second run must not be confused by anything the first left behind.
- [ ] **Step 4: Run `make test` and `make check-driverkit`.** Expected: unchanged from Task 9.
- [ ] **Step 5: Add the harness to `README.md`** (how to build it, that the modem must be in QMI mode, that it needs no root), then commit

```bash
git add -A && git commit -m "feat: harness USB transport and probe command"
```

---

### Task 11: Harness connect and ping

This task needs the modem attached in QMI mode with a working SIM.

**Files:**
- Modify: `harness/main.mm`, `README.md`

**Interfaces:**
- Consumes: `UsbTransport` (Task 10); `Session`, `SessionDelegate`, `LinkConfig` (Task 5); `QmapAggregator`, `qmap_next`, `qmap_parse_command`, `qmap_build_command_reply` (Task 4); `build_icmp4_echo`, `build_icmp6_echo` (Task 6).
- Produces two commands. Both drive `Session` from a 100 ms timer on the main queue, feed it every control message, and call `Session::stop()` before exiting, so no call or client is left on the modem.
  - `rmnet-harness connect [-v]`: prints `link up`, then one line each for the IPv4 address with mask and gateway, the IPv6 address with prefix length, the DNS servers, and the MTU; then stops and exits 0. Exits 1 with `no link after 90 s` otherwise.
  - `rmnet-harness ping [-6] [-c COUNT] ADDRESS`: after link up, starts bulk reads sized to the granted downlink size, then once a second sends an echo request (default count 3) built by Core, wrapped by `QmapAggregator` with mux `0x81`. The IPv4 source is the modem's IPv4 address and the IPv6 source is the modem's IPv6 address. For each received transfer it walks the frames with `qmap_next`: a command frame gets the reply from `qmap_build_command_reply`; a data frame that is an echo reply with our identifier prints `reply from ADDRESS: seq=N time=T ms`. It ends with `COUNT sent, M received`, and exits 0 if M is at least 1.

- [ ] **Step 1: Implement `connect`.**
- [ ] **Step 2: Run `./build/rmnet-harness connect`.** Expected: `link up`, an IPv4 line in `10.0.0.0/8`, an IPv6 line beginning `2001:db8:`, a DNS line containing `203.0.113.193`, `mtu 1500`, exit 0.
- [ ] **Step 3: Implement `ping`.**
- [ ] **Step 4: Run `./build/rmnet-harness ping 223.5.5.5`.** Expected: at least one `reply from 223.5.5.5` line, `3 sent, 3 received` or close to it, exit 0.
- [ ] **Step 5: Run `./build/rmnet-harness ping -6 2400:3200::1`.** Expected: at least one reply line, exit 0.
- [ ] **Step 6: Run `./build/rmnet-harness connect` once more.** Expected: `link up` again, which shows the earlier runs left nothing behind.
- [ ] **Step 7: Run `make test` and `make check-driverkit`.** Expected: `73 tests, 0 failed`; `driverkit check: 9 files ok`.
- [ ] **Step 8: Document both commands in `README.md`, then commit**

```bash
git add -A && git commit -m "feat: harness connect and ping through the real modem"
```

---

## After this plan

The driver (through the throughput gate) and then recovery and the host app are separate plans, written once this one is done, because their details depend on what the harness shows on the real modem.

The DHCP and neighbour-discovery tests here use hand-built frames. The spec asks for real macOS exchanges as fixtures; capturing them needs root, so that check moves to the driver plan, where the driver can log the frames macOS actually sends.
