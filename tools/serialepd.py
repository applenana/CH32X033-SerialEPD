"""SerialEPD v1 reference codec, reliable client and image CLI (Python 3.10+)."""
import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import secrets
import struct
import time
import zlib

WIDTH, HEIGHT, ROW_BYTES, FRAME_BYTES = 768, 552, 192, 105984
MAX_PAYLOAD, MAX_WIRE = 772, 797
OPEN, INFO, STATUS, BEGIN, DATA, COMMIT, ABORT = 1, 2, 3, 16, 17, 18, 19
STATES = ("IDLE", "INIT", "READY", "REFRESH", "DONE", "ERROR")
RESULTS = ("OK", "VERSION", "COMMAND", "ARGUMENT", "SESSION", "SEQUENCE", "STATE",
           "OFFSET", "CRC", "BUSY", "IO", "TIMEOUT")
HEADER = struct.Struct("<BBHIIHH")
PALETTE = [(0, 0, 0), (255, 255, 255), (255, 255, 0), (255, 0, 0)]

def cobs_encode(data):
    out = bytearray([0]); start = 0; code = 1
    for b in data:
        if b == 0:
            out[start] = code; start = len(out); out.append(0); code = 1
        else:
            out.append(b); code += 1
            if code == 255:
                out[start] = code; start = len(out); out.append(0); code = 1
    out[start] = code
    return bytes(out)

def cobs_decode(data):
    out = bytearray(); i = 0
    while i < len(data):
        code = data[i]; i += 1
        if code == 0 or i + code - 1 > len(data):
            raise ValueError("invalid COBS")
        part = data[i:i + code - 1]
        if 0 in part:
            raise ValueError("zero inside COBS")
        out.extend(part); i += code - 1
        if code != 255 and i < len(data):
            out.append(0)
    return bytes(out)

@dataclass(frozen=True)
class Packet:
    command: int
    sequence: int
    session: int
    payload: bytes = b""
    flags: int = 0

    def encode(self):
        if len(self.payload) > MAX_PAYLOAD:
            raise ValueError("payload exceeds negotiated v1 limit")
        raw = HEADER.pack(1, self.command, self.flags, self.sequence, self.session, len(self.payload), 0) + self.payload
        return cobs_encode(raw + struct.pack("<I", zlib.crc32(raw))) + b"\0"

    @classmethod
    def decode(cls, wire):
        raw = cobs_decode(wire)
        if len(raw) < 20:
            raise ValueError("short frame")
        v, cmd, flags, seq, session, n, reserved = HEADER.unpack_from(raw)
        if v != 1 or reserved or flags not in (0, 1) or n > MAX_PAYLOAD or len(raw) != 20 + n:
            raise ValueError("invalid header")
        if zlib.crc32(raw[:-4]) != struct.unpack_from("<I", raw, len(raw)-4)[0]:
            raise ValueError("CRC mismatch")
        return cls(cmd, seq, session, raw[16:-4], flags)

class StreamDecoder:
    def __init__(self):
        self.buffer = bytearray(); self.dropping = False

    def feed(self, data):
        packets = []
        for b in data:
            if b == 0:
                if self.buffer and not self.dropping:
                    try:
                        packets.append(Packet.decode(self.buffer))
                    except ValueError:
                        pass
                self.buffer.clear(); self.dropping = False
            elif not self.dropping:
                self.buffer.append(b)
                if len(self.buffer) >= MAX_WIRE:
                    self.buffer.clear(); self.dropping = True
        return packets

@dataclass(frozen=True)
class Reply:
    result: int
    state: int
    error: int
    driver_error: int
    offset: int
    next_sequence: int
    extra: bytes

    @classmethod
    def from_packet(cls, packet):
        if packet.flags != 1 or len(packet.payload) < 12:
            raise ValueError("invalid response")
        return cls(*struct.unpack_from("<BBBBII", packet.payload), packet.payload[12:])

    def as_dict(self):
        return dict(result=RESULTS[self.result] if self.result < len(RESULTS) else self.result,
                    state=STATES[self.state] if self.state < len(STATES) else self.state,
                    error=self.error, driver_error=self.driver_error, offset=self.offset,
                    next_sequence=self.next_sequence, extra=self.extra.hex())

class DeviceError(RuntimeError):
    def __init__(self, reply):
        self.reply = reply
        super().__init__(str(reply.as_dict()))

