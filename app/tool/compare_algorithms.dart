import 'dart:convert';
import 'dart:io';
import 'package:ink_studio/imaging/processor.dart';

// Run from app: dart run tool/compare_algorithms.dart [input.png]
void main(List<String> args) {
  final source = args.isEmpty ? null : File(args.first).readAsBytesSync();
  final out = Directory('../build/quality')..createSync(recursive: true);
  final results = <Map<String, Object?>>[];
  for (final mode in [
    DitherMode.floyd,
    DitherMode.burkes,
    DitherMode.blueNoise,
    DitherMode.perceptual,
  ]) {
    final result = processImage(
      ProcessRequest(source, ImageSettings(mode: mode)),
    );
    File('${out.path}/${mode.name}.png').writeAsBytesSync(result.preview);
    File('${out.path}/original.png').writeAsBytesSync(result.original);
    final stats = result.reconstruction;
    results.add({
      'mode': mode.name,
      'milliseconds': result.milliseconds,
      'counts': result.counts,
      if (stats != null && stats.passes > 0)
        'dbsInitialError': stats.initialError,
      if (stats != null && stats.passes > 0) 'dbsFinalError': stats.finalError,
    });
  }
  final json = const JsonEncoder.withIndent('  ').convert(results);
  File('${out.path}/timings.json').writeAsStringSync(json);
  stdout.writeln(json);
}
