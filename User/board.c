#include "ch32x035.h"
#include "board.h"
static volatile uint32_t ticks;
void TIM2_UP_IRQHandler(void) __attribute__((interrupt("WCH-Interrupt-fast")));
void TIM2_UP_IRQHandler(void)
{
    if (TIM2->INTFR & TIM_IT_Update) {
        TIM2->INTFR = (uint16_t)~TIM_IT_Update;
        ++ticks;
    }
}
uint32_t board_millis(void) { return ticks; }
void board_cs(uint8_t v) { GPIO_WriteBit(EPD_CS_PORT, EPD_CS_PIN, v ? Bit_SET : Bit_RESET); }
void board_dc(uint8_t v) { GPIO_WriteBit(EPD_DC_PORT, EPD_DC_PIN, v ? Bit_SET : Bit_RESET); }
void board_rst(uint8_t v) { GPIO_WriteBit(EPD_RST_PORT, EPD_RST_PIN, v ? Bit_SET : Bit_RESET); }
uint8_t board_busy(void) { return !GPIO_ReadInputDataBit(EPD_BUSY_PORT, EPD_BUSY_PIN); }
void board_init(void)
{
    GPIO_InitTypeDef g = {0};
    SPI_InitTypeDef s = {0};
    TIM_TimeBaseInitTypeDef t = {0};
    RCC_APB2PeriphClockCmd(RCC_APB2Periph_GPIOA | RCC_APB2Periph_GPIOC |
                          RCC_APB2Periph_AFIO | RCC_APB2Periph_SPI1, ENABLE);
    RCC_APB1PeriphClockCmd(RCC_APB1Periph_TIM2, ENABLE);
    board_cs(1); board_rst(1); board_dc(0);
    g.GPIO_Speed = GPIO_Speed_50MHz; g.GPIO_Mode = GPIO_Mode_Out_PP;
    g.GPIO_Pin = EPD_CS_PIN; GPIO_Init(EPD_CS_PORT, &g);
    g.GPIO_Pin = EPD_DC_PIN; GPIO_Init(EPD_DC_PORT, &g);
    g.GPIO_Pin = EPD_RST_PIN; GPIO_Init(EPD_RST_PORT, &g);
    /* Pull-down: a disconnected BUSY line fails closed (busy), not success. */
    g.GPIO_Pin = EPD_BUSY_PIN; g.GPIO_Mode = GPIO_Mode_IPD; GPIO_Init(EPD_BUSY_PORT, &g);
    g.GPIO_Pin = GPIO_Pin_5 | GPIO_Pin_7; g.GPIO_Mode = GPIO_Mode_AF_PP; GPIO_Init(GPIOA, &g);
    s.SPI_Direction = SPI_Direction_1Line_Tx; s.SPI_Mode = SPI_Mode_Master;
    s.SPI_DataSize = SPI_DataSize_8b; s.SPI_CPOL = SPI_CPOL_Low;
    s.SPI_CPHA = SPI_CPHA_1Edge; s.SPI_NSS = SPI_NSS_Soft;
    s.SPI_BaudRatePrescaler = SPI_BaudRatePrescaler_16; /* 3 MHz at 48 MHz */
    s.SPI_FirstBit = SPI_FirstBit_MSB; s.SPI_CRCPolynomial = 7;
    SPI_Init(SPI1, &s); SPI_Cmd(SPI1, ENABLE);
    t.TIM_Prescaler = (uint16_t)(SystemCoreClock / 1000000u - 1u);
    t.TIM_Period = 999; t.TIM_CounterMode = TIM_CounterMode_Up;
    TIM_TimeBaseInit(TIM2, &t); TIM_ClearITPendingBit(TIM2, TIM_IT_Update);
    TIM_ITConfig(TIM2, TIM_IT_Update, ENABLE); NVIC_EnableIRQ(TIM2_UP_IRQn);
    TIM_Cmd(TIM2, ENABLE);
}
int board_spi_write(const uint8_t *data, uint16_t size)
{
    uint32_t start = ticks;
    while (size--) {
        while (!(SPI1->STATR & SPI_I2S_FLAG_TXE)) if ((uint32_t)(ticks - start) > 20) return -1;
        SPI1->DATAR = *data++;
    }
    while (!(SPI1->STATR & SPI_I2S_FLAG_TXE)) if ((uint32_t)(ticks - start) > 20) return -1;
    while (SPI1->STATR & SPI_I2S_FLAG_BSY) if ((uint32_t)(ticks - start) > 20) return -1;
    return 0;
}
