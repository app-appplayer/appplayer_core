package com.makemind.appplayer_core

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Posts / cancels app notifications through [NotificationManagerCompat]
 * (FR-NOTIF). Notification ids are the app-provided string ids, hashed to the
 * int ids the platform requires.
 */
class NotificationBridge {

    private lateinit var context: Context

    fun attach(context: Context) {
        this.context = context
        ensureChannel()
    }

    fun post(id: String, title: String, body: String, source: String) {
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setAutoCancel(true)
        // The source app handle rides the tap intent so the plugin can route a
        // tap back to that app through the notification_taps EventChannel
        // (FR-NOTIF-004).
        contentIntent(id, source)?.let { builder.setContentIntent(it) }
        NotificationManagerCompat.from(context).notify(id.hashCode(), builder.build())
    }

    private fun contentIntent(id: String, source: String): PendingIntent? {
        val launch = context.packageManager
            .getLaunchIntentForPackage(context.packageName) ?: return null
        launch.putExtra(AppPlayerCorePlugin.EXTRA_SOURCE, source)
        launch.flags =
            Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_NEW_TASK
        return PendingIntent.getActivity(
            context,
            id.hashCode(),
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    fun cancel(id: String) {
        NotificationManagerCompat.from(context).cancel(id.hashCode())
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "AppPlayer",
                NotificationManager.IMPORTANCE_DEFAULT
            )
            val manager = context.getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    companion object {
        const val CHANNEL_ID = "appplayer_core_notifications"
    }
}
