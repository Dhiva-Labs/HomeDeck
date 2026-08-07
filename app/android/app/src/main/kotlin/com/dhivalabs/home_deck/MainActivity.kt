package com.dhivalabs.home_deck

import android.content.Context
import android.net.wifi.WifiManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    // Without a multicast lock, Android Wi-Fi drops the multicast packets
    // mDNS and SSDP discovery depend on.
    private var multicastLock: WifiManager.MulticastLock? = null

    private var googleHome: GoogleHomeBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        googleHome = GoogleHomeBridge(this).also {
            MethodChannel(
                flutterEngine.dartExecutor.binaryMessenger,
                GoogleHomeBridge.CHANNEL,
            ).setMethodCallHandler(it)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("homedeck-discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    override fun onDestroy() {
        googleHome?.dispose()
        googleHome = null
        multicastLock?.release()
        multicastLock = null
        super.onDestroy()
    }
}
