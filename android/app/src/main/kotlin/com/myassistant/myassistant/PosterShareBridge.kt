package com.myassistant.myassistant

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.os.Build
import android.provider.MediaStore
import android.util.Log
import androidx.core.content.FileProvider
import java.io.File

/**
 * Its own subclass, so this provider can never collide in the merged
 * manifest with a plugin that also declares androidx's FileProvider.
 */
class PosterFileProvider : FileProvider()

/**
 * GIFT CARDS → WHATSAPP, ONE TAP (2026-09-26).
 *
 * The client makes a birthday card for his daughter and wants to send it.
 * The share sheet is a long list to hunt through for an elderly father, so
 * the card goes straight to WhatsApp with the documented ACTION_SEND +
 * setPackage — no undocumented "jid" extra, so WhatsApp itself asks who it
 * is for and HE presses Send. WhatsApp Business is tried next; if neither
 * is installed the Dart side opens the normal share sheet instead.
 */
object PosterShareBridge {
    private const val TAG = "hari/poster"

    /** 'ok' | 'not_installed' | 'no_file' | 'failed' */
    fun shareImageTo(ctx: Context, path: String, mime: String, pkg: String): String {
        val file = File(path)
        if (!file.exists()) return "no_file"
        val uri = try {
            FileProvider.getUriForFile(ctx, ctx.packageName + ".posters", file)
        } catch (e: Throwable) {
            Log.w(TAG, "no uri for $path: ${e.javaClass.simpleName}")
            return "failed"
        }
        for (target in listOf(pkg, "com.whatsapp.w4b").distinct()) {
            try {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = mime
                    putExtra(Intent.EXTRA_STREAM, uri)
                    // ClipData carries the read grant on every Android version.
                    clipData = ClipData.newRawUri("card", uri)
                    addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    setPackage(target)
                }
                ctx.startActivity(send)
                Log.i(TAG, "shared to $target")
                return "ok"
            } catch (e: ActivityNotFoundException) {
                Log.i(TAG, "$target not installed")
            } catch (e: Throwable) {
                Log.w(TAG, "share to $target failed: ${e.javaClass.simpleName}: ${e.message}")
                return "failed"
            }
        }
        return "not_installed"
    }

    /**
     * Saves the card into his Photos (Pictures/MyAssistant). Android 10+
     * only — older phones would need a storage permission for this, so they
     * get the share sheet instead. 'ok' | 'unsupported' | 'failed'.
     */
    fun saveImageToGallery(ctx: Context, bytes: ByteArray, name: String): String {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return "unsupported"
        val resolver = ctx.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, name)
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "Pictures/MyAssistant")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = try {
            resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
        } catch (e: Throwable) {
            Log.w(TAG, "gallery insert failed: ${e.javaClass.simpleName}")
            null
        } ?: return "failed"
        return try {
            resolver.openOutputStream(uri)?.use { it.write(bytes) } ?: throw IllegalStateException("no stream")
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
            Log.i(TAG, "saved $name to Pictures/MyAssistant")
            "ok"
        } catch (e: Throwable) {
            Log.w(TAG, "gallery write failed: ${e.javaClass.simpleName}: ${e.message}")
            try { resolver.delete(uri, null, null) } catch (_: Throwable) {}
            "failed"
        }
    }
}
