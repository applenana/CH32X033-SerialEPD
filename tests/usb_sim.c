#include "fake/ch32x035.h"
USBFake fake_usb;
AFIOFake fake_afio;
uint32_t fake_irq_disable_count;
uint32_t usb_irq_disables(void) { return fake_irq_disable_count; }
/* Include production source so the harness can inspect private DMA buffers. */
#include "../User/ch32x035_usbfs_device.c"
#include "../User/cdc.c"
void usb_reset(void)
{
    memset(&fake_usb,0,sizeof fake_usb); cdc_init();
    fake_usb.INT_FG=USBFS_UIF_BUS_RST; USBFS_IRQHandler(); cdc_take_reset();
}
void usb_setup_raw(const uint8_t *p,uint32_t rx_register)
{
    memcpy(USBFS_EP0_4Buf,p,8); fake_usb.RX_LEN=(uint16_t)rx_register;
    fake_usb.RX_LEN_RESERVED=(uint16_t)(rx_register>>16);
    fake_usb.INT_ST=USBFS_UIS_TOKEN_SETUP; fake_usb.INT_FG=USBFS_UIF_TRANSFER;
    USBFS_IRQHandler();
}
void usb_setup(const uint8_t *p) { usb_setup_raw(p,8); }
void usb_in(uint8_t endpoint)
{
    fake_usb.INT_ST=USBFS_UIS_TOKEN_IN|endpoint;
    fake_usb.INT_FG=USBFS_UIF_TRANSFER; USBFS_IRQHandler();
}
void usb_out_raw(uint8_t endpoint,const uint8_t *p,uint16_t n,uint8_t toggle_ok,uint32_t rx_register)
{
    if(n<=64) memcpy(endpoint==0?USBFS_EP0_4Buf:USBFS_EP2_Buf,p,n);
    fake_usb.RX_LEN=(uint16_t)rx_register;
    fake_usb.RX_LEN_RESERVED=(uint16_t)(rx_register>>16);
    fake_usb.INT_ST=endpoint|(toggle_ok?USBFS_UIS_TOG_OK:0);
    fake_usb.INT_FG=USBFS_UIF_TRANSFER; USBFS_IRQHandler();
}
void usb_out(uint8_t endpoint,const uint8_t *p,uint16_t n,uint8_t toggle_ok)
{
    usb_out_raw(endpoint,p,n,toggle_ok,n);
}
uint16_t usb_data(uint8_t endpoint,uint8_t *p)
{
    uint16_t n=endpoint==0?fake_usb.UEP0_TX_LEN:endpoint==1?fake_usb.UEP1_TX_LEN:fake_usb.UEP3_TX_LEN;
    memcpy(p,endpoint==0?USBFS_EP0_4Buf:endpoint==1?USBFS_EP1_Buf:USBFS_EP3_Buf,n); return n;
}
uint16_t usb_ctrl(uint8_t endpoint)
{
    return endpoint==0?fake_usb.UEP0_CTRL_H:endpoint==1?fake_usb.UEP1_CTRL_H:endpoint==2?fake_usb.UEP2_CTRL_H:fake_usb.UEP3_CTRL_H;
}
uint8_t usb_address(void) { return fake_usb.DEV_ADDR; }
uint8_t usb_config(void) { return USBFS_DevConfig; }
void usb_suspend(uint8_t value)
{
    fake_usb.MIS_ST=value?USBFS_UMS_SUSPEND:0;
    fake_usb.INT_FG=USBFS_UIF_SUSPEND; USBFS_IRQHandler();
}

void usb_bus_reset(void)
{
    fake_usb.INT_FG=USBFS_UIF_BUS_RST; USBFS_IRQHandler();
}
#ifdef SERIAL_EPD_USB_SIM
#include "protocol.h"
#include "board.h"
/* Run the same transport/protocol sequence as production main.c. */
void usb_main_poll(uint32_t cycles)
{
    while(cycles--) {
        uint8_t byte;
        if(cdc_take_reset()) protocol_disconnect();
        protocol_poll(board_millis());
        cdc_poll();
        if(cdc_read_byte(&byte)) protocol_feed(byte,board_millis());
    }
}
#endif
