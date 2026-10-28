import ctypes
import os
import struct
import unittest

class USB(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=ctypes.CDLL(os.environ["SERIALEPD_USB_SIM"])
        cls.lib.usb_setup.argtypes=[ctypes.c_char_p]
        cls.lib.usb_out.argtypes=[ctypes.c_uint8,ctypes.c_char_p,ctypes.c_uint16,ctypes.c_uint8]
        cls.lib.cdc_send.argtypes=[ctypes.c_char_p,ctypes.c_uint16]

    def setUp(self): self.lib.usb_reset()
    def setup(self,typ,req,value=0,index=0,length=0):
        self.lib.usb_setup(struct.pack("<BBHHH",typ,req,value,index,length))
    def data(self,ep=0):
        buf=ctypes.create_string_buffer(128); n=self.lib.usb_data(ep,buf)
        return buf.raw[:n]
    def configured(self):
        self.setup(0,9,1); self.lib.usb_in(0); self.lib.cdc_take_reset()
    def read(self):
        b=ctypes.c_uint8(); return b.value if self.lib.cdc_read_byte(ctypes.byref(b)) else None
    def test_device_and_two_packet_config_descriptor(self):
        self.setup(0x80,6,0x100,length=64)
        d=self.data(); self.assertEqual(len(d),18); self.assertEqual(d[4],2)
        self.setup(0x80,6,0x200,length=255)
        d=self.data(); self.assertEqual(len(d),64)
        self.lib.usb_in(0); d+=self.data(); self.assertEqual(len(d),67)
        self.assertEqual(struct.unpack_from("<H",d,2)[0],67)
        self.lib.usb_in(0); self.assertEqual(self.lib.usb_ctrl(0)&3,2)
    def test_address_and_config_applied_after_status(self):
        self.setup(0,5,37); self.assertEqual(self.lib.usb_address(),0)
        self.lib.usb_in(0); self.assertEqual(self.lib.usb_address(),37)
        self.setup(0,9,1); self.assertEqual(self.lib.usb_config(),0)
        self.lib.usb_in(0); self.assertEqual(self.lib.usb_config(),1)
        self.setup(0,9,0); self.lib.usb_in(0); self.assertEqual(self.lib.usb_config(),0)
    def test_unsupported_control_requests_stall_and_recover(self):
        for args in [(0xC0,1,0,0,65535),(0x80,6,0x399,0,255),(0,9,2,0,0),
                     (0xA1,0x21,0,0,65535),(0,5,128,0,0)]:
            self.setup(*args); self.assertEqual(self.lib.usb_ctrl(0)&15,15)
        self.setup(0x80,6,0x100,length=18); self.assertEqual(len(self.data()),18)
    def test_line_coding_and_dtr(self):
        self.configured(); coding=struct.pack("<IBBB",921600,0,0,8)
        self.setup(0x21,0x20,length=7); self.lib.usb_out(0,coding,7,1); self.lib.usb_in(0)
        self.setup(0xA1,0x21,length=7); self.assertEqual(self.data(),coding)
        self.setup(0x21,0x22,value=3); self.assertEqual(self.lib.usb_ctrl(0)&3,0)
        self.setup(0x21,0x20,length=7); self.lib.usb_out(0,b"x",1,1)
        self.assertEqual(self.lib.usb_ctrl(0)&15,15)
    def test_serial_state_notification_and_toggle(self):
        self.configured(); self.lib.cdc_poll()
        self.assertEqual(self.data(1),bytes.fromhex("a1200000000002000300"))
        self.assertEqual(self.lib.usb_ctrl(1)&0x40,0)
        self.lib.usb_in(1)
        self.setup(0x21,0x22,value=1); self.lib.usb_in(0); self.lib.cdc_poll()
        self.assertEqual(self.lib.usb_ctrl(1)&0x40,0x40)
        self.lib.usb_in(1); self.assertEqual(self.lib.usb_ctrl(1)&0x40,0)
    def test_rx_nak_and_duplicate_usb_toggle(self):
        self.configured(); self.lib.usb_out(2,b"abc",3,0); self.assertIsNone(self.read())
        self.lib.usb_out(2,b"abc",3,1); self.assertEqual(self.lib.usb_ctrl(2)&12,8)
        self.assertEqual([self.read(),self.read(),self.read()],[97,98,99])
        self.assertEqual(self.lib.usb_ctrl(2)&12,0)
    def test_tx_segmentation_zlp_and_rx_backpressure(self):
        self.configured(); payload=bytes(range(128)); self.lib.cdc_send(payload,128)
        self.lib.usb_out(2,b"x",1,1); self.assertIsNone(self.read())
        self.lib.cdc_poll(); self.assertEqual(self.data(3),payload[:64]); self.lib.usb_in(3)
        self.lib.cdc_poll(); self.assertEqual(self.data(3),payload[64:]); self.lib.usb_in(3)
        self.assertFalse(self.lib.cdc_tx_idle()); self.lib.cdc_poll(); self.assertEqual(self.data(3),b"")
        self.lib.usb_in(3); self.assertTrue(self.lib.cdc_tx_idle()); self.assertEqual(self.read(),120)
    def test_endpoint_halt_clear_preserves_pending_rx(self):
        self.configured(); self.lib.usb_out(2,b"xy",2,1)
        self.setup(2,3,index=2); self.assertEqual(self.lib.usb_ctrl(2)&12,12)
        self.setup(2,1,index=2); self.assertEqual(self.lib.usb_ctrl(2)&12,8)
        self.assertEqual([self.read(),self.read()],[120,121]); self.assertEqual(self.lib.usb_ctrl(2)&12,0)
    def test_suspend_and_reset_flush_transport(self):
        self.configured(); self.lib.cdc_send(b"hello",5); self.lib.cdc_poll()
        self.lib.usb_suspend(1); self.assertTrue(self.lib.cdc_take_reset())
        self.lib.usb_suspend(0); self.assertTrue(self.lib.cdc_tx_idle())
        self.lib.usb_reset(); self.assertEqual(self.lib.usb_config(),0)

if __name__=="__main__": unittest.main()
