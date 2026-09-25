import 'dart:async';

import 'package:mcp_client/mcp_client.dart' hide ConnectionState, Logger;

/// How one connection is shared among several consumers — this host's own
/// screens and the devices it lends the connection to (spec 23 §6.1).
///
/// The rule it serves: **what the device receives does not grow with the
/// number of consumers.** A small device serves one request at a time over a
/// slow radio; consumers multiply, its capacity does not.
class ConnectionSharing {
  const ConnectionSharing({
    this.surfaceFixed = false,
    this.maxInFlight,
    this.isDocument = defaultIsDocument,
  });

  /// Whether the server's surface — its lists and documents — is fixed for the
  /// life of the connection: a serving device, whose surface changes only with
  /// its firmware or bundle (and a change means a new connection). The host
  /// says so; nothing here guesses. A general server keeps only the lists it
  /// promised to announce changes for (`listChanged`).
  final bool surfaceFixed;

  /// Outstanding requests allowed at once, or null for no limit. `ping` never
  /// waits for a slot — it is the liveness probe.
  final int? maxInFlight;

  /// Whether [uri] is a document. The device's declaration should be
  /// preferred where it exists; this is the scheme fallback — `ui://` and
  /// `bundle://` are what a serving device hands out (mcp_ui_dsl ·
  /// mcp_serving).
  final bool Function(String uri) isDocument;

  static bool defaultIsDocument(String uri) =>
      uri.startsWith('ui://') || uri.startsWith('bundle://');
}

/// One held connection, shared (spec 23 §6.1).
///
/// Wraps the [Client] a connector produced — whichever host built it, whatever
/// transport it runs on — so every consumer that reaches the connection
/// through this layer follows the same rules without knowing it:
///
/// - lists are read once and reused until the server says they changed, when
///   that is safe (a fixed surface, or a declared `listChanged`);
/// - documents are read once per connection on a fixed surface;
/// - a subscribed value is answered from the one the server last pushed;
/// - any other read already on its way is shared, not repeated;
/// - at most [ConnectionSharing.maxInFlight] requests are outstanding, the
///   rest wait here — not in the device's receive buffer;
/// - [lastMessageAt] records the last thing that came back, so liveness can
///   look at the whole link rather than one probe.
///
/// Notifications: this wrapper holds the inner client's single handler slot
/// per method, runs its own bookkeeping first and then the consumer's handler.
/// To a consumer it is the same one-handler-per-method client as before.
class SharedClient implements Client {
  SharedClient(this.inner, this.sharing) {
    for (final method in _watched) {
      _install(method);
    }
    _disconnectSub = inner.onDisconnect.listen((_) => _failWaiting());
  }

  /// The connector's client. Everything not governed here goes straight to it.
  final Client inner;
  final ConnectionSharing sharing;

  /// When the server last answered or sent anything, or null before that.
  DateTime? get lastMessageAt => _lastMessageAt;
  DateTime? _lastMessageAt;
  void _touch() => _lastMessageAt = DateTime.now();

  static const String _toolsList = 'tools/list';
  static const String _resourcesList = 'resources/list';
  static const String _templatesList = 'resources/templates/list';
  static const String _promptsList = 'prompts/list';
  static String _readKey(String uri) => 'resources/read $uri';

  static const List<String> _watched = [
    'notifications/tools/list_changed',
    'notifications/resources/list_changed',
    'notifications/prompts/list_changed',
    'notifications/resources/updated',
  ];

  final Map<String, Future<Object?>> _kept = {};
  final Map<String, Future<Object?>> _pending = {};
  final Set<String> _subscribed = {};
  final Map<String, Map<String, dynamic>> _lastPushed = {};
  final Map<String, Function(Map<String, dynamic>)> _consumer = {};
  final Set<String> _installed = {};
  int _inFlight = 0;
  final List<Completer<void>> _waiting = [];
  StreamSubscription<DisconnectReason>? _disconnectSub;

  // ---------------------------------------------------------------- sharing

  bool _listChangedDeclared(String method) {
    final caps = inner.serverCapabilities;
    if (caps == null) return false;
    return switch (method) {
      _toolsList => caps.toolsListChanged,
      _resourcesList || _templatesList => caps.resourcesListChanged,
      _promptsList => caps.promptsListChanged,
      _ => false,
    };
  }

