#include "rmnet/qmi_msgs.h"

#include <string.h>

namespace rmnet {

namespace {

// CTL "Allocate CID" and "Release CID".
constexpr uint8_t kTlvCtlService = 0x01;     // libqmi: CTL "Allocate CID" input "Service"
constexpr uint8_t kTlvCtlAllocInfo = 0x01;   // libqmi: CTL "Allocate CID" output "Allocation Info"
constexpr uint8_t kTlvCtlReleaseInfo = 0x01; // libqmi: CTL "Release CID" input "Release Info"

// WDA "Set Data Format" request.
constexpr uint8_t kTlvWdaQosFormat = 0x10;      // libqmi: "QoS Format"
constexpr uint8_t kTlvWdaLinkLayer = 0x11;      // libqmi: "Link Layer Protocol"
constexpr uint8_t kTlvWdaUlAgg = 0x12;          // libqmi: "Uplink Data Aggregation Protocol"
constexpr uint8_t kTlvWdaDlAgg = 0x13;          // libqmi: "Downlink Data Aggregation Protocol"
constexpr uint8_t kTlvWdaDlMaxDatagrams = 0x15; // libqmi: "Downlink Data Aggregation Max Datagrams"
constexpr uint8_t kTlvWdaDlMaxSize = 0x16;      // libqmi: "Downlink Data Aggregation Max Size"
constexpr uint8_t kTlvWdaEndpoint = 0x17;       // libqmi: "Endpoint Info"
constexpr uint8_t kTlvWdaUlMaxDatagramsIn = 0x1B; // libqmi: "Uplink Data Aggregation Max Datagrams"
constexpr uint8_t kTlvWdaUlMaxSizeIn = 0x1C;      // libqmi: "Uplink Data Aggregation Max Size"
// WDA "Set Data Format" response: 0x11 to 0x16 as in the request, then the uplink limits.
constexpr uint8_t kTlvWdaUlMaxDatagramsOut = 0x17; // libqmi: "Uplink Data Aggregation Max Datagrams"
constexpr uint8_t kTlvWdaUlMaxSizeOut = 0x18;      // libqmi: "Uplink Data Aggregation Max Size"

constexpr uint32_t kLinkLayerRawIp = 2;       // libqmi: QMI_WDA_LINK_LAYER_PROTOCOL_RAW_IP
constexpr uint32_t kAggQmap = 5;              // libqmi: QMI_WDA_DATA_AGGREGATION_PROTOCOL_QMAP
constexpr uint32_t kEndpointHsusb = 2;        // libqmi: QMI_DATA_ENDPOINT_TYPE_HSUSB
constexpr uint32_t kDlMaxDatagrams = 32;
constexpr uint32_t kDlMaxSize = 31744;
constexpr uint32_t kUlMaxDatagrams = 32;
constexpr uint32_t kUlMaxSize = 16384;
constexpr uint32_t kMinUsableDlSize = 2048;

// WDS "Bind Mux Data Port".
constexpr uint8_t kTlvWdsBindEndpoint = 0x10;   // libqmi: "Endpoint Info"
constexpr uint8_t kTlvWdsBindMuxId = 0x11;      // libqmi: "Mux ID"
constexpr uint8_t kTlvWdsBindClientType = 0x13; // libqmi: "Client Type"
constexpr uint32_t kClientTypeTethered = 1;     // libqmi: QMI_WDS_CLIENT_TYPE_TETHERED

// WDS "Set IP Family".
constexpr uint8_t kTlvWdsFamilyPreference = 0x01; // libqmi: "Preference"

// WDS "Start Network" and "Stop Network".
constexpr uint8_t kTlvWdsStartFamily = 0x19;   // libqmi: "IP Family Preference"
constexpr uint8_t kTlvWdsStartProfile = 0x31;  // libqmi: "Profile Index 3GPP"
constexpr uint8_t kTlvWdsHandle = 0x01;        // libqmi: "Packet Data Handle"
constexpr uint8_t kTlvWdsCallEnd = 0x10;       // libqmi: "Call End Reason"
constexpr uint8_t kTlvWdsVerboseCallEnd = 0x11; // libqmi: "Verbose Call End Reason"

// WDS "Get Current Settings".
constexpr uint8_t kTlvWdsRequestedSettings = 0x10; // libqmi: "Requested Settings"
// libqmi QmiWdsRequestedSettings: PROFILE_ID | PDP_TYPE | APN_NAME | DNS_ADDRESS | IP_ADDRESS |
// GATEWAY_INFO | PCSCF_ADDRESS | PCSCF_SERVER_ADDRESS_LIST | MTU | IP_FAMILY, as captured.
constexpr uint32_t kRequestedSettings = 0x0000AF1D;
constexpr uint8_t kTlvV4DnsPrimary = 0x15;   // libqmi: "Primary IPv4 DNS Address"
constexpr uint8_t kTlvV4DnsSecondary = 0x16; // libqmi: "Secondary IPv4 DNS Address"
constexpr uint8_t kTlvV4Addr = 0x1E;         // libqmi: "IPv4 Address"
constexpr uint8_t kTlvV4Gateway = 0x20;      // libqmi: "IPv4 Gateway Address"
constexpr uint8_t kTlvV4Mask = 0x21;         // libqmi: "IPv4 Gateway Subnet Mask"
constexpr uint8_t kTlvV6Addr = 0x25;         // libqmi: "IPv6 Address"
constexpr uint8_t kTlvV6Gateway = 0x26;      // libqmi: "IPv6 Gateway Address"
constexpr uint8_t kTlvV6DnsPrimary = 0x27;   // libqmi: "IPv6 Primary DNS Address"
constexpr uint8_t kTlvV6DnsSecondary = 0x28; // libqmi: "IPv6 Secondary DNS Address"
constexpr uint8_t kTlvMtu = 0x29;            // libqmi: "MTU"

// WDS "Packet Service Status" indication.
constexpr uint8_t kTlvWdsConnectionStatus = 0x01; // libqmi: "Connection Status"
constexpr uint8_t kTlvWdsIpFamily = 0x12;         // libqmi: "IP Family"

QmiHeader ctl_request(uint8_t txid, uint16_t msg_id) {
  return {QmiService::CTL, 0, QmiKind::Request, txid, msg_id};
}

QmiHeader service_request(QmiService service, uint8_t client, uint16_t txid, uint16_t msg_id) {
  return {service, client, QmiKind::Request, txid, msg_id};
}

// Endpoint Info: u32le endpoint type, u32le interface number.
void tlv_endpoint(QmiBuilder* b, uint8_t type, uint32_t iface_number) {
  uint8_t v[8];
  Writer w(v, sizeof v);
  w.u32le(kEndpointHsusb);
  w.u32le(iface_number);
  b->tlv(type, v, sizeof v);
}

bool response_ok(const QmiMessage& m) {
  QmiResult r = qmi_result(m);
  return r.present && r.ok;
}

// Outcome of looking up a TLV with a fixed minimum size.
enum class Tlv { Absent, Short, Found };

Tlv find_sized(const QmiMessage& m, uint8_t type, size_t min_len, Span* v) {
  if (!qmi_find_tlv(m.tlvs, type, v)) return Tlv::Absent;
  return v->len < min_len ? Tlv::Short : Tlv::Found;
}

// Reads an optional u32le TLV into *out (0 when absent). False if present but short.
bool optional_u32(const QmiMessage& m, uint8_t type, uint32_t* out) {
  Span v;
  switch (find_sized(m, type, 4, &v)) {
    case Tlv::Absent:
      *out = 0;
      return true;
    case Tlv::Short:
      return false;
    case Tlv::Found:
      break;
  }
  *out = Reader(v.data, v.len).u32le();
  return true;
}

// Reads an optional IPv4 address TLV, a u32le, into network byte order. *found reports presence.
bool optional_v4(const QmiMessage& m, uint8_t type, uint8_t out[4], bool* found) {
  Span v;
  Tlv t = find_sized(m, type, 4, &v);
  *found = t == Tlv::Found;
  if (t != Tlv::Found) return t == Tlv::Absent;
  for (int i = 0; i < 4; ++i) out[i] = v.data[3 - i];
  return true;
}

// Reads an optional TLV of at least `n` bytes, copying the first `n`. *found reports presence.
bool optional_bytes(const QmiMessage& m, uint8_t type, size_t n, uint8_t* out, bool* found) {
  Span v;
  Tlv t = find_sized(m, type, n, &v);
  *found = t == Tlv::Found;
  if (t != Tlv::Found) return t == Tlv::Absent;
  memcpy(out, v.data, n);
  return true;
}

}  // namespace

size_t build_ctl_sync(uint8_t* buf, size_t cap, uint8_t txid) {
  QmiBuilder b(buf, cap, ctl_request(txid, kCtlSync));
  return b.finish();
}

size_t build_ctl_get_client_id(uint8_t* buf, size_t cap, uint8_t txid, QmiService service) {
  QmiBuilder b(buf, cap, ctl_request(txid, kCtlGetClientId));
  b.tlv_u8(kTlvCtlService, static_cast<uint8_t>(service));
  return b.finish();
}

bool parse_ctl_get_client_id(const QmiMessage& m, QmiService* service, uint8_t* client) {
  Span v;
  if (!response_ok(m) || find_sized(m, kTlvCtlAllocInfo, 2, &v) != Tlv::Found) return false;
  *service = static_cast<QmiService>(v.data[0]);
  *client = v.data[1];
  return true;
}

size_t build_ctl_release_client_id(uint8_t* buf, size_t cap, uint8_t txid, QmiService service,
                                   uint8_t client) {
  QmiBuilder b(buf, cap, ctl_request(txid, kCtlReleaseClientId));
  const uint8_t info[2] = {static_cast<uint8_t>(service), client};
  b.tlv(kTlvCtlReleaseInfo, info, sizeof info);
  return b.finish();
}

size_t build_wda_set_data_format(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                                 uint32_t iface_number) {
  QmiBuilder b(buf, cap, service_request(QmiService::WDA, client, txid, kWdaSetDataFormat));
  b.tlv_u8(kTlvWdaQosFormat, 0);
  b.tlv_u32(kTlvWdaLinkLayer, kLinkLayerRawIp);
  b.tlv_u32(kTlvWdaUlAgg, kAggQmap);
  b.tlv_u32(kTlvWdaDlAgg, kAggQmap);
  b.tlv_u32(kTlvWdaDlMaxDatagrams, kDlMaxDatagrams);
  b.tlv_u32(kTlvWdaDlMaxSize, kDlMaxSize);
  tlv_endpoint(&b, kTlvWdaEndpoint, iface_number);
  b.tlv_u32(kTlvWdaUlMaxDatagramsIn, kUlMaxDatagrams);
  b.tlv_u32(kTlvWdaUlMaxSizeIn, kUlMaxSize);
  return b.finish();
}

bool parse_wda_data_format(const QmiMessage& m, DataFormat* out) {
  DataFormat f;
  if (!response_ok(m) || !optional_u32(m, kTlvWdaLinkLayer, &f.link_layer) ||
      !optional_u32(m, kTlvWdaUlAgg, &f.ul_agg) || !optional_u32(m, kTlvWdaDlAgg, &f.dl_agg) ||
      !optional_u32(m, kTlvWdaDlMaxDatagrams, &f.dl_max_datagrams) ||
      !optional_u32(m, kTlvWdaDlMaxSize, &f.dl_max_size) ||
      !optional_u32(m, kTlvWdaUlMaxDatagramsOut, &f.ul_max_datagrams) ||
      !optional_u32(m, kTlvWdaUlMaxSizeOut, &f.ul_max_size)) {
    return false;
  }
  *out = f;
  return true;
}

bool data_format_usable(const DataFormat& f) {
  return f.link_layer == kLinkLayerRawIp && f.ul_agg == kAggQmap && f.dl_agg == kAggQmap &&
         f.dl_max_size >= kMinUsableDlSize;
}

size_t build_wds_bind_mux(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                          uint32_t iface_number, uint8_t mux_id) {
  QmiBuilder b(buf, cap, service_request(QmiService::WDS, client, txid, kWdsBindMuxDataPort));
  tlv_endpoint(&b, kTlvWdsBindEndpoint, iface_number);
  b.tlv_u8(kTlvWdsBindMuxId, mux_id);
  b.tlv_u32(kTlvWdsBindClientType, kClientTypeTethered);
  return b.finish();
}

size_t build_wds_set_ip_family(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                               uint8_t family) {
  QmiBuilder b(buf, cap, service_request(QmiService::WDS, client, txid, kWdsSetIpFamily));
  b.tlv_u8(kTlvWdsFamilyPreference, family);
  return b.finish();
}

size_t build_wds_start_network(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                               uint8_t profile, uint8_t family) {
  QmiBuilder b(buf, cap, service_request(QmiService::WDS, client, txid, kWdsStartNetwork));
  b.tlv_u8(kTlvWdsStartFamily, family);
  b.tlv_u8(kTlvWdsStartProfile, profile);
  return b.finish();
}

bool parse_wds_start_network(const QmiMessage& m, uint32_t* handle, CallEnd* end) {
  *end = {0, 0, 0};
  Span v;
  if (find_sized(m, kTlvWdsCallEnd, 2, &v) == Tlv::Found) {
    end->reason = Reader(v.data, v.len).u16le();
  }
  if (find_sized(m, kTlvWdsVerboseCallEnd, 4, &v) == Tlv::Found) {
    Reader r(v.data, v.len);
    end->verbose_type = r.u16le();
    end->verbose_reason = r.u16le();
  }
  if (!response_ok(m) || find_sized(m, kTlvWdsHandle, 4, &v) != Tlv::Found) return false;
  *handle = Reader(v.data, v.len).u32le();
  return true;
}

size_t build_wds_stop_network(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                              uint32_t handle) {
  QmiBuilder b(buf, cap, service_request(QmiService::WDS, client, txid, kWdsStopNetwork));
  b.tlv_u32(kTlvWdsHandle, handle);
  return b.finish();
}

size_t build_wds_get_current_settings(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid) {
  QmiBuilder b(buf, cap, service_request(QmiService::WDS, client, txid, kWdsGetCurrentSettings));
  b.tlv_u32(kTlvWdsRequestedSettings, kRequestedSettings);
  return b.finish();
}

bool parse_wds_current_settings(const QmiMessage& m, RuntimeSettings* out) {
  if (!response_ok(m)) return false;
  RuntimeSettings s = *out;  // committed only if every TLV present is well formed

  bool found;
  if (!optional_v4(m, kTlvV4Addr, s.v4_addr, &found)) return false;
  if (found) s.has_v4 = true;
  if (!optional_v4(m, kTlvV4Gateway, s.v4_gateway, &found)) return false;
  if (!optional_v4(m, kTlvV4Mask, s.v4_mask, &found)) return false;

  uint8_t dns4[2][4];
  uint8_t n4 = 0;
  const uint8_t dns4_types[2] = {kTlvV4DnsPrimary, kTlvV4DnsSecondary};
  for (uint8_t type : dns4_types) {
    if (!optional_v4(m, type, dns4[n4], &found)) return false;
    if (found) ++n4;
  }
  if (n4 > 0) {
    memcpy(s.v4_dns, dns4, sizeof dns4);
    s.v4_dns_count = n4;
  }

  // IPv6 address and gateway: 16 address bytes, then u8 prefix length.
  uint8_t v6[17];
  if (!optional_bytes(m, kTlvV6Addr, sizeof v6, v6, &found)) return false;
  if (found) {
    memcpy(s.v6_addr, v6, 16);
    s.v6_prefix_len = v6[16];
    s.has_v6 = true;
  }
  if (!optional_bytes(m, kTlvV6Gateway, sizeof v6, v6, &found)) return false;
  if (found) memcpy(s.v6_gateway, v6, 16);

  uint8_t dns6[2][16];
  uint8_t n6 = 0;
  const uint8_t dns6_types[2] = {kTlvV6DnsPrimary, kTlvV6DnsSecondary};
  for (uint8_t type : dns6_types) {
    if (!optional_bytes(m, type, 16, dns6[n6], &found)) return false;
    if (found) ++n6;
  }
  if (n6 > 0) {
    memcpy(s.v6_dns, dns6, sizeof dns6);
    s.v6_dns_count = n6;
  }

  Span v;
  switch (find_sized(m, kTlvMtu, 4, &v)) {
    case Tlv::Short:
      return false;
    case Tlv::Found:
      s.mtu = Reader(v.data, v.len).u32le();
      break;
    case Tlv::Absent:
      break;
  }

  *out = s;
  return true;
}

bool parse_wds_packet_status(const QmiMessage& m, PacketStatus* out) {
  Span v;
  if (find_sized(m, kTlvWdsConnectionStatus, 2, &v) != Tlv::Found) return false;
  PacketStatus p;
  p.status = v.data[0];
  p.reconfigure = v.data[1] != 0;
  p.family = 0;
  switch (find_sized(m, kTlvWdsIpFamily, 1, &v)) {
    case Tlv::Short:
      return false;
    case Tlv::Found:
      p.family = v.data[0];
      break;
    case Tlv::Absent:
      break;
  }
  *out = p;
  return true;
}

}  // namespace rmnet
