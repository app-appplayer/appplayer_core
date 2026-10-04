package com.makemind.appplayer_core

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
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

    /**
     * [at] is milliseconds since the epoch. A time in the future goes to the
     * [AlarmManager], so it is shown with this process gone (a reminder that
     * a bought time is running out); [NotificationAlarmReceiver] shows it.
     */
    fun post(
        id: String, title: String, body: String, source: String,
        at: Long? = null, expiresAt: Long? = null,
    ) {
        if (expiresAt != null && System.currentTimeMillis() >= expiresAt) return
        if (at != null && at > System.currentTimeMillis() + 1000) {
            schedule(id, title, body, source, at, expiresAt)
            return
        }
        show(context, id, title, body, source)
    }

    private fun schedule(
        id: String, title: String, body: String, source: String,
        at: Long, expiresAt: Long?,
    ) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = alarmIntent(context, id, title, body, source, expiresAt)
        // Exact where the app may (a 30-second warning is useless late);
        // otherwise the system's nearest allowed moment.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    fun show(context: Context, id: String, title: String, body: String, source: String) {
        this.context = context
        ensureChannel()
        val builder = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(body)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setAutoCancel(true)
        // The source app handle rides the tap intent so the plugin can route a
        // tap back to that app through the notification_taps EventChannel
        // (FR-NOTIF-004).
        contentIntent(id, source)?.let { builder.setContentIntent(it) }
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) {
            Log.w("AppPlayerNotification", "not shown $id: notifications are off for this app")
            return
        }
        manager.notify(id.hashCode(), builder.build())
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
        context.getSystemService(AlarmManager::class.java)
            ?.cancel(alarmIntent(context, id, "", "", "", null))
        NotificationManagerCompat.from(context).cancel(id.hashCode())
    }

    private fun alarmIntent(
        context: Context, id: String, title: String, body: String, source: String,
        expiresAt: Long?,
    ): PendingIntent {
        val intent = Intent(context, NotificationAlarmReceiver::class.java)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_TITLE, title)
            .putExtra(EXTRA_BODY, body)
            .putExtra(EXTRA_SOURCE, source)
            .putExtra(EXTRA_EXPIRES_AT, expiresAt ?: 0L)
        return PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
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
        const val EXTRA_ID = "appplayer.notification.id"
        const val EXTRA_TITLE = "appplayer.notification.title"
        const val EXTRA_BODY = "appplayer.notification.body"
        const val EXTRA_SOURCE = "appplayer.notification.source"
        const val EXTRA_EXPIRES_AT = "appplayer.notification.expiresAt"
    }
}
