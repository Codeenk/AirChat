package com.airchat.native_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * Optional user-enabled persistent foreground service ("Wire Keeper").
 *
 * Keeps the app process alive so the Dart-side WebSocket wire stays plugged
 * in even after swipe-away on OEM launchers that force-stop background apps.
 * Stores nothing — it is purely a keep-alive shell around the existing wire.
 *
 * Uses the `remoteMessaging` foreground-service type: designed for messaging
 * apps and (unlike dataSync) has no 6-hour daily cap on Android 14/15.
 */
class WireKeeperService : Service() {

    companion object {
        const val CHANNEL_ID = "airchat_wire_keeper"
        const val NOTIFICATION_ID = 43
        const val ACTION_STOP = "com.airchat.native_bridge.WIRE_KEEPER_STOP"

        fun start(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
            try {
                val intent = Intent(context, WireKeeperService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, WireKeeperService::class.java))
        }

        fun isRunning(context: Context): Boolean {
            // Cheap check via the notification channel presence is unreliable;
            // the Dart side tracks the toggle. This is a best-effort helper.
            return false
        }
    }

    override fun onCreate() {
        super.onCreate()
        getSharedPreferences("airchat_native", Context.MODE_PRIVATE)
            .edit().putBoolean("wire_keeper_enabled", true).apply()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Wire Keeper",
                NotificationManager.IMPORTANCE_MIN // silent, bottom of the shade
            )
            channel.setShowBadge(false)
            nm.createNotificationChannel(channel)
        }
        val notification: Notification =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("AirChat wire connected")
                .setContentText("Staying reachable for instant messages")
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_REMOTE_MESSAGING
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
        }
        return START_STICKY // resurrect after OEM kills when possible
    }

    override fun onDestroy() {
        getSharedPreferences("airchat_native", Context.MODE_PRIVATE)
            .edit().putBoolean("wire_keeper_enabled", false).apply()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
