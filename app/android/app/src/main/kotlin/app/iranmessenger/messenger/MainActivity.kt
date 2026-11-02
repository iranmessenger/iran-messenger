package app.iranmessenger.messenger

import android.app.Activity
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Besides hosting Flutter, receives items shared from other apps
 * (Android's share sheet) and hands them to the Dart side.
 *
 * A shared file is copied into this app's private cache first, because the
 * permission to read the other app's content ends with this activity.
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null

    // Backup files: the user picks where to save or what to open.
    private var fileResult: MethodChannel.Result? = null
    private var saveSource: String? = null

    // Sending files, importing a folder of GIFs, opening received files.
    private val attachments by lazy { Attachments(this) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "irm/share").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "take") {
                    result.success(pending)
                    pending = null
                } else {
                    result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "irm/files")
            .setMethodCallHandler { call, result ->
                if (attachments.handle(call, result)) return@setMethodCallHandler
                if (fileResult != null) {
                    result.error("busy", "another file request is open", null)
                    return@setMethodCallHandler
                }
                when (call.method) {
                    "save" -> {
                        fileResult = result
                        saveSource = call.argument<String>("path")
                        startActivityForResult(
                            Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "application/octet-stream"
                                putExtra(Intent.EXTRA_TITLE, call.argument<String>("name"))
                            },
                            REQUEST_SAVE
                        )
                    }
                    "open" -> {
                        fileResult = result
                        startActivityForResult(
                            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                                addCategory(Intent.CATEGORY_OPENABLE)
                                type = "*/*"
                            },
                            REQUEST_OPEN
                        )
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "irm/device")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "maker" -> result.success(Build.MANUFACTURER.lowercase())
                    "autostart" -> result.success(openAutoStart())
                    "bootId" -> result.success(bootId())
                    "buzz" -> {
                        buzz()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        capture(intent)
    }

    /** A BUZZ: three strong pulses, like the old Yahoo! Messenger one. */
    private fun buzz() {
        val pattern = longArrayOf(0, 160, 90, 160, 90, 260)
        val vibrator: Vibrator? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager)?.defaultVibrator
        } else {
            @Suppress("DEPRECATION")
            getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
        }
        if (vibrator == null || !vibrator.hasVibrator()) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            vibrator.vibrate(VibrationEffect.createWaveform(pattern, -1))
        } else {
            @Suppress("DEPRECATION")
            vibrator.vibrate(pattern, -1)
        }
    }

    /**
     * Changes once per power-on of the phone, so the intro animation plays
     * once after each start (or restart) and not on every app launch.
     */
    private fun bootId(): String {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                return "c" + Settings.Global.getInt(contentResolver, Settings.Global.BOOT_COUNT)
            } catch (e: Exception) {
                // Not exposed on this build; fall back to the boot time.
            }
        }
        val bootedAt = System.currentTimeMillis() - android.os.SystemClock.elapsedRealtime()
        return "t" + (bootedAt / 600000L)
    }

    /**
     * Several makers stop background apps unless the user allows them in
     * their own "auto-start" list. Its location differs per maker and per
     * version, so the known pages are tried in turn; this app's settings
     * page is the fallback.
     */
    private fun openAutoStart(): Boolean {
        for ((pkg, cls) in AUTO_START) {
            try {
                startActivity(
                    Intent().setComponent(ComponentName(pkg, cls))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                )
                return true
            } catch (e: Exception) {
                // Not this maker or not this version; try the next one.
            }
        }
        return try {
            startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            true
        } catch (e: Exception) {
            false
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (attachments.onResult(requestCode, resultCode, data)) return
        if (requestCode != REQUEST_SAVE && requestCode != REQUEST_OPEN) return
        val result = fileResult ?: return
        fileResult = null
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        try {
            if (requestCode == REQUEST_SAVE) {
                val source = saveSource
                saveSource = null
                if (uri == null || source == null) {
                    result.success(false)
                    return
                }
                contentResolver.openOutputStream(uri)?.use { out ->
                    File(source).inputStream().use { it.copyTo(out) }
                }
                result.success(true)
            } else {
                if (uri == null) {
                    result.success(null)
                    return
                }
                val out = File(cacheDir, "picked_${System.currentTimeMillis()}.irmbk")
                contentResolver.openInputStream(uri)?.use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
                result.success(out.absolutePath)
            }
        } catch (e: Exception) {
            result.success(if (requestCode == REQUEST_SAVE) false else null)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        capture(intent)
        pending?.let {
            channel?.invokeMethod("shared", it)
            pending = null
        }
    }

    private fun capture(intent: Intent?) {
        if (intent?.action != Intent.ACTION_SEND) return
        val type = intent.type ?: return
        if (type.startsWith("text/")) {
            val text = intent.getStringExtra(Intent.EXTRA_TEXT) ?: return
            pending = mapOf("text" to text.take(4000))
            return
        }
        @Suppress("DEPRECATION")
        val uri = intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM) ?: return
        val mime = contentResolver.getType(uri) ?: type
        val ext = MimeTypeMap.getSingleton().getExtensionFromMimeType(mime) ?: "bin"
        val out = File(cacheDir, "shared_${System.currentTimeMillis()}.$ext")
        try {
            val copied = contentResolver.openInputStream(uri)?.use { input ->
                out.outputStream().use { output ->
                    val buffer = ByteArray(64 * 1024)
                    var total = 0L
                    while (true) {
                        val n = input.read(buffer)
                        if (n < 0) break
                        total += n
                        // Larger than anything the messenger can send.
                        if (total > MAX_BYTES) return@use false
                        output.write(buffer, 0, n)
                    }
                    true
                }
            } ?: false
            if (!copied) {
                out.delete()
                pending = mapOf("error" to "too_large")
                return
            }
            pending = mapOf("path" to out.absolutePath, "mime" to mime)
        } catch (e: Exception) {
            out.delete()
        }
        // Do not handle the same share again after a configuration change.
        intent.action = Intent.ACTION_MAIN
    }

    companion object {
        private const val MAX_BYTES = 26L * 1024 * 1024
        private const val REQUEST_SAVE = 7301
        private const val REQUEST_OPEN = 7302
        private val AUTO_START = listOf(
            "com.miui.securitycenter" to "com.miui.permcenter.autostart.AutoStartManagementActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.huawei.systemmanager" to "com.huawei.systemmanager.optimize.process.ProtectActivity",
            "com.hihonor.systemmanager" to "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.permission.startup.StartupAppListActivity",
            "com.coloros.safecenter" to "com.coloros.safecenter.startupapp.StartupAppListActivity",
            "com.oppo.safe" to "com.oppo.safe.permission.startup.StartupAppListActivity",
            "com.vivo.permissionmanager" to "com.vivo.permissionmanager.activity.BgStartUpManagerActivity",
            "com.iqoo.secure" to "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity",
            "com.oneplus.security" to "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity",
            "com.samsung.android.lool" to "com.samsung.android.sm.battery.ui.BatteryActivity",
        )
    }
}
