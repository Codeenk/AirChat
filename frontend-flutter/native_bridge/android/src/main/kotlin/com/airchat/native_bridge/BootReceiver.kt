package com.airchat.native_bridge

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences

/// Restarts the Wire Keeper after device boot if the user enabled it.
/// The enabled flag lives in default shared prefs (native-readable).
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return
        val prefs: SharedPreferences =
            context.getSharedPreferences("airchat_native", Context.MODE_PRIVATE)
        if (prefs.getBoolean("wire_keeper_enabled", false)) {
            WireKeeperService.start(context)
        }
    }
}
