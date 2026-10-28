#ifndef SERIAL_EPD_CDC_H
#define SERIAL_EPD_CDC_H
#include <stdint.h>
void cdc_init(void);
void cdc_poll(void);
int cdc_read_byte(uint8_t *byte);
int cdc_tx_idle(void);
void cdc_send(const uint8_t *data, uint16_t size);
int cdc_take_reset(void);
#endif
