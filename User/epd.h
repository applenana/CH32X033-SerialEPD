#ifndef SERIAL_EPD_H
#define SERIAL_EPD_H
#include <stdint.h>
#define EPD_WIDTH 768u
#define EPD_HEIGHT 552u
#define EPD_ROW_BYTES 192u
#define EPD_FRAME_BYTES 105984ul
enum { EPD_IDLE, EPD_INIT, EPD_READY, EPD_REFRESH, EPD_DONE, EPD_ERROR };
void epd_hw_init(void);
void epd_begin(uint8_t panel, uint32_t now);
void epd_poll(uint32_t now);
int epd_write(const uint8_t *data, uint16_t length);
void epd_commit(uint32_t now);
void epd_abort(void);
uint8_t epd_state(void);
uint8_t epd_error(void);
#endif
