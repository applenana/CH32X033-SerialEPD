/* Register sequences and A0 gate mapping researched from atunverse/moink
 * src/epd_drv.c (see docs/references.md). No framebuffer required. */
#include "epd.h"
#include "board.h"
#include <stddef.h>
static uint8_t state, error, panel, phase, saw_busy;
static uint16_t rows;
static uint32_t entered, ready_since;
static void fail(uint8_t e)
{
    error = e; state = EPD_ERROR; board_cs(1); board_rst(0);
}
static int cmd(uint8_t c, const uint8_t *p, uint16_t n)
{
    board_cs(1); board_dc(0); board_cs(0);
    if (board_spi_write(&c, 1)) { fail(1); return -1; }
    if (n) { board_dc(1); if (board_spi_write(p, n)) { fail(1); return -1; } }
    board_cs(1); return 0;
}
static void window(uint16_t start, uint16_t end)
{
    const uint8_t p[] = {0,0,2,255,(uint8_t)(start>>8),(uint8_t)start,
                        (uint8_t)(end>>8),(uint8_t)end,1};
    cmd(0x83,p,sizeof p);
}
/* Length, command, data. A1 unlock/boost/TCON/PLL/VCOM/cascade sequence. */
static const uint8_t a1_init[] = {
    6,0xAA,0x49,0x55,0x20,0x08,0x09,0x18,
    1,0x01,0x3F, 2,0x00,0x4B,0x69,
    4,0x05,0x40,0x1F,0x1F,0x2C, 4,0x08,0x6F,0x1F,0x1F,0x22,
    4,0x06,0x6F,0x1F,0x14,0x14, 4,0x03,0,0x54,0,0x44,
    2,0x60,2,0, 1,0x30,8, 1,0x50,0x3F,
    4,0x61,3,0,2,0x58, 4,0x65,0x10,0,0x20,0,
    1,0xE3,0x2F, 1,0x84,1, 0
};
static void configure(void)
{
    if (panel) {
        const uint8_t *p = a1_init;
        while (*p && state != EPD_ERROR) { uint8_t n=*p++; uint8_t c=*p++; cmd(c,p,n); p+=n; }
        if (state != EPD_ERROR) window(0,599);
    } else {
        const uint8_t psr=0x0B, res[]={3,0,2,0x28};
        if (!cmd(0x00,&psr,1)) cmd(0x61,res,4);
    }
    if (state != EPD_ERROR) cmd(0x04,NULL,0);
}
void epd_hw_init(void) { state=EPD_IDLE; error=0; board_cs(1); board_rst(0); }
uint8_t epd_state(void) { return state; }
uint8_t epd_error(void) { return error; }
void epd_begin(uint8_t p, uint32_t now)
{
    panel=p; error=0; rows=0; phase=0; state=EPD_INIT; entered=now;
    board_cs(1); board_rst(1);
}
void epd_abort(void) { board_cs(1); board_rst(0); state=EPD_IDLE; error=0; rows=0; }
void epd_poll(uint32_t now)
{
    uint32_t elapsed=now-entered;
    uint32_t limit=panel?180000ul:45000ul;
    if (state==EPD_INIT) {
        switch (phase) {
        case 0: if(elapsed>=20) { board_rst(0); phase=1; entered=now; } break;
        case 1: if(elapsed>=40) { board_rst(1); phase=2; entered=now; } break;
        case 2:
            if(elapsed>=50 && !board_busy()) { phase=3; entered=now; }
            else if(elapsed>(panel?180000ul:10000ul)) fail(2);
            break;
        case 3:
            if(elapsed>=30) { configure(); phase=4; entered=now; } break;
        case 4:
            if(elapsed>=10 && !board_busy()) {
                /* Reference repeats POWER_ON before writing RAM. */
                if(!cmd(0x04,NULL,0)) { phase=5; entered=now; }
            } else if(elapsed>limit) fail(2);
            break;
        case 5:
            if(elapsed>=10 && !board_busy()) {
                if(panel) {
                    window(0,551);
                    if(state!=EPD_ERROR && !cmd(0x10,NULL,0)) { board_dc(1); board_cs(0); }
                }
                if(state!=EPD_ERROR) state=EPD_READY;
            } else if(elapsed>45000ul) fail(2);
            break;
        }
    } else if (state==EPD_REFRESH) {
        if(phase==0) {
            if(board_busy()) { saw_busy=1; ready_since=now; }
            /* A1 has false early BUSY release: minimum 14 s plus stable ready.
             * A0 requires observing BUSY asserted, then stable high for 100 ms. */
            if(elapsed>limit) { fail(3); return; }
            if(!panel && !saw_busy && elapsed>1000) { fail(4); return; }
            if(!board_busy() && (panel || saw_busy) && elapsed>=(panel?14000ul:100ul)
               && (uint32_t)(now-ready_since)>=(panel?500ul:100ul)) {
                const uint8_t zero=0;
                if(!cmd(0x02,&zero,1)) { phase=1; entered=now; }
            }
        } else if(phase==1) {
            if(elapsed>=10 && !board_busy()) {
                const uint8_t sleep=0xA5;
                if(!cmd(0x07,&sleep,1)) { phase=2; entered=now; }
            } else if(elapsed>45000ul) fail(5);
        } else if(elapsed>=200) state=EPD_DONE;
    }
}
int epd_write(const uint8_t *data, uint16_t length)
{
    if(state!=EPD_READY || !length || length%EPD_ROW_BYTES ||
       rows+length/EPD_ROW_BYTES>EPD_HEIGHT) return -1;
    while(length) {
        if(!panel) {
            uint16_t y=rows<276 ? rows*2 : 2*(552-rows)-1;
            window(y,y);
            if(state==EPD_ERROR || cmd(0x10,NULL,0)) return -1;
            board_dc(1); board_cs(0);
        }
        if(board_spi_write(data,EPD_ROW_BYTES)) { fail(1); return -1; }
        if(!panel) board_cs(1);
        ++rows; data+=EPD_ROW_BYTES; length-=EPD_ROW_BYTES;
    }
    return 0;
}
void epd_commit(uint32_t now)
{
    const uint8_t zero=0;
    if(state!=EPD_READY || rows!=EPD_HEIGHT) { fail(6); return; }
    board_cs(1); window(0,panel?599:551);
    if(state==EPD_ERROR || cmd(0x12,&zero,1)) return;
    state=EPD_REFRESH; phase=0; entered=ready_since=now; saw_busy=board_busy();
}
