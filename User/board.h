#ifndef SERIAL_EPD_BOARD_H
#define SERIAL_EPD_BOARD_H
#include <stdint.h>
/* Default CH32X033F8P6 profile: 3.3 V, SPI1 PA5/PA7. See docs/hardware.md. */
#define EPD_CS_PORT GPIOA
#define EPD_CS_PIN GPIO_Pin_4
#define EPD_DC_PORT GPIOA
#define EPD_DC_PIN GPIO_Pin_0
#define EPD_RST_PORT GPIOA
#define EPD_RST_PIN GPIO_Pin_1
#define EPD_BUSY_PORT GPIOA
#define EPD_BUSY_PIN GPIO_Pin_2
void board_init(void);
uint32_t board_millis(void);
int board_spi_write(const uint8_t *data, uint16_t size);
void board_cs(uint8_t level);
void board_dc(uint8_t level);
void board_rst(uint8_t level);
uint8_t board_busy(void);
#endif
