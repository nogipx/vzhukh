package com.example.flume

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.IBinder
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    companion object {
        const val CHANNEL = "com.example.flume/vpn"
        const val VPN_REQUEST_CODE = 1001
    }

    private var channel: MethodChannel? = null
    private var pendingResult: MethodChannel.Result? = null
    private var vpnService: FlumeVpnService? = null

    private val serviceConnection = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, binder: IBinder) {
            vpnService = (binder as FlumeVpnService.LocalBinder).getService()
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
                "startVpn" -> handleStartVpn(result)
                "stopVpn" -> handleStopVpn(result)
                else -> result.notImplemented()
            }
        }
    }

    private fun handleStartVpn(result: MethodChannel.Result) {
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
        val serviceIntent = Intent(this, FlumeVpnService::class.java)
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
            val fd = vpnService!!.startTun()
            result.success(fd)
        } catch (e: Exception) {
            result.error("TUN_ERROR", e.message, null)
        }
    }

    private fun handleStopVpn(result: MethodChannel.Result) {
        vpnService?.stopTun()
        try {
            unbindService(serviceConnection)
        } catch (_: Exception) {}
        vpnService = null
        stopService(Intent(this, FlumeVpnService::class.java))
        result.success(null)
    }
}
