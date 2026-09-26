package com.myassistant.myassistant

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.util.Log

/**
 * "OPEN SWIGGY" ON A PHONE WITHOUT SWIGGY.
 *
 * Owner, 2026-09-23: check it is there; if not, the Play Store — "and
 * then open that app". Android lets only the user press Install, so the
 * Store page is where we stop; what this app CAN do is the part after:
 * watch for that package to arrive and open it.
 *
 * Android 10+ forbids starting another app's screen from the background,
 * and the Store is in front while it installs. So the moment it lands we
 * post "Swiggy is installed — tap to open", and if the user comes back to
 * this app first, MainActivity.onResume opens it straight away.
 */
object InstallWatch {
    private const val TAG = "hari/install"
    private const val CHANNEL = "app_installed"
    private const val WINDOW_MS = 20 * 60 * 1000L

    private var wantPkg = ""
    private var wantName = ""
    private var until = 0L
    private var readyPkg: String? = null
    private var readyUntil = 0L
    /**
     * A task's own install (build 117): no "is installed" notification and
     * nothing opened on return here — the task opens the app itself.
     */
    private var quiet = false
    private var receiver: BroadcastReceiver? = null

    private fun now() = System.currentTimeMillis()
    private fun norm(s: String) = s.lowercase().replace(Regex("[^a-z0-9]"), "")

    /** Called when the Store was opened for an app the phone lacks. */
    fun arm(ctx: Context, pkg: String, name: String, forTask: Boolean = false) {
        val app = ctx.applicationContext
        wantPkg = pkg
        wantName = norm(name)
        until = now() + WINDOW_MS
        readyPkg = null
        quiet = forTask
        if (receiver != null) return
        val r = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                if (i.getBooleanExtra(Intent.EXTRA_REPLACING, false)) return
                val added = i.data?.schemeSpecificPart ?: return
                onAdded(app, added)
            }
        }
        val f = IntentFilter(Intent.ACTION_PACKAGE_ADDED).apply { addDataScheme("package") }
        try {
            if (Build.VERSION.SDK_INT >= 33) {
                app.registerReceiver(r, f, Context.RECEIVER_EXPORTED)
            } else {
                app.registerReceiver(r, f)
            }
            receiver = r
            Log.i(TAG, "watching for ${pkg.ifEmpty { name }}")
        } catch (e: Throwable) {
            Log.w(TAG, "could not watch installs: ${e.javaClass.simpleName}")
        }
    }

    private fun disarm(app: Context) {
        receiver?.let { try { app.unregisterReceiver(it) } catch (_: Throwable) {} }
        receiver = null
    }

    /**
     * A task's install is over, however it ended: nothing is watched any
     * more, so an app that lands later is neither announced nor opened the
     * next time the owner comes back here.
     */
    fun clear(ctx: Context) {
        val app = ctx.applicationContext
        readyPkg?.let {
            (app.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)
                ?.cancel(it.hashCode())
        }
        wantPkg = ""
        wantName = ""
        until = 0L
        readyPkg = null
        quiet = false
        disarm(app)
    }

    private fun onAdded(app: Context, added: String) {
        if (now() > until) { disarm(app); return }
        val pm = app.packageManager
        val launch = pm.getLaunchIntentForPackage(added) ?: return
        val label = try {
            pm.getApplicationLabel(pm.getApplicationInfo(added, 0)).toString()
        } catch (_: Throwable) { added }
        val match = if (wantPkg.isNotEmpty()) {
            added == wantPkg
        } else {
            val n = norm(label)
            wantName.isNotEmpty() && n.isNotEmpty() &&
                (n == wantName || n.startsWith(wantName) || wantName.startsWith(n))
        }
        if (!match) return
        Log.i(TAG, "installed $added ($label)")
        readyPkg = added
        readyUntil = now() + WINDOW_MS
        if (!quiet) notifyReady(app, added, label, launch)
        disarm(app)
    }

    /**
     * The app to open now the user is back here — once, while fresh.
     * [installer]: the install's own watcher asking; a task's app is only
     * ever handed to it, never opened by coming back here.
     */
    fun takeReady(ctx: Context, installer: Boolean = false): Intent? {
        if (quiet && !installer) return null
        val pkg = readyPkg ?: return null
        readyPkg = null
        if (now() > readyUntil) return null
        (ctx.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager)
            ?.cancel(pkg.hashCode())
        return ctx.packageManager.getLaunchIntentForPackage(pkg)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
    }

    private fun notifyReady(app: Context, pkg: String, label: String, launch: Intent) {
        try {
            val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= 26 && nm.getNotificationChannel(CHANNEL) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(CHANNEL, "Apps you asked to open",
                        NotificationManager.IMPORTANCE_HIGH))
            }
            launch.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            val pi = PendingIntent.getActivity(app, pkg.hashCode(), launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val b = if (Build.VERSION.SDK_INT >= 26) {
                Notification.Builder(app, CHANNEL)
            } else {
                @Suppress("DEPRECATION") Notification.Builder(app)
            }
            nm.notify(pkg.hashCode(), b
                .setSmallIcon(R.drawable.ic_stat_hari)
                .setContentTitle("$label is installed")
                .setContentText("Tap to open it.")
                .setAutoCancel(true)
                .setContentIntent(pi)
                .build())
        } catch (e: Throwable) {
            Log.w(TAG, "notify failed: ${e.javaClass.simpleName}")
        }
    }
}
