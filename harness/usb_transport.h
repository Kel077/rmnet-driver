// Userspace USB transport for the modem's QMI interface (device 2c7c:0801, the interface whose
// class, subclass and protocol are all 0xff), built on IOUSBHost.framework.
//
// QMI control messages travel as USB CDC encapsulated commands and responses on the default
// control pipe, addressed to the interface. The interrupt endpoint announces waiting responses
// (A1 01, RESPONSE_AVAILABLE). Bulk endpoints carry data.
//
// Handlers run on the main dispatch queue. Every IOUSBHost failure, including an Objective-C
// exception, is reported as a failed call, never thrown.
#pragma once

#include <stddef.h>
#include <stdint.h>

#include <functional>
#include <memory>
#include <string>

class UsbTransport {
 public:
  using Handler = std::function<void(const uint8_t* data, size_t len)>;
  using ErrorHandler = std::function<void(const std::string& what)>;

  UsbTransport();
  ~UsbTransport();
  UsbTransport(const UsbTransport&) = delete;
  UsbTransport& operator=(const UsbTransport&) = delete;

  bool open(std::string* error);  // device 2c7c:0801, the interface with class, subclass and protocol 0xff
  uint8_t interface_number() const;
  uint8_t bulk_in() const;
  uint8_t bulk_out() const;
  uint8_t interrupt_in() const;
  size_t bulk_packet_size() const;
  std::string serial() const;  // the USB serial number string
  bool send_control(const uint8_t* data, size_t len);  // CDC SEND_ENCAPSULATED_COMMAND
  void start_control(Handler on_message);  // one call per QMUX message, on the main queue
  void start_bulk(size_t read_size, Handler on_transfer);  // keeps 8 reads posted; one call per completed transfer, on the main queue
  // Called once, on the main queue, when the interrupt or bulk read path has failed for good:
  // a read kept failing after clearing the stall and re-posting, or could not be posted.
  void set_error_handler(ErrorHandler on_error);
  bool write_bulk(const uint8_t* data, size_t len);  // len > 0; returns when the transfer completes
  void close();

  struct Impl;

 private:
  std::shared_ptr<Impl> impl_;
};
