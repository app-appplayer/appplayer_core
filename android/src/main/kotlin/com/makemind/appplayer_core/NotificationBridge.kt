package com.makemind.appplayer_core

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationChannelGroup
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
 *
 * Every app gets its own channel group named after the app and channels of its
 * own under it (platform spec 26 §3.2); the channel ids carry the app key, so
 * an app can never reach the system channel or another app's. Each
 * notification shows the app's name as its source and is grouped per app.
 */
class NotificationBridge {

    private lateinit var context: Context

    /** One of an app's channels as declared by the app. */
    data class ChannelSpec(val id: String, val name: String, val importance: String) {
        companion object {
            fun from(raw: Map<String, Any?>?): ChannelSpec? {
                val id = raw?.get("id") as? String ?: return null
                val name = raw["name"] as? String ?: id
                return ChannelSpec(id, name, raw["importance"] as? String ?: "normal")
            }
        }
    }

    fun attach(context: Context) {
        this.context = context
        ensureChannels()
    }

    /**
     * [at] is milliseconds since the epoch. A time in the future goes to the
     * [AlarmManager], so it is shown with this process gone (a reminder that
     * a bought time is running out); [NotificationAlarmReceiver] shows it.
     */
    fun post(
        id: String, title: String, body: String, source: String,
        appName: String?, channel: ChannelSpec?,
        at: Long? = null, expiresAt: Long? = null,
    ) {
        if (expiresAt != null && System.currentTimeMillis() >= expiresAt) return
        if (at != null && at > System.currentTimeMillis() + 1000) {
            schedule(id, title, body, source, appName, channel, at, expiresAt)
            return
        }
        show(context, id, title, body, source, appName, channel)
    }

    /** Creates an app's channels ahead of any notification (spec 26 §3.2). */
    fun declareChannels(source: String, appName: String?, channels: List<ChannelSpec>) {
        if (!::context.isInitialized) return
        val key = appKey(source)
        ensureAppGroup(key, appName)
        for (c in channels) ensureAppChannel(key, c)
    }

    private fun schedule(
        id: String, title: String, body: String, source: String,
        appName: String?, channel: ChannelSpec?, at: Long, expiresAt: Long?,
    ) {
        val alarms = context.getSystemService(AlarmManager::class.java) ?: return
        val pending = alarmIntent(
            context, id, title, body, source, appName, channel, expiresAt)
        // Exact where the app may (a 30-second warning is useless late);
        // otherwise the system's nearest allowed moment.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S || alarms.canScheduleExactAlarms()) {
            alarms.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        } else {
            alarms.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, at, pending)
        }
    }

    fun show(
        context: Context, id: String, title: String, body: String, source: String,
        appName: String?, channel: ChannelSpec?,
    ) {
        this.context = context
        ensureChannels()
        val key = appKey(source)
        val name = appName?.takeIf { it.isNotBlank() } ?: key
        ensureAppGroup(key, name)
        val spec = channel ?: ChannelSpec(DEFAULT_CHANNEL, name, "normal")
        val channelId = ensureAppChannel(key, spec)
        val group = groupKey(key)
        val builder = NotificationCompat.Builder(context, channelId)
            .setContentTitle(title)
            .setContentText(body)
            // The app that posted it, where the person can see who is speaking.
            .setSubText(name)
            .setGroup(group)
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
        // One summary per app, so its notifications fold under the app's name.
        val summary = NotificationCompat.Builder(context, channelId)
            .setContentTitle(name)
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setGroup(group)
            .setGroupSummary(true)
            .setGroupAlertBehavior(NotificationCompat.GROUP_ALERT_CHILDREN)
            .setAutoCancel(true)
            .build()
        manager.notify(("summary:$key").hashCode(), summary)
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
            ?.cancel(alarmIntent(context, id, "", "", "", null, null, null))
        NotificationManagerCompat.from(context).cancel(id.hashCode())
    }

    private fun alarmIntent(
        context: Context, id: String, title: String, body: String, source: String,
        appName: String?, channel: ChannelSpec?, expiresAt: Long?,
    ): PendingIntent {
        val intent = Intent(context, NotificationAlarmReceiver::class.java)
            .putExtra(EXTRA_ID, id)
            .putExtra(EXTRA_TITLE, title)
            .putExtra(EXTRA_BODY, body)
            .putExtra(EXTRA_SOURCE, source)
            .putExtra(EXTRA_APP_NAME, appName)
            .putExtra(EXTRA_EXPIRES_AT, expiresAt ?: 0L)
        if (channel != null) {
            intent.putExtra(EXTRA_CHANNEL_ID, channel.id)
                .putExtra(EXTRA_CHANNEL_NAME, channel.name)
                .putExtra(EXTRA_CHANNEL_IMPORTANCE, channel.importance)
        }
        return PendingIntent.getBroadcast(
            context,
            id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    /** The two channels that are the platform's own, never an app's. */
    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        // What the platform itself tells the person (device added / released):
        // loud, and no app can post to it.
        manager.createNotificationChannel(
            NotificationChannel(SYSTEM_CHANNEL_ID, "System", NotificationManager.IMPORTANCE_HIGH)
        )
        // The channel pushes without a channel of their own have used so far.
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "AppPlayer", NotificationManager.IMPORTANCE_DEFAULT)
        )
    }

    private fun ensureAppGroup(key: String, appName: String?) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        manager.createNotificationChannelGroup(
            NotificationChannelGroup(groupKey(key), appName?.takeIf { it.isNotBlank() } ?: key)
        )
    }

    /** The app's channel as a platform channel id, created if it is not there. */
    private fun ensureAppChannel(key: String, spec: ChannelSpec): String {
        val channelId = channelId(key, spec.id)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = context.getSystemService(NotificationManager::class.java)
            val channel = NotificationChannel(channelId, spec.name, importanceOf(spec.importance))
            channel.group = groupKey(key)
            manager?.createNotificationChannel(channel)
        }
        return channelId
    }

    private fun importanceOf(name: String): Int = when (name) {
        "low" -> NotificationManager.IMPORTANCE_LOW
        "high" -> NotificationManager.IMPORTANCE_HIGH
        else -> NotificationManager.IMPORTANCE_DEFAULT
    }

    companion object {
        const val CHANNEL_ID = "appplayer_core_notifications"
        const val SYSTEM_CHANNEL_ID = "appplayer_system"
        const val DEFAULT_CHANNEL = "default"
        const val EXTRA_ID = "appplayer.notification.id"
        const val EXTRA_TITLE = "appplayer.notification.title"
        const val EXTRA_BODY = "appplayer.notification.body"
        const val EXTRA_SOURCE = "appplayer.notification.source"
        const val EXTRA_APP_NAME = "appplayer.notification.appName"
        const val EXTRA_CHANNEL_ID = "appplayer.notification.channelId"
        const val EXTRA_CHANNEL_NAME = "appplayer.notification.channelName"
        const val EXTRA_CHANNEL_IMPORTANCE = "appplayer.notification.channelImportance"
        const val EXTRA_EXPIRES_AT = "appplayer.notification.expiresAt"

        /** The app's key from its handle (`bundle:chat` → `chat`). */
        fun appKey(source: String): String = source.substringAfter(':')

        /** The platform ids carry the app key, so no two apps share one. */
        fun groupKey(key: String) = "app.$key"
        fun channelId(key: String, channel: String) = "app.$key.$channel"
    }
}
