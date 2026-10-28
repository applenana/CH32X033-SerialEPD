import 'dart:async';
import 'dart:isolate';
import 'auto_tune.dart';
import 'processor.dart';

class AutoCancelled implements Exception {
  const AutoCancelled();
}

/// An owned worker so cancellation actually stops CPU work. No native plugins
/// or ports to hardware are used here; discarding the isolate is safe.
class AutoTuneJob {
  final _port = ReceivePort();
  final _result = Completer<AutoResult>();
  Isolate? _worker;
  Timer? _deadline;
  bool _closed = false;
  Future<AutoResult> get result => _result.future;

  AutoTuneJob(
    ProcessRequest request, {
    void Function(AutoProgress)? onProgress,
  }) {
    _port.listen((message) {
      if (_closed) return;
      if (message is AutoProgress) {
        onProgress?.call(message);
      } else if (message is AutoResult) {
        _result.complete(message);
        _close();
      } else {
        _fail(
          StateError(
            message is List ? 'AUTO 处理失败：${message.first}' : 'AUTO 后台提前退出',
          ),
        );
      }
    });
    _deadline = Timer(const Duration(minutes: 3), () {
      _fail(TimeoutException('AUTO 处理超时，已保留原参数'));
    });
    unawaited(_spawn(request));
  }

  Future<void> _spawn(ProcessRequest request) async {
    try {
      final worker = await Isolate.spawn(
        _run,
        [request, _port.sendPort],
        onError: _port.sendPort,
        onExit: _port.sendPort,
      );
      if (_closed) {
        worker.kill(priority: Isolate.immediate);
      } else {
        _worker = worker;
      }
    } catch (e, st) {
      if (!_closed) {
        _result.completeError(e, st);
        _close();
      }
    }
  }

  static void _run(List<Object> args) {
    final output = args[1] as SendPort;
    output.send(autoTune(args[0] as ProcessRequest, onProgress: output.send));
  }

  void _fail(Object reason) {
    if (_closed) return;
    _result.completeError(reason);
    _close();
  }

  void cancel() => _fail(const AutoCancelled());

  void _close() {
    if (_closed) return;
    _closed = true;
    _deadline?.cancel();
    _worker?.kill(priority: Isolate.immediate);
    _port.close();
  }
}
