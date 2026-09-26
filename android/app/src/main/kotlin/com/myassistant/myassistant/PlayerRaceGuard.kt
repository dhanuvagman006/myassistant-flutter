package com.myassistant.myassistant

import android.os.Looper
import android.util.Log

/**
 * THE VOICE'S LAST CHUNK MUST NOT TAKE THE APP DOWN (2026-09-26).
 *
 * The owner's "order a guitar on Amazon": as the Play Store came to the
 * front, the app went to the background, the voice player was stopped
 * (LiveService.silence) while its feeding thread was still writing her
 * reply — and Android's AudioTrack threw "Unable to retrieve AudioTrack
 * pointer for write()" on that thread. An exception nobody catches on any
 * thread kills the whole process: the install the owner had asked for
 * died with it, mid-way, and the Install button was never pressed. The
 * same crash was logged on 2026-09-24.
 *
 * The write that failed was sound for a player already stopped: nothing is
 * lost by letting that one thread end. So exactly that exception — an
 * AudioTrack IllegalStateException on a thread other than the main one —
 * ends its thread quietly; everything else goes to the handler that was
 * there before, as always.
 */
object PlayerRaceGuard {
    private const val TAG = "hari/audio"

    fun install() {
        val previous = Thread.getDefaultUncaughtExceptionHandler()
        if (previous is Handler) return
        Thread.setDefaultUncaughtExceptionHandler(Handler(previous))
    }

    /** Pure, so the rule can be checked on its own. */
    fun isPlayerRace(t: Thread, e: Throwable, main: Thread?): Boolean {
        if (t === main) return false
        // The same race also surfaces as a NullPointerException on
        // "android.media.AudioTrack.write(…)" (review, 2026-09-26).
        if (e !is IllegalStateException && e !is NullPointerException) return false
        val msg = e.message.orEmpty()
        if (msg.contains("AudioTrack")) return true
        return e.stackTrace.any { it.className == "android.media.AudioTrack" }
    }

    private class Handler(
        private val previous: Thread.UncaughtExceptionHandler?,
    ) : Thread.UncaughtExceptionHandler {
        override fun uncaughtException(t: Thread, e: Throwable) {
            if (isPlayerRace(t, e, Looper.getMainLooper()?.thread)) {
                Log.w(TAG, "player thread '${t.name}' ended after its track was stopped: ${e.message}")
                return
            }
            previous?.uncaughtException(t, e)
        }
    }
}
