import ctypes
import os
from pathlib import Path
import random
import struct
import sys
import unittest
import zlib
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import serialepd as s

class Firmware(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = ctypes.CDLL(os.environ["SERIALEPD_SIM"])
        cls.lib.sim_feed.argtypes = [ctypes.c_char_p, ctypes.c_uint32]
        for name in ("sim_bytes", "sim_refreshes", "sim_crc"):
            getattr(cls.lib,name).restype = ctypes.c_uint32
        cls.lib.sim_set_time.argtypes = [ctypes.c_uint32]

    def setUp(self):
        self.lib.sim_reset(); self.seq = 1; self.sid = 0x12345678

    def take(self):
        out = ctypes.create_string_buffer(128); n = self.lib.sim_take(out)
        return s.Packet.decode(out.raw[:n-1]) if n else None

    def send(self, cmd, payload=b"", seq=None, sid=None):
        p = s.Packet(cmd, self.seq if seq is None else seq, self.sid if sid is None else sid, payload)
        self.lib.sim_feed(p.encode(), len(p.encode()))
        response = self.take()
        self.assertIsNotNone(response)
        return s.Reply.from_packet(response)

    def open(self):
        self.assertEqual(self.send(s.OPEN,seq=0).result, 0)

    def command(self, cmd, payload=b""):
        reply = self.send(cmd,payload); self.seq += 1; return reply

    def begin(self, frame, panel=0):
        self.open()
        r = self.command(s.BEGIN,struct.pack("<BBHHHII",panel,1,768,552,0,len(frame),zlib.crc32(frame)))
        self.assertEqual((r.result,r.state),(0,1)); self.lib.sim_advance(200)

    def upload(self, frame, panel=0):
        self.begin(frame,panel)
        for off in range(0,len(frame),768):
            r=self.command(s.DATA,struct.pack("<I",off)+frame[off:off+768])
            self.assertEqual((r.result,r.offset),(0,off+768))

    def test_crc_vector(self):
        self.lib.protocol_crc32.restype=ctypes.c_uint32
        self.lib.protocol_crc32.argtypes=[ctypes.c_uint32,ctypes.c_char_p,ctypes.c_uint16]
        self.assertEqual(self.lib.protocol_crc32(0xFFFFFFFF,b"123456789",9)^0xFFFFFFFF,0xCBF43926)

    def test_stateless_info_status(self):
        info=self.send(s.INFO,seq=0,sid=0)
        self.assertEqual(s.capabilities(info.extra),dict(width=768,height=552,max_chunk=768,panel_mask=3,format=1,firmware="0.1.0",frame_bytes=105984))
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).state,0)

    def test_full_a0_and_mapping(self):
        frame=bytes(range(256))*414
        self.upload(frame)
        self.assertEqual(self.lib.sim_bytes(),s.FRAME_BYTES)
        self.assertEqual(self.lib.sim_crc(),zlib.crc32(frame))
        self.assertEqual([self.lib.sim_window(i) for i in range(552)], list(range(0,552,2))+list(range(551,0,-2)))
        self.assertEqual(self.command(s.COMMIT).state,3)
        self.lib.sim_advance(200); self.lib.sim_busy(0); self.lib.sim_advance(500)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).state,4)

    def test_a1_continuous_cs_and_minimum_refresh(self):
        frame=bytes([0x1B])*s.FRAME_BYTES
        self.upload(frame,1); self.assertEqual(self.lib.sim_cs(),0)
        self.assertEqual(self.lib.sim_windows(),2)
        self.assertEqual(self.command(s.COMMIT).state,3)
        self.lib.sim_busy(0); self.lib.sim_advance(13999)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).state,3)
        self.lib.sim_advance(501)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).state,4)

    def test_duplicate_data_no_double_write(self):
        self.begin(bytes(s.FRAME_BYTES)); payload=struct.pack("<I",0)+bytes(768)
        a=self.send(s.DATA,payload); b=self.send(s.DATA,payload)
        self.assertEqual(a,b); self.assertEqual(self.lib.sim_bytes(),768)
        # Read-only probe must not evict the replay cache.
        self.send(s.STATUS,seq=0,sid=0)
        self.assertEqual(self.send(s.DATA,payload),a)
        self.assertEqual(self.send(s.DATA,payload[:-1]+b"\1").result,5)

    def test_duplicate_commit_no_second_refresh(self):
        self.upload(bytes(s.FRAME_BYTES)); a=self.send(s.COMMIT)
        self.assertEqual(self.send(s.COMMIT),a); self.assertEqual(self.lib.sim_refreshes(),1)
        self.lib.sim_advance(10); self.lib.sim_busy(0); self.lib.sim_advance(1000)
        self.assertEqual(self.send(s.COMMIT),a); self.assertEqual(self.lib.sim_refreshes(),1)

    def test_wrong_frame_crc_never_refreshes(self):
        self.begin(bytes(s.FRAME_BYTES))
        for off in range(0,s.FRAME_BYTES,768):
            self.command(s.DATA,struct.pack("<I",off)+bytes([1])*768)
        self.assertEqual(self.command(s.COMMIT).result,8)
        self.assertEqual(self.lib.sim_refreshes(),0); self.assertEqual(self.lib.sim_rst(),0)

    def test_offsets_length_session_sequence(self):
        self.begin(bytes(s.FRAME_BYTES))
        self.assertEqual(self.command(s.DATA,struct.pack("<I",192)+bytes(192)).result,7)
        self.assertEqual(self.command(s.DATA,struct.pack("<I",0)+bytes(191)).result,3)
        self.assertEqual(self.send(s.COMMIT,seq=99).result,5)
        self.assertEqual(self.send(s.COMMIT,sid=9).result,4)
        self.assertEqual(self.command(s.COMMIT).result,6)
        self.assertEqual(self.lib.sim_bytes(),0)

    def test_timeout_and_recovery(self):
        self.begin(bytes(s.FRAME_BYTES)); self.lib.sim_advance(30001)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).error,11)
        self.assertEqual(self.command(s.ABORT).result,0)
    def test_slow_trickle_cannot_keep_panel_powered_indefinitely(self):
        self.begin(bytes(s.FRAME_BYTES))
        for row in range(5):
            self.lib.sim_advance(23000)
            self.assertEqual(self.command(s.DATA,struct.pack("<I",row*192)+bytes(192)).result,0)
        self.lib.sim_advance(6000)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).error,11)
        self.assertEqual(self.lib.sim_rst(),0)

    def test_busy_stuck_and_spi_failure(self):
        self.open(); self.lib.sim_busy(1)
        self.command(s.BEGIN,struct.pack("<BBHHHII",0,1,768,552,0,s.FRAME_BYTES,0))
        self.lib.sim_advance(10200)
        r=self.send(s.STATUS,seq=0,sid=0)
        self.assertEqual((r.state,r.driver_error),(5,2))
        self.lib.sim_reset(); self.seq=1
        self.begin(bytes(s.FRAME_BYTES)); self.lib.sim_spi_fail(1)
        self.assertEqual(self.command(s.DATA,struct.pack("<I",0)+bytes(192)).result,10)

    def test_reset_aborts_upload_but_preserves_refresh(self):
        self.begin(bytes(s.FRAME_BYTES)); self.lib.protocol_disconnect()
        self.assertEqual(self.send(s.DATA,struct.pack("<I",0)+bytes(192)).result,4)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).state,0)
        self.lib.sim_reset(); self.seq=1; self.upload(bytes(s.FRAME_BYTES)); self.command(s.COMMIT)
        self.lib.protocol_disconnect(); self.sid=2; self.seq=1; self.open()
        self.assertEqual(self.command(s.ABORT).result,9)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).state,3)

    def test_noise_corruption_truncation_and_fragmentation(self):
        self.open()
        bad=bytearray(s.Packet(s.STATUS,1,self.sid).encode()); bad[-3]^=0x80
        self.lib.sim_feed(bytes(bad),len(bad)); self.assertIsNone(self.take())
        self.lib.sim_feed(b"\1"*2000+b"\0",2001); self.assertIsNone(self.take())
        p=s.Packet(s.STATUS,1,self.sid).encode()
        self.lib.sim_feed(p[:7],7); self.lib.sim_advance(2001)
        self.lib.sim_feed(p[7:],len(p)-7); self.assertIsNone(self.take())
        for b in p: self.lib.sim_feed(bytes([b]),1)
        self.assertEqual(s.Reply.from_packet(self.take()).result,0)

    def test_random_malformed_frames_never_refresh(self):
        rng=random.Random(2026)
        for _ in range(3000):
            data=rng.randbytes(rng.randrange(0,1000))+b"\0"
            self.lib.sim_feed(data,len(data)); self.take()
        self.assertEqual(self.lib.sim_refreshes(),0)
        self.assertEqual(self.send(s.INFO,seq=0,sid=0).result,0)

    def test_timer_wrap(self):
        self.lib.sim_set_time(0xFFFFFF80); self.begin(bytes(s.FRAME_BYTES))
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).state,2)
        self.lib.sim_advance(30001)
        self.assertEqual(self.send(s.STATUS,seq=0,sid=0).error,11)

    def test_valid_crc_bad_headers_and_random_commands(self):
        self.open(); rng=random.Random(33)
        for version,flags,reserved,expected in [(2,0,0,1),(1,2,0,3),(1,0,1,3)]:
            raw=s.HEADER.pack(version,s.STATUS,flags,1,self.sid,0,reserved)
            wire=s.cobs_encode(raw+struct.pack("<I",zlib.crc32(raw)))+b"\0"
            self.lib.sim_feed(wire,len(wire))
            self.assertEqual(s.Reply.from_packet(self.take()).result,expected)
        for seq in range(1,2001):
            payload=rng.randbytes(rng.randrange(773))
            reply=self.send(rng.choice([3,16,17,18,19,255]),payload,seq=seq)
            self.assertNotEqual(reply.state,3)
        self.assertEqual(self.lib.sim_refreshes(),0)

    def test_new_session_takeover_and_open_replay(self):
        self.open(); first=self.send(s.OPEN,seq=0)
        self.assertEqual(first.result,0)
        self.command(s.STATUS)
        self.assertEqual(self.send(s.OPEN,seq=0).result,5)
        self.sid=0x55667788; self.seq=1; self.open()
        self.assertEqual(self.send(s.STATUS,sid=0x12345678).result,4)

    def test_a0_refresh_timeout_and_abort_during_init(self):
        self.open()
        self.command(s.BEGIN,struct.pack("<BBHHHII",0,1,768,552,0,s.FRAME_BYTES,0))
        self.assertEqual(self.command(s.ABORT).state,0)
        self.lib.sim_reset(); self.seq=1; self.upload(bytes(s.FRAME_BYTES)); self.command(s.COMMIT)
        self.lib.sim_advance(45001)
        r=self.send(s.STATUS,seq=0,sid=0)
        self.assertEqual((r.state,r.driver_error),(5,3))
        self.assertEqual(self.lib.sim_rst(),0)

