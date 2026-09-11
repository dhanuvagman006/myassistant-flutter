package com.myassistant.myassistant

import android.content.Context
import android.content.Intent
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.media.AudioManager
import android.os.BatteryManager
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent

/**
 * On-device controls behind the assistant's phone_control tool — the
 * flashlight/volume/media/battery basics every phone assistant has.
 * Every method returns a plain success flag; the Dart side reports
 * honestly instead of assuming.
 */
object DeviceControl {

    fun torch(context: Context, on: Boolean): Boolean {
        return try {
            val cm = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
            val id = cm.cameraIdList.firstOrNull { cid ->
                cm.getCameraCharacteristics(cid)
                    .get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true
            } ?: return false
            cm.setTorchMode(id, on)
            true
        } catch (e: Exception) {
            false
        }
    }

    /** value: 0-100 mapped onto the media stream; -1 = up, -2 = down. */
    fun volume(context: Context, mode: String, value: Int): Boolean {
        return try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val stream = AudioManager.STREAM_MUSIC
            when (mode) {
                "set" -> {
                    val max = am.getStreamMaxVolume(stream)
                    val v = (value.coerceIn(0, 100) * max) / 100
                    am.setStreamVolume(stream, v, AudioManager.FLAG_SHOW_UI)
                }
                "up" -> am.adjustStreamVolume(stream, AudioManager.ADJUST_RAISE, AudioManager.FLAG_SHOW_UI)
                "down" -> am.adjustStreamVolume(stream, AudioManager.ADJUST_LOWER, AudioManager.FLAG_SHOW_UI)
                "mute" -> am.adjustStreamVolume(stream, AudioManager.ADJUST_MUTE, AudioManager.FLAG_SHOW_UI)
                "unmute" -> am.adjustStreamVolume(stream, AudioManager.ADJUST_UNMUTE, AudioManager.FLAG_SHOW_UI)
                else -> return false
            }
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Media-session keys reach whichever app is playing (Spotify, YT Music…). */
    fun media(context: Context, key: String): Boolean {
        val code = when (key) {
            "play" -> KeyEvent.KEYCODE_MEDIA_PLAY
            "pause" -> KeyEvent.KEYCODE_MEDIA_PAUSE
            "next" -> KeyEvent.KEYCODE_MEDIA_NEXT
            "previous" -> KeyEvent.KEYCODE_MEDIA_PREVIOUS
            else -> return false
        }
        return try {
            val am = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
            am.dispatchMediaKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
            true
        } catch (e: Exception) {
            false
        }
    }

    /** Battery percentage, or -1 when unreadable. */
    fun battery(context: Context): Int {
        return try {
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY)
        } catch (e: Exception) {
            -1
        }
    }

    fun openPanel(context: Context, panel: String): Boolean {
        val intent = when (panel) {
            "wifi" ->
                if (Build.VERSION.SDK_INT >= 29) Intent(Settings.Panel.ACTION_WIFI)
                else Intent(Settings.ACTION_WIFI_SETTINGS)
            "bluetooth" -> Intent(Settings.ACTION_BLUETOOTH_SETTINGS)
            "sound" ->
                if (Build.VERSION.SDK_INT >= 29) Intent(Settings.Panel.ACTION_VOLUME)
                else Intent(Settings.ACTION_SOUND_SETTINGS)
            "display" -> Intent(Settings.ACTION_DISPLAY_SETTINGS)
            "battery" -> Intent(Intent.ACTION_POWER_USAGE_SUMMARY)
            else -> Intent(Settings.ACTION_SETTINGS)
        }
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (e: Exception) {
            false
        }
    }
}
