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
import android.os.Build
import android.os.IBinder
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

// A FragmentActivity because the biometric prompt (local_auth) is a fragment.
class MainActivity : FlutterFragmentActivity() {

    companion object {
        const val CHANNEL = "dev.nogipx.vzhukh/vpn"
        const val VPN_REQUEST_CODE = 1001
        const val DEBUG_VPN_REQUEST_CODE = 1002
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

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        super.onCreate(savedInstanceState)
        forwardDebugStart(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        forwardDebugStart(intent)
    }

    /**
     * Debug builds only: the service is not exported, so adb reaches it
     * through here.
     *   adb shell am start -n dev.nogipx.vzhukh/.MainActivity \
     *     -a dev.nogipx.vzhukh.DEBUG_START --es config '{"hops":[...]}'
     */
    private fun forwardDebugStart(intent: Intent?) {
        val debuggable = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
        if (!debuggable || intent?.action != VzhukhVpnService.ACTION_DEBUG_START) return
        debugConfig = intent.getStringExtra("config")
        val consent = VpnService.prepare(this)
        if (consent != null) {
            startActivityForResult(consent, DEBUG_VPN_REQUEST_CODE)
            return
        }
        startDebugTunnel()
    }

    private var debugConfig: String? = null

    private fun startDebugTunnel() {
        startForegroundService(Intent(this, VzhukhVpnService::class.java).apply {
            action = VzhukhVpnService.ACTION_DEBUG_START
            putExtra("config", debugConfig)
        })
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "startVpn" -> handleStartVpn(call.arguments as? Map<*, *>, result)
                "stopVpn" -> handleStopVpn(result)
                "vpnStatus" -> result.success(vpnService?.status() ?: GoTunnel.status())
                "getInstalledApps" -> handleGetInstalledApps(result)
                "getOwnApkPath" -> handleGetOwnApkPath(result)
                "isTv" -> result.success(isTvDevice())
                "deviceName" -> result.success(deviceName())
                else -> result.notImplemented()
            }
        }
    }

    /** What the user calls this device, for paired devices to show. */
    private fun deviceName(): String =
        Settings.Global.getString(contentResolver, Settings.Global.DEVICE_NAME)
            ?.takeIf { it.isNotBlank() }
            ?: "${Build.MANUFACTURER} ${Build.MODEL}"

    private var pendingConfig: String = ""
    private var pendingRoutingMode: String = "blacklist"
    private var pendingRoutingPackages: List<String> = emptyList()

    private fun handleStartVpn(args: Map<*, *>?, result: MethodChannel.Result) {
        pendingConfig = args?.get("config") as? String ?: ""
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
        if (requestCode == DEBUG_VPN_REQUEST_CODE && resultCode == RESULT_OK) {
            startDebugTunnel()
            return
        }
        if (requestCode == VPN_REQUEST_CODE) {
            if (resultCode == RESULT_OK) {
                pendingResult?.let { doBindAndStart(it) }
            } else {
                pendingResult?.error("PERMISSION_DENIED", "Tunnel permission denied", null)
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
            vpnService!!.startTunnel(pendingConfig, pendingRoutingMode, pendingRoutingPackages)
            result.success(true)
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