  Future<T> _list<T>(String method, Future<T> Function() send) async {
    final keep = sharing.surfaceFixed || _listChangedDeclared(method);
    return (await (keep ? _keep(method, send) : _share(method, send))) as T;
  }

  Future<Object?> _keep(String key, Future<Object?> Function() send) {
    final kept = _kept[key];
    if (kept != null) return kept;
    final f = _gated(send);
    _kept[key] = f;
    // A failure is not a value: the next asker tries again.
    f.catchError((Object _) {
      if (identical(_kept[key], f)) _kept.remove(key);
      return null;
    });
    return f;
  }

  Future<Object?> _share(String key, Future<Object?> Function() send) {
    final pending = _pending[key];
    if (pending != null) return pending;
    final f = _gated(send);
    _pending[key] = f;
    f.whenComplete(() {
      if (identical(_pending[key], f)) _pending.remove(key);
    }).catchError((Object _) => null);
    return f;
  }

  /// Run [send] within the in-flight limit, and note the answer as life.
  Future<T> _gated<T>(Future<T> Function() send) async {
    final max = sharing.maxInFlight;
    if (max != null) {
      while (_inFlight >= max) {
        final turn = Completer<void>();
        _waiting.add(turn);
        await turn.future;
      }
      _inFlight++;
    }
    try {
      final result = await send();
      _touch();
      return result;
    } on McpError catch (e) {
      if (e.code != null) _touch(); // an error reply is still a reply
      rethrow;
    } finally {
      if (max != null) {
        if (_inFlight > 0) _inFlight--;
        if (_waiting.isNotEmpty) _waiting.removeAt(0).complete();
      }
    }
  }

  /// Waiting requests fail with the connection: they must not move to the
  /// next one, where a call could run a second time (23 §6.1.3).
  void _failWaiting() {
    final waiting = List<Completer<void>>.of(_waiting);
    _waiting.clear();
    _inFlight = 0;
    for (final w in waiting) {
      if (!w.isCompleted) w.completeError(McpError('Transport disconnected'));
    }
  }

  void _onServerSaid(String method, Map<String, dynamic> params) {
    switch (method) {
      case 'notifications/tools/list_changed':
        _kept.remove(_toolsList);
      case 'notifications/prompts/list_changed':
        _kept.remove(_promptsList);
      case 'notifications/resources/list_changed':
        _kept.remove(_resourcesList);
        _kept.remove(_templatesList);
        _kept.removeWhere((k, _) => k.startsWith('resources/read '));
        _lastPushed.clear();
      case 'notifications/resources/updated':
        final uri = params['uri'];
        if (uri is! String) return;
        _kept.remove(_readKey(uri));
        // The extended form carries the value: a single `content` object (as
        // nodes send it) or a `contents` list. The URI-only form does not.
        final content = params['content'];
        final contents = params['contents'];
        if (content is Map) {
          _lastPushed[uri] = {
            'contents': [content],
          };
        } else if (contents is List) {
          _lastPushed[uri] = {'contents': contents};
        } else {
          _lastPushed.remove(uri);
        }
    }
  }

  void _install(String method) {
    if (!_installed.add(method)) return;
    inner.onNotification(method, (params) {
      _touch();
      // What the server says is current comes first: a consumer that reacts by
      // reading must not get the copy this notification just replaced.
      _onServerSaid(method, params);
      final handler = _consumer[method];
      if (handler != null) return handler(params);
    });
  }

  // ----------------------------------------------------- governed requests

  @override
  Future<List<Tool>> listTools() =>
      _list(_toolsList, () => inner.listTools());

  @override
  Future<List<Resource>> listResources() =>
      _list(_resourcesList, () => inner.listResources());

  @override
  Future<List<ResourceTemplate>> listResourceTemplates() =>
      _list(_templatesList, () => inner.listResourceTemplates());

  @override
  Future<List<Prompt>> listPrompts() =>
      _list(_promptsList, () => inner.listPrompts());

