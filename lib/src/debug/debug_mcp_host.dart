/// Debug MCP host — a localhost streamable-HTTP MCP endpoint that
/// exposes the [DebugSurface] primitives as four tools for test
/// automation drivers:
///
///   * `ui.screenshot` — PNG of the rendered surface (optional crop).
///   * `ui.tree`       — render tree with per-node bounds.
///   * `ui.tap`        — synthetic tap by coordinate or element id.
///   * `ui.type`       — text injection into the focused field.
///
/// Desktop-only, settings-gated (see `AppPlayerCoreService.initialize`).
/// Built on `ServerBootstrap` from `package:brain_kernel/mcp_host.dart`.
library;

import 'dart:convert';
import 'dart:ui' show Rect;

import 'package:brain_kernel/brain_kernel.dart'
    show KernelImageContent, KernelTextContent, KernelToolResult;
import 'package:brain_kernel/mcp_host.dart' show ServerBootstrap;

import 'debug_capture.dart';

/// Serves the [DebugSurface] over a localhost MCP endpoint. One instance
/// per `AppPlayerCoreService` when the Debug MCP setting is enabled on a
/// desktop platform.
class DebugMcpHost {
  DebugMcpHost(this._surface);

  final DebugSurface _surface;
  ServerBootstrap? _boot;

  /// Bind the endpoint on `127.0.0.1:[port]/mcp` and register the four
  /// tools. Idempotent-safe: a second call while already started is a
  /// no-op.
  Future<void> start({int port = 7930}) async {
    if (_boot != null) return;
    final boot = ServerBootstrap(
      name: 'appplayer-debug',
      version: '0.1.0',
      debugMode: true,
    );
    _registerTools(boot);
    await boot.startStreamableHttp(
      host: '127.0.0.1',
      port: port,
      endpoint: '/mcp',
    );
    _boot = boot;
  }

  /// Tear down the transport.
  Future<void> stop() async {
    final boot = _boot;
    _boot = null;
    if (boot != null) await boot.shutdown();
  }

  void _registerTools(ServerBootstrap boot) {
    boot.addTool(
      name: 'ui.screenshot',
      description: 'Capture the rendered surface as a PNG image. Optional '
          '`area` crops to a logical-pixel rectangle; `pixelRatio` scales '
          'the raster (default 1.0).',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'pixelRatio': <String, dynamic>{
            'type': 'number',
            'description': 'Device-pixel scale for the raster (default 1.0).',
          },
          'area': <String, dynamic>{
            'type': 'object',
            'description': 'Optional crop rectangle in logical pixels.',
            'properties': <String, dynamic>{
              'x': <String, dynamic>{'type': 'number'},
              'y': <String, dynamic>{'type': 'number'},
              'w': <String, dynamic>{'type': 'number'},
              'h': <String, dynamic>{'type': 'number'},
            },
            'required': <String>['x', 'y', 'w', 'h'],
          },
        },
      },
      handler: (args) async {
        final pixelRatio = _asDouble(args['pixelRatio']) ?? 1.0;
        final area = _asRect(args['area']);
        final bytes = await _surface.captureScreenshot(
          pixelRatio: pixelRatio,
          area: area,
        );
        if (bytes == null) {
          return _errorResult('capture boundary not attached');
        }
        return KernelToolResult(
          content: <KernelImageContent>[
            KernelImageContent(
              data: base64Encode(bytes),
              mimeType: 'image/png',
            ),
          ],
        );
      },
    );

    boot.addTool(
      name: 'ui.tree',
      description: 'Return the rendered widget tree as a list of nodes, '
          'each with `{type, id?, text?, label?, title?, rect:[x,y,w,h]}` '
          'in logical pixels.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{},
      },
      handler: (args) async {
        final nodes = _surface.layoutSnapshot();
        return _textResult(jsonEncode(<String, dynamic>{'nodes': nodes}));
      },
    );

    boot.addTool(
      name: 'ui.tap',
      description: 'Dispatch a synthetic tap. Provide `elementId` to tap a '
          'node center, or `x`/`y` logical coordinates.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'x': <String, dynamic>{'type': 'number'},
          'y': <String, dynamic>{'type': 'number'},
          'elementId': <String, dynamic>{
            'type': 'string',
            'description': 'Node id in `<type>:<key>` or bare `<key>` form.',
          },
        },
      },
      handler: (args) async {
        final elementId = args['elementId'] as String?;
        double x;
        double y;
        if (elementId != null && elementId.isNotEmpty) {
          final rect = _surface.resolveElementRect(elementId);
          if (rect == null) {
            return _errorResult('elementId not found', extra: <String, dynamic>{
              'elementId': elementId,
            });
          }
          x = rect.center.dx;
          y = rect.center.dy;
        } else {
          final ax = _asDouble(args['x']);
          final ay = _asDouble(args['y']);
          if (ax == null || ay == null) {
            return _errorResult('x/y (number) or elementId required');
          }
          x = ax;
          y = ay;
        }
        await _surface.dispatchTap(x, y);
        return _textResult(jsonEncode(<String, dynamic>{
          'ok': true,
          'x': x,
          'y': y,
          if (elementId != null && elementId.isNotEmpty) 'elementId': elementId,
        }));
      },
    );

    boot.addTool(
      name: 'ui.type',
      description: 'Inject text into the focused editable field. `clear` '
          '(default true) overwrites vs appends; `submit` (default false) '
          'fires the field onSubmitted; `elementId` taps to focus first.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'text': <String, dynamic>{'type': 'string'},
          'clear': <String, dynamic>{
            'type': 'boolean',
            'description':
                'When true (default) overwrites existing text; when false '
                'appends.',
          },
          'submit': <String, dynamic>{
            'type': 'boolean',
            'description': 'When true, invoke the field onSubmitted after '
                'writing (default false).',
          },
          'elementId': <String, dynamic>{
            'type': 'string',
            'description': 'Optional node id to tap (focus) before typing.',
          },
        },
        'required': <String>['text'],
      },
      handler: (args) async {
        final text = args['text'];
        if (text is! String) {
          return _errorResult('text (string) required');
        }
        final clear = args['clear'] as bool? ?? true;
        final submit = args['submit'] as bool? ?? false;
        final elementId = args['elementId'] as String?;
        final result = await _surface.typeText(
          text,
          clear: clear,
          submit: submit,
          elementId: elementId,
        );
        return KernelToolResult(
          content: <KernelTextContent>[
            KernelTextContent(text: jsonEncode(result)),
          ],
          isError: result['ok'] == false,
        );
      },
    );
  }

  // ── Helpers ────────────────────────────────────────────────────

  KernelToolResult _textResult(String text, {bool isError = false}) {
    return KernelToolResult(
      content: <KernelTextContent>[KernelTextContent(text: text)],
      isError: isError,
    );
  }

  KernelToolResult _errorResult(String message, {Map<String, dynamic>? extra}) {
    return _textResult(
      jsonEncode(<String, dynamic>{
        'ok': false,
        'error': message,
        if (extra != null) ...extra,
      }),
      isError: true,
    );
  }

  double? _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  Rect? _asRect(Object? v) {
    if (v is! Map) return null;
    final x = _asDouble(v['x']);
    final y = _asDouble(v['y']);
    final w = _asDouble(v['w']);
    final h = _asDouble(v['h']);
    if (x == null || y == null || w == null || h == null) return null;
    return Rect.fromLTWH(x, y, w, h);
  }
}
