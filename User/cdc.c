/* Bounded SEP/1 stream adapter. WCH owns USB enumeration and PHY sequencing. */
#include "ch32x035_usbfs_device.h"
#include "cdc.h"
#include "cdc_usb.h"
#include <stddef.h>
_Static_assert(sizeof(USBFSD->RX_LEN)==2,"USB RX_LEN must use a 16-bit MMIO access");
#ifndef SERIAL_EPD_HOST_TEST
_Static_assert(offsetof(USBFSD_TypeDef,RX_LEN)==0x08,"USB RX_LEN offset");
_Static_assert(offsetof(USBFSD_TypeDef,UEP4_1_MOD)==0x0C,"USB endpoint mode offset");
_Static_assert(offsetof(USBFSD_TypeDef,UEP0_DMA)==0x10,"USB endpoint DMA offset");
_Static_assert(offsetof(USBFSD_TypeDef,UEP0_CTRL_H)==0x22,"USB endpoint control offset");
_Static_assert(offsetof(USBFSD_TypeDef,UEP5_DMA)==0x54,"USB upper endpoint DMA offset");
#endif
uint8_t cdc_line_coding[7]={0x00,0xC2,0x01,0,0,0,8};
static uint8_t tx[128];
static volatile uint8_t reset_event, rx_len, rx_pos, rx_pending, tx_zlp, notify_pending;
static volatile uint16_t tx_len, tx_pos;
static int valid_ep(uint16_t index) { return index==0x81 || index==2 || index==0x83; }
static int ep_halted(uint8_t ep)
{
    if(ep==2) return (USBFSD->UEP2_CTRL_H&USBFS_UEP_R_RES_MASK)==USBFS_UEP_R_RES_STALL;
    if(ep==0x81) return (USBFSD->UEP1_CTRL_H&USBFS_UEP_T_RES_MASK)==USBFS_UEP_T_RES_STALL;
    return (USBFSD->UEP3_CTRL_H&USBFS_UEP_T_RES_MASK)==USBFS_UEP_T_RES_STALL;
}
/* Input validation only: accepted requests retain WCH's control-transfer flow. */
int cdc_usb_setup_valid(void)
{
    uint8_t type=USBFS_SetupReqType, req=USBFS_SetupReqCode;
    uint16_t value=USBFS_SetupReqValue, index=USBFS_SetupReqIndex, length=USBFS_SetupReqLen;
    if(type==0x80 && req==USB_GET_DESCRIPTOR && length) {
        if(!index && (value==0x0100 || value==0x0200)) return 1;
        return (value>>8)==3 && (value&255)<=3 && (index==0 || index==0x0409);
    }
    if(type==0 && req==USB_SET_ADDRESS) return !index && !length && value<128 && !USBFS_DevConfig;
    if(type==0 && req==USB_SET_CONFIGURATION) return !index && !length && value<=1;
    if(type==0x80 && req==USB_GET_CONFIGURATION) return !value && !index && length==1;
    if(req==USB_GET_STATUS && !value && length==2) {
        return (type==0x80 && !index) || (type==0x81 && USBFS_DevConfig && index<2) ||
            (type==0x82 && ((USBFS_DevConfig && valid_ep(index)) || index==0 || index==0x80));
    }
    if(USBFS_DevConfig && type==2 && (req==USB_SET_FEATURE || req==USB_CLEAR_FEATURE))
        return !value && !length && valid_ep(index);
    if(USBFS_DevConfig && index<2 && !value) {
        if(type==0x81 && req==USB_GET_INTERFACE) return length==1;
        if(type==1 && req==USB_SET_INTERFACE) return !length;
    }
    if(USBFS_DevConfig && index==0) {
        if(type==0xA1 && req==CDC_GET_LINE_CODING) return !value && length==7;
        if(type==0x21 && req==CDC_SET_LINE_CODING) return !value && length==7;
        if(type==0x21 && req==CDC_SET_LINE_CTLSTE) return value<=3 && !length;
        if(type==0x21 && req==CDC_SEND_BREAK) return !length;
    }
    return 0;
}
void cdc_usb_reset(void)
{
    reset_event=1;
    rx_pending=rx_pos=rx_len=0; tx_len=tx_pos=tx_zlp=0;
    USBFS_Endp_Busy[1]=USBFS_Endp_Busy[3]=0;
    notify_pending=!!USBFS_DevConfig;
    USBFSD->UEP1_CTRL_H=(USBFSD->UEP1_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_NAK;
    USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_NAK;
    USBFSD->UEP3_CTRL_H=(USBFSD->UEP3_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_NAK;
}
void cdc_usb_out(uint16_t length)
{
    if(!USBFS_DevConfig || reset_event || rx_pending) return;
    USBFSD->UEP2_CTRL_H^=USBFS_UEP_R_TOG;
    USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_NAK;
    if(length<=DEF_USBD_ENDP2_SIZE) { rx_len=(uint8_t)length; rx_pos=0; rx_pending=1; }
    else cdc_usb_reset();
}
void cdc_usb_notify(void) { notify_pending=1; }
void cdc_usb_clear_halt(uint8_t ep)
{
    if(ep==2) USBFSD->UEP2_CTRL_H=(rx_pending || reset_event)?USBFS_UEP_R_RES_NAK:USBFS_UEP_R_RES_ACK;
    else if(ep==0x81) USBFSD->UEP1_CTRL_H=USBFS_Endp_Busy[1]?USBFS_UEP_T_RES_ACK:USBFS_UEP_T_RES_NAK;
    else if(ep==0x83) USBFSD->UEP3_CTRL_H=USBFS_Endp_Busy[3]?USBFS_UEP_T_RES_ACK:USBFS_UEP_T_RES_NAK;
}
void cdc_init(void)
{
    USBFS_DevConfig=USBFS_DevAddr=USBFS_DevSleepStatus=USBFS_DevEnumStatus=0;
    USBFS_SetupReqLen=USBFS_SetupReqCode=USBFS_SetupReqType=0;
    const uint8_t initial_line[7]={0x00,0xC2,0x01,0,0,0,8};
    memcpy(cdc_line_coding,initial_line,sizeof initial_line);
    cdc_usb_reset();
    Delay_Init();
    USBFS_RCC_Init();
    /* Use the same supply-detection/PHY initialization path as the passing example. */
    USBFS_Device_Init(ENABLE,PWR_VDD_SupplyVoltage());
}
int cdc_take_reset(void)
{
    if(!reset_event) return 0;
    NVIC_DisableIRQ(USBFS_IRQn); int r=reset_event; reset_event=0;
    if(r && USBFS_DevConfig && !(USBFS_DevSleepStatus&2) && !ep_halted(2))
        USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_ACK;
    NVIC_EnableIRQ(USBFS_IRQn); return r;
}
int cdc_tx_idle(void) { return !USBFS_Endp_Busy[3] && tx_pos==tx_len && !tx_zlp; }
void cdc_send(const uint8_t *p,uint16_t n)
{
    NVIC_DisableIRQ(USBFS_IRQn);
    if(USBFS_DevConfig && !(USBFS_DevSleepStatus&2) && !reset_event && cdc_tx_idle() && n<=sizeof tx) {
        memcpy(tx,p,n); tx_len=n; tx_pos=0; tx_zlp=!(n%DEF_USBD_ENDP3_SIZE);
    }
    NVIC_EnableIRQ(USBFS_IRQn);
}
void cdc_poll(void)
{
    /* Enumeration/idle polling must not repeatedly mask the USB interrupt. */
    if(!USBFS_DevConfig || (USBFS_DevSleepStatus&2) || reset_event) return;
    if(!notify_pending && tx_pos==tx_len && !tx_zlp) return;
    NVIC_DisableIRQ(USBFS_IRQn);
    if(USBFS_DevConfig && !(USBFS_DevSleepStatus&2) && !reset_event) {
        if(notify_pending && !USBFS_Endp_Busy[1] && !ep_halted(0x81)) {
            const uint8_t notification[]={0xA1,0x20,0,0,0,0,2,0,3,0};
            memcpy(USBFS_EP1_Buf,notification,sizeof notification);
            USBFSD->UEP1_TX_LEN=sizeof notification; notify_pending=0; USBFS_Endp_Busy[1]=1;
            USBFSD->UEP1_CTRL_H=(USBFSD->UEP1_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_ACK;
        }
        if(!USBFS_Endp_Busy[3] && !ep_halted(0x83) && (tx_pos<tx_len || tx_zlp)) {
            uint16_t n=tx_len-tx_pos; if(n>DEF_USBD_ENDP3_SIZE) n=DEF_USBD_ENDP3_SIZE;
            if(n) memcpy(USBFS_EP3_Buf,tx+tx_pos,n); else tx_zlp=0;
            tx_pos+=n; USBFSD->UEP3_TX_LEN=n; USBFS_Endp_Busy[3]=1;
            USBFSD->UEP3_CTRL_H=(USBFSD->UEP3_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_ACK;
        }
    }
    NVIC_EnableIRQ(USBFS_IRQn);
}
int cdc_read_byte(uint8_t *p)
{
    if(!rx_pending) return 0;
    int got=0; NVIC_DisableIRQ(USBFS_IRQn);
    if(USBFS_DevConfig && !(USBFS_DevSleepStatus&2) && !reset_event && rx_pending && cdc_tx_idle()) {
        if(rx_pos<rx_len) { *p=USBFS_EP2_Buf[rx_pos++]; got=1; }
        if(rx_pos==rx_len) {
            rx_pending=0;
            if(!ep_halted(2)) USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_ACK;
        }
    }
    NVIC_EnableIRQ(USBFS_IRQn); return got;
}
