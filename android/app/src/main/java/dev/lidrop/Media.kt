package dev.lidrop

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Base64
import android.util.LruCache
import android.util.Size
import java.io.ByteArrayOutputStream

data class Item(val uri: Uri, val name: String, val mime: String, val size: Long, val isVideo: Boolean, val date: Long = 0)

fun queryMedia(ctx: Context, limit: Int = 400): List<Item> {
    val res = ArrayList<Item>()
    val proj = arrayOf(
        MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.DISPLAY_NAME,
        MediaStore.Files.FileColumns.MIME_TYPE, MediaStore.Files.FileColumns.SIZE,
        MediaStore.Files.FileColumns.MEDIA_TYPE, MediaStore.Files.FileColumns.DATE_ADDED,
    )
    val sel = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?)"
    val args = arrayOf(
        MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
        MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
    )
    ctx.contentResolver.query(
        MediaStore.Files.getContentUri("external"), proj, sel, args, "date_added DESC"
    )?.use { c ->
        while (c.moveToNext() && res.size < limit) {
            val video = c.getInt(4) == MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
            val base = if (video) MediaStore.Video.Media.EXTERNAL_CONTENT_URI else MediaStore.Images.Media.EXTERNAL_CONTENT_URI
            res += Item(
                ContentUris.withAppendedId(base, c.getLong(0)),
                c.getString(1) ?: "file",
                c.getString(2) ?: if (video) "video/mp4" else "image/jpeg",
                c.getLong(3), video, c.getLong(5) * 1000,
            )
        }
    }
    return res
}

fun describe(ctx: Context, uri: Uri): Item {
    var name = "file"; var size = -1L
    ctx.contentResolver.query(uri, null, null, null, null)?.use { c ->
        if (c.moveToFirst()) {
            c.getColumnIndex(OpenableColumns.DISPLAY_NAME).takeIf { it >= 0 }?.let { name = c.getString(it) ?: name }
            c.getColumnIndex(OpenableColumns.SIZE).takeIf { it >= 0 }?.let { size = c.getLong(it) }
        }
    }
    val mime = ctx.contentResolver.getType(uri) ?: "application/octet-stream"
    return Item(uri, name, mime, size, mime.startsWith("video/"))
}

private val cache = LruCache<Uri, Bitmap>(120)

fun thumbnail(ctx: Context, item: Item, px: Int = 512): Bitmap? {
    cache.get(item.uri)?.let { return it }
    val bmp = runCatching {
        if (Build.VERSION.SDK_INT >= 29) {
            ctx.contentResolver.loadThumbnail(item.uri, Size(px, px), null)
        } else if (item.isVideo) {
            MediaMetadataRetriever().run {
                try { setDataSource(ctx, item.uri); getFrameAtTime(0) } finally { release() }
            }
        } else {
            val o = BitmapFactory.Options().apply { inSampleSize = 4 }
            ctx.contentResolver.openInputStream(item.uri)?.use { BitmapFactory.decodeStream(it, null, o) }
        }
    }.getOrNull()
    if (bmp != null) cache.put(item.uri, bmp)
    return bmp
}

/** The file's own shape, longest side 512, JPEG q85, base64. */
fun thumbBase64(bmp: Bitmap?): String {
    if (bmp == null) return ""
    val k = 512f / maxOf(bmp.width, bmp.height)
    val out = if (k >= 1f) bmp else Bitmap.createScaledBitmap(bmp, (bmp.width * k).toInt().coerceAtLeast(1), (bmp.height * k).toInt().coerceAtLeast(1), true)
    val bo = ByteArrayOutputStream()
    out.compress(Bitmap.CompressFormat.JPEG, 85, bo)
    return Base64.encodeToString(bo.toByteArray(), Base64.NO_WRAP)
}

@Suppress("unused") private val keep: ContentResolver? = null
