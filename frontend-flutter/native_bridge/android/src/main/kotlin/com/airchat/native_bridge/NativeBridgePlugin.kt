package com.airchat.native_bridge

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodChannel

/**
 * Registers the "airchat/native" and "airchat/native_battery" channels on
 * EVERY Flutter engine — including the background isolate spawned by Firebase
 * messaging (plugin registrants run on all engines, unlike Activity-based channels).
 */
class NativeBridgePlugin : FlutterPlugin {
    private var applicationContext: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext

        // Wake guard / Wire Keeper (existing)
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

        // Battery optimization (Android 6+ Doze/App Standby) — handles API 23-35
        MethodChannel(binding.binaryMessenger, "airchat/native_battery")
            .setMethodCallHandler { call, result ->
                val ctx = applicationContext
                if (ctx == null) {
                    result.error("no_context", "Application context unavailable", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "isIgnoringBatteryOptimizations" -> {
                        try {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                                result.success(true)
                            } else {
                                val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                                result.success(pm.isIgnoringBatteryOptimizations(ctx.packageName))
                            }
                        } catch (e: Exception) {
                            // OEM ServiceSpecificException (code 7) on some devices
                            result.success(false)
                        }
                    }
                    "requestIgnoreBatteryOptimizations" -> {
                        try {
                            if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
                                result.success(true)
                                return@setMethodCallHandler
                            }
                            val pm = ctx.getSystemService(Context.POWER_SERVICE) as PowerManager
                            if (pm.isIgnoringBatteryOptimizations(ctx.packageName)) {
                                result.success(true)
                                return@setMethodCallHandler
                            }
                            val intent = Intent().apply {
                                action = Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS
                                data = Uri.parse("package:${ctx.packageName}")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            ctx.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            // OEM where direct intent ActivityNotFound — fallback to list
                            try {
                                val fallback = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                }
                                ctx.startActivity(fallback)
                                result.success(true)
                            } catch (e2: Exception) {
                                result.success(false)
                            }
                        }
                    }
                    "openBatteryOptimizationSettings" -> {
                        try {
                            val intent = Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS).apply {
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            ctx.startActivity(intent)
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = null
    }
}
