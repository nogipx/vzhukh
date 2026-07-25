package dev.nogipx.vzhukh

import android.app.UiModeManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.net.VpnService
import android.os.IBinder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "dev.nogipx.vzhukh/vpn"
        const val VPN_REQUEST_CODE = 1001
    }

    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var vpnService: VzhukhVpnService? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            vpnService = (binder as VzhukhVpnService.LocalBinder).getService()
            pendingResult?.let { result ->
                pendingResult = null
                startTunAndReply(result)
            }
        }

        override fun onServiceDisconnected(name: ComponentName) {
            vpnService = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> handleStartVpn(call.arguments as? Map<*, *>, result)
                "stopVpn" -> handleStopVpn(result)
                "getInstalledApps" -> handleGetInstalledApps(result)
                "getOwnApkPath" -> handleGetOwnApkPath(result)
                "isTv" -> result.success(isTvDevice())
                else -> result.notImplemented()
            }
        }
    }

    private var pendingSshHost: String = ""
    private var pendingRoutingMode: String = "blacklist"
    private var pendingRoutingPackages: List<String> = emptyList()

    private fun handleStartVpn(args: Map<*, *>?, result: MethodChannel.Result) {
        pendingSshHost = args?.get("sshHost") as? String ?: ""
        pendingRoutingMode = args?.get("routingMode") as? String ?: "blacklist"
        @Suppress("UNCHECKED_CAST")
        pendingRoutingPackages = args?.get("routingPackages") as? List<String> ?: emptyList()
        // Check VPN permission first
        val intent = VpnService.prepare(this)
        if (intent != null) {
            pendingResult = result
            startActivityForResult(intent, VPN_REQUEST_CODE)
            return
        }
        doBindAndStart(result)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                pendingResult?.let { doBindAndStart(it) }
            } else {
                pendingResult?.error("PERMISSION_DENIED", "VPN permission denied", null)
                pendingResult = null
            }
        }
    }

    private fun doBindAndStart(result: MethodChannel.Result) {
        val serviceIntent = Intent(this, VzhukhVpnService::class.java)
        startService(serviceIntent)

        if (vpnService != null) {
            startTunAndReply(result)
        } else {
            pendingResult = result
            bindService(serviceIntent, serviceConnection, Context.BIND_AUTO_CREATE)
        }
    }

    private fun startTunAndReply(result: MethodChannel.Result) {
        try {
            val fd = vpnService!!.startTun(pendingSshHost, pendingRoutingMode, pendingRoutingPackages)
            result.success(fd)
        } catch (e: Exception) {
            result.error("TUN_ERROR", e.message, null)
        }
    }

    /**
     * True when running on a TV. Checks the current UI mode first, and falls
     * back to the leanback feature for boxes that report an odd mode type.
     */
    private fun isTvDevice(): Boolean {
        val uiMode = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        if (uiMode?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) return true
        return packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK) ||
            packageManager.hasSystemFeature(PackageManager.FEATURE_TELEVISION)
    }

    /**
     * Path to this app's own APK, so it can be pushed to another device
     * without downloading anything. Split installs would need every piece and
     * `pm install-multiple`, so they are reported as unsupported rather than
     * silently installing a base that will not run.
     */
    private fun handleGetOwnApkPath(result: MethodChannel.Result) {
        val info = applicationInfo
        val splits = info.splitSourceDirs
        if (splits != null && splits.isNotEmpty()) {
            result.error("SPLIT_APK", "App is installed as split APKs", null)
            return
        }
        result.success(info.sourceDir)
    }

    private fun handleGetInstalledApps(result: MethodChannel.Result) {
        Thread {
            val pm = packageManager
            val apps = pm.getInstalledApplications(PackageManager.GET_META_DATA)
                .map { info ->
                    val label = pm.getApplicationLabel(info).toString()
                    val icon = try {
                        val drawable = pm.getApplicationIcon(info.packageName)
                        val bmp = Bitmap.createBitmap(48, 48, Bitmap.Config.ARGB_8888)
                        val canvas = Canvas(bmp)
                        drawable.setBounds(0, 0, 48, 48)
                        drawable.draw(canvas)
                        val out = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.PNG, 100, out)
                        out.toByteArray()
                    } catch (_: Exception) { null }
                    mapOf("packageName" to info.packageName, "label" to label, "icon" to icon)
                }
                .sortedBy { it["label"] as String }
            runOnUiThread { result.success(apps) }
        }.start()
    }

    private fun handleStopVpn(result: MethodChannel.Result) {
        (vpnService ?: VzhukhVpnService.instance)?.shutdown()
        try {
            unbindService(serviceConnection)
        } catch (_: Exception) {}
        vpnService = null
        result.success(null)
    }
}
