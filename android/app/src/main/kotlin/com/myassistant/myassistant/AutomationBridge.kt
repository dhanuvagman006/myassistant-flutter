package com.myassistant.myassistant

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * "hari/automation" — the Dart task loop's line to the accessibility
 * service (HariAccessibilityService). Reading a screen is one binder call
 * per element, so snapshots and actions run on one worker thread, in
 * order, and never on the UI thread.
 */
object AutomationBridge {

    private const val TAG = "hari/auto"
    private val worker = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    private fun component(ctx: Context) = ComponentName(ctx, HariAccessibilityService::class.java)

    /** Switched on in Settings — true a moment before the service binds. */
    fun enabledInSettings(ctx: Context): Boolean {
        val list = Settings.Secure.getString(
            ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = component(ctx)
        return list.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    fun register(messenger: BinaryMessenger, activity: Activity) {
        MethodChannel(messenger, "hari/automation").setMethodCallHandler { call, result ->
            val ctx = activity.applicationContext
            val svc = HariAccessibilityService.instance
            when (call.method) {
                "status" -> result.success(mapOf(
                    "connected" to (svc != null),
                    "enabled" to enabledInSettings(ctx),
                ))
                // Straight to our switch where the phone allows it, else the
                // accessibility list with our entry highlighted.
                "openSettings" -> {
                    val cn = component(ctx).flattenToString()
                    val tries = ArrayList<Intent>()
                    if (Build.VERSION.SDK_INT >= 33) {
                        // Not in the public SDK constants; phones that do
                        // not let an app open it fall through to the list.
                        tries.add(Intent("android.settings.ACCESSIBILITY_DETAILS_SETTINGS")
                            .putExtra(Intent.EXTRA_COMPONENT_NAME, cn))
                    }
                    tries.add(Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS)
                        .putExtra(":settings:fragment_args_key", cn)
                        .putExtra(":settings:show_fragment_args",
                            Bundle().apply { putString(":settings:fragment_args_key", cn) }))
                    var ok = false
                    for (i in tries) {
                        try {
                            i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            activity.startActivity(i)
                            ok = true
                            break
                        } catch (e: Throwable) {
                            Log.w(TAG, "settings intent refused: ${e.javaClass.simpleName}")
                        }
                    }
                    result.success(ok)
                }
                // Android 13+: an app installed from a file must first be
                // allowed "restricted settings" from its App info menu.
                "openAppInfo" -> {
                    try {
                        activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${ctx.packageName}")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(true)
                    } catch (_: Throwable) { result.success(false) }
                }
                "resolveApp" -> result.success(resolveApp(activity, call.argument<String>("name") ?: ""))
                "launch" -> result.success(launch(activity,
                    call.argument<String>("pkg") ?: "", call.argument<String>("url") ?: ""))
                "bringBack" -> {
                    try {
                        activity.startActivity(Intent(activity, MainActivity::class.java).addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                                Intent.FLAG_ACTIVITY_SINGLE_TOP))
                        result.success(true)
                    } catch (_: Throwable) { result.success(false) }
                }
                "begin" -> {
                    if (svc == null) { result.success(false); return@setMethodCallHandler }
                    svc.begin(call.argument<List<String>>("allowed") ?: emptyList(),
                        call.argument<String>("status") ?: "Working on it…",
                        call.argument<Boolean>("any") == true)
                    result.success(true)
                }
                "allow" -> { svc?.allow(call.argument<String>("pkg") ?: ""); result.success(svc != null) }
                "say" -> { svc?.status(call.argument<String>("text") ?: ""); result.success(true) }
                "end" -> { svc?.end(call.argument<String>("final") ?: ""); result.success(true) }
                // "Install Swiggy": press Install on the Store page just
                // opened, then open the app when it lands.
                "autoInstall" -> result.success(svc?.autoInstall(
                    call.argument<String>("pkg") ?: "", call.argument<String>("name") ?: "") ?: false)
                "foreground" -> result.success(svc?.foreground() ?: "")
                "stopRequested" -> result.success(svc?.stopRequested ?: false)
                "snapshot" -> {
                    if (svc == null) { result.success(null); return@setMethodCallHandler }
                    worker.execute {
                        val snap = try { svc.snapshot() } catch (e: Throwable) {
                            Log.w(TAG, "snapshot failed: ${e.javaClass.simpleName}")
                            null
                        }
                        // The screenshot rides along — only for a screen the
                        // run may touch.
                        if (snap == null || snap["allowed"] != true || call.argument<Boolean>("shot") == false) {
                            main.post { result.success(snap) }
                        } else {
                            svc.captureScreen { shot ->
                                main.post { result.success(if (shot == null) snap else snap + ("shot" to shot)) }
                            }
                        }
                    }
                }
                "act" -> {
                    if (svc == null) {
                        result.success(mapOf("ok" to false, "error" to "no_service"))
                        return@setMethodCallHandler
                    }
                    @Suppress("UNCHECKED_CAST")
                    val a = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                    worker.execute {
                        val r = try { svc.act(a) } catch (e: Throwable) {
                            mapOf("ok" to false, "error" to "exception:${e.javaClass.simpleName}")
                        }
                        main.post { result.success(r) }
                    }
                }
                "settle" -> {
                    if (svc == null) { result.success(false); return@setMethodCallHandler }
                    val quiet = (call.argument<Number>("quietMs") ?: 450).toLong()
                    val max = (call.argument<Number>("maxMs") ?: 4000).toLong()
                    svc.settle(quiet, max) { result.success(true) }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun resolveApp(activity: Activity, name: String): Map<String, String>? =
        matchLauncherApp(activity.packageManager, name)?.let { mapOf("pkg" to it.first, "label" to it.second) }

    /**
     * Opens the task's starting point. A link for an app opens INSIDE that
     * app only (the package is pinned); if the app doesn't take the link,
     * the app itself opens instead — never the browser in its place.
     */
    private fun launch(activity: Activity, pkg: String, url: String): Map<String, Any?> {
        val pm = activity.packageManager
        if (url.isNotEmpty()) {
            try {
                val i = Intent(Intent.ACTION_VIEW, Uri.parse(url)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                if (pkg.isNotEmpty()) i.setPackage(pkg)
                activity.startActivity(i)
                return mapOf("ok" to true, "how" to "link")
            } catch (e: Throwable) {
                Log.i(TAG, "link not taken (${e.javaClass.simpleName}); opening the app")
                if (pkg.isEmpty()) return mapOf("ok" to false, "error" to "no_browser")
            }
        }
        if (pkg.isEmpty()) return mapOf("ok" to false, "error" to "no_app")
        val launch = pm.getLaunchIntentForPackage(pkg)
            ?: return mapOf("ok" to false, "error" to "not_installed")
        return try {
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            activity.startActivity(launch)
            mapOf("ok" to true, "how" to "app")
        } catch (e: Throwable) {
            mapOf("ok" to false, "error" to "launch_failed")
        }
    }
}

/** An installed app by spoken name — exact > prefix > contains. (pkg, label) */
fun matchLauncherApp(pm: PackageManager, name: String): Pair<String, String>? {
    val want = name.lowercase().replace(Regex("[^a-z0-9]"), "")
    if (want.isEmpty()) return null
    val apps = pm.queryIntentActivities(
        Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
    var best: Pair<String, String>? = null
    var bestScore = -1
    for (ri in apps) {
        val label = ri.loadLabel(pm).toString()
        val norm = label.lowercase().replace(Regex("[^a-z0-9]"), "")
        if (norm.isEmpty()) continue
        val score = when {
            norm == want -> 1000
            norm.startsWith(want) -> 700 - label.length
            want.startsWith(norm) -> 600 - label.length
            norm.contains(want) -> 400 - label.length
            else -> -1
        }
        if (score > bestScore) {
            bestScore = score
            best = ri.activityInfo.packageName to label
        }
    }
    return best?.takeIf { bestScore >= 0 }
}
