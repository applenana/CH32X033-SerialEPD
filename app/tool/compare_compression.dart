import 'dart:io';
import 'package:ink_studio/imaging/processor.dart';

void main(List<String> args) {
  final source = File(args.isEmpty ? '../build/quality/astronaut.png' : args.first)
      .readAsBytesSync();
  final out = Directory('../build/compression-comparison')
    ..createSync(recursive: true);
  const values = [0.0, .25, .5, .75, 1.0];
  for (final mode in [DitherMode.blueNoise, DitherMode.perceptual]) {
    for (final dynamicRange in values) {
      for (final gamutCompression in values) {
        final result = processImage(ProcessRequest(
          source,
          ImageSettings(
            mode: mode,
            dynamicRange: dynamicRange,
            gamutCompression: gamutCompression,
          ),
        ));
        final name = '${mode.name}_d${(dynamicRange * 100).round()}_g${(gamutCompression * 100).round()}.png';
        File('${out.path}/$name').writeAsBytesSync(result.preview);
      }
    }
  }
}
