#include "fake/ch32x035.h"
USBFake fake_usb;
AFIOFake fake_afio;
/* Include production source so the harness can inspect private DMA buffers. */
#include "../User/cdc.c"
void usb_reset(void)
{
    memset(&fake_usb,0,sizeof fake_usb); cdc_init();
    fake_usb.INT_FG=USBFS_UIF_BUS_RST; USBFS_IRQHandler(); cdc_take_reset();
}
void usb_setup(const uint8_t *p)
{
    memcpy(ep0,p,8); fake_usb.RX_LEN=8;
    fake_usb.INT_ST=USBFS_UIS_TOKEN_SETUP; fake_usb.INT_FG=USBFS_UIF_TRANSFER;
    USBFS_IRQHandler();
}
void usb_in(uint8_t endpoint)
{
    fake_usb.INT_ST=USBFS_UIS_TOKEN_IN|endpoint;
    fake_usb.INT_FG=USBFS_UIF_TRANSFER; USBFS_IRQHandler();
}
void usb_out(uint8_t endpoint,const uint8_t *p,uint16_t n,uint8_t toggle_ok)
{
    if(n<=64) memcpy(endpoint==0?ep0:ep2,p,n);
    fake_usb.RX_LEN=n;
    fake_usb.INT_ST=endpoint|(toggle_ok?USBFS_UIS_TOG_OK:0);
    fake_usb.INT_FG=USBFS_UIF_TRANSFER; USBFS_IRQHandler();
}
uint16_t usb_data(uint8_t endpoint,uint8_t *p)
{
    uint16_t n=endpoint==0?fake_usb.UEP0_TX_LEN:endpoint==1?fake_usb.UEP1_TX_LEN:fake_usb.UEP3_TX_LEN;
    memcpy(p,endpoint==0?ep0:endpoint==1?ep1:ep3,n); return n;
}
uint16_t usb_ctrl(uint8_t endpoint)
{
    return endpoint==0?fake_usb.UEP0_CTRL_H:endpoint==1?fake_usb.UEP1_CTRL_H:endpoint==2?fake_usb.UEP2_CTRL_H:fake_usb.UEP3_CTRL_H;
}
uint8_t usb_address(void) { return fake_usb.DEV_ADDR; }
uint8_t usb_config(void) { return configured; }
void usb_suspend(uint8_t value)
{
    fake_usb.MIS_ST=value?USBFS_UMS_SUSPEND:0;
    fake_usb.INT_FG=USBFS_UIF_SUSPEND; USBFS_IRQHandler();
}
