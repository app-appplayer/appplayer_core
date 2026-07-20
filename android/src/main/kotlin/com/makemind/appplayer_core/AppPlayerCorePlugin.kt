package com.makemind.appplayer_core

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/**
 * Android side of the appplayer_core Platform Integration Foundation
 * (FR-PLATFORM): background execution (foreground service + WorkManager),
 * OS runtime permissions, and notifications.
 */
class AppPlayerCorePlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener,
    PluginRegistry.NewIntentListener {

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var wakesChannel: EventChannel
    private lateinit var permissionChangesChannel: EventChannel
    private lateinit var notificationTapsChannel: EventChannel

    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null

    private var wakesSink: EventChannel.EventSink? = null
    private var notificationTapsSink: EventChannel.EventSink? = null

    // A tap that arrived before Dart subscribed to the taps stream (cold start);
    // flushed when the sink attaches.
    private var pendingTapSource: String? = null

    // Pending permission requests keyed by request code.
    private val pendingPermissions = mutableMapOf<Int, Result>()
    private var nextRequestCode = 1000

    private val notifications = NotificationBridge()

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, CHANNEL_METHODS)
        methodChannel.setMethodCallHandler(this)

        wakesChannel = EventChannel(binding.binaryMessenger, CHANNEL_WAKES)
        wakesChannel.setStreamHandler(streamHandler { wakesSink = it })

        permissionChangesChannel =
            EventChannel(binding.binaryMessenger, CHANNEL_PERMISSION_CHANGES)
        permissionChangesChannel.setStreamHandler(streamHandler { })

        notificationTapsChannel =
            EventChannel(binding.binaryMessenger, CHANNEL_NOTIFICATION_TAPS)
        notificationTapsChannel.setStreamHandler(streamHandler {
            notificationTapsSink = it
            // Flush a tap captured before the stream was listened to.
            if (it != null) {
                pendingTapSource?.let { source -> it.success(source) }
                pendingTapSource = null
            }
        })

        notifications.attach(context)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        wakesChannel.setStreamHandler(null)
        permissionChangesChannel.setStreamHandler(null)
        notificationTapsChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "background.initialize" -> result.success(null)
            "background.begin" -> result.success(startBackground())
            "background.end" -> {
                stopBackground()
                result.success(null)
            }
            "background.runJob" -> {
                val jobId = call.argument<String>("jobId") ?: ""
                enqueueJob(jobId)
                result.success(null)
            }
            "permission.status" -> result.success(
                statusOf(mapPermission(call.argument<String>("permission")))
            )
            "permission.request" -> requestPermission(
                call.argument<String>("permission"), result
            )
            "notification.permissionStatus" ->
                result.success(notificationPermissionStatus())
            "notification.requestPermission" ->
                requestPermission("notifications", result)
            "notification.post" -> {
                notifications.post(
                    call.argument<String>("id") ?: "",
                    call.argument<String>("title") ?: "",
                    call.argument<String>("body") ?: "",
                    call.argument<String>("source") ?: ""
                )
                result.success(null)
            }
            "notification.cancel" -> {
                notifications.cancel(call.argument<String>("id") ?: "")
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // --- Background execution ------------------------------------------------

    private fun startBackground(): Boolean {
        return try {
            val intent = Intent(context, BackgroundService::class.java)
            ContextCompat.startForegroundService(context, intent)
            true
        } catch (e: Exception) {
            false
        }
    }

    private fun stopBackground() {
        context.stopService(Intent(context, BackgroundService::class.java))
    }

    private fun enqueueJob(jobId: String) {
        val request = OneTimeWorkRequestBuilder<BackgroundJobWorker>()
            .setInputData(workDataOf(BackgroundJobWorker.KEY_JOB_ID to jobId))
            .build()
        WorkManager.getInstance(context).enqueue(request)
    }

    // --- Permissions ---------------------------------------------------------

    private fun mapPermission(name: String?): String? = when (name) {
        "bluetooth" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                Manifest.permission.BLUETOOTH_CONNECT else null
        "location" -> Manifest.permission.ACCESS_FINE_LOCATION
        "notifications" ->
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU)
                Manifest.permission.POST_NOTIFICATIONS else null
        "camera" -> Manifest.permission.CAMERA
        "microphone" -> Manifest.permission.RECORD_AUDIO
        // backgroundExecution (foreground service), localNetwork, usb have no
        // Android runtime permission — treated as granted.
        else -> null
    }

    private fun statusOf(permission: String?): String {
        if (permission == null) return "granted"
        val granted = ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED
        return if (granted) "granted" else "denied"
    }

    private fun notificationPermissionStatus(): String {
        return if (NotificationManagerCompat.from(context).areNotificationsEnabled())
            "granted" else "denied"
    }

    private fun requestPermission(name: String?, result: Result) {
        val permission = mapPermission(name)
        if (permission == null) {
            result.success("granted")
            return
        }
        val current = activity
        if (current == null) {
            result.success(statusOf(permission))
            return
        }
        val code = nextRequestCode++
        pendingPermissions[code] = result
        current.requestPermissions(arrayOf(permission), code)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        val result = pendingPermissions.remove(requestCode) ?: return false
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        result.success(if (granted) "granted" else "denied")
        return true
    }

    // --- ActivityAware -------------------------------------------------------

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addRequestPermissionsResultListener(this)
        binding.addOnNewIntentListener(this)
        // Cold start via a notification tap: the launch intent carries the
        // source extra.
        handleTapIntent(binding.activity.intent)
    }

    override fun onNewIntent(intent: Intent): Boolean {
        handleTapIntent(intent)
        return false
    }

    private fun handleTapIntent(intent: Intent?) {
        val source = intent?.getStringExtra(EXTRA_SOURCE) ?: return
        // Consume so a config-change / re-delivery does not re-fire it.
        intent.removeExtra(EXTRA_SOURCE)
        val sink = notificationTapsSink
        if (sink != null) {
            sink.success(source)
        } else {
            pendingTapSource = source
        }
    }

    override fun onDetachedFromActivityForConfigChanges() = detachActivity()

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivity() = detachActivity()

    private fun detachActivity() {
        activityBinding?.removeRequestPermissionsResultListener(this)
        activityBinding?.removeOnNewIntentListener(this)
        activity = null
        activityBinding = null
    }

    private fun streamHandler(onListen: (EventChannel.EventSink?) -> Unit) =
        object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                onListen(events)
            }

            override fun onCancel(arguments: Any?) {
                onListen(null)
            }
        }

    companion object {
        const val CHANNEL_METHODS = "makemind.appplayer_core/methods"
        const val CHANNEL_WAKES = "makemind.appplayer_core/wakes"
        const val CHANNEL_PERMISSION_CHANGES =
            "makemind.appplayer_core/permission_changes"
        const val CHANNEL_NOTIFICATION_TAPS =
            "makemind.appplayer_core/notification_taps"
        const val EXTRA_SOURCE = "com.makemind.appplayer_core.SOURCE"
    }
}
