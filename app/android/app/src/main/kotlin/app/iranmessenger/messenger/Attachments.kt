package app.iranmessenger.messenger

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import androidx.core.content.FileProvider
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Files the user sends, GIFs imported from a whole folder, and opening a
 * received file in another app. Everything goes through Android's own
 * pickers, so the app needs no storage permission. Picked files are copied
 * into this app's cache because the permission to read them ends with the
 * picker; copying runs off the main thread.
 */
class Attachments(private val activity: Activity) {
    private var result: MethodChannel.Result? = null
    private var maxBytes = 0L
    private val main = Handler(Looper.getMainLooper())

    /** Returns false if [call] is not one of ours. */
    fun handle(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "pick" -> {
                if (!claim(result)) return true
                maxBytes = (call.argument<Number>("max") ?: 0).toLong()
                activity.startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    },
                    REQUEST_PICK
                )
            }
            "gifFolder" -> {
                if (!claim(result)) return true
                maxBytes = (call.argument<Number>("max") ?: 0).toLong()
                activity.startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE), REQUEST_TREE)
            }
            "view" -> result.success(
                view(call.argument<String>("path")!!, call.argument<String>("name")!!, call.argument<String>("mime")!!)
            )
            else -> return false
        }
        return true
    }

    private fun claim(r: MethodChannel.Result): Boolean {
        if (result != null) {
            r.error("busy", "another file request is open", null)
            return false
        }
        result = r
        return true
    }

    /** Returns false if [requestCode] is not one of ours. */
    fun onResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_PICK && requestCode != REQUEST_TREE) return false
        val r = result ?: return true
        result = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        if (uri == null) {
            r.success(null)
            return true
        }
        Thread {
            val answer: Any? = try {
                if (requestCode == REQUEST_PICK) pickOne(uri) else gifFolder(uri)
            } catch (e: Exception) {
                mapOf("error" to "failed")
            }
            main.post { r.success(answer) }
        }.start()
        return true
    }

    private fun pickOne(uri: Uri): Map<String, Any?> {
        var name = "file"
        var size = -1L
        activity.contentResolver.query(uri, null, null, null, null)?.use { c ->
            if (c.moveToFirst()) {
                val n = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val s = c.getColumnIndex(OpenableColumns.SIZE)
                if (n >= 0 && !c.isNull(n)) name = c.getString(n)
                if (s >= 0 && !c.isNull(s)) size = c.getLong(s)
            }
        }
        if (size > maxBytes) return mapOf("error" to "too_large", "size" to size)
        val mime = activity.contentResolver.getType(uri) ?: "application/octet-stream"
        val out = copy(uri, name) ?: return mapOf("error" to "too_large")
        return mapOf("path" to out.absolutePath, "name" to name, "mime" to mime, "size" to out.length())
    }

    /** Copies every GIF, WebP and MP4 in the chosen folder (not subfolders). */
    private fun gifFolder(tree: Uri): Map<String, Any?> {
        val children = DocumentsContract.buildChildDocumentsUriUsingTree(
            tree, DocumentsContract.getTreeDocumentId(tree)
        )
        val files = mutableListOf<Map<String, Any?>>()
        var tooLarge = 0
        var other = 0
        activity.contentResolver.query(
            children,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_SIZE
            ),
            null, null, null
        )?.use { c ->
            while (c.moveToNext()) {
                val id = c.getString(0)
                val name = c.getString(1) ?: continue
                val mime = c.getString(2) ?: ""
                val size = if (c.isNull(3)) 0L else c.getLong(3)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) continue
                val kind = gifMime(name, mime)
                if (kind == null) {
                    other++
                    continue
                }
                if (size > maxBytes || files.size >= MAX_FOLDER_ITEMS) {
                    tooLarge++
                    continue
                }
                val doc = DocumentsContract.buildDocumentUriUsingTree(tree, id)
                val out = copy(doc, name)
                if (out == null) tooLarge++ else files.add(mapOf("path" to out.absolutePath, "name" to name, "mime" to kind))
            }
        }
        return mapOf("files" to files, "tooLarge" to tooLarge, "other" to other)
    }

    private fun gifMime(name: String, mime: String): String? {
        val ext = name.substringAfterLast('.', "").lowercase()
        return when {
            mime == "image/gif" || ext == "gif" -> "image/gif"
            mime == "image/webp" || ext == "webp" -> "image/webp"
            mime == "video/mp4" || ext == "mp4" -> "video/mp4"
            else -> null
        }
    }

    /** Copies [uri] into the cache, giving up past [maxBytes]. */
    private fun copy(uri: Uri, name: String): File? {
        val dir = File(activity.cacheDir, "picked").apply { mkdirs() }
        val safe = name.replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").take(80)
        val out = File(dir, "${System.nanoTime()}_$safe")
        val ok = activity.contentResolver.openInputStream(uri)?.use { input ->
            out.outputStream().use { output ->
                val buffer = ByteArray(64 * 1024)
                var total = 0L
                while (true) {
                    val n = input.read(buffer)
                    if (n < 0) break
                    total += n
                    if (total > maxBytes) return@use false
                    output.write(buffer, 0, n)
                }
                true
            }
        } ?: false
        if (!ok) {
            out.delete()
            return null
        }
        return out
    }

    /** Opens a received file in whichever app handles its type. */
    private fun view(path: String, name: String, mime: String): Boolean {
        val dir = File(activity.cacheDir, "open").apply {
            mkdirs()
            listFiles()?.forEach { it.delete() }
        }
        val safe = name.replace(Regex("[^\\p{L}\\p{N}._ -]"), "_").take(80).ifEmpty { "file" }
        val copy = File(dir, safe)
        File(path).copyTo(copy, overwrite = true)
        val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.files", copy)
        return try {
            activity.startActivity(
                Intent.createChooser(
                    Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
                        .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION),
                    null
                ).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            )
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    companion object {
        private const val REQUEST_PICK = 7303
        private const val REQUEST_TREE = 7304
        private const val MAX_FOLDER_ITEMS = 200
    }
}
