package com.dhivalabs.home_deck

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) because the Google Home
// Permissions API needs an AndroidX ActivityResultCaller to drive its
// consent UI.
class MainActivity : FlutterFragmentActivity() {
    // Without a multicast lock, Android Wi-Fi drops the multicast packets
    // mDNS and SSDP discovery depend on.
    private var multicastLock: WifiManager.MulticastLock? = null

    private var googleHome: GoogleHomeBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("homedeck-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val bridge = GoogleHomeBridge(this)
        googleHome = bridge
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            GoogleHomeBridge.CHANNEL,
        ).setMethodCallHandler(bridge)
    }

    override fun onDestroy() {
        googleHome?.dispose()
        googleHome = null
        multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }
}
