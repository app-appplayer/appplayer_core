import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('NoopMetricsPort', () {
    const port = NoopMetricsPort();

    test('recordLatency is a no-op', () {
      port.recordLatency('op', const Duration(milliseconds: 5));
      port.recordLatency('op', Duration.zero, tags: const {'k': 'v'});
    });

    test('recordCount is a no-op (default value)', () {
      port.recordCount('m');
      port.recordCount('m', value: 42, tags: const {'k': 'v'});
    });

    test('recordError is a no-op', () {
      port.recordError('op', 'NPE');
      port.recordError('op', 'NPE', tags: const {'k': 'v'});
    });
  });
}
