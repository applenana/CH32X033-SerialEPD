#include "ch32x035.h"
#include "board.h"
#include "cdc.h"
#include "epd.h"
#include "protocol.h"
void protocol_send(const uint8_t *p,uint16_t n) { cdc_send(p,n); }
int main(void)
{
    NVIC_PriorityGroupConfig(NVIC_PriorityGroup_1);
    SystemCoreClockUpdate(); board_init(); epd_hw_init(); protocol_init(); cdc_init();
#ifndef SERIAL_EPD_DISABLE_WATCHDOG
    /* Same 32/4000 setup as WCH IWDG example (nominally about 2.7 s). */
    IWDG_WriteAccessCmd(IWDG_WriteAccess_Enable);
    IWDG_SetPrescaler(IWDG_Prescaler_32); IWDG_SetReload(4000);
    IWDG_ReloadCounter(); IWDG_Enable();
#endif
    for(;;) {
        uint8_t byte;
        if(cdc_take_reset()) protocol_disconnect();
        protocol_poll(board_millis());
        cdc_poll();
        if(cdc_read_byte(&byte)) protocol_feed(byte,board_millis());
#ifndef SERIAL_EPD_DISABLE_WATCHDOG
        IWDG_ReloadCounter();
#endif
    }
}
