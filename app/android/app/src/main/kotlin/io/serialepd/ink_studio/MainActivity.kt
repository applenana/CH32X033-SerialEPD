package io.serialepd.ink_studio

import android.content.ActivityNotFoundException
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var galleryResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.serialepd/gallery")
            .setMethodCallHandler { call, result ->
                if (call.method != "pickImage") return@setMethodCallHandler result.notImplemented()
                if (galleryResult != null) {
                    return@setMethodCallHandler result.error("gallery_busy", "Image selection is already open", null)
                }
                galleryResult = result
                val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                    Intent(MediaStore.ACTION_PICK_IMAGES).apply { type = "image/*" }
                } else {
                    // ACTION_GET_CONTENT opens a document/file picker on many
                    // devices. ACTION_PICK targets the user's gallery app.
                    Intent(Intent.ACTION_PICK, MediaStore.Images.Media.EXTERNAL_CONTENT_URI).apply {
                        type = "image/*"
                    }
                }
                try {
                    startActivityForResult(intent, 4102)
                } catch (_: ActivityNotFoundException) {
                    // A few AOSP builds have no gallery app; retain a usable
                    // fallback without changing the normal gallery behavior.
                    startActivityForResult(
                        Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                            type = "image/*"
                            addCategory(Intent.CATEGORY_OPENABLE)
                        },
                        4102,
                    )
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "io.serialepd/power")
            .setMethodCallHandler { call, result ->
                if (call.method == "keepScreenOn") {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    @Deprecated("Android activity result bridge for the system photo picker")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != 4102) return
        val result = galleryResult ?: return
        galleryResult = null
        if (resultCode != RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        try {
            val uri = data.data!!
            val bytes = readGalleryImage(uri)
            val name = contentResolver.query(uri, null, null, null, null)?.use { cursor ->
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (cursor.moveToFirst() && index >= 0) cursor.getString(index) else null
            } ?: "相册图片"
            result.success(mapOf("bytes" to bytes, "name" to name))
        } catch (error: Exception) {
            result.error("gallery_read", error.message ?: "Cannot read selected image", null)
        }
    }

    private fun readGalleryImage(uri: Uri): ByteArray {
        val source = contentResolver.openInputStream(uri)?.use { it.readBytes() }
            ?: error("Cannot read selected image")
        if (source.size <= 25 * 1024 * 1024) return source
        val options = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(source, 0, source.size, options)
        var sample = 1
        while ((options.outWidth / sample) * (options.outHeight / sample) > 2_000_000) sample *= 2
        val bitmap = BitmapFactory.decodeByteArray(
            source,
            0,
            source.size,
            BitmapFactory.Options().apply { inSampleSize = sample },
        ) ?: error("Image format is not supported")
        return ByteArrayOutputStream().use { output ->
            bitmap.compress(Bitmap.CompressFormat.JPEG, 95, output)
            bitmap.recycle()
            output.toByteArray()
        }
    }
}
