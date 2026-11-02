import 'dart:async';
import 'dart:isolate';

import 'processor.dart';

/// Keeps one image-processing isolate alive for the lifetime of the editor.
///
/// The previous implementation used [compute] for every preview. That is
/// safe, but it pays isolate startup and library initialization costs for each
/// slider move. This worker also retains the prepared, resized source so
/// changing colour settings does not decode and resize the original again.
class ImageProcessWorker {
  final ReceivePort _events = ReceivePort();
  Isolate? _isolate;
  SendPort? _commands;
  Future<void>? _starting;
  int _nextId = 0;
  final Map<int, Completer<ProcessedImage>> _pending = {};
  bool _closed = false;

  Future<void> _ensureStarted() {
    return _starting ??= _start();
  }

  Future<void> _start() async {
    final ready = Completer<SendPort>();
    _events.listen((message) {
      if (message is SendPort && !ready.isCompleted) {
        ready.complete(message);
        return;
      }
      _handle(message);
    });
    _isolate = await Isolate.spawn(_run, _events.sendPort);
    _commands = await ready.future.timeout(const Duration(seconds: 10));
  }

  Future<ProcessedImage> process(
    ProcessRequest request, {
    required int preparationRevision,
    required bool prepare,
  }) async {
    if (_closed) throw StateError('图像处理器已关闭');
    await _ensureStarted();
    final id = _nextId++;
    final result = Completer<ProcessedImage>();
    _pending[id] = result;
    _commands!.send(<Object?>[id, preparationRevision, prepare, request]);
    try {
      final image = await result.future;
      return image;
    } finally {
      _pending.remove(id);
    }
  }

  void _handle(Object? message) {
    if (message is! List || message.length < 3 || message[0] is! int) return;
    final id = message[0] as int;
    final result = _pending[id];
    if (result == null || result.isCompleted) return;
    if (message[1] == true) {
      result.complete(message[2] as ProcessedImage);
    } else {
      result.completeError(StateError(message[2].toString()));
    }
  }

  static void _run(SendPort main) {
    final commands = ReceivePort();
    main.send(commands.sendPort);
    PreparedImage? prepared;
    int? preparedRevision;
    commands.listen((message) {
      if (message is! List || message.length < 4) return;
      final id = message[0] as int;
      final revision = message[1] as int;
      final prepare = message[2] as bool;
      final request = message[3] as ProcessRequest;
      try {
        if (prepare || prepared == null || preparedRevision != revision) {
          prepared = prepareImage(request);
          preparedRevision = revision;
        }
        final image = processPrepared(
          prepared!,
          request.settings,
          preparationMilliseconds: 0,
        );
        main.send(<Object?>[id, true, image]);
      } catch (error) {
        main.send(<Object?>[id, false, error.toString()]);
      }
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(StateError('图像处理器已关闭'));
    }
    _pending.clear();
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _commands = null;
    _events.close();
  }
}
