// The host side of integration_test/ux_bench_test.dart (see there for how
// to run it). Takes the frame timings the phone reports for each moment,
// writes them all to build/ux_bench.json, and prints the percentiles.
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
      responseDataCallback: (data) async {
        if (data == null) return;
        Directory('build').createSync(recursive: true);
        File('build/ux_bench.json')
            .writeAsStringSync(const JsonEncoder.withIndent('  ').convert(data));
        stdout.writeln('\nFrame times (ms)       build p50/p90/p99/worst   '
            'raster p50/p90/p99/worst   frames');
        for (final entry in data.entries) {
          final m = entry.value;
          if (m is! Map || m['frame_build_times'] == null) continue;
          String row(List<dynamic> micros) {
            final ms = [for (final v in micros) (v as num) / 1000.0]..sort();
            if (ms.isEmpty) return '-';
            double at(double p) =>
                ms[((ms.length - 1) * p).round().clamp(0, ms.length - 1)];
            return [at(0.5), at(0.9), at(0.99), ms.last]
                .map((v) => v.toStringAsFixed(1))
                .join('/');
          }

          stdout.writeln('${entry.key.padRight(22)} '
              '${row(m['frame_build_times'] as List).padRight(25)} '
              '${row(m['frame_rasterizer_times'] as List).padRight(26)} '
              '${m['frame_count']}');
        }
        stdout.writeln('Saved build/ux_bench.json');
      },
    );
