/// Exception hierarchy for AppPlayer Core (SDD §8).
///
/// All public API failures throw a subclass of [AppPlayerException].
/// Bundle exceptions are split into two stages — [BundleLoadException] for
/// `mcp_bundle` loader stage and [BundleAdaptException] for Core-side
/// adaptation (entry validation, version compatibility, URI resolution).
library;

abstract class AppPlayerException implements Exception {
  AppPlayerException(this.message, {this.cause, this.stackTrace});

  final String message;
  final Object? cause;
  final StackTrace? stackTrace;

  @override
  String toString() =>
      cause == null ? '$runtimeType: $message' : '$runtimeType: $message (cause: $cause)';
}

//
// Server / Connection
//

abstract class ServerException extends AppPlayerException {
  ServerException(super.message, {super.cause, super.stackTrace});
  String get serverId;
}

class ServerNotFoundException extends ServerException {
  ServerNotFoundException(this.serverId)
      : super('Server not found: $serverId');
  @override
  final String serverId;
}

class ConnectionFailedException extends ServerException {
  ConnectionFailedException(this.serverId, String message, {Object? cause})
      : super(message, cause: cause);
  @override
  final String serverId;
}

class ConnectionTimeoutException extends ServerException {
  ConnectionTimeoutException(this.serverId)
      : super('Connection timeout for server $serverId');
  @override
  final String serverId;
}

class ConnectionNotFoundException extends ServerException {
  ConnectionNotFoundException(this.serverId)
      : super('No connection found for server $serverId');
  @override
  final String serverId;
}

// Deprecated alias for pre-0.2 callers. Remove before first pub release.
@Deprecated('Use ServerException subclasses. Removed before first pub release.')
abstract class ConnectionException extends AppPlayerException {
  ConnectionException(super.message, {super.cause, super.stackTrace});
}

//
// Application / Resource loading (Online path)
//

abstract class LoadException extends AppPlayerException {
  LoadException(super.message, {super.cause, super.stackTrace});
}

class ResourceNotFoundException extends LoadException {
  ResourceNotFoundException(super.message);
}

class DefinitionParseException extends LoadException {
  DefinitionParseException(this.uri, {Object? cause})
      : super('Failed to parse definition at $uri', cause: cause);
  final String uri;
}

//
// Tool
//

abstract class ToolException extends AppPlayerException {
  ToolException(super.message, {super.cause, super.stackTrace});
}

class ToolNotFoundException extends ToolException {
  ToolNotFoundException(this.name, this.available)
      : super('Tool not found: $name (available: ${available.join(', ')})');
  final String name;
  final List<String> available;
}

class ToolExecutionException extends ToolException {
  ToolExecutionException(this.name, {Object? cause})
      : super('Tool execution failed: $name', cause: cause);
  final String name;
}

//
// Resource subscription
//

class ResourceSubscriptionException extends AppPlayerException {
  ResourceSubscriptionException(this.uri, {Object? cause})
      : super('Resource subscription failed: $uri', cause: cause);
  final String uri;
}

//
// Bundle — Load stage (mcp_bundle loader delegation)
//

enum BundleLoadReason {
  unsupportedSchema,
  invalidManifest,
  integrity,
  notFound,
  parseError,
  fetchError,
  unknown,
}

class BundleLoadException extends AppPlayerException {
  BundleLoadException({
    required this.bundleId,
    required this.reason,
    String? message,
    Object? cause,
  }) : super(
          message ?? 'Bundle load failed ($bundleId): ${reason.name}',
          cause: cause,
        );

  final String bundleId;
  final BundleLoadReason reason;
}

//
// Bundle — Adapt stage (Core-side UiSection → ApplicationDefinition)
//

enum BundleAdaptReason {
  invalidBundleType,
  unsupportedEntryPoint,
  incompatibleRuntimeVersion,
  uriResolution,
  unknown,
}

class BundleAdaptException extends AppPlayerException {
  BundleAdaptException({
    required this.bundleId,
    required this.reason,
    String? message,
    Object? cause,
  }) : super(
          message ?? 'Bundle adapt failed ($bundleId): ${reason.name}',
          cause: cause,
        );

  final String bundleId;
  final BundleAdaptReason reason;
}

/// Low-level URI resolution failure (without bundleId context). Typically
/// wrapped by [BundleAdaptException] at the orchestrator level.
class BundleUriResolutionException extends AppPlayerException {
  BundleUriResolutionException(this.uri, String reason, {Object? cause})
      : super('Cannot resolve bundle URI $uri: $reason', cause: cause);
  final String uri;
}

//
// Bundle — Install stage (FR-INSTALL-007)
//

enum BundleInstallReason {
  notFound,
  format,
  integrity,
  signature,
  compatibility,
  limit,
  alreadyInstalled,
  busy,
  fetchError,
  unknown,
}

class BundleInstallException extends AppPlayerException {
  BundleInstallException({
    required this.reason,
    this.bundleId,
    String? message,
    Object? cause,
  }) : super(
          message ??
              'Bundle install failed${bundleId != null ? ' ($bundleId)' : ''}: '
                  '${reason.name}',
          cause: cause,
        );

  /// Manifest id when it could be recovered from the source; otherwise `null`
  /// (e.g. the source file itself was missing before any manifest was seen).
  final String? bundleId;
  final BundleInstallReason reason;
}

//
// Dashboard
//

abstract class DashboardException extends AppPlayerException {
  DashboardException(super.message, {super.cause, super.stackTrace});
}

class DashboardBundleLoadException extends DashboardException {
  DashboardBundleLoadException(this.bundleId, String message, {Object? cause})
      : super(message, cause: cause);
  final String bundleId;
}

class SlotBindingException extends DashboardException {
  SlotBindingException(this.slotId, String reason, {Object? cause})
      : super('Slot binding failed for $slotId: $reason', cause: cause);
  final String slotId;
}

//
// Tenant
//

abstract class TenantException extends AppPlayerException {
  TenantException(super.message, {super.cause, super.stackTrace});
}

class TenantResolveException extends TenantException {
  TenantResolveException(this.appCode, String reason, {Object? cause})
      : super('Tenant resolve failed for $appCode: $reason', cause: cause);
  final String appCode;
}

class TenantAccessDeniedException extends TenantException {
  TenantAccessDeniedException({required this.resource, required this.reason})
      : super('Access denied to $resource: $reason');
  final String resource;
  final String reason;
}

//
// Storage
//

class StorageException extends AppPlayerException {
  StorageException(this.operation, {Object? cause})
      : super('Storage operation failed: $operation', cause: cause);
  final String operation;
}
