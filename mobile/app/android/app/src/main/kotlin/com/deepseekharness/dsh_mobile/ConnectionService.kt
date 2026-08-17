package com.deepseekharness.dsh_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Foreground service that keeps the tunnel (LAN proxy / P2P / relay) alive
 * when the UI goes to the background: raising the process priority stops OEM
 * battery savers from killing the app and dropping the connection.
 *
 * The service itself does no work — the Flutter/Dart side owns the sockets —
 * it only holds a foreground notification and stays alive. Start it from
 * Dart via the "dsh_mobile/connection" MethodChannel once a session connects,
 * stop it when the session closes.
 */
class ConnectionService : Service() {

    companion object {
        const val CHANNEL_ID = "dsh_connection"
        const val NOTIF_ID = 1
    }

    override fun onCreate() {
        super.onCreate()
        val nm = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                getString(R.string.connection_channel_name),
                NotificationManager.IMPORTANCE_LOW
            )
            nm.createNotificationChannel(channel)
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(getString(R.string.connection_notif_title))
            .setContentText(getString(R.string.connection_notif_text))
            .setSmallIcon(android.R.drawable.ic_dialog_info)
            .setOngoing(true)
            .build()
        startForeground(NOTIF_ID, notification)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Re-spawned by the system after a kill; the Dart side re-registers.
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
