import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:ink_studio/protocol/codec.dart';
import 'package:ink_studio/protocol/client.dart';
import 'package:ink_studio/transport/serial_transport.dart';

class Device extends SerialTransport {
  final input = StreamController<Uint8List>();
  final decoder = FrameDecoder();
  final received = <int>[];
  final commands = <int>[];
  int state = 0, sequence = 1, commits = 0;
  bool dropData = false, dropCommit = false, dropAllCommits = false;
  Packet? last;
  Uint8List? cached;
  int crc = 0;
  @override
  Stream<Uint8List> get incoming => input.stream;
  @override
  Future<void> close() => input.close();
  @override
  Future<void> write(Uint8List bytes) async {
    for (final p in decoder.add(bytes)) {
      commands.add(p.command);
      if (p.command != Command.status &&
          last?.sequence == p.sequence &&
          last?.session == p.session) {
        if (!(dropAllCommits && p.command == Command.commit)) {
          input.add(cached!);
        }
        continue;
      }
      if (p.command == Command.open) {
        sequence = 1;
        if (state != 3) {
          state = 0;
          received.clear();
        }
      }
      if (p.command == Command.begin) {
        state = 2;
        sequence++;
        crc = ByteData.sublistView(p.payload).getUint32(12, Endian.little);
      }
      if (p.command == Command.data) {
        expect(
          ByteData.sublistView(p.payload).getUint32(0, Endian.little),
          received.length,
        );
        received.addAll(p.payload.sublist(4));
        sequence++;
      }
      if (p.command == Command.commit) {
        expect(received.length, frameBytes);
        expect(crc32(received), crc);
        commits++;
        state = 3;
        sequence++;
      }
      if (p.command == Command.abort) {
        state = 0;
        sequence++;
      }
      if (p.command == Command.status && state == 3) state = 4;
      final data = ByteData(12)
        ..setUint8(1, state)
        ..setUint32(4, received.length, Endian.little)
        ..setUint32(8, sequence, Endian.little);
      final response = Packet(
        p.command,
        p.sequence,
        p.session,
        payload: data.buffer.asUint8List(),
        flags: 1,
      ).encode();
      if (p.command != Command.status) {
        last = p;
        cached = response;
      }
      if (p.command == Command.data && dropData) {
        dropData = false;
        continue;
      }
      if (p.command == Command.commit && (dropCommit || dropAllCommits)) {
        dropCommit = false;
        continue;
      }
      // USB packets may split at any byte boundary.
      input.add(response.sublist(0, 7));
      input.add(response.sublist(7));
    }
  }
}

Capabilities caps() => Capabilities([
  1,
  4,
  0,
  3,
  40,
  2,
  2,
  4,
  0,
  3,
  0,
  0,
  3,
  2,
  3,
  1,
  5,
  4,
  0,
  158,
  1,
  0,
]);
void main() {
  test(
    'Full 105984-byte four-color transfer survives lost DATA and COMMIT ACK',
    () async {
      final device = Device()
        ..dropData = true
        ..dropCommit = true;
      final client = SepClient(
        device,
        replyTimeout: const Duration(milliseconds: 15),
      );
      final frame = Uint8List(frameBytes)..fillRange(0, frameBytes, 0x1b);
      final events = <TransferProgress>[];
      await client.upload(
        frame,
        0,
        caps(),
        progress: events.add,
        cancel: () => false,
      );
      expect(device.received, frame);
      expect(device.commits, 1);
      expect(events.last.phase, '画面已更新');
      expect(device.commands.where((c) => c == Command.commit).length, 2);
      await client.close();
    },
  );
  test('Cancellation aborts before COMMIT', () async {
    final d = Device();
    final client = SepClient(d);
    var cancel = false;
    await expectLater(
      client.upload(
        Uint8List(frameBytes),
        1,
        caps(),
        progress: (p) {
          if (p.fraction > 0) cancel = true;
        },
        cancel: () => cancel,
      ),
      throwsA(isA<UploadCancelled>()),
    );
    expect(d.commands.last, Command.abort);
    expect(d.commits, 0);
    await client.close();
  });
  test('Unknown COMMIT outcome never auto-aborts or repeats image', () async {
    final d = Device()..dropAllCommits = true;
    final c = SepClient(
      d,
      replyTimeout: const Duration(milliseconds: 10),
      retries: 1,
    );
    await expectLater(
      c.upload(
        Uint8List(frameBytes),
        0,
        caps(),
        progress: (_) {},
        cancel: () => false,
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(d.commits, 1);
    expect(d.commands.contains(Command.abort), false);
    expect((await c.probe()).state, 4);
    await c.close();
  });
}
