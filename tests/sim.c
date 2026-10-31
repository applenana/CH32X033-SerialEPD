#include <stdint.h>
#include <string.h>
#include "protocol.h"
#include "epd.h"
#ifdef SERIAL_EPD_USB_SIM
#include "cdc.h"
#endif
static uint8_t output[128], busy, dc, cs, rst, current_cmd, spi_fail;
static uint16_t output_len, windows[600], window_count;
static uint32_t clock_ms, ram_bytes, refreshes, ram_crc, init_commands;
void board_cs(uint8_t v) { cs=v; }
void board_dc(uint8_t v) { dc=v; }
void board_rst(uint8_t v) { rst=v; }
uint8_t board_busy(void) { return busy; }
uint32_t board_millis(void) { return clock_ms; }
int board_spi_write(const uint8_t *data,uint16_t n)
{
    if(spi_fail) return -1;
    if(cs) return -1;
    if(!dc && n==1) {
        current_cmd=data[0]; ++init_commands;
        if(current_cmd==0x12) { ++refreshes; busy=1; }
    } else if(current_cmd==0x10) {
        ram_bytes+=n; ram_crc=protocol_crc32(ram_crc,data,n);
    } else if(current_cmd==0x83 && n==9 && window_count<600) {
        windows[window_count++]=((uint16_t)data[4]<<8)|data[5];
    }
    return 0;
}
void protocol_send(const uint8_t *p,uint16_t n) {
#ifdef SERIAL_EPD_USB_SIM
    cdc_send(p,n);
#else
    memcpy(output,p,n); output_len=n;
#endif
}
void sim_reset(void)
{
    busy=dc=spi_fail=0; cs=rst=1; output_len=window_count=0;
    clock_ms=ram_bytes=refreshes=init_commands=0; ram_crc=0xFFFFFFFFu;
    epd_hw_init(); protocol_init();
}
void sim_feed(const uint8_t *p,uint32_t n) { while(n--) protocol_feed(*p++,clock_ms); }
uint16_t sim_take(uint8_t *p) { uint16_t n=output_len; memcpy(p,output,n); output_len=0; return n; }
void sim_advance(uint32_t ms) { for(uint32_t i=0;i<ms;++i) { ++clock_ms; protocol_poll(clock_ms); } }
void sim_set_time(uint32_t now) { clock_ms=now; }
void sim_busy(uint8_t v) { busy=v; }
void sim_spi_fail(uint8_t v) { spi_fail=v; }
uint32_t sim_bytes(void) { return ram_bytes; }
uint32_t sim_refreshes(void) { return refreshes; }
uint32_t sim_crc(void) { return ram_crc^0xFFFFFFFFu; }
uint16_t sim_window(uint16_t i) { return i<window_count?windows[i]:65535; }
uint16_t sim_windows(void) { return window_count; }
uint8_t sim_cs(void) { return cs; }
uint8_t sim_rst(void) { return rst; }
