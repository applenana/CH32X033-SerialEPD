// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';
import 'package:ink_studio/imaging/processor.dart';
import 'package:ink_studio/imaging/reconstruction.dart';

// Compile to an executable to measure release/AOT, not debug/JIT warmup.
void main(List<String> args) {
  final source = args.isEmpty ? null : File(args.first).readAsBytesSync();
  final prepared = prepareImage(ProcessRequest(source, const ImageSettings()));
  for (final mode in [DitherMode.blueNoise, DitherMode.perceptual]) {
    final settings = ImageSettings(mode: mode);
    final times = <int>[];
    ProcessedImage? result;
    for (var i = 0; i < 4; i++) {
      final watch = Stopwatch()..start();
      result = processPrepared(prepared, settings);
      if (i > 0) times.add(watch.elapsedMicroseconds);
    }
    times.sort();
    print(
      jsonEncode({
        'stage': 'prepared',
        'mode': mode.name,
        'medianMs': times[1] / 1000,
        'counts': result!.counts,
        'error': result.reconstruction?.finalError,
      }),
    );
  }
  for (final optimize in [false, true]) {
    final watch = Stopwatch()..start();
    final result = reconstruct(
      prepared.rgb,
      prepared.width,
      prepared.height,
      optimize: optimize,
    );
    print(
      jsonEncode({
        'stage': 'reconstruct',
        'optimize': optimize,
        'ms': watch.elapsedMicroseconds / 1000,
        'error': result.finalError,
      }),
    );
  }
  final watch = Stopwatch()..start();
  processImage(ProcessRequest(source, const ImageSettings()));
  print(jsonEncode({'stage': 'full', 'ms': watch.elapsedMicroseconds / 1000}));
}
