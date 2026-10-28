import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_studio/protocol/client.dart';
import 'package:ink_studio/protocol/codec.dart';
import 'package:ink_studio/transport/serial_transport.dart';

// This transport runs the unmodified production protocol.c + epd.c against
// tests/sim.c. Only the board pins and clock are simulated; no protocol mock.
class FirmwareTransport extends SerialTransport {
  final DynamicLibrary lib;
  final input = StreamController<Uint8List>();
  late final void Function(Pointer<Uint8>, int) feed;
  late final int Function(Pointer<Uint8>) take;
  late final void Function(int) advance, busy;
  final _wire = FrameDecoder();
  bool dropData = true, dropCommit = true;
  FirmwareTransport(String path) : lib = DynamicLibrary.open(path) {
    lib.lookupFunction<Void Function(), void Function()>('sim_reset')();
    feed = lib
        .lookupFunction<
          Void Function(Pointer<Uint8>, Uint32),
          void Function(Pointer<Uint8>, int)
        >('sim_feed');
    take = lib
        .lookupFunction<
          Uint16 Function(Pointer<Uint8>),
          int Function(Pointer<Uint8>)
        >('sim_take');
    advance = lib.lookupFunction<Void Function(Uint32), void Function(int)>(
      'sim_advance',
    );
    busy = lib.lookupFunction<Void Function(Uint8), void Function(int)>(
      'sim_busy',
    );
  }
  int read(String name) =>
      lib.lookupFunction<Uint32 Function(), int Function()>(name)();
  @override
  Stream<Uint8List> get incoming => input.stream;
  @override
  Future<void> close() => input.close();
  @override
  Future<void> write(Uint8List bytes) async {
    final pointer = calloc<Uint8>(bytes.length), reply = calloc<Uint8>(128);
    try {
      pointer.asTypedList(bytes.length).setAll(0, bytes);
      feed(pointer, bytes.length);
      final n = take(reply);
      if (n == 0) return;
      final response = Uint8List.fromList(reply.asTypedList(n));
      final packet = _wire.add(response).single;
      if (packet.command == Command.begin) {
        advance(200);
      }
      if (packet.command == Command.commit) {
        advance(200);
        busy(0);
        advance(15000);
      }
      if (packet.command == Command.data && dropData) {
        dropData = false;
        return;
      }
      if (packet.command == Command.commit && dropCommit) {
        dropCommit = false;
        return;
      }
      for (var i = 0; i < n; i += 13) {
        input.add(response.sublist(i, (i + 13).clamp(0, n)));
      }
    } finally {
      calloc.free(pointer);
      calloc.free(reply);
    }
  }
}

void main() {
  final path = File(
    '../build/tests/${Platform.isWindows ? 'sim.dll' : 'sim.so'}',
  ).absolute.path;
  for (final panel in [0, 1]) {
    test(
      'Dart -> production C firmware A$panel: full frame, CRC, lost ACKs, single refresh',
      () async {
        final transport = FirmwareTransport(path);
        final c = SepClient(
          transport,
          replyTimeout: const Duration(milliseconds: 15),
        );
        final caps = Capabilities((await c.probe(Command.info)).extra);
        expect(caps.compatible, true);
        final frame = Uint8List.fromList(
          List.generate(frameBytes, (i) => i % 256),
        );
        await c.upload(
          frame,
          panel,
          caps,
          progress: (_) {},
          cancel: () => false,
        );
        expect(transport.read('sim_bytes'), frameBytes);
        expect(transport.read('sim_crc'), crc32(frame));
        expect(transport.read('sim_refreshes'), 1);
        expect((await c.probe()).state, 4);
        await c.close();
      },
      skip: !File(path).existsSync()
          ? 'Run python tools/test.py first to build native simulation'
          : false,
    );
  }
}
