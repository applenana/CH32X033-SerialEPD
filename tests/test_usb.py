import ctypes
import json
from pathlib import Path
import os
import struct
import unittest

class USB(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.lib=ctypes.CDLL(os.environ["SERIALEPD_USB_SIM"])
        cls.lib.usb_setup.argtypes=[ctypes.c_char_p]
        cls.lib.usb_setup_raw.argtypes=[ctypes.c_char_p,ctypes.c_uint32]
        cls.lib.usb_out_raw.argtypes=[ctypes.c_uint8,ctypes.c_char_p,ctypes.c_uint16,ctypes.c_uint8,ctypes.c_uint32]
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
    def test_control_sequence_matches_hardware_verified_wch_source(self):
        # Generated from the preserved official controller, not this adapter.
        # GPIO/UART are stubbed; this fixture is not a physical USB capture.
        fixture=json.loads(Path(__file__).with_name("wch-control-trace.json").read_text())
        for i,event in enumerate(fixture["events"]):
            with self.subTest(event=i,kind=event["event"]):
                args=event["args"]
                if event["event"]=="reset": self.lib.usb_reset()
                elif event["event"]=="setup": self.setup(*args)
                elif event["event"]=="in": self.lib.usb_in(0)
                elif event["event"]=="out":
                    data=bytes.fromhex(args[0]); self.lib.usb_out(0,data,len(data),1)
                actual=dict(ctrl=self.lib.usb_ctrl(0),address=self.lib.usb_address(),
                            config=self.lib.usb_config(),data=self.data().hex())
                self.assertEqual(actual,event["expected"])

    def test_idle_main_loop_leaves_usb_interrupt_enabled(self):
        for configured in (False,True):
            if configured:
                self.configured(); self.lib.cdc_poll(); self.lib.usb_in(1)
            before=self.lib.usb_irq_disables()
            for _ in range(1000):
                self.lib.cdc_take_reset(); self.lib.cdc_poll(); self.read()
            self.assertEqual(self.lib.usb_irq_disables(),before)

    def test_suspend_resume_preserves_bulk_data_toggles(self):
        self.configured()
        self.lib.usb_out(2,b"a",1,1); self.assertEqual(self.read(),97)
        self.lib.cdc_send(b"b",1); self.lib.cdc_poll(); self.lib.usb_in(3)
        before_rx=self.lib.usb_ctrl(2)&0x80
        before_tx=self.lib.usb_ctrl(3)&0x40
        self.lib.usb_suspend(1); self.lib.cdc_take_reset()
        self.lib.usb_suspend(0); self.lib.cdc_take_reset()
        self.assertEqual(self.lib.usb_ctrl(2)&0x80,before_rx)
        self.assertEqual(self.lib.usb_ctrl(3)&0x40,before_tx)
        self.lib.usb_out(2,b"c",1,1); self.assertEqual(self.read(),99)

    def test_setup_ignores_bits_outside_rx_length_register(self):
        request=struct.pack("<BBHHH",0x80,6,0x100,0,64)
        self.lib.usb_setup_raw(request,0xA5A50008)
        self.assertEqual(self.lib.usb_ctrl(0)&3,0)
        self.assertEqual(len(self.data()),18)
        self.assertEqual(self.data()[:2],bytes([18,1]))

    def test_completed_setup_does_not_depend_on_out_receive_length(self):
        # WCH SimulateCDC dispatches SETUP from INT_ST, without an RX_LEN gate.
        # The event has a complete eight-byte setup buffer in all these cases.
        request=struct.pack("<BBHHH",0x80,6,0x100,0,64)
        for received in (0,7,8,64,0xA5A50000):
            with self.subTest(received=received):
                self.lib.usb_reset()
                self.lib.usb_setup_raw(request,received)
                self.assertEqual(self.lib.usb_ctrl(0)&3,0)
                self.assertEqual(self.data()[:2],bytes([18,1]))
                self.assertEqual(len(self.data()),18)
        # Request validation still runs even when the OUT length is zero.
        self.lib.usb_setup_raw(struct.pack("<BBHHH",0x80,6,0x399,0,64),0)
        self.assertEqual(self.lib.usb_ctrl(0)&15,15)

    def test_control_out_uses_16_bit_rx_length(self):
        self.configured()
        coding=struct.pack("<IBBB",115200,0,0,8)
        self.setup(0x21,0x20,length=7)
        self.lib.usb_out_raw(0,coding,7,1,0xA5A50007)
        self.assertEqual(self.lib.usb_ctrl(0)&3,0)
        self.lib.usb_in(0)
        self.setup(0xA1,0x21,length=7)
        self.assertEqual(self.data(),coding)
        self.lib.usb_in(0)
        self.lib.usb_out_raw(0,b"",0,1,0xA5A50000)
        self.assertEqual(self.lib.usb_ctrl(0)&15,0)

    def test_bulk_out_uses_16_bit_rx_length_and_rejects_oversize(self):
        self.configured(); payload=bytes(range(64))
        self.lib.usb_out_raw(2,payload,64,1,0xA5A50040)
        self.assertEqual([self.read() for _ in range(64)],list(payload))
        self.lib.usb_out_raw(2,b"x"*65,65,1,0xA5A50041)
        self.assertTrue(self.lib.cdc_take_reset())
        self.assertIsNone(self.read())

    def test_enumeration_with_receive_length_not_updated_for_setup(self):
        upper=0xA5A50000
        setup_lengths=iter((0,64,7,8,0,64,7,0,8))
        def setup(typ,req,value=0,index=0,length=0):
            packet=struct.pack("<BBHHH",typ,req,value,index,length)
            self.lib.usb_setup_raw(packet,upper|next(setup_lengths))
        def control_read(value,length,index=0):
            setup(0x80,6,value,index,length)
            result=b""
            while True:
                self.assertEqual(self.lib.usb_ctrl(0)&3,0)
                packet=self.data(); result+=packet
                self.lib.usb_in(0)
                if len(packet)<64 or len(result)>=length: break
            self.assertEqual(self.lib.usb_ctrl(0)&12,0)
            self.lib.usb_out_raw(0,b"",0,1,upper)
            self.assertEqual(self.lib.usb_ctrl(0)&15,0)
            return result
        first=control_read(0x100,8)
        self.assertEqual(len(first),8); self.assertEqual(first[7],64)
        self.lib.usb_reset()
        setup(0,5,37)
        self.assertEqual(self.lib.usb_address(),0)
        self.lib.usb_in(0); self.assertEqual(self.lib.usb_address(),37)
        self.assertEqual(len(control_read(0x100,18)),18)
        header=control_read(0x200,9)
        total=struct.unpack_from("<H",header,2)[0]
        config=control_read(0x200,total)
        self.assertEqual(len(config),67); self.assertEqual(config[:9],header)
        self.assertEqual(control_read(0x300,255),bytes.fromhex("04030904"))
        for index in (1,2):
            descriptor=control_read(0x300|index,255,0x409)
            self.assertEqual(len(descriptor),descriptor[0])
        setup(0,9,1); self.assertEqual(self.lib.usb_config(),1)
        self.lib.usb_in(0); self.assertEqual(self.lib.usb_config(),1)
        self.assertTrue(self.lib.cdc_take_reset())
        self.assertEqual(self.lib.usb_ctrl(2)&12,0)

    def test_device_and_two_packet_config_descriptor(self):
        self.setup(0x80,6,0x100,length=64)
        d=self.data(); self.assertEqual(len(d),18); self.assertEqual(d[4],2)
        self.setup(0x80,6,0x200,length=255)
        d=self.data(); self.assertEqual(len(d),64)
        self.lib.usb_in(0); d+=self.data(); self.assertEqual(len(d),67)
        self.assertEqual(struct.unpack_from("<H",d,2)[0],67)
        self.lib.usb_in(0)
        # WCH keeps IN ACK with a zero-length packet and arms status OUT.
        self.assertEqual(self.data(),b"")
        self.assertEqual(self.lib.usb_ctrl(0)&15,0)
    def test_wch_address_after_status_and_config_during_setup(self):
        # Match the hardware-proven WCH handler: address is deferred, config is immediate.
        self.setup(0,5,37); self.assertEqual(self.lib.usb_address(),0)
        self.lib.usb_in(0); self.assertEqual(self.lib.usb_address(),37)
        self.setup(0,9,1); self.assertEqual(self.lib.usb_config(),1)
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
        self.lib.usb_suspend(0); self.assertTrue(self.lib.cdc_take_reset())
        self.assertTrue(self.lib.cdc_tx_idle())
        self.lib.usb_out(2,b"resume",6,1)
        self.assertEqual([self.read() for _ in range(6)],list(b"resume"))
        self.lib.usb_reset(); self.assertEqual(self.lib.usb_config(),0)

if __name__=="__main__": unittest.main()
