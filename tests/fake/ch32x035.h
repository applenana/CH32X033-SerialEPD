#ifndef TEST_USB_HAL_H
#define TEST_USB_HAL_H
#include <stdint.h>
typedef struct {
    uint8_t UEP4_1_MOD, UEP2_3_MOD, BASE_CTRL, DEV_ADDR, INT_FG, INT_ST, MIS_ST, UDEV_CTRL, INT_EN;
    uint16_t RX_LEN;
    uint32_t UEP0_DMA, UEP1_DMA, UEP2_DMA, UEP3_DMA;
    uint16_t UEP0_CTRL_H, UEP1_CTRL_H, UEP2_CTRL_H, UEP3_CTRL_H;
    uint16_t UEP0_TX_LEN, UEP1_TX_LEN, UEP3_TX_LEN;
} USBFake;
extern USBFake fake_usb;
#define USBFSD (&fake_usb)
typedef struct { uint32_t CTLR; } AFIOFake;
extern AFIOFake fake_afio;
#define AFIO (&fake_afio)
typedef struct { uint32_t GPIO_Pin, GPIO_Mode; } GPIO_InitTypeDef;
#define GPIOC 0
#define GPIO_Pin_16 65536
#define GPIO_Pin_17 131072
#define GPIO_Mode_IN_FLOATING 0
#define GPIO_Mode_IPU 1
#define RCC_APB2Periph_AFIO 1
#define RCC_APB2Periph_GPIOC 2
#define RCC_AHBPeriph_USBFS 4
#define ENABLE 1
#define USBFS_IRQn 0
static inline void NVIC_EnableIRQ(int n) {(void)n;}
static inline void NVIC_DisableIRQ(int n) {(void)n;}
static inline void RCC_APB2PeriphClockCmd(int a,int b) {(void)a;(void)b;}
static inline void RCC_AHBPeriphClockCmd(int a,int b) {(void)a;(void)b;}
static inline void GPIO_Init(int a,GPIO_InitTypeDef *b) {(void)a;(void)b;}
#endif
