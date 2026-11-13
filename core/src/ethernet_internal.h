// Helpers shared by the Ethernet emulator's source files (ethernet.cpp, dhcp.cpp, ndp.cpp).
// Private to core/src; never include it from a public header.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include "rmnet/ethernet.h"

namespace rmnet {
namespace eth_internal {

inline constexpr size_t kEthHeaderLen = 14;
inline constexpr size_t kIpv4HeaderLen = 20;
inline constexpr size_t kIpv6HeaderLen = 40;

inline constexpr uint16_t kEtherTypeIpv4 = 0x0800;
inline constexpr uint16_t kEtherTypeIpv6 = 0x86DD;
inline constexpr uint16_t kEtherTypeArp = 0x0806;

inline uint16_t get16(const uint8_t* p) { return (uint16_t)(p[0] << 8 | p[1]); }

inline void put16(uint8_t* p, uint16_t v) {
  p[0] = (uint8_t)(v >> 8);
  p[1] = (uint8_t)v;
}

inline void put32(uint8_t* p, uint32_t v) {
  p[0] = (uint8_t)(v >> 24);
  p[1] = (uint8_t)(v >> 16);
  p[2] = (uint8_t)(v >> 8);
  p[3] = (uint8_t)v;
}

inline TxResult drop() { return {TxAction::Drop, {nullptr, 0}, 0}; }
inline TxResult forward(const uint8_t* ip, size_t len) { return {TxAction::Forward, {ip, len}, 0}; }
inline TxResult replied(size_t len) { return {TxAction::Reply, {nullptr, 0}, len}; }

}  // namespace eth_internal
}  // namespace rmnet
