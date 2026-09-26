package com.myassistant.myassistant

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

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

    /**
     * How long a look waits for its picture after the element walk. A
     * picture takes ~100-600 ms (a "too soon" retry and the Android 14
     * secure-window check add 350 ms each); past this the look goes
     * without one rather than hold the step.
     */
    private const val SHOT_WAIT_MS = 2500L

    private fun component(ctx: Context) = ComponentName(ctx, HariAccessibilityService::class.java)

    /**
     * The task loop's own calls. Each one tells the service the loop is
     * alive (HariAccessibilityService.heard); a run it stops hearing from
     * ends itself. Setup-screen calls (status, openSettings…) do not count:
     * a reopened app polling them has no loop running.
     */
    private val LOOP_CALLS = setOf(
        "begin", "launch", "allow", "say", "snapshot", "act", "settle",
        "stopRequested", "ownerWait", "ownerAnswer", "waitForApp",
    )

    /** Switched on in Settings — true a moment before the service binds. */
    fun enabledInSettings(ctx: Context): Boolean {
        val list = Settings.Secure.getString(
            ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: return false
        val me = component(ctx)
        return list.split(':').any { ComponentName.unflattenFromString(it) == me }
    }

    fun register(messenger: BinaryMessenger, activity: Activity) {
        LauncherLabels.watch(activity)
        MethodChannel(messenger, "hari/automation").setMethodCallHandler { call, result ->
            val ctx = activity.applicationContext
            val svc = HariAccessibilityService.instance
            if (call.method in LOOP_CALLS) svc?.heard()
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
                // Build 115: is this exact app on the phone? Asked BEFORE the
                // conversation closes for a task, so a missing app becomes a
                // question ("install it, or use Swiggy?") instead of a
                // failure read out after the conversation has gone.
                "installed" -> {
                    val pkg = call.argument<String>("pkg") ?: ""
                    result.success(pkg.isNotEmpty() &&
                        activity.packageManager.getLaunchIntentForPackage(pkg) != null)
                }
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
                // False while an app is installing: the two would end each
                // other (HariAccessibilityService.begin).
                "begin" -> {
                    if (svc == null) { result.success(false); return@setMethodCallHandler }
                    result.success(svc.begin(call.argument<List<String>>("allowed") ?: emptyList(),
                        call.argument<String>("status") ?: "Working on it…",
                        call.argument<Boolean>("any") == true,
                        call.argument<Boolean>("may_install") == true,
                        call.argument<String>("install_app") ?: ""))
                }
                // The owner's turn (sign-in, OTP…): the bar's Stop becomes
                // Continue; Dart polls ownerAnswer and reads nothing else.
                "ownerWait" -> {
                    svc?.ownerWait(call.argument<String>("text") ?: "")
                    result.success(svc != null)
                }
                "ownerAnswer" -> result.success(svc?.ownerAnswer() ?: "stop")
                "allow" -> { svc?.allow(call.argument<String>("pkg") ?: ""); result.success(svc != null) }
                "say" -> { svc?.status(call.argument<String>("text") ?: ""); result.success(true) }
                "end" -> { svc?.end(call.argument<String>("final") ?: ""); result.success(true) }
                // "Install Swiggy": press Install on the Store page just
                // opened, then open the app when it lands.
                "autoInstall" -> result.success(svc?.autoInstall(
                    call.argument<String>("pkg") ?: "", call.argument<String>("name") ?: "") ?: false)
                // Build 117: a task whose app is not on the phone installs it
                // first — the app's own store page (or a search for it), with
                // Install pressed by the service — and then carries on.
                "installForTask" -> {
                    if (svc == null) { result.success(false); return@setMethodCallHandler }
                    val pkg = call.argument<String>("pkg") ?: ""
                    val name = call.argument<String>("name") ?: ""
                    // Refused BEFORE the store opens or the watch is armed:
                    // another install (or run) owns the Store and the watch,
                    // and a money app is the owner's to install (review,
                    // 2026-09-26).
                    if (svc.installing || svc.running ||
                        (pkg.isNotEmpty() && HariAccessibilityService.never(pkg))) {
                        Log.i("hari/install", "task install refused: installing=${svc.installing} running=${svc.running} pkg=$pkg")
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val tries = if (pkg.isNotEmpty()) listOf(
                        "market://details?id=" + Uri.encode(pkg),
                        "https://play.google.com/store/apps/details?id=" + Uri.encode(pkg)
                    ) else listOf(
                        "market://search?q=" + Uri.encode(name) + "&c=apps",
                        "https://play.google.com/store/search?q=" + Uri.encode(name) + "&c=apps"
                    )
                    InstallWatch.arm(activity.applicationContext, pkg, name, forTask = true)
                    var opened = false
                    for (u in tries) {
                        try {
                            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(u))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            Log.i("hari/install", "opened $u")
                            opened = true
                            break
                        } catch (e: Throwable) {
                            Log.w("hari/install", "failed $u: ${e.javaClass.simpleName}")
                        }
                    }
                    val started = opened && svc.autoInstall(pkg, name, forTask = true)
                    if (!started) InstallWatch.clear(activity.applicationContext)
                    result.success(started)
                }
                "installState" -> result.success(mapOf(
                    "installing" to (svc?.installing ?: false),
                    "outcome" to (svc?.installOutcome ?: "")))
                "foreground" -> result.success(svc?.foreground() ?: "")
                "stopRequested" -> result.success(svc?.stopRequested ?: false)
                "snapshot" -> {
                    if (svc == null) { result.success(null); return@setMethodCallHandler }
                    // THE ELEMENTS AND THE PICTURE AT ONCE (2026-09-24). The
                    // picture used to start only after the whole element
                    // walk — 150-400 ms a step. Now both start together.
                    // The picture is only taken of a screen the run may
                    // touch (asked first), and dropped if the walk then finds
                    // another app in front. access.shot says how it came out;
                    // a black (secure) picture is never sent.
                    val shooting = call.argument<Boolean>("shot") != false && svc.mayPhotograph()
                    val shot = AtomicReference<HariAccessibilityService.Shot?>(null)
                    val gotShot = CountDownLatch(1)
                    if (shooting) svc.captureScreen { s -> shot.set(s); gotShot.countDown() }
                    worker.execute {
                        val snap = try { svc.snapshot() } catch (e: Throwable) {
                            Log.w(TAG, "snapshot failed: ${e.javaClass.simpleName}")
                            null
                        }
                        if (shooting) {
                            try { gotShot.await(SHOT_WAIT_MS, TimeUnit.MILLISECONDS) } catch (_: InterruptedException) {}
                        }
                        val s = shot.get()
                        when {
                            snap == null -> {
                                svc.noPicture()
                                main.post { result.success(null) }
                            }
                            snap["allowed"] != true || !shooting -> {
                                svc.noPicture()
                                main.post { result.success(withShot(snap, "none", null, 0L, 0, null)) }
                            }
                            s == null -> {
                                // Still coming after the wait: this look goes
                                // without it (a late picture never counts).
                                svc.noPicture()
                                main.post { result.success(withShot(snap, "failed", null, SHOT_WAIT_MS, 0, null)) }
                            }
                            else -> {
                                svc.shotSent(s.status)
                                main.post { result.success(withShot(snap, s.status, s.jpeg, s.ms, s.kb, s.grid)) }
                            }
                        }
                    }
                }
                // The first look waits for the opened app to be drawn, not a
                // fixed time (HariAccessibilityService.waitForApp).
                "waitForApp" -> {
                    if (svc == null) { result.success(null); return@setMethodCallHandler }
                    val pkg = call.argument<String>("pkg") ?: ""
                    val max = (call.argument<Number>("maxMs") ?: 5000).toLong()
                    worker.execute {
                        val r = try { svc.waitForApp(pkg, max) } catch (e: Throwable) {
                            mapOf("ok" to false, "reason" to "exception:${e.javaClass.simpleName}")
                        }
                        main.post { result.success(r) }
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
                // Waits for the last action's effect; answers {ms, reason}
                // (HariAccessibilityService.settle).
                "settle" -> {
                    if (svc == null) { result.success(null); return@setMethodCallHandler }
                    val quiet = (call.argument<Number>("quietMs") ?: 450).toLong()
                    val max = (call.argument<Number>("maxMs") ?: 4000).toLong()
                    val expect = (call.argument<Number>("expectMs") ?: 0).toLong()
                    val min = (call.argument<Number>("minMs") ?: 250).toLong()
                    svc.settle(quiet, max, expect, min) { ms, reason ->
                        result.success(mapOf("ms" to ms, "reason" to reason))
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /**
     * The look plus its picture: access.shot, times/sizes for the log, and
     * the picture's brightness grid (stays on the phone: the Dart loop
     * compares it to tell whether a picture-only screen changed).
     */
    private fun withShot(snap: Map<String, Any?>, status: String, jpeg: String?,
                         ms: Long, kb: Int, grid: String?): Map<String, Any?> {
        @Suppress("UNCHECKED_CAST")
        val access = (snap["access"] as? Map<String, Any?>).orEmpty() + ("shot" to status)
        var out = snap + ("access" to access) + ("shot_ms" to ms)
        if (jpeg != null) out = out + ("shot" to jpeg) + ("shot_kb" to kb)
        if (grid != null) out = out + ("grid" to grid)
        return out
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

/**
 * THE PHONE'S APP NAMES, READ ONCE. Matching a spoken name meant loading
 * the label of every launcher app on every call — 100-600 ms per "open X"
 * on a budget phone, several times a task. The list is kept for 10 minutes
 * and dropped the moment an app is installed, removed or updated.
 */
object LauncherLabels {
    private const val TTL_MS = 10 * 60_000L

    /** (package, label, label reduced to a-z0-9) */
    class App(val pkg: String, val label: String, val norm: String)

    @Volatile private var apps: List<App>? = null
    @Volatile private var readAt = 0L
    private var watching = false

    fun list(pm: PackageManager): List<App> {
        val now = SystemClock.uptimeMillis()
        apps?.let { if (now - readAt < TTL_MS) return it }
        val fresh = pm.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0)
            .map { ri ->
                val label = ri.loadLabel(pm).toString()
                App(ri.activityInfo.packageName, label, label.lowercase().replace(Regex("[^a-z0-9]"), ""))
            }
        apps = fresh
        readAt = now
        return fresh
    }

    fun clear() {
        apps = null
    }

    /** Once per process: any install, removal or update clears the list. */
    @Synchronized
    fun watch(ctx: Context) {
        if (watching) return
        val app = ctx.applicationContext
        val f = IntentFilter().apply {
            addAction(Intent.ACTION_PACKAGE_ADDED)
            addAction(Intent.ACTION_PACKAGE_REMOVED)
            addAction(Intent.ACTION_PACKAGE_CHANGED)
            addAction(Intent.ACTION_PACKAGE_REPLACED)
            addDataScheme("package")
        }
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) = clear()
        }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(r, f, Context.RECEIVER_EXPORTED)
            } else {
                app.registerReceiver(r, f)
            }
            watching = true
        } catch (e: Throwable) {
            // Without the watch the 10-minute limit still applies.
            Log.w("hari/auto", "could not watch app changes: ${e.javaClass.simpleName}")
        }
    }
}

/**
 * An installed app by spoken name — exact > prefix > contains. (pkg, label)
 * [strict] refuses a contains-only match: for removing an app, a loose
 * match could name the wrong one.
 */
fun matchLauncherApp(pm: PackageManager, name: String, strict: Boolean = false): Pair<String, String>? {
    val want = name.lowercase().replace(Regex("[^a-z0-9]"), "")
    if (want.isEmpty()) return null
    var best: Pair<String, String>? = null
    var bestScore = -1
    for (a in LauncherLabels.list(pm)) {
        val norm = a.norm
        if (norm.isEmpty()) continue
        val score = when {
            norm == want -> 1000
            norm.startsWith(want) -> 700 - a.label.length
            want.startsWith(norm) -> 600 - a.label.length
            norm.contains(want) -> 400 - a.label.length
            else -> -1
        }
        if (score > bestScore) {
            bestScore = score
            best = a.pkg to a.label
        }
    }
    return best?.takeIf { bestScore >= (if (strict) 500 else 0) }
}
