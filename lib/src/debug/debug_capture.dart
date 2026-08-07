/// Debug capture surface — the pure-Flutter primitives the Debug MCP
/// server drives (screenshot, layout tree with bounds, element-rect
/// resolution, synthetic tap, text injection).
///
/// Desktop-only, settings-gated. The host wraps the rendered app in a
/// `RepaintBoundary` keyed by [captureKey] (via
/// `AppPlayerCoreService.debugCaptureWrap`) so the capture primitives
/// have a stable render boundary to read from.
///
/// The load-bearing recipes here are lifted verbatim from the studio's
/// `ui_control_tools.dart` / `studio_workspace.dart` — they carry
/// non-obvious correctness details (two-step hit-test + dispatch, the
/// always-touch pointer kind, the RenderMetaData walk) that must not be
/// simplified.
library;

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Owns the capture `GlobalKey` and the pure-Flutter capture / input
/// primitives. One instance per active Debug MCP host.
class DebugSurface {
  DebugSurface();

  /// Key for the `RepaintBoundary` the host wraps the rendered app in.
  /// The capture / layout primitives read the render object off this key.
  final GlobalKey captureKey = GlobalKey();

  // ── Screenshot ─────────────────────────────────────────────────

  /// Capture the boundary to PNG bytes. Full window when [area] is null;
  /// otherwise crops to [area] (logical coordinates) via a
  /// `PictureRecorder` pass. Returns null when the boundary is not yet
  /// attached / sized.
  Future<Uint8List?> captureScreenshot({
    double pixelRatio = 1.0,
    Rect? area,
  }) async {
    final ro = captureKey.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) return null;
    if (!ro.attached || !ro.hasSize) return null;
    try {
      final fullImage = await ro.toImage(pixelRatio: pixelRatio);
      if (area == null) {
        final byteData =
            await fullImage.toByteData(format: ui.ImageByteFormat.png);
        return byteData?.buffer.asUint8List();
      }
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      final src = Rect.fromLTWH(
        area.left * pixelRatio,
        area.top * pixelRatio,
        area.width * pixelRatio,
        area.height * pixelRatio,
      );
      final dst = Rect.fromLTWH(0, 0, area.width, area.height);
      canvas.drawImageRect(fullImage, src, dst, ui.Paint());
      final picture = recorder.endRecording();
      final cropped = await picture.toImage(
        area.width.toInt(),
        area.height.toInt(),
      );
      final byteData =
          await cropped.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  // ── Layout snapshot ────────────────────────────────────────────

  /// Walk the capture boundary's render subtree and emit one entry per
  /// `RenderMetaData` node that AppPlayer's flutter_mcp_ui runtime wraps
  /// rendered widgets in. Each entry carries `{type, id?, text?, label?,
  /// title?, rect:[x,y,w,h]}` in capture-root coordinates. Returns an
  /// empty list when the boundary is not attached yet.
  List<Map<String, dynamic>> layoutSnapshot() {
    final root = _captureRenderBox();
    if (root == null) return const <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    void visit(RenderObject ro) {
      if (ro is RenderMetaData) {
        final meta = ro.metaData;
        if (meta is Map<String, dynamic> && ro.hasSize && ro.attached) {
          final box = ro;
          final transform = box.getTransformTo(root);
          final rect = MatrixUtils.transformRect(
            transform,
            Offset.zero & box.size,
          );
          final entry = <String, dynamic>{
            'type': meta['type']?.toString() ?? '?',
            'rect': <double>[rect.left, rect.top, rect.width, rect.height],
          };
          for (final key in const <String>['id', 'text', 'label', 'title']) {
            final v = meta[key];
            if (v is String && v.isNotEmpty) entry[key] = v;
          }
          out.add(entry);
        }
      }
      ro.visitChildren(visit);
    }

    visit(root);
    if (out.isNotEmpty) return out;

    // Nothing carried metadata. That is not the same as "nothing is on
    // screen", and returning an empty list said the opposite: a caller reads
    // `{nodes: []}` as an empty page and stops looking. Fall back to what the
    // render tree itself knows — text and its position — which is enough to
    // find a label, assert a value, or aim a tap.
    return textSnapshot();
  }

  /// Every piece of text actually painted, with where it sits.
  ///
  /// Reads `RenderParagraph`, so it sees what the user sees regardless of
  /// which widget produced it — a screen assembled by a runtime that attaches
  /// no metadata still answers.
  List<Map<String, dynamic>> textSnapshot() {
    final root = _captureRenderBox();
    if (root == null) return const <Map<String, dynamic>>[];
    final out = <Map<String, dynamic>>[];
    void visit(RenderObject ro) {
      if (ro is RenderParagraph && ro.hasSize && ro.attached) {
        final text = ro.text.toPlainText().trim();
        if (text.isNotEmpty) {
          final rect = MatrixUtils.transformRect(
            ro.getTransformTo(root),
            Offset.zero & ro.size,
          );
          out.add(<String, dynamic>{
            'type': 'text',
            'text': text,
            'rect': <double>[rect.left, rect.top, rect.width, rect.height],
          });
        }
      }
      ro.visitChildren(visit);
    }

    visit(root);
    return out;
  }

  /// The rendered surface's size, or null before it is attached.
  Size? surfaceSize() => _captureRenderBox()?.size;

  /// Scroll by [dy] logical pixels (positive scrolls down) at ([x], [y]).
  ///
  /// A pointer scroll, not a scrollable's controller: the surface under the
  /// cursor is whatever the document put there, and driving a controller would
  /// require knowing which one — which is exactly what a caller inspecting an
  /// unfamiliar screen does not know.
  Future<void> dispatchScroll(double x, double y, double dy, double dx) async {
    final binding = WidgetsBinding.instance;
    final position = Offset(x, y);
    binding.handlePointerEvent(PointerHoverEvent(position: position));
    binding.handlePointerEvent(PointerScrollEvent(
      position: position,
      scrollDelta: Offset(dx, dy),
    ));
    await binding.endOfFrame;
  }

  // ── Element-rect resolution ────────────────────────────────────

  /// Resolve an [elementId] to its on-screen rect (capture-root coords),
  /// or null when no node matches. Accepts `<type>:<key>` (strict) or a
  /// bare `<key>` (matches the first node whose id/text/label/title
  /// equals the key regardless of type).
  Rect? resolveElementRect(String elementId) {
    final colon = elementId.indexOf(':');
    final String? wantType;
    final String wantKey;
    if (colon < 1) {
      wantType = null;
      wantKey = elementId;
    } else {
      wantType = elementId.substring(0, colon);
      wantKey = elementId.substring(colon + 1);
    }
    final root = _captureRenderBox();
    if (root == null) return null;
    return _findMetaRect(root, root, wantType, wantKey);
  }

  Rect? _findMetaRect(
    RenderBox root,
    RenderObject node,
    String? wantType,
    String wantKey,
  ) {
    if (node is RenderMetaData) {
      final meta = node.metaData;
      if (meta is Map<String, dynamic> && node.hasSize && node.attached) {
        final type = meta['type']?.toString() ?? '';
        // `wantType == null` = id-only form: skip the type filter so any
        // node whose id/text/label/title equals `wantKey` matches.
        if (wantType == null || type == wantType) {
          for (final keyField in const <String>['id', 'text', 'label', 'title']) {
            final v = meta[keyField];
            if (v is String && v == wantKey) {
              final transform = node.getTransformTo(root);
              return MatrixUtils.transformRect(
                transform,
                Offset.zero & node.size,
              );
            }
          }
        }
      }
    }
    Rect? hit;
    node.visitChildren((c) {
      if (hit != null) return;
      hit = _findMetaRect(root, c, wantType, wantKey);
    });
    return hit;
  }

  RenderBox? _captureRenderBox() {
    final ro = captureKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.attached && ro.hasSize) return ro;
    return null;
  }

