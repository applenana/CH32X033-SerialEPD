#include "protocol.h"
#include "epd.h"
#include <string.h>
static uint8_t wire[PROTO_MAX_WIRE], raw[PROTO_MAX_RAW], previous[PROTO_MAX_RAW];
static uint8_t reply[128], cached[128];
static uint16_t used, previous_len, cached_len;
static uint8_t dropping, last_error, active;
static uint32_t session, next_seq, offset, expected_crc, running_crc, last_data, last_byte;
static uint32_t transfer_start;
static uint32_t bad_frames;
static uint16_t get16(const uint8_t *p) { return (uint16_t)p[0]|((uint16_t)p[1]<<8); }
static uint32_t get32(const uint8_t *p) { return (uint32_t)get16(p)|((uint32_t)get16(p+2)<<16); }
static void put16(uint8_t *p,uint16_t v) { p[0]=(uint8_t)v; p[1]=(uint8_t)(v>>8); }
static void put32(uint8_t *p,uint32_t v) { put16(p,(uint16_t)v); put16(p+2,(uint16_t)(v>>16)); }
uint32_t protocol_crc32(uint32_t crc,const uint8_t *p,uint16_t n)
{
    while(n--) { crc^=*p++; for(uint8_t i=0;i<8;++i) crc=(crc>>1)^((crc&1)?0xEDB88320ul:0); }
    return crc;
}
static uint16_t encode(const uint8_t *p,uint16_t n,uint8_t *out)
{
    uint16_t code_pos=0, w=1; uint8_t code=1;
    while(n--) {
        if(!*p) { out[code_pos]=code; code_pos=w++; code=1; ++p; }
        else { out[w++]=*p++; if(++code==255) { out[code_pos]=code; code_pos=w++; code=1; } }
    }
    out[code_pos]=code; out[w++]=0; return w;
}
static uint16_t decode(void)
{
    uint16_t r=0,w=0;
    while(r<used) {
        uint8_t code=wire[r++];
        if(!code || (uint16_t)(r+code-1)>used) return 0;
        for(uint8_t i=1;i<code;++i) { if(w>=sizeof raw) return 0; raw[w++]=wire[r++]; }
        if(code!=255 && r<used) { if(w>=sizeof raw) return 0; raw[w++]=0; }
    }
    return w;
}
/* Common reply payload: result,state,error,panel driver error,offset,next sequence. */
static uint16_t respond(uint8_t result,uint8_t cache,uint16_t extra)
{
    reply[0]=1; reply[1]=raw[1]; put16(reply+2,1);
    memcpy(reply+4,raw+4,8); put16(reply+12,(uint16_t)(12+extra)); put16(reply+14,0);
    reply[16]=result; reply[17]=epd_state(); reply[18]=last_error; reply[19]=epd_error();
    put32(reply+20,offset); put32(reply+24,next_seq);
    uint16_t n=(uint16_t)(28+extra); put32(reply+n,protocol_crc32(0xFFFFFFFFul,reply,n)^0xFFFFFFFFul);
    /* wire is free after decode and also provides temporary response storage. */
    n=encode(reply,(uint16_t)(n+4),wire);
    if(cache) { memcpy(cached,wire,n); cached_len=n; }
    protocol_send(wire,n); return n;
}
static void abandon(uint8_t reason)
{
    epd_abort(); active=0; last_error=reason;
}
static uint8_t execute(uint8_t cmd,const uint8_t *p,uint16_t n,uint32_t now,uint16_t *extra)
{
    uint8_t st=epd_state();
    switch(cmd) {
    case CMD_INFO:
        if(n) return RES_ARGUMENT;
        /* TLV type:u8 length:u8. Unknown types are skipped. */
        { const uint8_t caps[]={1,4,0,3,0x28,2, 2,4,0,3,0,0, 3,2,3,1,
                              4,3,0,1,0, 5,4,0,0x9E,1,0};
          memcpy(reply+28,caps,sizeof caps); *extra=sizeof caps; }
        return RES_OK;
    case CMD_STATUS:
        if(n) return RES_ARGUMENT;
        put32(reply+28,bad_frames); *extra=4; return RES_OK;
    case CMD_BEGIN:
        if(n!=16 || p[0]>1 || p[1]!=1 || get16(p+2)!=768 || get16(p+4)!=552 ||
           get16(p+6) || get32(p+8)!=EPD_FRAME_BYTES) return RES_ARGUMENT;
        if(st==EPD_INIT || st==EPD_READY || st==EPD_REFRESH) return RES_BUSY;
        offset=0; expected_crc=get32(p+12); running_crc=0xFFFFFFFFul;
        last_error=0; active=1; last_data=transfer_start=now; epd_begin(p[0],now); return RES_OK;
    case CMD_DATA:
        if(n<196 || (n-4)%EPD_ROW_BYTES) return RES_ARGUMENT;
        if(st==EPD_INIT) return RES_BUSY;
        if(st!=EPD_READY || !active) return RES_STATE;
        if(get32(p)!=offset) return RES_OFFSET;
        if((uint32_t)(n-4)>EPD_FRAME_BYTES-offset) return RES_ARGUMENT;
        if(epd_write(p+4,(uint16_t)(n-4))) { active=0; last_error=RES_IO; return RES_IO; }
        running_crc=protocol_crc32(running_crc,p+4,(uint16_t)(n-4));
        offset+=n-4; last_data=now; return RES_OK;
    case CMD_COMMIT:
        if(n) return RES_ARGUMENT;
        if(st!=EPD_READY || !active || offset!=EPD_FRAME_BYTES) return RES_STATE;
        if((running_crc^0xFFFFFFFFul)!=expected_crc) { abandon(RES_CRC); return RES_CRC; }
        active=0; epd_commit(now);
        if(epd_state()==EPD_ERROR) { last_error=RES_IO; return RES_IO; }
        return RES_OK;
    case CMD_ABORT:
        if(n) return RES_ARGUMENT;
        if(st==EPD_REFRESH) return RES_BUSY;
        abandon(0); offset=0; return RES_OK;
    default: return RES_COMMAND;
    }
}
static void packet(uint16_t n,uint32_t now)
{
    if(n<20 || get16(raw+12)>PROTO_MAX_PAYLOAD || n!=20+get16(raw+12) ||
       (protocol_crc32(0xFFFFFFFFul,raw,(uint16_t)(n-4))^0xFFFFFFFFul)!=get32(raw+n-4)) {
        ++bad_frames; return;
    }
    if(raw[0]!=1) { respond(RES_VERSION,0,0); return; }
    if(get16(raw+2) || get16(raw+14)) { respond(RES_ARGUMENT,0,0); return; }
    uint32_t sid=get32(raw+8), seq=get32(raw+4);
    /* Stateless discovery/status never takes ownership or changes the replay cache. */
    if(!sid && !seq && (raw[1]==CMD_INFO || raw[1]==CMD_STATUS)) {
        uint16_t extra=0;
        uint8_t result=execute(raw[1],raw+16,get16(raw+12),now,&extra);
        respond(result,0,extra); return;
    }
    /* Exact comparison avoids CRC-collision-based false duplicate detection. */
    if(previous_len==n && !memcmp(previous,raw,n)) { protocol_send(cached,cached_len); return; }
    if(raw[1]==CMD_OPEN) {
        if(!sid || seq!=0 || get16(raw+12)) { respond(RES_ARGUMENT,0,0); return; }
        if(sid==session) { respond(RES_SEQUENCE,0,0); return; }
        if(epd_state()!=EPD_REFRESH) { abandon(0); offset=0; }
        session=sid; next_seq=1;
        memcpy(previous,raw,n); previous_len=n; respond(RES_OK,1,0); return;
    }
    if(!session || sid!=session) { respond(RES_SESSION,0,0); return; }
    /* Sequence zero is reserved; wrap requires a new session. */
    if(!seq || seq!=next_seq) { respond(RES_SEQUENCE,0,0); return; }
    uint16_t extra=0;
    uint8_t result=execute(raw[1],raw+16,get16(raw+12),now,&extra);
    ++next_seq; memcpy(previous,raw,n); previous_len=n; respond(result,1,extra);
}
void protocol_init(void)
{
    used=previous_len=cached_len=0; dropping=last_error=active=0;
    session=next_seq=offset=bad_frames=last_byte=last_data=0;
}
void protocol_disconnect(void)
{
    if(epd_state()!=EPD_REFRESH) abandon(0);
    session=next_seq=previous_len=used=0; active=0; dropping=0;
}
void protocol_feed(uint8_t b,uint32_t now)
{
    last_byte=now;
    if(!b) {
        if(!dropping && used) { uint16_t n=decode(); if(n) packet(n,now); else ++bad_frames; }
        used=0; dropping=0; return;
    }
    if(dropping) return;
    if(used>=sizeof wire) { dropping=1; used=0; ++bad_frames; return; }
    wire[used++]=b;
}
void protocol_poll(uint32_t now)
{
    epd_poll(now);
    if(used && (uint32_t)(now-last_byte)>2000) { used=0; dropping=1; ++bad_frames; }
    if(active && epd_state()==EPD_ERROR) { active=0; last_error=RES_IO; }
    if(active && epd_state()==EPD_INIT) last_data=transfer_start=now;
    if(active && epd_state()==EPD_READY &&
       ((uint32_t)(now-last_data)>30000 || (uint32_t)(now-transfer_start)>120000)) abandon(RES_TIMEOUT);
    if(epd_state()==EPD_ERROR) last_error=RES_IO;
}
