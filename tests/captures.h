// Frames recorded from an RM520N-GL by a dry run (tests/fixtures/capture-dryrun.txt),
// in capture order. Client 15 is the IPv4 WDS client, client 16 the IPv6 one.
#pragma once

// >> ctl cid=0 request tx=1 msg=0x0027
inline const char* kCtlSyncReq = "01 0b 00 00 00 00 00 01 27 00 00 00";
// << ctl cid=0 response tx=1 msg=0x0027
inline const char* kCtlSyncResp = "01 12 00 80 00 00 01 01 27 00 07 00 02 04 00 00 00 00 00";
// >> ctl cid=0 request tx=2 msg=0x0022
inline const char* kCtlGetWdaReq = "01 0f 00 00 00 00 00 02 22 00 04 00 01 01 00 1a";
// << ctl cid=0 response tx=2 msg=0x0022
inline const char* kCtlGetWdaResp = "01 17 00 80 00 00 01 02 22 00 0c 00 02 04 00 00 00 00 00 01 02 00 1a 01";
// >> wda cid=1 request tx=1 msg=0x0020
inline const char* kWdaSetFormatReq = "01 4c 00 00 1a 01 00 01 00 20 00 40 00 10 01 00 00 11 04 00 02 00 00 00 12 04 00 05 00 00 00 13 04 00 05 00 00 00 15 04 00 20 00 00 00 16 04 00 00 7c 00 00 17 08 00 02 00 00 00 04 00 00 00 1b 04 00 20 00 00 00 1c 04 00 00 40 00 00";
// Not recorded: kWdaSetFormatReq with TLV 0x1A "Flow Control" = 01 after the endpoint TLV (0x17),
// so the QMUX length is 0x50 (was 0x4c) and the TLV length 0x44 (was 0x40).
inline const char* kWdaSetFormatReqFlow = "01 50 00 00 1a 01 00 01 00 20 00 44 00 10 01 00 00 11 04 00 02 00 00 00 12 04 00 05 00 00 00 13 04 00 05 00 00 00 15 04 00 20 00 00 00 16 04 00 00 7c 00 00 17 08 00 02 00 00 00 04 00 00 00 1a 01 00 01 1b 04 00 20 00 00 00 1c 04 00 00 40 00 00";
// << wda cid=1 response tx=1 msg=0x0020
inline const char* kWdaSetFormatResp = "01 5a 00 80 1a 01 02 01 00 20 00 4e 00 02 04 00 00 00 00 00 10 01 00 00 11 04 00 02 00 00 00 12 04 00 05 00 00 00 13 04 00 05 00 00 00 14 04 00 00 00 00 00 15 04 00 20 00 00 00 16 04 00 00 7c 00 00 17 04 00 20 00 00 00 18 04 00 00 40 00 00 1a 04 00 00 00 00 00 1b 01 00 00";
// >> ctl cid=0 request tx=3 msg=0x0022
inline const char* kCtlGetWds4Req = "01 0f 00 00 00 00 00 03 22 00 04 00 01 01 00 01";
// << ctl cid=0 response tx=3 msg=0x0022
inline const char* kCtlGetWds4Resp = "01 17 00 80 00 00 01 03 22 00 0c 00 02 04 00 00 00 00 00 01 02 00 01 0f";
// >> wds cid=15 request tx=2 msg=0x00a2
inline const char* kWdsBind4Req = "01 22 00 00 01 0f 00 02 00 a2 00 16 00 10 08 00 02 00 00 00 04 00 00 00 11 01 00 81 13 04 00 01 00 00 00";
// << wds cid=15 response tx=2 msg=0x00a2
inline const char* kWdsBind4Resp = "01 13 00 80 01 0f 02 02 00 a2 00 07 00 02 04 00 00 00 00 00";
// >> wds cid=15 request tx=3 msg=0x004d
inline const char* kWdsFamily4Req = "01 10 00 00 01 0f 00 03 00 4d 00 04 00 01 01 00 04";
// << wds cid=15 response tx=3 msg=0x004d
inline const char* kWdsFamily4Resp = "01 13 00 80 01 0f 02 03 00 4d 00 07 00 02 04 00 00 00 00 00";
// >> wds cid=15 request tx=4 msg=0x0020
inline const char* kWdsStart4Req = "01 14 00 00 01 0f 00 04 00 20 00 08 00 19 01 00 04 31 01 00 01";
// << wds cid=15 response tx=4 msg=0x0020
inline const char* kWdsStart4Resp = "01 1a 00 80 01 0f 02 04 00 20 00 0e 00 02 04 00 00 00 00 00 01 04 00 c0 9a b2 e2";
// << wds cid=15 indication tx=1 msg=0x0022
inline const char* kWdsConnected4Ind = "01 22 00 80 01 0f 04 01 00 22 00 16 00 01 02 00 02 00 12 01 00 04 13 02 00 80 88 14 01 00 00 15 01 00 00";
// >> wds cid=15 request tx=5 msg=0x002d
inline const char* kWdsSettings4Req = "01 13 00 00 01 0f 00 05 00 2d 00 07 00 10 04 00 1d af 00 00";
// << wds cid=15 response tx=5 msg=0x002d
inline const char* kWdsSettings4Resp = "01 52 00 80 01 0f 02 05 00 2d 00 46 00 02 04 00 00 00 00 00 11 01 00 03 15 04 00 c1 71 00 cb 16 04 00 d1 71 00 cb 1e 04 00 e6 f6 66 0a 1f 02 00 00 01 20 04 00 e5 f6 66 0a 21 04 00 fc ff ff ff 22 01 00 01 23 01 00 00 29 04 00 dc 05 00 00 2b 01 00 04";
// >> ctl cid=0 request tx=4 msg=0x0022
inline const char* kCtlGetWds6Req = "01 0f 00 00 00 00 00 04 22 00 04 00 01 01 00 01";
// << ctl cid=0 response tx=4 msg=0x0022
inline const char* kCtlGetWds6Resp = "01 17 00 80 00 00 01 04 22 00 0c 00 02 04 00 00 00 00 00 01 02 00 01 10";
// >> wds cid=16 request tx=6 msg=0x00a2
inline const char* kWdsBind6Req = "01 22 00 00 01 10 00 06 00 a2 00 16 00 10 08 00 02 00 00 00 04 00 00 00 11 01 00 81 13 04 00 01 00 00 00";
// << wds cid=16 response tx=6 msg=0x00a2
inline const char* kWdsBind6Resp = "01 13 00 80 01 10 02 06 00 a2 00 07 00 02 04 00 00 00 00 00";
// >> wds cid=16 request tx=7 msg=0x004d
inline const char* kWdsFamily6Req = "01 10 00 00 01 10 00 07 00 4d 00 04 00 01 01 00 06";
// << wds cid=16 response tx=7 msg=0x004d
inline const char* kWdsFamily6Resp = "01 13 00 80 01 10 02 07 00 4d 00 07 00 02 04 00 00 00 00 00";
// >> wds cid=16 request tx=8 msg=0x0020
inline const char* kWdsStart6Req = "01 14 00 00 01 10 00 08 00 20 00 08 00 19 01 00 06 31 01 00 01";
// << wds cid=16 response tx=8 msg=0x0020
inline const char* kWdsStart6Resp = "01 1a 00 80 01 10 02 08 00 20 00 0e 00 02 04 00 00 00 00 00 01 04 00 70 f3 b3 e2";
// >> wds cid=16 request tx=9 msg=0x002d
inline const char* kWdsSettings6Req = "01 13 00 00 01 10 00 09 00 2d 00 07 00 10 04 00 1d af 00 00";
// << wds cid=16 indication tx=1 msg=0x0022
inline const char* kWdsConnected6Ind = "01 22 00 80 01 10 04 01 00 22 00 16 00 01 02 00 02 00 12 01 00 06 13 02 00 80 88 14 01 00 00 15 01 00 00";
// << wds cid=16 response tx=9 msg=0x002d
inline const char* kWdsSettings6Resp = "01 7d 00 80 01 10 02 09 00 2d 00 71 00 02 04 00 00 00 00 00 11 01 00 03 1f 02 00 00 01 22 01 00 01 25 11 00 20 01 0d b8 8a f4 b2 60 61 fc 0d be 3a b2 6e 08 40 26 11 00 20 01 0d b8 8a f4 b2 60 a0 89 88 dc 13 7d 62 53 40 27 10 00 20 01 0d b8 20 00 00 00 02 70 00 00 00 00 00 01 28 10 00 20 01 0d b8 20 00 00 00 03 70 00 00 00 00 00 01 29 04 00 dc 05 00 00 2b 01 00 06 2e 01 00 00";
// >> wds cid=16 request tx=10 msg=0x0021
inline const char* kWdsStop6Req = "01 13 00 00 01 10 00 0a 00 21 00 07 00 01 04 00 70 f3 b3 e2";
// << wds cid=16 response tx=10 msg=0x0021
inline const char* kWdsStop6Resp = "01 13 00 80 01 10 02 0a 00 21 00 07 00 02 04 00 00 00 00 00";
// >> ctl cid=0 request tx=5 msg=0x0023
inline const char* kCtlRelease6Req = "01 10 00 00 00 00 00 05 23 00 05 00 01 02 00 01 10";
// << wds cid=16 indication tx=2 msg=0x0022
inline const char* kWdsDisconnected6Ind = "01 21 00 80 01 10 04 02 00 22 00 15 00 01 02 00 01 00 10 02 00 02 00 11 04 00 03 00 d0 07 12 01 00 06";
// << ctl cid=0 response tx=5 msg=0x0023
inline const char* kCtlRelease6Resp = "01 17 00 80 00 00 01 05 23 00 0c 00 02 04 00 00 00 00 00 01 02 00 01 10";
// >> wds cid=15 request tx=11 msg=0x0021
inline const char* kWdsStop4Req = "01 13 00 00 01 0f 00 0b 00 21 00 07 00 01 04 00 c0 9a b2 e2";
// << wds cid=15 response tx=11 msg=0x0021
inline const char* kWdsStop4Resp = "01 13 00 80 01 0f 02 0b 00 21 00 07 00 02 04 00 00 00 00 00";
// >> ctl cid=0 request tx=6 msg=0x0023
inline const char* kCtlRelease4Req = "01 10 00 00 00 00 00 06 23 00 05 00 01 02 00 01 0f";
// << wds cid=15 indication tx=2 msg=0x0022
inline const char* kWdsDisconnected4Ind = "01 21 00 80 01 0f 04 02 00 22 00 15 00 01 02 00 01 00 10 02 00 f0 03 11 04 00 06 00 24 00 12 01 00 04";
// << ctl cid=0 response tx=6 msg=0x0023
inline const char* kCtlRelease4Resp = "01 17 00 80 00 00 01 06 23 00 0c 00 02 04 00 00 00 00 00 01 02 00 01 0f";
// >> ctl cid=0 request tx=7 msg=0x0023
inline const char* kCtlReleaseWdaReq = "01 10 00 00 00 00 00 07 23 00 05 00 01 02 00 1a 01";
// << ctl cid=0 response tx=7 msg=0x0023
inline const char* kCtlReleaseWdaResp = "01 17 00 80 00 00 01 07 23 00 0c 00 02 04 00 00 00 00 00 01 02 00 1a 01";
