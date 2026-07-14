import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fact-check repro for the runtime 0.5.1 process-singleton ThemeManager —
/// documents exactly what the host's per-entry brightness re-injection can
/// and cannot cover. Two engines are created the way the core service does
/// (one runtime per app handle); the assertions show the shared-singleton
/// cross-talk between them.
Map<String, dynamic> _appDef({Map<String, dynamic>? theme}) => {
      'type': 'application',
      'title': 'repro',
      'version': '1.0.0',
      'routes': {'/': 'ui://pages/home'},
      if (theme != null) 'theme': theme,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('engines share ONE ThemeManager instance (process singleton)', () async {
    final a = MCPUIRuntime();
    final b = MCPUIRuntime();
    expect(identical(a.engine.themeManager, b.engine.themeManager), isTrue);
  });

  test('H1: palette pollution — app without theme inherits the previous '
      'app\'s custom palette; brightness re-injection cannot fix it', () async {
    final tm = ThemeManager();

    // App A declares a custom light palette (a market sample would).
    final a = MCPUIRuntime();
    await a.initialize(
      _appDef(theme: {
        'mode': 'light',
        'color': {'primary': '#FF0000'},
      }),
      pageLoader: (route) async => {'type': 'page', 'content': {}},
    );

    // App B (freshly installed) declares NO theme block.
    final b = MCPUIRuntime();
    await b.initialize(
      _appDef(),
      pageLoader: (route) async => {'type': 'page', 'content': {}},
    );

    // B renders with A's palette and A's declared mode — the singleton
    // kept A's customization (B declared neither).
    expect(tm.getThemeValue('color.primary'), '#FF0000');
    expect(tm.getThemeValue('mode'), 'light');

    // The host's re-injection pins BRIGHTNESS only; the foreign palette
    // stays. This is the "dark but weird colors" symptom.
    tm.setHostBrightness(Brightness.dark);
    expect(tm.flutterThemeMode, ThemeMode.dark);
    expect(tm.getThemeValue('color.primary'), '#FF0000');
  });

  test('H2: a disposing runtime surface clears the OTHER app\'s host pin',
      () async {
    final tm = ThemeManager();
    tm.setHostBrightness(Brightness.dark); // running app's pin (re-injected)
    expect(tm.flutterThemeMode, ThemeMode.dark);

    // Any other runtime widget's dispose path runs this line (0.5.1
    // mcp_ui_runtime.dart:604/622/1391) against the SHARED manager:
    tm.setHostBrightness(null);

    // The still-running app has lost its pin without any rebuild of its
    // own — per-entry re-injection cannot see this until the next entry.
    expect(tm.flutterThemeMode, isNot(ThemeMode.dark));
  });

  test('H4: runtime destroy resets the WHOLE singleton (pin included) — '
      'ownership tags must not outlive the session', () async {
    final tm = ThemeManager();
    // Entry state: an app's baseline + dark pin.
    tm.setTheme({
      'mode': 'system',
      'dark': {'mode': 'dark'},
    });
    tm.setHostBrightness(Brightness.dark);
    expect(tm.flutterThemeMode, ThemeMode.dark);

    // MCPUIRuntime.destroy() runs this exact call (mcp_ui_runtime.dart:506):
    tm.reset();

    // Everything is gone — definition AND pin. Any entry-gate that skips
    // re-applying based on a stale ownership tag renders "weird dark".
    expect(tm.flutterThemeMode, isNot(ThemeMode.dark));
    expect(tm.getThemeValue('dark'), isNull);
  });

  test('H5: fingerprint flips on ANY external mutation — the liveness probe '
      'a skip-gate must use instead of an ownership tag', () async {
    final tm = ThemeManager();
    tm.setTheme({
      'mode': 'system',
      'dark': {'mode': 'dark'},
    });
    tm.setHostBrightness(Brightness.dark);
    final applied = tm.fingerprint;

    // Untouched state → same fingerprint (skip is safe).
    expect(tm.fingerprint, applied);

    // A destroy-path reset invalidates it (skip must NOT happen).
    tm.reset();
    expect(tm.fingerprint, isNot(applied));

    // Even a foreign setTheme with identical content invalidates it —
    // the fingerprint embeds the theme-data map identity.
    tm.setTheme({
      'mode': 'system',
      'dark': {'mode': 'dark'},
    });
    tm.setHostBrightness(Brightness.dark);
    expect(tm.fingerprint, isNot(applied));
  });
}
