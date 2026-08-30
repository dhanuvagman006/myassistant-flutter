package com.myassistant.myassistant

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.os.Process
import android.provider.Settings
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Calendar

// local_auth requires FlutterFragmentActivity (not FlutterActivity),
// otherwise the biometric prompt throws no_fragment_activity and never shows.
class MainActivity : FlutterFragmentActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // APP USAGE (screen time). Android gates UsageStatsManager behind a
        // manually granted special permission — no runtime dialog exists, the
        // user must flip the switch in Settings. This channel exposes just
        // enough for the assistant: has permission? open that settings
        // screen; read per-app foreground minutes for a day.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hari/usage")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "hasPermission" -> result.success(hasUsagePermission())
                    "openSettings" -> {
                        try {
                            startActivity(
                                Intent(Settings.ACTION_USAGE_ACCESS_SETTINGS)
                                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            )
                            result.success(true)
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    "getDayUsage" -> {
                        val daysAgo = call.argument<Int>("daysAgo") ?: 0
                        result.success(dayUsage(daysAgo))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun hasUsagePermission(): Boolean {
        return try {
            val appOps = getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = appOps.unsafeCheckOpNoThrow(
                AppOpsManager.OPSTR_GET_USAGE_STATS,
                Process.myUid(),
                packageName
            )
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            false
        }
    }

    /** Foreground minutes per app for one local calendar day. */
    private fun dayUsage(daysAgo: Int): List<Map<String, Any>> {
        if (!hasUsagePermission()) return emptyList()
        return try {
            val cal = Calendar.getInstance()
            cal.add(Calendar.DAY_OF_YEAR, -daysAgo)
            cal.set(Calendar.HOUR_OF_DAY, 0)
            cal.set(Calendar.MINUTE, 0)
            cal.set(Calendar.SECOND, 0)
            cal.set(Calendar.MILLISECOND, 0)
            val start = cal.timeInMillis
            val end = start + 24L * 3600_000L

            val usm = getSystemService(Context.USAGE_STATS_SERVICE) as UsageStatsManager
            val pm = packageManager
            // INTERVAL_BEST buckets can span days; aggregate by package and
            // clamp to the window so one app is not double-counted.
            val byPkg = HashMap<String, Long>()
            for (s in usm.queryUsageStats(UsageStatsManager.INTERVAL_DAILY, start, end - 1)) {
                if (s.totalTimeInForeground <= 0) continue
                byPkg[s.packageName] =
                    (byPkg[s.packageName] ?: 0L) + s.totalTimeInForeground
            }
            byPkg.entries
                .asSequence()
                .map { (pkg, ms) ->
                    val minutes = (ms / 60_000L).toInt()
                    var label = pkg
                    var launchable = false
                    try {
                        val ai: ApplicationInfo = pm.getApplicationInfo(pkg, 0)
                        label = pm.getApplicationLabel(ai).toString()
                        launchable = pm.getLaunchIntentForPackage(pkg) != null
                    } catch (e: Exception) {
                        // uninstalled since — keep the package id as label
                    }
                    Triple(pkg, label, Pair(minutes, launchable))
                }
                // Only apps a person actually opens: >=1 minute and launchable
                // (drops launchers, system UI and services from the report).
                .filter { it.third.first >= 1 && it.third.second }
                .sortedByDescending { it.third.first }
                .take(25)
                .map {
                    mapOf(
                        "package" to it.first,
                        "name" to it.second,
                        "minutes" to it.third.first
                    )
                }
                .toList()
        } catch (e: Exception) {
            emptyList()
        }
    }
}
