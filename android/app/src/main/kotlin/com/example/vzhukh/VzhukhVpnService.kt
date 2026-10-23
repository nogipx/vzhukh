package dev.nogipx.vzhukh

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Binder
import android.os.IBinder
import android.os.ParcelFileDescriptor
import androidx.core.app.NotificationCompat

class VzhukhVpnService : VpnService() {

    companion object {
        const val CHANNEL_ID = "vzhukh_vpn"
        const val NOTIFICATION_ID = 1
        const val ACTION_STOP = "dev.nogipx.vzhukh.STOP"
        const val ACTION_DEBUG_START = "dev.nogipx.vzhukh.DEBUG_START"

        var instance: VzhukhVpnService? = null
    }

    inner class LocalBinder : Binder() {
        fun getService() = this@VzhukhVpnService
    }

    private val binder = LocalBinder()
    private var tunPfd: ParcelFileDescriptor? = null
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    override fun onBind(intent: Intent): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        instance = this
        createNotificationChannel()
    }

    override fun onDestroy() {
        stopTunnel()
        instance = null
        super.onDestroy()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            shutdown()
            return START_NOT_STICKY
        }
        startForeground(NOTIFICATION_ID, buildNotification())
        // Debug builds only: start a tunnel from adb, for testing without
        // the UI.
        //   adb shell am start-foreground-service -n dev.nogipx.vzhukh/.VzhukhVpnService \
        //     -a dev.nogipx.vzhukh.DEBUG_START --es config '{"hops":[...]}'
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (debuggable && intent?.action == ACTION_DEBUG_START) {
            try {
                startTunnel(intent.getStringExtra("config") ?: "")
            } catch (e: Exception) {
                android.util.Log.e("vzhukh", "debug start: ${e.message}")
            }
        }
        return START_NOT_STICKY
    }

    /**
     * Establishes the TUN and starts the Go tunnel on it with [config] JSON
     * (internal/mobile.Config). Throws with the reason if either fails.
     *
     * vzhukh itself is always outside the VPN: the SSH connections the
     * tunnel makes must go out directly, whatever server or chain they lead
     * to, and excluding the app does that without carving routes.
     */
    fun startTunnel(
        config: String,
        routingMode: String = "blacklist",
        routingPackages: List<String> = emptyList(),
        dnsServers: List<String> = emptyList(),
    ) {
        stopTunnel()

        val builder = Builder()
            .setSession("Vzhukh")
            .addAddress("10.0.0.2", 32)
            .addRoute("0.0.0.0", 0)
            .setMtu(1500)
            .setBlocking(false)

        // IPv4 only: the TUN routes no IPv6, so an IPv6 resolver would be
        // asked around the tunnel. The engine sends every query on to the
        // far end over TCP, whichever resolver it is addressed to.
        val added = dnsServers
            .filter { it.matches(Regex("""\d{1,3}(\.\d{1,3}){3}""")) }
            .count { runCatching { builder.addDnsServer(it) }.isSuccess }
        if (added == 0) {
            builder.addDnsServer("8.8.8.8")
            builder.addDnsServer("8.8.4.4")
        }

        if (routingMode == "whitelist") {
            // Only the listed apps are in; vzhukh is not one of them.
            routingPackages.filter { it != packageName }.forEach { pkg ->
                try { builder.addAllowedApplication(pkg) } catch (_: Exception) {}
            }
        } else {
            builder.addDisallowedApplication(packageName)
            routingPackages.forEach { pkg ->
                try { builder.addDisallowedApplication(pkg) } catch (_: Exception) {}
            }
        }

        val pfd = builder.establish()
            ?: throw IllegalStateException("VpnService.Builder.establish() returned null")
        tunPfd = pfd

        GoTunnel.start(pfd.fd, config)?.let { error ->
            stopTunnel()
            throw IllegalStateException(error)
        }
        watchNetwork()
    }

    fun status(): String = GoTunnel.status()

    /**
     * Tells the tunnel whenever the default network changes, so a chain
     * that died with the old network is redialed at once instead of at the
     * next keepalive; and keeps the VPN's underlying network current, so
     * the system meters and reports traffic against the right one.
     */
    private fun watchNetwork() {
        val cm = getSystemService(ConnectivityManager::class.java) ?: return
        val callback = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                setUnderlyingNetworks(arrayOf(network))
                GoTunnel.nudge("network available")
            }

            override fun onLost(network: Network) {
                setUnderlyingNetworks(null)
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                if (caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)) {
                    GoTunnel.nudge("network validated")
                }
            }
        }
        cm.registerDefaultNetworkCallback(callback)
        networkCallback = callback
    }

    override fun onRevoke() {
        // Another VPN took over, or the user turned this one off in Settings.
        shutdown()
        super.onRevoke()
    }

    fun stopTunnel() {
        networkCallback?.let {
            try {
                getSystemService(ConnectivityManager::class.java)?.unregisterNetworkCallback(it)
            } catch (_: Exception) {}
        }
        networkCallback = null
        GoTunnel.stop()
        try {
            tunPfd?.close()
        } catch (_: Exception) {}
        tunPfd = null
    }

    fun shutdown() {
        stopTunnel()
        @Suppress("DEPRECATION")
        stopForeground(true)
        stopSelf()
    }

    private fun createNotificationChannel() {
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Tunnel",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while traffic goes through your server"
        }
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, VzhukhVpnService::class.java).apply { action = ACTION_STOP },
            PendingIntent.FLAG_IMMUTABLE,
        )
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("vzhukh")
            .setContentText("SSH tunnel active")
            .setSmallIcon(R.drawable.ic_stat_vzhukh)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Stop", stopIntent)
            .setOngoing(true)
            .build()
    }
}
