import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/material.dart';

/// Minimal AppPlayer Core example used by CI to verify the public API
/// builds on every supported platform (Android / iOS / Linux / macOS /
/// Web / Windows). Not a runnable demo — it just instantiates the
/// service so the build matrix exercises the package surface.
void main() {
  runApp(const _ExampleApp());
}

class _ExampleApp extends StatelessWidget {
  const _ExampleApp();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AppPlayer Core example',
      home: Scaffold(
        appBar: AppBar(title: const Text('AppPlayer Core example')),
        body: const _Body(),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  late final LogBuffer _logBuffer;
  late final Logger _logger;

  @override
  void initState() {
    super.initState();
    _logBuffer = LogBuffer();
    _logger = CompositeLogger(<Logger>[
      NoopLogger(),
      BufferLogger(_logBuffer),
    ]);
    _logger.info('example.boot', const {'plat': 'demo'});
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('AppPlayer Core public API smoke test'),
            const SizedBox(height: 12),
            Text('LogBuffer entries: ${_logBuffer.entries.length}'),
          ],
        ),
      ),
    );
  }
}
