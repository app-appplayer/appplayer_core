package com.makemind.appplayer_core

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Shows a notification whose time has come (FR-NOTIF) — scheduled by
 * [NotificationBridge.post] with a future time, delivered here by the
 * AlarmManager whether or not this app is running.
 */
class NotificationAlarmReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra(NotificationBridge.EXTRA_ID)
        if (id == null) {
            Log.w(TAG, "alarm without an id")
            return
        }
        // Delivered after what it says stopped being true (an inexact alarm
        // woken late): not shown.
        val expiresAt = intent.getLongExtra(NotificationBridge.EXTRA_EXPIRES_AT, 0L)
        if (expiresAt > 0L && System.currentTimeMillis() >= expiresAt) {
            Log.i(TAG, "dropped $id: woken after it expired")
            return
        }
        Log.i(TAG, "showing $id")
        NotificationBridge().show(
            context,
            id,
            intent.getStringExtra(NotificationBridge.EXTRA_TITLE) ?: "",
            intent.getStringExtra(NotificationBridge.EXTRA_BODY) ?: "",
            intent.getStringExtra(NotificationBridge.EXTRA_SOURCE) ?: "",
        )
    }

    companion object {
        private const val TAG = "AppPlayerNotification"
    }
}
