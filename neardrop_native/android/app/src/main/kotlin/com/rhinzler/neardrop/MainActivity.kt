package com.rhinzler.neardrop

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.Settings
import java.io.File
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "neardrop/platform")
            .setMethodCallHandler { call, result ->
                val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
                when (call.method) {
                    "acquireMulticast" -> {
                        if (multicastLock == null) {
                            multicastLock = wifi.createMulticastLock("NearDropDiscovery")
                        }
                        if (multicastLock?.isHeld != true) multicastLock?.acquire()
                        result.success(null)
                    }
                    "releaseMulticast" -> {
                        if (multicastLock?.isHeld == true) multicastLock?.release()
                        result.success(null)
                    }
                    "preparePublicReceiveDirectory" -> preparePublicReceiveDirectory(result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun preparePublicReceiveDirectory(result: MethodChannel.Result) {
        // /storage/emulated/0 is Android's user-visible shared-storage root.
        // A top-level /NearDrop folder cannot be written under scoped storage
        // without the special all-files-access permission on Android 11+.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !Environment.isExternalStorageManager()) {
            try {
                startActivity(Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                    data = Uri.parse("package:$packageName")
                })
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
            result.error(
                "storage_permission_required",
                "Allow NearDrop to manage files, then press Start discovery again.",
                null,
            )
            return
        }

        val directory = File(Environment.getExternalStorageDirectory(), "NearDrop")
        if (!directory.exists() && !directory.mkdirs()) {
            result.error("storage_directory_failed", "Could not create ${directory.absolutePath}.", null)
            return
        }
        result.success(directory.absolutePath)
    }

    override fun onDestroy() {
        if (multicastLock?.isHeld == true) multicastLock?.release()
        super.onDestroy()
    }
}
