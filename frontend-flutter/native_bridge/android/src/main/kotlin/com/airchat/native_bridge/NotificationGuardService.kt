package com.airchat.native_bridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat

/**
 * Short-lived dataSync foreground service started when an FCM wake arrives.
 *
 * Why: on OEM phones (Realme/Oppo/Xiaomi/Samsung...), a freshly-spawned
 * background process may be denied network access. Promoting to a foreground
 * service for ~12 seconds (Signal/Delta Chat trick) guarantees network while
 * the Dart isolate fetches + decrypts the queued message.
 *
 * Android 15 caps dataSync FGS at 6h/day — a 12s burst is negligible.
 */
class NotificationGuardService : Service() {

    companion object {
        const val CHANNEL_ID = "airchat_guard"
        const val NOTIFICATION_ID = 42
        private const val STOP_DELAY_MS = 12_000L

        fun start(context: Context) {
            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return
            try {
                val intent = Intent(context, NotificationGuardService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (_: Exception) {
                // Background FGS start can throw on some OEMs — non-fatal.
            }
        }
    }

    private val handler = Handler(Looper.getMainLooper())
    private val stopRunnable = Runnable { stopSelf() }

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Message sync",
                    NotificationManager.IMPORTANCE_MIN
                )
            )
        }
        val notification: Notification =
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("AirChat")
                .setContentText("Checking for messages…")
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setOngoing(true)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        handler.postDelayed(stopRunnable, STOP_DELAY_MS)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Re-delivery while running: extend the window slightly.
        handler.removeCallbacks(stopRunnable)
        handler.postDelayed(stopRunnable, STOP_DELAY_MS)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(stopRunnable)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