  // ── Synthetic tap ──────────────────────────────────────────────

  /// Dispatch a synthetic tap at ([x], [y]) through Flutter's
  /// `GestureBinding` pointer pipeline — the same path a real pointer
  /// takes.
  Future<void> dispatchTap(double x, double y, {int holdMs = 40}) async {
    final binding = GestureBinding.instance;
    final position = Offset(x, y);
    final now = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final pointer = _nextPointer++;
    final kind = _pointerKind();
    // Explicit hit-test → dispatchEvent so the event traverses the same
    // widget chain a real pointer would. Calling `handlePointerEvent`
    // alone does NOT add the pointer to the binding's `_hitTests` map, so
    // the matching `up` lands without a target and `onTap` never fires.
    // Two-step (hitTest + dispatchEvent) matches Flutter's
    // PointerEventConverter pipeline.
    final downEvent = PointerDownEvent(
      timeStamp: now,
      pointer: pointer,
      position: position,
      kind: kind,
    );
    final hitResult = HitTestResult();
    // Load-bearing two-step (hitTest + dispatchEvent). `hitTest` is
    // deprecated in favour of the view-scoped variant, but the single-view
    // form is exactly what the studio recipe relies on and switching would
    // change the pipeline; keep it and silence the info.
    // ignore: deprecated_member_use
    binding.hitTest(hitResult, position);
    binding.dispatchEvent(downEvent, hitResult);
    await Future<void>.delayed(Duration(milliseconds: holdMs));
    binding.dispatchEvent(
      PointerUpEvent(
        timeStamp: now + Duration(milliseconds: holdMs),
        pointer: pointer,
        position: position,
        kind: kind,
      ),
      hitResult,
    );
  }

