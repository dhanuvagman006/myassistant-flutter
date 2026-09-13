package com.myassistant.myassistant

import android.app.AppOpsManager
import android.app.usage.UsageStatsManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.ConnectivityManager
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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hari/updater")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "install" -> ApkInstaller.install(
                        applicationContext,
                        call.argument<String>("path") ?: ""
                    ) { ok -> result.success(ok) }
                    // Is the connection one the user pays for by the
                    // megabyte? A ~200 MB update must not start itself on
                    // mobile data. Unknown state is treated as metered:
                    // the cost of asking is a tap, the cost of guessing
                    // wrong is the user's data plan.
                    "isMetered" -> {
                        val cm = applicationContext
                            .getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
                        result.success(cm?.isActiveNetworkMetered ?: true)
                    }
                    else -> result.notImplemented()
                }
            }

        // INTENT URIs. Tools that reach the phone's own apps — the clock for
        // alarms and timers, the launcher for Home, an app's settings page —
        // send an `intent://#Intent;action=…;end` URI. These have no host,
        // and url_launcher could not open them: the Dart fallback then
        // synthesised "https://" out of the empty host and handed THAT to a
        // browser. Asking for an alarm opened Brave, and because the tool
        // had already reported success the assistant said the alarm was set.
        //
        // Intent.parseUri is what the URI format was designed for. It also
        // tells us honestly whether anything can handle it, so a phone with
        // no clock app produces a failure the user is told about rather than
        // a browser window.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hari/intent")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launch" -> {
                        val uri = call.argument<String>("uri") ?: ""
                        if (uri.isEmpty()) {
                            result.success(false)
                            return@setMethodCallHandler
                        }
                        try {
                            val intent = Intent.parseUri(uri, Intent.URI_INTENT_SCHEME)
                            // Never let a crafted URI hand our own components a
                            // task: an intent URI is external input.
                            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            intent.selector = null
                            if (intent.resolveActivity(packageManager) == null) {
                                result.success(false)
                            } else {
                                applicationContext.startActivity(intent)
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            result.success(false)
                        }
                    }
                    // OPEN ANY INSTALLED APP BY THE NAME A PERSON USES.
                    //
                    // The phone is the only thing that knows what is on it,
                    // so resolution happens here rather than against a list
                    // on the server. Matching is deliberately forgiving —
                    // people say "BigBasket" for "BigBasket: Grocery Store"
                    // — and ranked, so the closest label wins rather than
                    // whichever package happened to be enumerated first.
                    "launchApp" -> {
                        val want = (call.argument<String>("name") ?: "")
                            .lowercase().replace(Regex("[^a-z0-9]"), "")
                        if (want.isEmpty()) {
                            result.success(null)
                            return@setMethodCallHandler
                        }
                        val pm = packageManager
                        val main = Intent(Intent.ACTION_MAIN)
                            .addCategory(Intent.CATEGORY_LAUNCHER)
                        val apps = pm.queryIntentActivities(main, 0)
                        var bestPkg: String? = null
                        var bestLabel: String? = null
                        var bestScore = -1
                        for (ri in apps) {
                            val label = ri.loadLabel(pm).toString()
                            val norm = label.lowercase().replace(Regex("[^a-z0-9]"), "")
                            if (norm.isEmpty()) continue
                            // exact > prefix > contains. Longer labels lose
                            // ties so "Uber" beats "Uber Driver".
                            val score = when {
                                norm == want -> 1000
                                norm.startsWith(want) -> 700 - label.length
                                want.startsWith(norm) -> 600 - label.length
                                norm.contains(want) -> 400 - label.length
                                else -> -1
                            }
                            if (score > bestScore) {
                                bestScore = score
                                bestPkg = ri.activityInfo.packageName
                                bestLabel = label
                            }
                        }
                        val pkg = bestPkg
                        if (pkg == null || bestScore < 0) {
                            result.success(null) // not installed — caller says so
                        } else {
                            val launch = pm.getLaunchIntentForPackage(pkg)
                            if (launch == null) {
                                result.success(null)
                            } else {
                                launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                applicationContext.startActivity(launch)
                                result.success(bestLabel)
                            }
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hari/device")
            .setMethodCallHandler { call, result ->
                val ctx = applicationContext
                when (call.method) {
                    "torch" -> result.success(
                        DeviceControl.torch(ctx, call.argument<Boolean>("on") == true))
                    "volume" -> result.success(
                        DeviceControl.volume(ctx,
                            call.argument<String>("mode") ?: "",
                            call.argument<Int>("value") ?: 0))
                    "media" -> result.success(
                        DeviceControl.media(ctx, call.argument<String>("key") ?: ""))
                    "battery" -> result.success(DeviceControl.battery(ctx))
                    "openPanel" -> result.success(
                        DeviceControl.openPanel(ctx, call.argument<String>("panel") ?: ""))
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "hari/sms")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSms" -> result.success(
                        sendSms(
                            call.argument<String>("to") ?: "",
                            call.argument<String>("body") ?: ""
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    /** True automatic SMS — SmsManager sends without opening any app.
     *  Runtime SEND_SMS permission is checked/asked on the Dart side. */
    private fun sendSms(to: String, body: String): Boolean {
        return try {
            @Suppress("DEPRECATION")
            val sm = android.telephony.SmsManager.getDefault()
            val parts = sm.divideMessage(body)
            if (parts.size > 1) sm.sendMultipartTextMessage(to, null, parts, null, null)
            else sm.sendTextMessage(to, null, body, null, null)
            true
        } catch (e: Exception) {
            false
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
