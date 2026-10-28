#ifndef SERIAL_EPD_PROTOCOL_H
#define SERIAL_EPD_PROTOCOL_H
#include <stdint.h>
#define PROTO_MAX_PAYLOAD 772u
#define PROTO_MAX_RAW (16u + PROTO_MAX_PAYLOAD + 4u)
#define PROTO_MAX_WIRE (PROTO_MAX_RAW + PROTO_MAX_RAW/254u + 2u)
enum { CMD_OPEN=1, CMD_INFO=2, CMD_STATUS=3, CMD_BEGIN=0x10,
       CMD_DATA=0x11, CMD_COMMIT=0x12, CMD_ABORT=0x13 };
enum { RES_OK, RES_VERSION, RES_COMMAND, RES_ARGUMENT, RES_SESSION,
       RES_SEQUENCE, RES_STATE, RES_OFFSET, RES_CRC, RES_BUSY, RES_IO, RES_TIMEOUT };
/* send callback must accept the complete reply; caller gates input on TX space. */
void protocol_init(void);
void protocol_feed(uint8_t byte, uint32_t now);
void protocol_poll(uint32_t now);
void protocol_disconnect(void);
void protocol_send(const uint8_t *data, uint16_t length);
uint32_t protocol_crc32(uint32_t crc, const uint8_t *p, uint16_t n);
#endif
