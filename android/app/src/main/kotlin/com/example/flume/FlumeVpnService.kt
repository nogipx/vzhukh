package com.example.flume

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.VpnService
import android.os.Binder
import android.os.IBinder
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat

class FlumeVpnService : VpnService() {

    companion object {
        const val CHANNEL_ID = "flume_vpn"
        const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "com.example.flume.STOP"

        var instance: FlumeVpnService? = null
    }

    inner class LocalBinder : Binder() {
        fun getService() = this@FlumeVpnService
    }

    private val binder = LocalBinder()
    private var tunPfd: ParcelFileDescriptor? = null

    override fun onBind(intent: Intent): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onDestroy() {
        instance = null
        stopTun()
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        return START_STICKY
    }

    fun startTun(): Int {
        stopTun()

        val builder = Builder()
            .setSession("Flume")
            .addAddress("10.0.0.2", 32)
            .addDnsServer("8.8.8.8")
            .addDnsServer("8.8.4.4")
            .addRoute("0.0.0.0", 0) // route all IPv4
            .addRoute("::", 0)      // route all IPv6
            .setMtu(1500)
            .setBlocking(false)

        // Exclude our own app so SSH doesn't loop through the VPN
        builder.addDisallowedApplication(packageName)

        tunPfd = builder.establish()
            ?: throw IllegalStateException("VpnService.Builder.establish() returned null")

        return tunPfd!!.fd
    }

    fun stopTun() {
        try {
            tunPfd?.close()
        } catch (_: Exception) {}
        tunPfd = null
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Flume VPN",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "SSH tunnel active"
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, FlumeVpnService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Flume VPN")
            .setContentText("SSH tunnel active")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopIntent)
            .setOngoing(true)
            .build()
    }
}
