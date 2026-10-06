package com.myassistant.myassistant

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * THE RECORDED OPENING ON THE CALL STREAM (2026-10-06, the owner: "the
 * recorded one is played as media and the live conversation as a call, so
 * make sure both volume levels are the same").
 *
 * GPT-Live's voice arrives over WebRTC and plays as voice communication;
 * the app's own player plays as media — two volume sliders. So the cached
 * "Hello Sir" is played here as voice communication, on the loudspeaker
 * like the live voice: one volume, one route, the same loudness.
 */
object VoiceClip {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var track: AudioTrack? = null

    /** Plays 16-bit mono [pcm] at [rate]; [done] is called once, when it ends or fails. */
    fun play(ctx: Context, pcm: ByteArray, rate: Int, done: (Boolean) -> Unit) {
        stop()
        if (pcm.size < 2 || rate <= 0) return done(false)
        var finished = false
        val finish = { ok: Boolean ->
            if (!finished) {
                finished = true
                done(ok)
            }
        }
        try {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.mode = AudioManager.MODE_IN_COMMUNICATION
            if (Build.VERSION.SDK_INT >= 31) {
                am.availableCommunicationDevices
                    .firstOrNull { it.type == AudioDeviceInfo.TYPE_BUILTIN_SPEAKER }
                    ?.let { am.setCommunicationDevice(it) }
            } else {
                @Suppress("DEPRECATION")
                am.isSpeakerphoneOn = true
            }
            val t = AudioTrack(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build(),
                AudioFormat.Builder()
                    .setSampleRate(rate)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .build(),
                pcm.size,
                AudioTrack.MODE_STATIC,
                AudioManager.AUDIO_SESSION_ID_GENERATE,
            )
            t.write(pcm, 0, pcm.size)
            track = t
            val ms = pcm.size / 2 * 1000L / rate
            t.play()
            // The end, by the clock: a static track's marker is unreliable on
            // some devices, and a little air after the last word is natural.
            main.postDelayed({
                if (track === t) stop()
                finish(true)
            }, ms + 60)
        } catch (e: Exception) {
            stop()
            finish(false)
        }
    }

    fun stop() {
        val t = track ?: return
        track = null
        try { t.stop() } catch (_: Exception) {}
        try { t.release() } catch (_: Exception) {}
    }
}
