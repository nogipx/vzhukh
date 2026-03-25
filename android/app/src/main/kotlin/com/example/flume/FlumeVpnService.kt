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

    fun startTun(excludeIp: String): Int {
        stopTun()

        val builder = Builder()
            .setSession("Flume")
            .addAddress("10.0.0.2", 32)
            .addDnsServer("8.8.8.8")
            .addDnsServer("8.8.4.4")
            .setMtu(1500)
            .setBlocking(false)

        // Route all IPv4 except the SSH server IP so the SSH connection
        // itself bypasses the VPN (no loop). Same effect as protect() but
        // works without raw fd access.
        for ((addr, prefix) in routesExcluding(excludeIp)) {
            builder.addRoute(addr, prefix)
        }
        builder.addRoute("::", 0) // route all IPv6

        tunPfd = builder.establish()
            ?: throw IllegalStateException("VpnService.Builder.establish() returned null")

        return tunPfd!!.fd
    }

    /**
     * Returns CIDR routes covering 0.0.0.0/0 except [excludeIp]/32.
     * At most 32 entries. If [excludeIp] is blank or unparseable, returns
     * a single 0.0.0.0/0 route (SSH will loop, but the tunnel still works
     * for testing on a known-safe server).
     */
    private fun routesExcluding(excludeIp: String): List<Pair<String, Int>> {
        if (excludeIp.isBlank()) return listOf("0.0.0.0" to 0)
        return try {
            val parts = excludeIp.split(".").map { it.toInt() }
            require(parts.size == 4 && parts.all { it in 0..255 })
            val excl = (parts[0] shl 24) or (parts[1] shl 16) or (parts[2] shl 8) or parts[3]

            val routes = mutableListOf<Pair<String, Int>>()
            var netAddr = 0
            for (i in 0 until 32) {
                val prefixLen = i + 1
                val splitBit = 1 shl (31 - i)
                if (excl and splitBit != 0) {
                    routes.add(intToIp(netAddr) to prefixLen)
                    netAddr = netAddr or splitBit
                } else {
                    routes.add(intToIp(netAddr or splitBit) to prefixLen)
                }
            }
            routes
        } catch (_: Exception) {
            listOf("0.0.0.0" to 0)
        }
    }

    private fun intToIp(n: Int): String =
        "${(n ushr 24) and 0xFF}.${(n ushr 16) and 0xFF}.${(n ushr 8) and 0xFF}.${n and 0xFF}"

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
