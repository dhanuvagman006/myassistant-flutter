package com.myassistant.myassistant

import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.util.Log
import io.flutter.plugin.common.MethodChannel

/**
 * "UNINSTALL INSTAGRAM" — any app the owner names, with Android's own
 * confirmation as the owner's permission.
 *
 * The assistant finds the app and opens the system's "Do you want to
 * uninstall this app?" dialog. It never taps that dialog — the installer
 * is on the accessibility service's never-act list — so an app leaves the
 * phone only when the owner presses OK themselves. What it reports is what
 * the phone shows afterwards (is the package still there?), not the
 * dialog's result code alone.
 *
 * Statuses: uninstalled | cancelled | no_answer | not_found | system_app |
 * self | busy | device_admin (an active device admin — Android refuses
 * until the owner switches that off) | blocked_by_policy (the phone's
 * settings or its administrator forbid it) | failed_after_confirm (the
 * owner said OK and the app is still there) | failed (the confirmation
 * could not be opened).
 */
object AppRemover {
    const val REQUEST = 7301
    private const val TAG = "hari/uninstall"
    private val main = Handler(Looper.getMainLooper())

    /**
     * Android's own reason for a refused uninstall (the uninstaller's
     * EXTRA_INSTALL_RESULT; PackageManager.DELETE_FAILED_*, hidden names).
     */
    private const val EXTRA_RESULT = "android.intent.extra.INSTALL_RESULT"
    private const val DELETE_FAILED_DEVICE_POLICY_MANAGER = -2
    private const val DELETE_FAILED_USER_RESTRICTED = -3
    private const val DELETE_FAILED_OWNER_BLOCKED = -4
    /** The dialog's Cancel button (Back gives RESULT_CANCELED instead). */
    private const val DELETE_FAILED_ABORTED = -5

    private var pending: MethodChannel.Result? = null
    private var pendingPkg = ""
    private var pendingLabel = ""
    private var timeout: Runnable? = null

    fun installed(pm: PackageManager, pkg: String): Boolean = try {
        pm.getApplicationInfo(pkg, 0)
        true
    } catch (_: PackageManager.NameNotFoundException) {
        false
    }

    fun start(activity: Activity, name: String, wantPkg: String, result: MethodChannel.Result) {
        val pm = activity.packageManager
        // A known package is exact; otherwise the launcher label, and only
        // a close match — a loose one could name the wrong app.
        val pkg = if (wantPkg.isNotEmpty() && installed(pm, wantPkg)) wantPkg
        else matchLauncherApp(pm, name, strict = true)?.first
        if (pkg == null) {
            result.success(mapOf("status" to "not_found", "label" to name))
            return
        }
        val info = try { pm.getApplicationInfo(pkg, 0) } catch (_: Throwable) { null }
        val label = info?.let { pm.getApplicationLabel(it).toString() } ?: name
        if (pkg == activity.packageName) {
            result.success(mapOf("status" to "self", "label" to label))
            return
        }
        // Came with the phone: Android offers only Disable, on the app's
        // own info page — open that for them.
        if (info != null && info.flags and ApplicationInfo.FLAG_SYSTEM != 0) {
            val opened = try {
                activity.startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                    Uri.parse("package:$pkg")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                true
            } catch (_: Throwable) { false }
            result.success(mapOf("status" to "system_app", "label" to label, "opened_info" to opened))
            return
        }
        if (pending != null) {
            result.success(mapOf("status" to "busy", "label" to label))
            return
        }
        // AN ACTIVE DEVICE ADMIN (a work profile manager, a phone finder, some
        // parental-control apps) cannot be removed: Android's dialog would
        // open and then fail. Say so before, with where to switch it off.
        if (isDeviceAdmin(activity, pkg)) {
            result.success(mapOf("status" to "device_admin", "label" to label))
            return
        }
        pending = result
        pendingPkg = pkg
        pendingLabel = label
        try {
            @Suppress("DEPRECATION")
            val i = Intent(Intent.ACTION_UNINSTALL_PACKAGE, Uri.parse("package:$pkg"))
                .putExtra(Intent.EXTRA_RETURN_RESULT, true)
            @Suppress("DEPRECATION")
            activity.startActivityForResult(i, REQUEST)
            Log.i(TAG, "confirmation opened")
        } catch (e: Throwable) {
            Log.w(TAG, "could not open the confirmation: ${e.javaClass.simpleName}")
            reply(mapOf("status" to "failed", "label" to label))
            return
        }
        // Never wait forever: the dialog can be dismissed in ways that
        // return nothing (the owner switches away and forgets it).
        timeout = Runnable { answer(activity, null) }.also { main.postDelayed(it, 180_000) }
    }

    private fun isDeviceAdmin(activity: Activity, pkg: String): Boolean = try {
        val dpm = activity.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
        dpm?.activeAdmins?.any { it.packageName == pkg } == true
    } catch (_: Throwable) { false }

    /** From MainActivity.onActivityResult. True when it was ours. */
    fun onResult(activity: Activity, requestCode: Int, resultCode: Int, data: Intent? = null): Boolean {
        if (requestCode != REQUEST) return false
        val androidCode = data?.getIntExtra(EXTRA_RESULT, 0) ?: 0
        if (resultCode == Activity.RESULT_OK && installed(activity.packageManager, pendingPkg)) {
            // OK can arrive before the package manager has caught up: look
            // again every half second, for up to 5 s, before saying it
            // failed (one look at 1.2 s called real removals failures).
            val until = SystemClock.uptimeMillis() + 5_000
            val poll = object : Runnable {
                override fun run() {
                    if (pending == null) return
                    val gone = !installed(activity.packageManager, pendingPkg)
                    if (gone || SystemClock.uptimeMillis() >= until) answer(activity, resultCode, androidCode)
                    else main.postDelayed(this, 500)
                }
            }
            main.postDelayed(poll, 500)
        } else {
            answer(activity, resultCode, androidCode)
        }
        return true
    }

    private fun answer(activity: Activity, code: Int?, androidCode: Int = 0) {
        if (pending == null) return
        val gone = !installed(activity.packageManager, pendingPkg)
        val status = when {
            gone -> "uninstalled"
            androidCode == DELETE_FAILED_DEVICE_POLICY_MANAGER -> "device_admin"
            androidCode == DELETE_FAILED_USER_RESTRICTED ||
                androidCode == DELETE_FAILED_OWNER_BLOCKED -> "blocked_by_policy"
            code == Activity.RESULT_CANCELED || androidCode == DELETE_FAILED_ABORTED -> "cancelled"
            code == null -> "no_answer"
            // The owner said OK (or Android gave a reason) and it is still
            // here: that really failed.
            code == Activity.RESULT_OK || androidCode < 0 -> "failed_after_confirm"
            // Android 15's new uninstaller answers Cancel with
            // RESULT_FIRST_USER and no reason at all — the owner kept it
            // (seen 2026-09-24: a Cancel was reported as "couldn't open").
            else -> "cancelled"
        }
        Log.i(TAG, "result $status")
        reply(mapOf("status" to status, "label" to pendingLabel))
    }

    private fun reply(m: Map<String, Any?>) {
        val r = pending ?: return
        pending = null
        timeout?.let { main.removeCallbacks(it) }
        timeout = null
        try { r.success(m) } catch (e: Throwable) {
            Log.w(TAG, "reply failed: ${e.javaClass.simpleName}")
        }
    }
}