class Client:
    """One outstanding request. Retries use byte-identical session/sequence/payload.

    A request timeout has an uncertain outcome. Do not invent a new sequence or
    automatically restart COMMIT; probe STATUS, or explicitly open a new session.
    """
    def __init__(self, transport, timeout=2.5, retries=3):
        self.transport = transport; self.timeout = timeout; self.retries = retries
        self.session = 0; self.sequence = 0; self.decoder = StreamDecoder()
        self.pending = None

    def _exchange(self, request):
        wire = b"\0" + request.encode()  # terminate any abandoned partial frame
        for _ in range(self.retries + 1):
            deadline = time.monotonic() + self.timeout
            sent = 0
            while sent < len(wire):
                n = self.transport.write(wire[sent:])
                if not n or time.monotonic() >= deadline:
                    raise TimeoutError("serial write stalled; command outcome is uncertain")
                sent += n
            while time.monotonic() < deadline:
                for packet in self.decoder.feed(self.transport.read(256)):
                    if (packet.command, packet.sequence, packet.session, packet.flags) == (
                            request.command, request.sequence, request.session, 1):
                        return Reply.from_packet(packet)
        raise TimeoutError("no valid response after retries; probe status before taking further action")

    def probe(self, command=STATUS):
        if command not in (INFO, STATUS):
            raise ValueError("only INFO/STATUS support stateless queries")
        reply = self._exchange(Packet(command, 0, 0))
        if reply.result:
            raise DeviceError(reply)
        return reply

    def open(self):
        self.session = secrets.randbits(32) or 1
        self.sequence = 0
        reply = self._exchange(Packet(OPEN, 0, self.session))
        if reply.result:
            self.session = 0
            raise DeviceError(reply)
        self.sequence = 1
        self.pending = None
        return reply

    def request(self, command, payload=b""):
        if not self.session or not self.sequence:
            raise RuntimeError("open a new session first")
        request = Packet(command, self.sequence, self.session, payload)
        if self.pending is not None and self.pending != request:
            raise RuntimeError("previous request outcome is uncertain; retry that exact request, probe status, or open a new session")
        self.pending = request
        reply = self._exchange(request)
        self.pending = None
        # Only in-sequence command results consume sequence, including validation errors.
        if reply.result not in (1, 4, 5) and reply.next_sequence == (self.sequence + 1) & 0xFFFFFFFF:
            self.sequence = reply.next_sequence
        if reply.result:
            raise DeviceError(reply)
        return reply

    def wait_state(self, wanted, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            reply = self.probe()
            if reply.state == 5 or reply.error:
                raise DeviceError(reply)
            if reply.state == wanted:
                return reply
            if reply.state == 0:
                raise RuntimeError("transfer no longer active; USB reset, suspend, or another client may have cancelled it")
            time.sleep(0.1)
        raise TimeoutError("panel operation still pending; use status to inspect it")

    def upload(self, frame, panel, progress=None):
        if len(frame) != FRAME_BYTES or panel not in (0, 1):
            raise ValueError("requires 105984-byte 768x552 2bpp frame and panel 0 or 1")
        initial = self.open()
        if initial.state == 3:
            raise DeviceError(Reply(9, initial.state, initial.error, initial.driver_error,
                                    initial.offset, initial.next_sequence, b""))
        self.request(BEGIN, struct.pack("<BBHHHII", panel, 1, WIDTH, HEIGHT, 0, len(frame), zlib.crc32(frame)))
        self.wait_state(2, 420)  # A1 reset wait + initial power wait + repeated power-on
        for offset in range(0, len(frame), 768):
            block = frame[offset:offset + 768]
            reply = self.request(DATA, struct.pack("<I", offset) + block)
            if reply.offset != offset + len(block):
                raise RuntimeError("device offset differs from acknowledged block")
            if progress:
                progress(reply.offset, len(frame))
        self.request(COMMIT)
        return self.wait_state(4, 240)

def capabilities(extra):
    result = {}; i = 0
    while i < len(extra):
        if len(extra) - i < 2 or i + 2 + extra[i+1] > len(extra):
            raise ValueError("truncated capability TLV")
        tag, n = extra[i:i+2]; data = extra[i+2:i+2+n]; i += 2+n
        if tag == 1 and n == 4:
            result["width"], result["height"] = struct.unpack("<HH", data)
        elif tag == 2 and n == 4:
            result["max_chunk"] = struct.unpack("<I", data)[0]
        elif tag == 3 and n == 2:
            result["panel_mask"], result["format"] = data
        elif tag == 4 and n == 3:
            result["firmware"] = ".".join(map(str, data))
        elif tag == 5 and n == 4:
            result["frame_bytes"] = struct.unpack("<I", data)[0]
        else:
            result[f"unknown_{tag}"] = data.hex()
    return result

def pack_indices(indices):
    if len(indices) != WIDTH * HEIGHT or any(x not in range(4) for x in indices):
        raise ValueError("expected 768x552 palette indices 0..3")
    return bytes((indices[i] << 6) | (indices[i+1] << 4) | (indices[i+2] << 2) | indices[i+3]
                 for i in range(0, len(indices), 4))

def unpack_indices(frame):
    if len(frame) != FRAME_BYTES:
        raise ValueError("invalid raw frame size")
    return bytes((b >> shift) & 3 for b in frame for shift in (6, 4, 2, 0))

def frame_preview(frame):
    from PIL import Image
    img = Image.frombytes("P", (WIDTH, HEIGHT), unpack_indices(frame))
    img.putpalette(sum((list(c) for c in PALETTE), []) + [0] * (768 - 12))
    return img.convert("RGB")

def convert_image(path, fit="contain", dither=False, rotate=0):
    from PIL import Image, ImageOps
    with Image.open(path) as source:
        rgba = ImageOps.exif_transpose(source).convert("RGBA")
        background = Image.new("RGBA", rgba.size, "white")
        background.alpha_composite(rgba)
        img = background.convert("RGB").rotate(rotate, expand=True)
    if fit == "cover":
        img = ImageOps.fit(img, (WIDTH, HEIGHT), method=Image.Resampling.LANCZOS)
    else:
        fitted = ImageOps.contain(img, (WIDTH, HEIGHT), method=Image.Resampling.LANCZOS)
        img = Image.new("RGB", (WIDTH, HEIGHT), "white")
        img.paste(fitted, ((WIDTH-fitted.width)//2, (HEIGHT-fitted.height)//2))
    pal = Image.new("P", (1, 1))
    # Repeat the four colors instead of adding accidental extra black entries.
    pal.putpalette(sum((list(c) for c in PALETTE), []) * 64)
    quant = img.quantize(palette=pal, dither=Image.Dither.FLOYDSTEINBERG if dither else Image.Dither.NONE)
    return pack_indices(bytes(x % 4 for x in quant.tobytes()))

def test_pattern():
    from PIL import Image, ImageDraw
    img = Image.new("RGB", (WIDTH, HEIGHT), "white"); d = ImageDraw.Draw(img)
    d.fontmode = "1"
    for i, color in enumerate(PALETTE):
        d.rectangle((i*192,100,(i+1)*192-1,450), fill=color)
    d.text((12,12), "TOP LEFT  (0,0)     SerialEPD 768 x 552", fill="black")
    d.text((520,520), "BOTTOM RIGHT  (767,551)", fill="black")
    d.rectangle((0,0,767,551), outline="black", width=3)
    d.line((30,60,150,60), fill="red", width=5)
    d.polygon([(150,60),(135,50),(135,70)], fill="red")
    lookup = {color:i for i,color in enumerate(PALETTE)}
    return pack_indices(bytes(lookup[p] for p in img.getdata()))

def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="command", required=True)
    sub.add_parser("ports", help="list serial devices")
    for name in ("info", "status", "abort"):
        p = sub.add_parser(name); p.add_argument("--port", required=True)
    p = sub.add_parser("convert"); p.add_argument("image"); p.add_argument("output")
    p.add_argument("--preview"); p.add_argument("--fit", choices=("contain", "cover"), default="contain")
    p.add_argument("--dither", action="store_true"); p.add_argument("--rotate", type=int, choices=(0,90,180,270), default=0)
    p = sub.add_parser("pattern"); p.add_argument("output"); p.add_argument("--preview")
    p = sub.add_parser("send"); p.add_argument("frame"); p.add_argument("--port", required=True)
    p.add_argument("--panel", choices=("a0", "a1"), required=True)
    args = ap.parse_args()
    if args.command in ("convert", "pattern"):
        frame = test_pattern() if args.command == "pattern" else convert_image(args.image, args.fit, args.dither, args.rotate)
        Path(args.output).write_bytes(frame)
        if args.preview:
            frame_preview(frame).save(args.preview)
        print(f"{len(frame)} bytes; CRC32={zlib.crc32(frame):08x}")
        return
    import serial
    if args.command == "ports":
        from serial.tools.list_ports import comports
        for port in comports():
            print(port.device, port.description, port.hwid)
        return
    frame = Path(args.frame).read_bytes() if args.command == "send" else None
    with serial.Serial(args.port, 115200, timeout=0.1, write_timeout=3) as port:
        client = Client(port)
        if args.command in ("info", "status"):
            reply = client.probe(INFO if args.command == "info" else STATUS)
            result = reply.as_dict()
            if args.command == "info": result["capabilities"] = capabilities(reply.extra)
        elif args.command == "abort":
            client.open(); result = client.request(ABORT).as_dict()
        else:
            def progress(done, total): print(f"\rUpload {done}/{total} ({done*100//total}%)", end="", flush=True)
            result = client.upload(frame, 0 if args.panel == "a0" else 1, progress).as_dict(); print()
        print(json.dumps(result, indent=2))

if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, TimeoutError) as exc:
        raise SystemExit(str(exc)) from exc
