package com.myassistant.myassistant

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import java.io.File

/**
 * SELF-UPDATE through the system PackageInstaller.
 *
 * Why not just open the APK: that flow needs a tap on every single
 * update. A session-based install with USER_ACTION_NOT_REQUIRED updates
 * SILENTLY on Android 12+ — but only once this app is its own installer
 * of record, which the FIRST session install establishes (that one still
 * shows the system confirmation). Every update after it is hands-free.
 */
object ApkInstaller {

    private const val TAG = "HariUpdater"

    /** Runs the whole session dance on a WORKER thread — the 185 MB copy
     *  on the platform (UI) thread froze the channel call, the write never
     *  finished, and every attempt left an orphaned uncommitted session.
     *  Calls [done] on the main thread with whether the commit was issued. */
    fun install(context: Context, apkPath: String, done: (Boolean) -> Unit) {
        Thread {
            val ok = try {
                doInstall(context, apkPath)
            } catch (e: Exception) {
                android.util.Log.e(TAG, "install failed", e)
                false
            }
            android.os.Handler(context.mainLooper).post { done(ok) }
        }.start()
    }

    private fun doInstall(context: Context, apkPath: String): Boolean {
        val file = File(apkPath)
        if (!file.exists()) {
            android.util.Log.e(TAG, "apk missing: $apkPath")
            return false
        }
        val installer = context.packageManager.packageInstaller
        // Clear our own abandoned sessions (earlier frozen attempts) so
        // they can't pile up or hold storage.
        for (info in installer.mySessions) {
            try {
                android.util.Log.i(TAG, "abandoning stale session ${info.sessionId}")
                installer.abandonSession(info.sessionId)
            } catch (_: Exception) {}
        }
        val params = PackageInstaller.SessionParams(
            PackageInstaller.SessionParams.MODE_FULL_INSTALL
        ).apply {
            setAppPackageName(context.packageName)
            setSize(file.length())
            if (Build.VERSION.SDK_INT >= 31) {
                setRequireUserAction(
                    PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED
                )
            }
        }
        val sessionId = installer.createSession(params)
        android.util.Log.i(TAG, "session $sessionId created, writing ${file.length()} bytes")
        installer.openSession(sessionId).use { session ->
            session.openWrite("app.apk", 0, file.length()).use { out ->
                file.inputStream().use { it.copyTo(out, 1 shl 20) }
                session.fsync(out)
            }
            android.util.Log.i(TAG, "session $sessionId written, committing")
            val flags =
                if (Build.VERSION.SDK_INT >= 31)
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                else PendingIntent.FLAG_UPDATE_CURRENT
            val intent = Intent(context, InstallResultReceiver::class.java)
                .setAction("com.myassistant.myassistant.INSTALL_RESULT")
            val pending = PendingIntent.getBroadcast(context, sessionId, intent, flags)
            session.commit(pending.intentSender)
            android.util.Log.i(TAG, "session $sessionId committed")
        }
        return true
    }
}

/** Handles the session result: a first-time install needs the system's
 *  one confirmation screen; a permitted silent update just completes
 *  (the process is replaced — the new version runs on next open). */
class InstallResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, -1)
        android.util.Log.i(
            "HariUpdater",
            "install result status=$status msg=${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}"
        )
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirm: Intent? =
                    if (Build.VERSION.SDK_INT >= 33)
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    else intent.getParcelableExtra(Intent.EXTRA_INTENT)
                confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                try {
                    if (confirm != null) context.startActivity(confirm)
                } catch (_: Exception) {}
            }
            // SUCCESS ends this process (we were replaced); failures are
            // silent here — the app re-offers the update on next launch.
        }
    }
}
