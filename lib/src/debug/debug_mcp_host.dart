/// Debug MCP host — a localhost streamable-HTTP MCP endpoint that
/// exposes the [DebugSurface] primitives as four tools for test
/// automation drivers:
///
///   * `ui.screenshot` — PNG of the rendered surface (optional crop).
///   * `ui.tree`       — render tree with per-node bounds.
///   * `ui.tap`        — synthetic tap by coordinate or element id.
///   * `ui.type`       — text injection into the focused field.
///   * `ui.text`       — the text actually painted, with rects.
///   * `ui.scroll`     — scroll the surface, so a long page can be inspected.
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
  DebugMcpHost(this._surface, {this.listBundles, this.openBundle});

  final DebugSurface _surface;

  /// Installed bundles, for a harness that must open one by id.
  final Future<List<({String id, String name})>> Function()? listBundles;

  /// Opens an installed bundle. The tier supplies this — the core knows what
  /// is installed, only the shell knows how to put it on screen.
  ///
  /// Without it a harness has to reach the bundle through the launcher, which
  /// means registering it in the tier's app list first; a probe that edits the
  /// user's app registry to run is a probe that changes what it measures (and
  /// loses whatever the running copy writes back).
  final Future<bool> Function(String bundleId)? openBundle;

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
      name: 'ui.text',
      description: 'Every piece of text currently painted, with its rect: '
          '`{texts:[{text, rect:[x,y,w,h]}]}`. Reads the render tree, so it '
          'sees what the user sees whatever produced it.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'contains': <String, dynamic>{
            'type': 'string',
            'description': 'Only entries containing this substring.',
          },
        },
      },
      handler: (args) async {
        final needle = (args['contains'] as String?)?.trim();
        var texts = _surface.textSnapshot();
        if (needle != null && needle.isNotEmpty) {
          texts = texts
              .where((t) => (t['text'] as String? ?? '').contains(needle))
              .toList();
        }
        return _textResult(jsonEncode(<String, dynamic>{'texts': texts}));
      },
    );

    boot.addTool(
      name: 'ui.scroll',
      description: 'Scroll the surface under a point. `dy` positive scrolls '
          'down (default 300), `dx` optional; `x`/`y` default to the centre. '
          'Without this a long page cannot be inspected at all — the part '
          'below the fold is invisible to every other tool here.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'dy': <String, dynamic>{'type': 'number'},
          'dx': <String, dynamic>{'type': 'number'},
          'x': <String, dynamic>{'type': 'number'},
          'y': <String, dynamic>{'type': 'number'},
        },
      },
      handler: (args) async {
        final size = _surface.surfaceSize();
        if (size == null) return _errorResult('surface not attached');
        final x = _asDouble(args['x']) ?? size.width / 2;
        final y = _asDouble(args['y']) ?? size.height / 2;
        final dy = _asDouble(args['dy']) ?? 300;
        final dx = _asDouble(args['dx']) ?? 0;
        await _surface.dispatchScroll(x, y, dy, dx);
        return _textResult(jsonEncode(<String, dynamic>{
          'ok': true,
          'x': x,
          'y': y,
          'dy': dy,
          'dx': dx,
        }));
      },
    );

    if (listBundles != null) {
      boot.addTool(
        name: 'app.bundles',
        description: 'Installed bundles as `{id, name}` — what `app.open` can '
            'be asked for.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{},
        },
        handler: (args) async {
          final bundles = await listBundles!();
          return _textResult(jsonEncode(<String, dynamic>{
            'bundles': [
              for (final b in bundles)
                <String, dynamic>{'id': b.id, 'name': b.name},
            ],
          }));
        },
      );
    }

    if (openBundle != null) {
      boot.addTool(
        name: 'app.open',
        description: 'Open an installed bundle by id, without going through '
            'the launcher.',
        inputSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'id': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['id'],
        },
        handler: (args) async {
          final id = (args['id'] as String?)?.trim();
          if (id == null || id.isEmpty) {
            return _errorResult('id is required');
          }
          final opened = await openBundle!(id);
          if (!opened) {
            return _errorResult('no installed bundle with id',
                extra: <String, dynamic>{'id': id});
          }
          return _textResult(jsonEncode(<String, dynamic>{'ok': true, 'id': id}));
        },
      );
    }

    boot.addTool(
      name: 'ui.drag',
      description: 'Drag from one point to another. `holdMs` (default 600) is '
          'the press before the move, which is what a long-press draggable '
          'waits for.',
      inputSchema: <String, dynamic>{
        'type': 'object',
        'properties': <String, dynamic>{
          'x': <String, dynamic>{'type': 'number'},
          'y': <String, dynamic>{'type': 'number'},
          'toX': <String, dynamic>{'type': 'number'},
          'toY': <String, dynamic>{'type': 'number'},
          'holdMs': <String, dynamic>{'type': 'number'},
        },
        'required': <String>['x', 'y', 'toX', 'toY'],
      },
      handler: (args) async {
        final size = _surface.surfaceSize();
        if (size == null) return _errorResult('surface not attached');
        final x = _asDouble(args['x']);
        final y = _asDouble(args['y']);
        final toX = _asDouble(args['toX']);
        final toY = _asDouble(args['toY']);
        if (x == null || y == null || toX == null || toY == null) {
          return _errorResult('x, y, toX and toY are required');
        }
        await _surface.dispatchDrag(
          x,
          y,
          toX,
          toY,
          holdMs: (_asDouble(args['holdMs']) ?? 600).round(),
        );
        return _textResult(jsonEncode(<String, dynamic>{
          'ok': true,
          'from': <double>[x, y],
          'to': <double>[toX, toY],
        }));
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