class Codec(unittest.TestCase):
    def test_documented_vectors(self):
        import json
        path=Path(__file__).resolve().parents[1]/"docs/protocol-vectors.json"
        for v in json.loads(path.read_text())["vectors"]:
            p=s.Packet(v["command"],v["sequence"],v["session"],bytes.fromhex(v["payload_hex"]))
            self.assertEqual(p.encode().hex(),v["wire_hex"])
            self.assertEqual(s.cobs_decode(p.encode()[:-1]).hex(),v["raw_hex"])
    def test_cobs_roundtrip_and_boundaries(self):
        rng=random.Random(42)
        for n in (0,1,2,253,254,255,256,772,792):
            for data in (bytes(n),b"\xff"*n,rng.randbytes(n)):
                enc=s.cobs_encode(data); self.assertNotIn(0,enc)
                self.assertEqual(s.cobs_decode(enc),data)

    def test_stream_multiple_frames_and_noise(self):
        p=s.Packet(s.INFO,0,0); decoder=s.StreamDecoder()
        self.assertEqual(decoder.feed(b"garbage\0"+p.encode()*3),[p]*3)

    def test_pixels_are_msb_first(self):
        idx=bytes([0,1,2,3])*(s.WIDTH*s.HEIGHT//4)
        packed=s.pack_indices(idx)
        self.assertEqual(packed,bytes([0x1B])*s.FRAME_BYTES)
        self.assertEqual(s.unpack_indices(packed),idx)

    def test_reference_rotation_cancels(self):
        # MoInk page packIdx rotates 180 degrees; epd_drv mirrors it again.
        idx=bytes((i//768+i//4)%4 for i in range(768*552))
        reference_buffer=s.pack_indices(idx[::-1])
        lookup=bytes(((v&3)<<6)|((v&12)<<2)|((v&48)>>2)|((v&192)>>6) for v in range(256))
        reference_stream=bytes(lookup[v] for v in reference_buffer[::-1])
        self.assertEqual(s.pack_indices(idx),reference_stream)

    def test_pattern_and_conversion(self):
        import tempfile
        from PIL import Image
        frame=s.test_pattern(); self.assertEqual(len(frame),s.FRAME_BYTES)
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/"source.png"
            Image.new("RGBA",(10,10),(255,0,0,0)).save(path)
            self.assertEqual(s.convert_image(path),b"\x55"*s.FRAME_BYTES)

class HostClient(unittest.TestCase):
    def setUp(self):
        Firmware.setUpClass(); self.lib=Firmware.lib; self.lib.sim_reset()

    def test_real_client_full_upload_with_lost_acks_partial_io(self):
        from unittest.mock import patch
        lib=self.lib
        class Transport:
            def __init__(self):
                self.now=0.; self.rx=bytearray(); self.dropped=set()
            def write(self,data):
                part=data[:11]; lib.sim_feed(part,len(part))
                out=ctypes.create_string_buffer(128); n=lib.sim_take(out)
                if n:
                    response=s.Packet.decode(out.raw[:n-1])
                    if response.command in (s.OPEN,s.DATA,s.COMMIT) and response.command not in self.dropped:
                        self.dropped.add(response.command)
                    else:
                        self.rx.extend(out.raw[:n])
                return len(part)
            def read(self,n):
                self.now+=.02; lib.sim_advance(20)
                if lib.sim_refreshes(): lib.sim_busy(0)
                result=bytes(self.rx[:7]); del self.rx[:7]; return result
            def sleep(self,seconds):
                self.now+=seconds; lib.sim_advance(int(seconds*1000))
        transport=Transport(); client=s.Client(transport,timeout=.5)
        frame=bytes([0x1B])*s.FRAME_BYTES
        with patch.object(s.time,"monotonic",lambda:transport.now), patch.object(s.time,"sleep",transport.sleep):
            result=client.upload(frame,0)
        self.assertEqual(result.state,4)
        self.assertEqual(lib.sim_bytes(),s.FRAME_BYTES)
        self.assertEqual(lib.sim_refreshes(),1)
        self.assertEqual(lib.sim_crc(),zlib.crc32(frame))
        self.assertEqual(transport.dropped,{s.OPEN,s.DATA,s.COMMIT})

    def test_client_timeout_preserves_sequence_and_stops(self):
        from unittest.mock import patch
        class Silent:
            now=0.; writes=[]
            def write(self,data): self.writes.append(data); return len(data)
            def read(self,n): self.now+=1; return b""
        transport=Silent(); client=s.Client(transport,timeout=.5,retries=2)
        client.session=99; client.sequence=1
        with patch.object(s.time,"monotonic",lambda:transport.now):
            with self.assertRaises(TimeoutError): client.request(s.COMMIT)
        self.assertEqual(client.sequence,1)
        with self.assertRaises(RuntimeError): client.request(s.ABORT)
        self.assertEqual(len(transport.writes),3)
        self.assertTrue(all(x==transport.writes[0] for x in transport.writes))

if __name__ == "__main__": unittest.main()
