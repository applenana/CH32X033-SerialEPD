"""Full frame uploads through the production WCH IRQ, CDC adapter and SEP/1 core."""
import ctypes
import os
from pathlib import Path
import struct
import sys
import unittest
import zlib
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import serialepd as s


class USBProtocol(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib = ctypes.CDLL(os.environ["SERIALEPD_USB_PROTOCOL_SIM"])
        cls.lib.usb_setup.argtypes = [ctypes.c_char_p]
        cls.lib.usb_out.argtypes = [ctypes.c_uint8, ctypes.c_char_p, ctypes.c_uint16, ctypes.c_uint8]
        cls.lib.usb_main_poll.argtypes = [ctypes.c_uint32]
        for name in ("sim_bytes", "sim_refreshes", "sim_crc"):
            getattr(cls.lib, name).restype = ctypes.c_uint32

    def configure(self):
        self.lib.usb_setup(struct.pack("<BBHHH", 0, 9, 1, 0, 0))
        self.lib.usb_in(0)
        self.lib.usb_main_poll(2)
        self.lib.usb_in(1)

    def setUp(self):
        self.lib.sim_reset()
        self.lib.usb_reset()
        self.configure()
        self.sid = 0x12345678
        self.seq = 1

    def feed(self, data):
        for offset in range(0, len(data), 64):
            self.assertEqual(self.lib.usb_ctrl(2) & 12, 0, "OUT endpoint must accept next packet")
            chunk = data[offset:offset + 64]
            self.lib.usb_out(2, chunk, len(chunk), 1)
            self.lib.usb_main_poll(66)

    def take(self):
        data = bytearray()
        for _ in range(4):
            self.lib.usb_main_poll(2)
            if self.lib.usb_ctrl(3) & 3 != 0:
                break
            buf = ctypes.create_string_buffer(64)
            length = self.lib.usb_data(3, buf)
            data.extend(buf.raw[:length])
            self.lib.usb_in(3)
        return bytes(data)

    def send(self, command, payload=b"", seq=None, sid=None):
        request = s.Packet(command, self.seq if seq is None else seq,
                           self.sid if sid is None else sid, payload)
        self.feed(request.encode())
        data = self.take()
        self.assertTrue(data.endswith(b"\0"), "complete SEP/1 response over bulk IN")
        reply = s.Reply.from_packet(s.Packet.decode(data[:-1]))
        if seq is None:
            self.seq += 1
        return reply

    def upload(self, panel):
        frame = bytes(range(256)) * 414
        self.assertEqual(self.send(s.OPEN, seq=0).result, 0)
        begin = struct.pack("<BBHHHII", panel, 1, 768, 552, 0, len(frame), zlib.crc32(frame))
        self.assertEqual(self.send(s.BEGIN, begin).state, 1)
        self.lib.sim_advance(200)
        for offset in range(0, len(frame), 768):
            reply = self.send(s.DATA, struct.pack("<I", offset) + frame[offset:offset + 768])
            self.assertEqual((reply.result, reply.offset), (0, offset + 768))
        self.assertEqual(self.lib.sim_bytes(), len(frame))
        self.assertEqual(self.lib.sim_crc(), zlib.crc32(frame))
        if panel == 1:
            self.assertEqual(self.lib.sim_windows(), 2)
            self.assertEqual(self.lib.sim_cs(), 0)
        self.assertEqual(self.send(s.COMMIT).state, 3)
        self.assertEqual(self.lib.sim_refreshes(), 1)
        self.lib.sim_busy(0)
        self.lib.sim_advance(15000)
        self.assertEqual(self.send(s.STATUS, seq=0, sid=0).state, 4)

    def test_a0_full_frame_over_usb(self):
        self.upload(0)
        self.assertEqual([self.lib.sim_window(i) for i in range(552)],
                         list(range(0, 552, 2)) + list(range(551, 0, -2)))

    def test_a1_full_frame_over_usb(self):
        self.upload(1)
        self.assertEqual(self.lib.sim_windows(), 3)  # COMMIT restores the full refresh window.

    def test_bus_reset_discards_partial_frame_and_allows_reenumeration(self):
        request = s.Packet(s.OPEN, 0, self.sid, b"").encode()
        self.feed(request[:5])
        self.lib.usb_bus_reset()
        self.lib.usb_main_poll(2)
        self.assertEqual(self.lib.usb_config(), 0)
        self.configure()
        self.assertEqual(self.send(s.OPEN, seq=0).result, 0)
        self.assertEqual(self.send(s.INFO, seq=0, sid=0).result, 0)


if __name__ == "__main__":
    unittest.main()
