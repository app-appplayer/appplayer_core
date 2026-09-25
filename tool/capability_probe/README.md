# capability probe — does the build actually do what it declares

**This check runs *before* publishing.** There is no reason to wait for the
published package: during development a tier builds against the local packages
by path, so that build is exactly what is under test. Run after publishing, it
turns into "publish again to fix", and that loop is what it used to look like.

`analyze 0`, a full PASS and a clean dry-run are all **statements about the
source**. This folder asks the **built app**: does each declared capability
actually happen on screen.

What went unnoticed while this did not exist:

- **Bundled PDF and Lottie drew empty boxes.** The surfaces that need bytes
  could not read the `bundle://` → `file:` rewrite. Playback (audio) opened the
  path directly and worked, which is why "the asset path works" was believed.
- **The web plugin registrant shipped stale.** `connectivity_plus`,
  `audio_session`, `just_audio_web` and `video_player_web` were not registered,
  so reconnect, audio and video were dead while the suites were all green. It
  shows only in a browser.

Both come from the same cause: **no test passes through that place.**

## Usage

```bash
python3 build_probe.py <bundle-root>       # build the probe bundle and assets
# with the app running (debug MCP port open)
python3 verify.py --port 7930 --bundle "Capability probe"
```

### Getting the probe into the app — two ways

1. **`app.open` (recommended)** — the debug host opens an installed bundle by
   id. It does not go through the launcher, so **the user's app list is not
   touched.** The core has the door (`AppPlayerCoreService.debugOpenBundle`);
   **each tier wires its own shell routing** to it:

   ```dart
   core.debugOpenBundle = openInstalledBundleFromDebug;  // one line per tier shell
   ```

   **The core is not published for this.** The harness runs on the development
   tree — a tier building against the local core by path (the normal state
   before a release) already has the door. It ships with the next *real* cut.
   Bumping a version for a test tool is how the loop starts.

2. **Launcher registration (temporary)** — `register_probe.py <prefs-domain>`
   puts it into the app list. **The app must not be running** — a running app
   rewrites its own list and the registration disappears, or worse, **the app
   overwrites the list it held with a stale copy** (seen in practice). So this
   way is temporary: it changes what is measured in order to measure it.

`verify.py` walks the screen and checks two things:

1. **Reports** — every section's `… err:` line reads `(none)`. A missing
   capability is *reported* per §6.13, so a reason must be printed rather than
   an empty string, and a present one must read `(none)`.
2. **Drawing** — how many pixels in the section sit **on top of its own
   background**. Counting colours fails a red square on a black screen as "two
   colours", so pixels different from the background (the most common colour in
   that band) are counted.

**Platform views cannot be measured in pixels.** A web view or a video is a
native view and does not appear in a Flutter screenshot — it reads as blank even
when it works. Those sections (`--platform-view`) are judged **by their report
only**. Measuring them in pixels fails every time, and then the gate gets turned
off.

If either check disagrees, the run **exits non-zero.** The publish gate calls it.

## The second gate — expressions the spec writes in its own text (`run_corpus.py`)

The capability probe asks **whether a surface drew**. It cannot catch a value
that went empty before drawing — `{{round(price * quantity, 2)}}` is written by
§3.6.1 as its own example and was an **empty string** on screen from 0.5.1 on,
while 5,600 tests were green. Nobody had read the spec.

```bash
python3 run_corpus.py --port 7930      # with the host running
```

It builds a bundle from `spec_expression_corpus.json`, installs it, `app.open`s
it and reads the **painted value** with `ui.text`, comparing it with the
expected one. Any failure exits non-zero.

The unit pair lives in the runtime package (`test/spec/spec_expressions_test.dart`)
and feeds the same corpus to the engine directly. Both are needed: the unit
runs on every change and points at the defect precisely; this one checks that
**the value survives all the way to the screen.** An empty string does not look
like a defect on screen; it looks like design.

Note: the host caches bundles it has opened. After replacing a bundle on disk,
restart the host so it reads the new document. A case that was not painted is
reported as "not painted", not as a pass.

## Tier status (2026-08-07)

| Tier | Port | Door wiring | Result |
|---|---|---|---|
| Pro | 7930 | `core.debugOpenBundle = openInstalledBundleFromDebug` | **OK** — 24 checks |
| Standard | 7931 | `core.debugOpenBundle` → GoRouter `/app/:id` | **OK** — 16 checks |
| Custom | 7932 | the shell had no router, so the door and the capture boundary were added together | **OK** — 16 checks |
| X | 7933 | *replaces* the kiosk app (`xDebugAppOverride`) | **OK** — 16 checks |
| Cloud (web) | — | needs a browser build (the debug MCP is desktop only), together with the plugin registrant check |  |

**Ports differ per tier.** A clash is not an error; it goes wrong *silently* —
the second bind fails, that tier's host never starts, and the harness measures
the app that bound first. X shared 7931 with Standard, and it did not show until
the two ran side by side.

**X does not stack routes.** A dedicated device has no shell; one app is the
whole screen. Pushing a second renderer makes two app sessions, and the
runtime's theme state is a singleton, so each rebased the other on every build —
page transitions froze in place. So X's door **changes the app the kiosk
shows**: always one session, the same shape as the real device.

**Custom's shell is a per-contract placeholder**, so it had neither a render
screen nor a debug host. The door (`openInstalledBundleFromDebug`), the capture
boundary (`debugCaptureWrap`) and the debug host were added together; Pro's
renderer is reused, with the providers Custom lacks (core, app list) supplied by
the route. The app list stays empty — opening an unregistered installed bundle
is exactly the path the probe uses.

Every tier opens **an installed bundle without registering it** — registration
decides *whether it shows in the launcher*, not *whether it can run*. Without
that, the probe would have to edit the user's app list and would change what it
measures in order to measure it.

## Confirmed (2026-08-07, Pro)

```
capability probe OK — 24 section checks, all reported (none) and drew
```

And **the day's real defect was put back to confirm the gate fails** — with the
surfaces unable to read bundled asset bytes again:

```
capability probe FAILED (8 of 24 checks):
  - lottie: reported <empty>
  - pdf: reported <empty>
```

With this gate in place, that defect would have been caught **before**
publishing.