  @override
  Future<ReadResourceResult> readResource(String uri) async {
    if (sharing.surfaceFixed && sharing.isDocument(uri)) {
      return (await _keep(_readKey(uri), () => inner.readResource(uri)))
          as ReadResourceResult;
    }
    final subscribed = _subscribed.contains(uri);
    final pushed = _lastPushed[uri];
    if (pushed != null && subscribed) {
      return ReadResourceResult.fromJson(pushed);
    }
    final result = (await _share(_readKey(uri), () => inner.readResource(uri)))
        as ReadResourceResult;
    // While subscribed, the device announces every change, so what was just
    // read stays current until the next update — the next consumer to join
    // gets it without asking the device again.
    if (_subscribed.contains(uri)) {
      _lastPushed[uri] = {
        'contents': [for (final c in result.contents) c.toJson()],
      };
    }
    return result;
  }

  @override
  Future<CallToolResult> callTool(
    String name,
    Map<String, dynamic> toolArguments,
  ) =>
      _gated(() => inner.callTool(name, toolArguments));

  @override
  Future<ToolCallTracking> callToolWithTracking(
    String name,
    Map<String, dynamic> arguments, {
    bool trackProgress = true,
  }) =>
      _gated(() => inner.callToolWithTracking(name, arguments,
          trackProgress: trackProgress));

  @override
  Future<ReadResourceResult> getResourceWithTemplate(
    String templateUri,
    Map<String, dynamic> params,
  ) =>
      _gated(() => inner.getResourceWithTemplate(templateUri, params));

  @override
  Future<void> subscribeResource(String uri) async {
    await _gated(() => inner.subscribeResource(uri));
    _subscribed.add(uri);
  }

  @override
  Future<void> unsubscribeResource(String uri) async {
    await _gated(() => inner.unsubscribeResource(uri));
    _subscribed.remove(uri);
    _lastPushed.remove(uri);
  }

  @override
  Future<GetPromptResult> getPrompt(
    String name, [
    Map<String, dynamic>? promptArguments,
  ]) =>
      _gated(() => inner.getPrompt(name, promptArguments));

  @override
  Future<CompletionResult> complete(
    Map<String, dynamic> ref,
    Map<String, dynamic> argument, {
    Map<String, dynamic>? context,
  }) =>
      _gated(() => inner.complete(ref, argument, context: context));

  @override
  Future<void> setLoggingLevel(McpLogLevel level) =>
      _gated(() => inner.setLoggingLevel(level));

  @override
  Future<DiscoverResult> discover() => _gated(inner.discover);

  @override
  Future<Task> getTask(String taskId) => _gated(() => inner.getTask(taskId));

  @override
  Future<void> updateTask(String taskId, Map<String, dynamic> inputResponses) =>
      _gated(() => inner.updateTask(taskId, inputResponses));

  @override
  Future<void> cancelTask(String taskId) =>
      _gated(() => inner.cancelTask(taskId));

  /// The liveness probe: never queued behind the traffic it is checking on.
  @override
  Future<void> ping() async {
    try {
      await inner.ping();
      _touch();
    } on McpError catch (e) {
      if (e.code != null) _touch();
      rethrow;
    }
  }

  // ------------------------------------------------------- notifications

  @override
  void onNotification(String method, Function(Map<String, dynamic>) handler) {
    _consumer[method] = handler;
    _install(method);
  }

  @override
  void onToolsListChanged(Function() handler) =>
      onNotification('notifications/tools/list_changed', (_) => handler());

  @override
  void onResourcesListChanged(Function() handler) =>
      onNotification('notifications/resources/list_changed', (_) => handler());

  @override
  void onPromptsListChanged(Function() handler) =>
      onNotification('notifications/prompts/list_changed', (_) => handler());

  @override
  void onRootsListChanged(Function() handler) =>
      onNotification('notifications/roots/list_changed', (_) => handler());

  @override
  void onResourceUpdated(Function(String) handler) =>
      onNotification('notifications/resources/updated',
          (params) => handler(params['uri'] as String));

  @override
  void onResourceContentUpdated(
    Function(String uri, ResourceContentInfo content) handler,
  ) =>
      onNotification('notifications/resources/updated', (params) {
        final contentData = params['content'] as Map<String, dynamic>;
        handler(params['uri'] as String,
            ResourceContentInfo.fromJson(contentData));
      });

