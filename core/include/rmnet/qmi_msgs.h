// Builders and parsers for the QMI messages the driver sends and receives.
//
// Every builder writes one complete QMUX frame from the host and returns its length, or 0 if
// it does not fit in `cap`. Parsers trust the caller to have routed the message by service and
// message ID; they check the result TLV where there is one and reject TLVs shorter than their
// fixed layout.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/qmi.h"

namespace rmnet {

enum : uint16_t {
  kCtlGetClientId = 0x0022,         // libqmi: CTL "Allocate CID"
  kCtlReleaseClientId = 0x0023,     // libqmi: CTL "Release CID"
  kCtlSync = 0x0027,                // libqmi: CTL "Sync"
  kWdaSetDataFormat = 0x0020,       // libqmi: WDA "Set Data Format"
  kWdsStartNetwork = 0x0020,        // libqmi: WDS "Start Network"
  kWdsStopNetwork = 0x0021,         // libqmi: WDS "Stop Network"
  kWdsPacketServiceStatus = 0x0022, // libqmi: WDS "Packet Service Status" (indication)
  kWdsGetCurrentSettings = 0x002D,  // libqmi: WDS "Get Current Settings"
  kWdsSetIpFamily = 0x004D,         // libqmi: WDS "Set IP Family"
  kWdsBindMuxDataPort = 0x00A2,     // libqmi: WDS "Bind Mux Data Port"
};
enum : uint16_t {
  kQmiErrCallFailed = 0x000E,  // libqmi: QMI_PROTOCOL_ERROR_CALL_FAILED
  kQmiErrNoEffect = 0x001A,    // libqmi: QMI_PROTOCOL_ERROR_NO_EFFECT
};

// CTL. Transaction IDs are 8 bits; the client is always 0.
size_t build_ctl_sync(uint8_t* buf, size_t cap, uint8_t txid);
size_t build_ctl_get_client_id(uint8_t* buf, size_t cap, uint8_t txid, QmiService service);
bool parse_ctl_get_client_id(const QmiMessage& m, QmiService* service, uint8_t* client);
size_t build_ctl_release_client_id(uint8_t* buf, size_t cap, uint8_t txid, QmiService service,
                                   uint8_t client);

// WDA. The data format the modem settled on, as its Set Data Format response reports it.
struct DataFormat {
  uint32_t link_layer, ul_agg, dl_agg, dl_max_datagrams, dl_max_size, ul_max_datagrams,
      ul_max_size;
};
size_t build_wda_set_data_format(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                                 uint32_t iface_number);
// False unless the response succeeded. A field whose TLV is absent reads as 0.
bool parse_wda_data_format(const QmiMessage& m, DataFormat* out);
// Raw IP (2), QMAP (5) both ways, at least one datagram each way, dl_max_size from 2048 to
// 31744 and ul_max_size from 2048 to 16384 (the sizes requested, so a response cannot make the
// caller's buffers larger than asked for).
bool data_format_usable(const DataFormat& f);

// WDS.
size_t build_wds_bind_mux(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                          uint32_t iface_number, uint8_t mux_id);
size_t build_wds_set_ip_family(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                               uint8_t family);
size_t build_wds_start_network(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                               uint8_t profile, uint8_t family);
struct CallEnd {
  uint16_t reason;
  uint16_t verbose_type;
  uint16_t verbose_reason;
};
// False on failure; *end is zeroed, then filled from whichever call-end TLVs are present.
bool parse_wds_start_network(const QmiMessage& m, uint32_t* handle, CallEnd* end);
size_t build_wds_stop_network(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid,
                              uint32_t handle);
size_t build_wds_get_current_settings(uint8_t* buf, size_t cap, uint8_t client, uint16_t txid);

struct RuntimeSettings {  // all addresses in network byte order
  bool has_v4;
  uint8_t v4_addr[4], v4_gateway[4], v4_mask[4];
  uint8_t v4_dns[2][4];
  uint8_t v4_dns_count;
  bool has_v6;
  uint8_t v6_addr[16];
  uint8_t v6_prefix_len;
  uint8_t v6_gateway[16];
  uint8_t v6_dns[2][16];
  uint8_t v6_dns_count;
  uint32_t mtu;
};
// Merges into *out, so IPv4 and IPv6 replies combine. On failure *out is left unchanged. IPv4
// counts (has_v4, and its address, gateway and mask are taken) only when the reply holds all
// three; a reply missing any of them leaves those fields and has_v4 as they were.
bool parse_wds_current_settings(const QmiMessage& m, RuntimeSettings* out);

struct PacketStatus {  // status 1 disconnected, 2 connected; family 0 if absent
  uint8_t status;
  bool reconfigure;
  uint8_t family;
};
bool parse_wds_packet_status(const QmiMessage& m, PacketStatus* out);

}  // namespace rmnet
