/// The trust chrome every entry is shown in (platform spec 19 §9.7).
///
/// What a scanned code shows before — and around — the target's own UI is the
/// same rule on every tier: the issuer comes first and stays, and nothing
/// leaves the application without the person seeing where it goes. Tiers used
/// to draw this themselves and the copies drifted; a screen that forgot the
/// issuer looked like a working entry. It lives here once, and a tier supplies
/// only its words.
library;

import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show EntryIssuer;

import 'entry_target.dart';

/// The words the chrome speaks, in the host's language. English defaults so a
/// tier that has not translated still says something true.
class EntryChromeLabels {
  const EntryChromeLabels({
    this.unknownIssuer = 'Unidentified issuer',
    this.verified = 'Verified issuer',
    this.unverified = 'Not verified',
    this.guest = 'Guest',
    this.signedIn = 'Signed in',
    this.leaveTitle = 'Leaving this app',
    this.leaveLead =
        'This code points outside. Continue only if you expect to go here:',
    this.leaveContinue = 'Continue',
    this.leaveFailed = 'Nothing on this device could open it.',
    this.close = 'Close',
  });

  final String unknownIssuer;
  final String verified;
  final String unverified;
  final String guest;
  final String signedIn;
  final String leaveTitle;
  final String leaveLead;
  final String leaveContinue;
  final String leaveFailed;
  final String close;
}

/// Schemes an entry may hand to the operating system. Anything else would let
/// a printed code launch whatever else is installed.
const Set<String> kEntryLeavableSchemes = <String>{
  'https',
  'tel',
  'mailto',
  'sms',
};

/// Where an `external` target leaves to, or null when it must not leave:
/// not external, unparsable, or a scheme outside [kEntryLeavableSchemes].
Uri? entryLeaveDestination(EntryTargetRef target) {
  if (target.kind != EntryTargetKind.external) return null;
  final uri = Uri.tryParse(target.ref);
  if (uri == null || !kEntryLeavableSchemes.contains(uri.scheme)) return null;
  return uri;
}

/// Who issued what is on screen. A scanned code has no address bar; this is
/// the address bar, and it stays for as long as their surface is shown.
class EntryIssuerBar extends StatelessWidget {
  const EntryIssuerBar({
    super.key,
    required this.issuer,
    this.identified = false,
    this.showIdentity = true,
    this.labels = const EntryChromeLabels(),
    this.onClose,
  });

  final EntryIssuer issuer;

  /// Leaves the entry. Shown as a close control at the start of the bar: a
  /// desktop window has no system back, so without it an opened entry is a
  /// screen the viewer cannot get out of.
  final VoidCallback? onClose;

  /// Whether the viewer is signed in here. Shown because being anonymous is
  /// part of the answer, and the viewer should not have to infer it.
  final bool identified;
  final bool showIdentity;
  final EntryChromeLabels labels;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final verified = issuer.verified;
    final color =
        verified ? theme.colorScheme.primary : theme.colorScheme.outline;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: <Widget>[
              if (onClose != null) ...<Widget>[
                IconButton(
                  key: const Key('entry-close'),
                  icon: const Icon(Icons.close),
                  tooltip: labels.close,
                  onPressed: onClose,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 4),
              ],
              Icon(
                verified ? Icons.verified_user : Icons.help_outline,
                size: 20,
                color: color,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Text(
                      issuer.name.isEmpty ? labels.unknownIssuer : issuer.name,
                      style: theme.textTheme.titleSmall,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      verified ? labels.verified : labels.unverified,
                      style: theme.textTheme.labelSmall?.copyWith(color: color),
                    ),
                  ],
                ),
              ),
              if (showIdentity)
                Text(
                  identified ? labels.signedIn : labels.guest,
                  style: theme.textTheme.labelSmall,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// An entry's screen: the issuer on top, then [child] — the opened target, or
/// a message about why it is not open. Every state of an entry is drawn in
/// this frame, so none of them can forget who is asking.
class EntryFrame extends StatelessWidget {
  const EntryFrame({
    super.key,
    required this.issuer,
    required this.child,
    this.notice,
    this.identified = false,
    this.showIdentity = true,
    this.labels = const EntryChromeLabels(),
  });

  final EntryIssuer issuer;
  final Widget child;

  /// A resolver-supplied disclosure, shown under the issuer (§4.1.2).
  final String? notice;
  final bool identified;
  final bool showIdentity;
  final EntryChromeLabels labels;

  @override
  Widget build(BuildContext context) {
    final notice = this.notice;
    return Scaffold(
      body: Column(
        children: <Widget>[
          EntryIssuerBar(
            issuer: issuer,
            identified: identified,
            showIdentity: showIdentity,
            labels: labels,
            // Whatever opened the entry can take it back. Nothing to close on
            // a first screen.
            onClose: Navigator.of(context).canPop()
                ? () => Navigator.of(context).maybePop()
                : null,
          ),
          if (notice != null && notice.isNotEmpty)
            MaterialBanner(
              content: Text(notice),
              actions: const <Widget>[SizedBox.shrink()],
            ),
          Expanded(child: child),
        ],
      ),
    );
  }
}

/// A message inside an [EntryFrame]: a title, a body and optional actions,
/// with a way to close.
class EntryMessage extends StatelessWidget {
  const EntryMessage({
    super.key,
    required this.title,
    this.body = const <Widget>[],
    this.actions = const <Widget>[],
    this.labels = const EntryChromeLabels(),
  });

  final String title;
  final List<Widget> body;
  final List<Widget> actions;
  final EntryChromeLabels labels;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(title, style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 12),
                ...body,
                const SizedBox(height: 24),
                ...actions,
                TextButton(
                  onPressed: () => Navigator.of(context).maybePop(),
                  child: Text(labels.close),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Opens an address outside the application; answers whether something took
/// it.
typedef EntryLeaveOpener = Future<bool> Function(Uri destination);

/// Leaving the application for an `external` target. The destination is
/// written out and only a tap sends the person there — a replaced sticker
/// cannot move anyone silently.
class EntryLeaveScreen extends StatefulWidget {
  const EntryLeaveScreen({
    super.key,
    required this.issuer,
    required this.destination,
    required this.open,
    this.notice,
    this.identified = false,
    this.labels = const EntryChromeLabels(),
  });

  final EntryIssuer issuer;
  final Uri destination;
  final EntryLeaveOpener open;
  final String? notice;
  final bool identified;
  final EntryChromeLabels labels;

  @override
  State<EntryLeaveScreen> createState() => _EntryLeaveScreenState();
}

class _EntryLeaveScreenState extends State<EntryLeaveScreen> {
  bool _failed = false;

  @override
  Widget build(BuildContext context) {
    final labels = widget.labels;
    return EntryFrame(
      issuer: widget.issuer,
      notice: widget.notice,
      identified: widget.identified,
      showIdentity: false,
      labels: labels,
      child: EntryMessage(
        title: labels.leaveTitle,
        labels: labels,
        body: <Widget>[
          Text(labels.leaveLead),
          const SizedBox(height: 12),
          SelectableText(
            widget.destination.toString(),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          if (_failed) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              labels.leaveFailed,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
        actions: <Widget>[
          FilledButton(
            onPressed: () async {
              final ok = await widget.open(widget.destination);
              if (!ok && mounted) setState(() => _failed = true);
            },
            child: Text(labels.leaveContinue),
          ),
        ],
      ),
    );
  }
}