  @override
  void onProgress(
    Function(String requestId, double progress, String message) handler,
  ) =>
      onNotification('notifications/progress', (params) {
        final requestId =
            params['requestId'] as String? ?? params['request_id'] as String;
        handler(requestId, params['progress'] as double,
            params['message'] as String);
      });

  @override
  void onLogging(
    Function(McpLogLevel, String, String?, Map<String, dynamic>?) handler,
  ) =>
      onNotification('notifications/message', (params) {
        final levelName = (params['level'] as String).toLowerCase();
        final level = McpLogLevel.values.firstWhere(
          (l) => l.name == levelName,
          orElse: () => McpLogLevel.info,
        );
        final data = params['data'] as Map<String, dynamic>?;
        handler(level, data?['message'] as String? ?? '',
            params['logger'] as String?, data);
      });

  // ------------------------------------------------------ passed through

  @override
  String get name => inner.name;
  @override
  String get version => inner.version;
  @override
  String? get description => inner.description;
  @override
  ClientCapabilities get capabilities => inner.capabilities;
  @override
  String get protocolVersion => inner.protocolVersion;
  @override
  bool get isConnected => inner.isConnected;
  @override
  ServerCapabilities? get serverCapabilities => inner.serverCapabilities;
  @override
  Map<String, dynamic>? get serverInfo => inner.serverInfo;
  @override
  Stream<ServerInfo> get onConnect => inner.onConnect;
  @override
  Stream<DisconnectReason> get onDisconnect => inner.onDisconnect;
  @override
  Stream<McpError> get onError => inner.onError;
  @override
  bool get supportsTasks => inner.supportsTasks;
  @override
  bool get isStateless => inner.isStateless;
  @override
  String? get negotiatedProtocolVersion => inner.negotiatedProtocolVersion;
  @override
  List<Root> get roots => inner.roots;

  @override
  Future<void> connect(ClientTransport transport, {bool statelessMode = false}) =>
      inner.connect(transport, statelessMode: statelessMode);
  @override
  Future<void> connectWithRetry(
    ClientTransport transport, {
    int maxRetries = 3,
    Duration delay = const Duration(seconds: 2),
  }) =>
      inner.connectWithRetry(transport, maxRetries: maxRetries, delay: delay);
  @override
  Future<void> initialize() => inner.initialize();
  @override
  Task? taskFromResult(Map<String, dynamic> result) =>
      inner.taskFromResult(result);
  @override
  void notifyCancelled(String requestId, {String? reason}) =>
      inner.notifyCancelled(requestId, reason: reason);
  @override
  void notifyProgress(
    dynamic progressToken,
    double progress, {
    double? total,
    String? message,
  }) =>
      inner.notifyProgress(progressToken, progress,
          total: total, message: message);
  @override
  void onSamplingRequest(
    Future<CreateMessageResult> Function(CreateMessageRequest request) handler,
  ) =>
      inner.onSamplingRequest(handler);
  @override
  void onSamplingRequestMap(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) =>
      inner.onSamplingRequestMap(handler);
  @override
  void onElicitationRequest(
    Future<Map<String, dynamic>> Function(Map<String, dynamic> params) handler,
  ) =>
      inner.onElicitationRequest(handler);
  @override
  void onElicitationRequestTyped(
    Future<ElicitationResponse> Function(ElicitationRequest request) handler,
  ) =>
      inner.onElicitationRequestTyped(handler);
  @override
  void onListRoots(Future<List<Root>> Function() handler) =>
      inner.onListRoots(handler);
  @override
  void onListRootsMap(Future<List<Map<String, dynamic>>> Function() handler) =>
      inner.onListRootsMap(handler);
  @override
  void addRoot(Root root) => inner.addRoot(root);
  @override
  void addRootMap(Map<String, dynamic> root) => inner.addRootMap(root);
  @override
  void removeRoot(String uri) => inner.removeRoot(uri);
  @override
  Future<Subscription> listen(SubscriptionFilter filter) =>
      inner.listen(filter);

  @override
  void disconnect() {
    _failWaiting();
    inner.disconnect();
  }

  @override
  void dispose() {
    unawaited(_disconnectSub?.cancel());
    _failWaiting();
    inner.dispose();
  }
}
