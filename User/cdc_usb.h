#ifndef SERIAL_EPD_CDC_USB_H
#define SERIAL_EPD_CDC_USB_H
#include <stdint.h>
/* Internal boundary between the WCH USB controller and SEP/1 transport. */
extern uint8_t cdc_line_coding[7];
int cdc_usb_setup_valid(void);
void cdc_usb_out(uint16_t length);
void cdc_usb_reset(void);
void cdc_usb_notify(void);
void cdc_usb_clear_halt(uint8_t endpoint);
#endif
