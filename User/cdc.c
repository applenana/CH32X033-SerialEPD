/* USBFS register setup follows WCH SimulateCDC; control handling and bounded
 * transport are specific to SerialEPD. See docs/references.md. */
#include "ch32x035.h"
#include "ch32x035_usb.h"
#include "usb_desc.h"
#include "cdc.h"
#include <string.h>
static uint8_t ep0[64] __attribute__((aligned(4)));
static uint8_t ep1[64] __attribute__((aligned(4)));
static uint8_t ep2[64] __attribute__((aligned(4)));
static uint8_t ep3[64] __attribute__((aligned(4)));
static uint8_t tx[128], line[7]={0x00,0xC2,0x01,0,0,0,8};
static volatile uint8_t configured, suspended, reset_event, rx_len, rx_pos, rx_pending, in_busy;
static volatile uint16_t tx_len, tx_pos;
static volatile uint8_t tx_zlp, notify_pending, notify_busy;
static const uint8_t *control_data;
static uint16_t control_left;
static uint8_t control_zlp, pending_address, address_valid, set_line;
static uint8_t pending_config, config_valid;
static uint8_t reply_small[2];
static uint16_t le16(const uint8_t *p) { return p[0]|((uint16_t)p[1]<<8); }
static void endpoints(void)
{
    USBFSD->UEP4_1_MOD=USBFS_UEP1_TX_EN;
    USBFSD->UEP2_3_MOD=USBFS_UEP2_RX_EN|USBFS_UEP3_TX_EN;
    USBFSD->UEP0_DMA=(uint32_t)ep0; USBFSD->UEP1_DMA=(uint32_t)ep1;
    USBFSD->UEP2_DMA=(uint32_t)ep2; USBFSD->UEP3_DMA=(uint32_t)ep3;
    USBFSD->UEP0_CTRL_H=USBFS_UEP_R_RES_ACK|USBFS_UEP_T_RES_NAK;
    USBFSD->UEP1_CTRL_H=USBFS_UEP_T_RES_NAK;
    USBFSD->UEP2_CTRL_H=USBFS_UEP_R_RES_NAK;
    USBFSD->UEP3_CTRL_H=USBFS_UEP_T_RES_NAK;
    USBFSD->UEP0_TX_LEN=USBFSD->UEP1_TX_LEN=USBFSD->UEP3_TX_LEN=0;
    rx_len=rx_pos=rx_pending=in_busy=0; tx_len=tx_pos=0; tx_zlp=0;
    notify_pending=notify_busy=0;
}
static void stall(void)
{
    set_line=address_valid=config_valid=0; control_left=control_zlp=0;
    USBFSD->UEP0_CTRL_H=USBFS_UEP_T_RES_STALL|USBFS_UEP_R_RES_STALL;
}
static void control_next(void)
{
    uint16_t n=control_left>64?64:control_left;
    if(n) { memcpy(ep0,control_data,n); control_data+=n; control_left-=n; }
    else control_zlp=0;
    USBFSD->UEP0_TX_LEN=n;
    USBFSD->UEP0_CTRL_H=(USBFSD->UEP0_CTRL_H & ~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_ACK;
}
static void control_reply(const uint8_t *p,uint16_t size,uint16_t requested)
{
    control_data=p; control_left=size<requested?size:requested;
    control_zlp=(size<requested && !(control_left%64));
    control_next();
}
static void ack_status(void) { USBFSD->UEP0_TX_LEN=0; USBFSD->UEP0_CTRL_H=USBFS_UEP_T_TOG|USBFS_UEP_T_RES_ACK|USBFS_UEP_R_RES_NAK; }
static int valid_ep(uint16_t index) { return index==0x81 || index==2 || index==0x83; }
static uint8_t ep_halted(uint16_t index)
{
    if(index==2) return (USBFSD->UEP2_CTRL_H&USBFS_UEP_R_RES_MASK)==USBFS_UEP_R_RES_STALL;
    if(index==0x81) return (USBFSD->UEP1_CTRL_H&USBFS_UEP_T_RES_MASK)==USBFS_UEP_T_RES_STALL;
    return (USBFSD->UEP3_CTRL_H&USBFS_UEP_T_RES_MASK)==USBFS_UEP_T_RES_STALL;
}
static void setup(void)
{
    uint8_t type=ep0[0], req=ep0[1];
    uint16_t value=le16(ep0+2), index=le16(ep0+4), length=le16(ep0+6);
    control_left=control_zlp=set_line=address_valid=config_valid=0;
    USBFSD->UEP0_CTRL_H=USBFS_UEP_T_TOG|USBFS_UEP_R_TOG|USBFS_UEP_T_RES_NAK|USBFS_UEP_R_RES_NAK;
    if(type==0x80 && req==USB_GET_DESCRIPTOR) {
        const uint8_t *p=0; uint16_t n=0;
        if(value==0x0100 && index==0) { p=MyDevDescr; n=18; }
        else if(value==0x0200 && index==0) { p=MyCfgDescr; n=DEF_USBD_CONFIG_DESC_LEN; }
        else if((value>>8)==3 && (index==0 || index==0x0409)) {
            switch(value&255) {
            case 0:p=MyLangDescr;break; case 1:p=MyManuInfo;break;
            case 2:p=MyProdInfo;break; default:break;
            }
            if(p) n=p[0];
        }
        if(!p || !length) { stall(); return; }
        control_reply(p,n,length); return;
    }
    if(type==0 && req==USB_SET_ADDRESS && !index && !length && value<128 && !configured) {
        pending_address=(uint8_t)value; address_valid=1; ack_status(); return;
    }
    if(type==0 && req==USB_SET_CONFIGURATION && !index && !length && value<=1) {
        pending_config=(uint8_t)value; config_valid=1; ack_status(); return;
    }
    if(type==0x80 && req==USB_GET_CONFIGURATION && !value && !index && length==1) {
        reply_small[0]=configured; control_reply(reply_small,1,length); return;
    }
    if(req==USB_GET_STATUS && !value && length==2 &&
       ((type==0x80 && !index) || (type==0x81 && configured && index<2) ||
        (type==0x82 && ((configured && valid_ep(index)) || index==0 || index==0x80)))) {
        reply_small[0]=(type==0x82 && valid_ep(index))?ep_halted(index):0;
        reply_small[1]=0; control_reply(reply_small,2,length); return;
    }
    if(configured && type==2 && (req==USB_SET_FEATURE || req==USB_CLEAR_FEATURE) &&
       !value && !length && valid_ep(index)) {
        uint8_t halt=req==USB_SET_FEATURE;
        if(index==2) USBFSD->UEP2_CTRL_H=halt?
            (USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_STALL:
            (rx_pending?USBFS_UEP_R_RES_NAK:USBFS_UEP_R_RES_ACK);
        else if(index==0x81) USBFSD->UEP1_CTRL_H=halt?
            (USBFSD->UEP1_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_STALL:
            (notify_busy?USBFS_UEP_T_RES_ACK:USBFS_UEP_T_RES_NAK);
        else USBFSD->UEP3_CTRL_H=halt?
            (USBFSD->UEP3_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_STALL:
            (in_busy?USBFS_UEP_T_RES_ACK:USBFS_UEP_T_RES_NAK);
        ack_status(); return;
    }
    if(configured && index<2 && !value) {
        if(type==0x81 && req==USB_GET_INTERFACE && length==1) { reply_small[0]=0; control_reply(reply_small,1,1); return; }
        if(type==1 && req==USB_SET_INTERFACE && !length) { ack_status(); return; }
    }
    if(configured && index==0) {
        if(type==0xA1 && req==CDC_GET_LINE_CODING && !value && length==7) { control_reply(line,7,7); return; }
        if(type==0x21 && req==CDC_SET_LINE_CODING && !value && length==7) {
            set_line=1; USBFSD->UEP0_CTRL_H=USBFS_UEP_R_TOG|USBFS_UEP_R_RES_ACK|USBFS_UEP_T_RES_NAK; return;
        }
        if(type==0x21 && req==CDC_SET_LINE_CTLSTE && value<=3 && !length) { notify_pending=1; ack_status(); return; }
    }
    stall();
}
#ifndef SERIAL_EPD_HOST_TEST
void USBFS_IRQHandler(void) __attribute__((interrupt("WCH-Interrupt-fast")));
#endif
void USBFS_IRQHandler(void)
{
    uint8_t flags=USBFSD->INT_FG, status=USBFSD->INT_ST;
    if(flags&USBFS_UIF_BUS_RST) {
        configured=suspended=0; reset_event=1; endpoints(); USBFSD->DEV_ADDR=0;
        control_left=control_zlp=set_line=address_valid=config_valid=0;
        USBFSD->INT_FG=flags; return;
    }
    if(flags&USBFS_UIF_TRANSFER) {
        uint8_t ep=status&USBFS_UIS_ENDP_MASK;
        uint8_t token=status&USBFS_UIS_TOKEN_MASK;
        if(token==USBFS_UIS_TOKEN_SETUP && ep==0) { if(USBFSD->RX_LEN==8) setup(); else stall(); }
        else if(token==USBFS_UIS_TOKEN_IN) {
            if(ep==0) {
                USBFSD->UEP0_CTRL_H^=USBFS_UEP_T_TOG;
                if(control_left || control_zlp) control_next();
                else {
                    USBFSD->UEP0_CTRL_H=USBFS_UEP_R_TOG|USBFS_UEP_R_RES_ACK|USBFS_UEP_T_RES_NAK;
                    if(address_valid) { USBFSD->DEV_ADDR=pending_address; address_valid=0; }
                    if(config_valid) {
                        configured=pending_config; config_valid=0; reset_event=1;
                        rx_pending=rx_pos=rx_len=in_busy=0; tx_len=tx_pos=tx_zlp=0;
                        notify_busy=0; notify_pending=configured;
                        USBFSD->UEP1_CTRL_H=USBFS_UEP_T_RES_NAK;
                        USBFSD->UEP3_CTRL_H=USBFS_UEP_T_RES_NAK;
                        /* Main loop clears the old protocol session before accepting OUT. */
                        USBFSD->UEP2_CTRL_H=USBFS_UEP_R_RES_NAK;
                    }
                }
            } else if(ep==3) {
                USBFSD->UEP3_CTRL_H=(USBFSD->UEP3_CTRL_H^USBFS_UEP_T_TOG);
                USBFSD->UEP3_CTRL_H=(USBFSD->UEP3_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_NAK;
                in_busy=0;
            } else if(ep==1) {
                USBFSD->UEP1_CTRL_H=(USBFSD->UEP1_CTRL_H^USBFS_UEP_T_TOG);
                USBFSD->UEP1_CTRL_H=(USBFSD->UEP1_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_NAK;
                notify_busy=0;
            }
        } else if(token==USBFS_UIS_TOKEN_OUT && (status&USBFS_UIS_TOG_OK)) {
            if(ep==2 && configured) {
                USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H^USBFS_UEP_R_TOG);
                USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_NAK;
                if(USBFSD->RX_LEN<=sizeof ep2) {
                    rx_len=(uint8_t)USBFSD->RX_LEN; rx_pos=0; rx_pending=1;
                } else reset_event=1;
            } else if(ep==0) {
                if(set_line) {
                    set_line=0;
                    if(USBFSD->RX_LEN!=7) stall();
                    else { memcpy(line,ep0,7); ack_status(); }
                } else if(USBFSD->RX_LEN==0) {
                    control_left=control_zlp=0;
                    USBFSD->UEP0_CTRL_H=USBFS_UEP_R_RES_ACK|USBFS_UEP_T_RES_NAK;
                } else stall();
            }
        }
        USBFSD->INT_FG=USBFS_UIF_TRANSFER;
    }
    if(flags&USBFS_UIF_SUSPEND) {
        suspended=!!(USBFSD->MIS_ST&USBFS_UMS_SUSPEND);
        if(suspended) reset_event=1;
        USBFSD->INT_FG=USBFS_UIF_SUSPEND;
    }
}
void cdc_init(void)
{
    GPIO_InitTypeDef g={0};
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_AFIO|RCC_APB2Periph_GPIOC,ENABLE);
    RCC_AHBPeriphClockCmd(RCC_AHBPeriph_USBFS,ENABLE);
    g.GPIO_Pin=GPIO_Pin_16; g.GPIO_Mode=GPIO_Mode_IN_FLOATING; GPIO_Init(GPIOC,&g);
    g.GPIO_Pin=GPIO_Pin_17; g.GPIO_Mode=GPIO_Mode_IPU; GPIO_Init(GPIOC,&g);
    /* WCH 3.3 V USB PHY and integrated D+ 1.5k pull-up. */
    AFIO->CTLR=(AFIO->CTLR&~0x0Fu)|0x40u|0x0Cu|0x80u;
    USBFSD->BASE_CTRL=0; endpoints(); USBFSD->DEV_ADDR=0;
    USBFSD->BASE_CTRL=USBFS_UC_DEV_PU_EN|USBFS_UC_INT_BUSY|USBFS_UC_DMA_EN;
    USBFSD->INT_FG=0xFF; USBFSD->UDEV_CTRL=USBFS_UD_PD_DIS|USBFS_UD_PORT_EN;
    USBFSD->INT_EN=USBFS_UIE_SUSPEND|USBFS_UIE_BUS_RST|USBFS_UIE_TRANSFER;
    NVIC_EnableIRQ(USBFS_IRQn);
}
int cdc_take_reset(void)
{
    NVIC_DisableIRQ(USBFS_IRQn); int r=reset_event; reset_event=0;
    if(r) {
        rx_pending=rx_pos=rx_len=in_busy=0; tx_len=tx_pos=tx_zlp=0;
        USBFSD->UEP3_CTRL_H=(USBFSD->UEP3_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_NAK;
        if(configured && !ep_halted(2)) USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_ACK;
    }
    NVIC_EnableIRQ(USBFS_IRQn); return r;
}
int cdc_tx_idle(void) { return !in_busy && tx_pos==tx_len && !tx_zlp; }
void cdc_send(const uint8_t *p,uint16_t n)
{
    NVIC_DisableIRQ(USBFS_IRQn);
    if(configured && !suspended && !reset_event && cdc_tx_idle() && n<=sizeof tx) {
        memcpy(tx,p,n); tx_len=n; tx_pos=0; tx_zlp=!(n%64);
    }
    NVIC_EnableIRQ(USBFS_IRQn);
}
void cdc_poll(void)
{
    NVIC_DisableIRQ(USBFS_IRQn);
    if(configured && !suspended && !reset_event && notify_pending && !notify_busy && !ep_halted(0x81)) {
        const uint8_t notification[]={0xA1,0x20,0,0,0,0,2,0,3,0};
        memcpy(ep1,notification,sizeof notification); USBFSD->UEP1_TX_LEN=sizeof notification;
        notify_pending=0; notify_busy=1;
        USBFSD->UEP1_CTRL_H=(USBFSD->UEP1_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_ACK;
    }
    if(configured && !suspended && !reset_event && !in_busy && !ep_halted(0x83) && (tx_pos<tx_len || tx_zlp)) {
        uint16_t n=tx_len-tx_pos; if(n>64) n=64;
        if(n) memcpy(ep3,tx+tx_pos,n); else tx_zlp=0;
        tx_pos+=n; USBFSD->UEP3_TX_LEN=n; in_busy=1;
        USBFSD->UEP3_CTRL_H=(USBFSD->UEP3_CTRL_H&~USBFS_UEP_T_RES_MASK)|USBFS_UEP_T_RES_ACK;
    }
    NVIC_EnableIRQ(USBFS_IRQn);
}
int cdc_read_byte(uint8_t *p)
{
    int got=0; NVIC_DisableIRQ(USBFS_IRQn);
    if(configured && !suspended && !reset_event && rx_pending && cdc_tx_idle()) {
        if(rx_pos<rx_len) { *p=ep2[rx_pos++]; got=1; }
        if(rx_pos==rx_len) {
            rx_pending=0;
            if(!ep_halted(2)) USBFSD->UEP2_CTRL_H=(USBFSD->UEP2_CTRL_H&~USBFS_UEP_R_RES_MASK)|USBFS_UEP_R_RES_ACK;
        }
    }
    NVIC_EnableIRQ(USBFS_IRQn); return got;
}