  /// Drags from ([x], [y]) to ([toX], [toY]).
  ///
  /// [holdMs] is how long the pointer rests before moving — a long-press
  /// draggable needs it, a plain one does not. The move is sent in steps
  /// because a single jump does not look like a drag to a recogniser: it sees
  /// one enormous delta and no gesture in between.
  Future<void> dispatchDrag(
    double x,
    double y,
    double toX,
    double toY, {
    int holdMs = 600,
    int steps = 12,
  }) async {
    final binding = GestureBinding.instance;
    final start = Offset(x, y);
    final end = Offset(toX, toY);
    var stamp = SchedulerBinding.instance.currentSystemFrameTimeStamp;
    final pointer = _nextPointer++;
    final kind = _pointerKind();

    final hitResult = HitTestResult();
    // ignore: deprecated_member_use
    binding.hitTest(hitResult, start);
    binding.dispatchEvent(
      PointerDownEvent(
          timeStamp: stamp, pointer: pointer, position: start, kind: kind),
      hitResult,
    );
    await Future<void>.delayed(Duration(milliseconds: holdMs));

    var previous = start;
    for (var i = 1; i <= steps; i++) {
      final position = Offset.lerp(start, end, i / steps)!;
      stamp += const Duration(milliseconds: 16);
      binding.dispatchEvent(
        PointerMoveEvent(
          timeStamp: stamp,
          pointer: pointer,
          position: position,
          delta: position - previous,
          kind: kind,
        ),
        hitResult,
      );
      previous = position;
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }

    stamp += const Duration(milliseconds: 16);
    binding.dispatchEvent(
      PointerUpEvent(
          timeStamp: stamp, pointer: pointer, position: end, kind: kind),
      hitResult,
    );
  }

  int _nextPointer = 1000000;

  /// Gesture kind for synthetic taps: ALWAYS touch, on every platform —
  /// the same choice `flutter_test`'s WidgetTester makes. A mouse-kind
  /// Down/Up without a preceding PointerAddedEvent trips MouseTracker's
  /// device-lifecycle assertion and the corrupted tracker then silently
  /// swallows every later synthetic tap. Touch events bypass MouseTracker
  /// entirely; gesture recognizers accept both kinds.
  PointerDeviceKind _pointerKind() => PointerDeviceKind.touch;

  // ── Text injection ─────────────────────────────────────────────

  /// Type [text] into the currently-focused `EditableText`. When
  /// [elementId] is supplied the surface first taps its center to focus
  /// it (chaining). [clear] replaces existing content (default) vs
  /// appends; [submit] fires the field's `onSubmitted` afterwards.
  Future<Map<String, dynamic>> typeText(
    String text, {
    bool clear = true,
    bool submit = false,
    String? elementId,
  }) async {
    // Optional: tap to focus first.
    if (elementId != null && elementId.isNotEmpty) {
      final rect = resolveElementRect(elementId);
      if (rect == null) {
        return <String, dynamic>{
          'ok': false,
          'error': 'elementId not found',
          'elementId': elementId,
        };
      }
      await dispatchTap(rect.center.dx, rect.center.dy);
      // Give the focus change a frame to settle.
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) {
      return <String, dynamic>{'ok': false, 'error': 'no root element'};
    }
    // Walk the tree for the focused EditableText. EditableText is the
    // leaf Flutter exposes the TextEditingController on; both Material
    // `TextField` and Cupertino variants wrap one.
    EditableTextState? focused;
    void visit(Element el) {
      if (focused != null) return;
      final w = el.widget;
      if (w is EditableText) {
        final state = (el as StatefulElement).state as EditableTextState;
        if (state.widget.focusNode.hasFocus) {
          focused = state;
          return;
        }
      }
      el.visitChildren(visit);
    }

    root.visitChildren(visit);
    if (focused == null) {
      return <String, dynamic>{
        'ok': false,
        'error': 'no focused EditableText found — tap the field first '
            '(or pass elementId to chain)',
      };
    }
    final controller = focused!.widget.controller;
    final before = controller.text;
    final after = clear ? text : before + text;
    // Setting controller.value fires listeners → `onChanged` runs the
    // same path a real keystroke takes.
    controller.value = TextEditingValue(
      text: after,
      selection: TextSelection.collapsed(offset: after.length),
    );
    var submitted = false;
    if (submit) {
      final onSubmitted = focused!.widget.onSubmitted;
      if (onSubmitted != null) {
        try {
          onSubmitted(after);
          submitted = true;
        } catch (_) {
          /* best-effort — field's handler threw */
        }
      }
    }
    return <String, dynamic>{
      'ok': true,
      'text': text,
      'before': before,
      'after': after,
      'cleared': clear,
      'submitted': submitted,
    };
  }
}
