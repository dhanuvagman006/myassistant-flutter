package com.myassistant.myassistant

import android.app.Activity
import android.util.Log
import com.google.firebase.appdistribution.FirebaseAppDistribution
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * "hari/feedback" — the You tab's "Send feedback" row.
 *
 * Owner, 2026-09-25: "yes add the send feedback button". The client gets
 * the app through Firebase App Distribution, and the owner wants what the
 * client says to land next to the build it is about: Firebase console →
 * App Distribution → the release → Tester feedback. The SDK brings its own
 * form, its own tester sign-in and its own upload; this channel only opens
 * it.
 *
 * THE SCREENSHOT. We wanted none: the row is on the You tab, so the
 * automatic picture is always of the You tab. The SDK's overload that
 * takes a screenshot Uri says it accepts null for "none", but in
 * 16.0.0-beta20 it calls uri.getScheme() before its own null check, so
 * null throws a NullPointerException and the form never opens. So this
 * uses the one-argument startFeedback(): the form shows the picture under
 * a "Screenshot" tick-box the client can untick, and a "Gallery" button
 * to attach the right screen instead — which the prompt asks for. Worth
 * re-checking when the SDK version changes.
 *
 * NEVER AN UPDATER. The full SDK can also look for, download and install
 * new releases (updateIfNewReleaseAvailable, checkForNewRelease,
 * updateApp). None of that is called, here or anywhere: the app's own
 * updater ("hari/updater", ApkInstaller) stays the only thing that
 * installs a build, so the client never sees two update prompts for the
 * same release.
 */
object TesterFeedbackBridge {

    private const val TAG = "hari/feedback"
    private var activityRef: WeakReference<Activity>? = null

    fun register(messenger: BinaryMessenger, activity: Activity) {
        activityRef = WeakReference(activity)
        MethodChannel(messenger, "hari/feedback").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> start(result)
                else -> result.notImplemented()
            }
        }
    }

    /**
     * True once the form is on its way. The SDK hands nothing back (no
     * task, no callback): the tester sign-in, the screenshot and the form
     * all follow on their own, and its later failures ("release not
     * found", "failed to launch feedback") it shows as its own toasts.
     * What can fail HERE — Firebase not started, the SDK missing from a
     * build — becomes an error Dart turns into one toast, never a crash
     * on the You tab.
     */
    private fun start(result: MethodChannel.Result) {
        val activity = activityRef?.get()
        if (activity == null || activity.isFinishing) {
            result.error("unavailable", "The app is not on screen.", null)
            return
        }
        // Channel calls already arrive on the main thread; runOnUiThread
        // runs at once there, and keeps it true if that ever changes.
        activity.runOnUiThread {
            try {
                FirebaseAppDistribution.getInstance()
                    .startFeedback(R.string.feedback_prompt)
                result.success(true)
            } catch (e: Throwable) {
                Log.w(TAG, "start failed: ${e.javaClass.simpleName}: ${e.message}")
                result.error("unavailable", e.message ?: e.javaClass.simpleName, null)
            }
        }
    }
}
