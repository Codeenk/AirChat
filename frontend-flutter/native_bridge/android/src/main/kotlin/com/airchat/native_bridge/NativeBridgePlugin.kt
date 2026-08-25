package com.airchat.native_bridge

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the "airchat/native" MethodChannel on EVERY Flutter engine —
 * including the background isolate spawned by Firebase messaging (plugin
 * registrants run on all engines, unlike Activity-based channels).
 */
class NativeBridgePlugin : FlutterPlugin {
    private var applicationContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        MethodChannel(binding.binaryMessenger, "airchat/native")
            .setMethodCallHandler { call, result ->
                val ctx = applicationContext
                if (ctx == null) {
                    result.error("no_context", "Application context unavailable", null)
                    return@setMethodCallHandler
                }
                when (call.argument<String>("action")) {
                    "startWakeGuard" -> {
                        NotificationGuardService.start(ctx)
                        result.success(true)
                    }
                    "startWireKeeper" -> {
                        WireKeeperService.start(ctx)
                        result.success(true)
                    }
                    "stopWireKeeper" -> {
                        WireKeeperService.stop(ctx)
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = null
    }
}
