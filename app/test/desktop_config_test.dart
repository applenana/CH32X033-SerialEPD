import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_libserialport/flutter_libserialport.dart';
import 'package:ink_studio/transport/desktop_config.dart';

class Config extends Fake implements SerialPortConfig {
  int frees = 0;
  bool failPreparation = false;
  @override
  set baudRate(int value) {
    if (failPreparation) throw StateError('prepare failed');
  }
  @override
  set bits(int value) {}
  @override
  set stopBits(int value) {}
  @override
  set parity(int value) {}
  @override
  void setFlowControl(int value) {}
  @override
  void dispose() {
    if (++frees > 1) throw StateError('native double free');
  }
}

class Port extends Fake implements SerialPort {
  SerialPortConfig? owned;
  bool failApply = false;
  @override
  set config(SerialPortConfig value) {
    owned = value; // Matches the installed binding's ownership order.
    if (failApply) throw StateError('driver rejected config');
  }
  @override
  void dispose() => owned?.dispose();
}

void main() {
  for (final fail in [false, true]) {
    test('Config freed once by port after apply (failure=$fail)', () {
      for (var i = 0; i < 100; i++) {
        final port = Port()..failApply = fail;
        final config = Config();
        if (fail) {
          expect(() => configureDesktopPort(port, createConfig: () => config),
              throwsStateError);
        } else {
          configureDesktopPort(port, createConfig: () => config);
        }
        expect(config.frees, 0);
        port.dispose();
        expect(config.frees, 1);
      }
    });
  }
  test('Untransferred config is freed after preparation failure', () {
    final port = Port();
    final config = Config()..failPreparation = true;
    expect(() => configureDesktopPort(port, createConfig: () => config),
        throwsStateError);
    port.dispose();
    expect(config.frees, 1);
  });
}
