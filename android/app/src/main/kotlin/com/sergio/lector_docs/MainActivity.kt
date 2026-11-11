package com.sergio.lector_docs

import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.speech.tts.TextToSpeech
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

class MainActivity : FlutterActivity() {

    companion object {
        private const val CHANNEL = "lector/system"
        private const val HANDLED = "lector_handled"
        private var channel: MethodChannel? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /** Lets the reading notification talk to the Dart side. */
        fun sendToDart(method: String) {
            mainHandler.post { channel?.invokeMethod(method, null) }
        }
    }

    private var openedPath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "takeOpenedFile" -> {
                    result.success(openedPath)
                    openedPath = null
                }
                "receivedDir" -> result.success(receivedDir().absolutePath)
                "keepScreenOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                "openTtsSettings" -> result.success(
                    startSafely(Intent("com.android.settings.TTS_SETTINGS"))
                )
                "installTtsData" -> {
                    val intent = Intent(TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA)
                    val engine = call.arguments as? String
                    if (!engine.isNullOrEmpty()) intent.setPackage(engine)
                    result.success(startSafely(intent))
                }
                "openUrl" -> {
                    val url = call.arguments as? String ?: ""
                    result.success(startSafely(Intent(Intent.ACTION_VIEW, Uri.parse(url))))
                }
                "openStore" -> {
                    val pkg = call.arguments as? String ?: ""
                    val ok = startSafely(
                        Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=$pkg"))
                    ) || startSafely(
                        Intent(
                            Intent.ACTION_VIEW,
                            Uri.parse("https://play.google.com/store/apps/details?id=$pkg")
                        )
                    )
                    result.success(ok)
                }
                "startReading" -> {
                    val title = call.argument<String>("title") ?: "Lector"
                    ReadAloudService.start(this, title)
                    result.success(null)
                }
                "updateReading" -> {
                    val title = call.argument<String>("title") ?: "Lector"
                    val playing = call.argument<Boolean>("playing") ?: true
                    ReadAloudService.update(this, title, playing)
                    result.success(null)
                }
                "stopReading" -> {
                    ReadAloudService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleIntent(intent)
    }

    override fun onDestroy() {
        if (isFinishing) {
            ReadAloudService.stop(this)
            channel = null
        }
        super.onDestroy()
    }

    private fun startSafely(intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            false
        }
    }

    // ---------- Archivos que llegan desde otras apps ----------

    private fun receivedDir(): File = File(filesDir, "Recibidos").apply { mkdirs() }

    private fun handleIntent(intent: Intent?) {
        if (intent == null || intent.getBooleanExtra(HANDLED, false)) return
        val action = intent.action
        if (action != Intent.ACTION_VIEW && action != Intent.ACTION_SEND) return
        intent.putExtra(HANDLED, true)

        val uri: Uri? = if (action == Intent.ACTION_VIEW) intent.data else streamExtra(intent)
        val sharedText =
            if (action == Intent.ACTION_SEND && uri == null) intent.getStringExtra(Intent.EXTRA_TEXT) else null
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        val mime = intent.type
        if (uri == null && sharedText.isNullOrBlank()) return

        Thread {
            val path = try {
                if (uri != null) copyToReceived(uri, mime) else saveSharedText(sharedText!!, subject)
            } catch (e: Exception) {
                null
            }
            if (path != null) {
                mainHandler.post {
                    openedPath = path
                    channel?.invokeMethod("fileOpened", null)
                }
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun streamExtra(intent: Intent): Uri? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }

    private fun copyToReceived(uri: Uri, mime: String?): String? {
        var name: String? = null
        var size = -1L
        try {
            contentResolver.query(
                uri,
                arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE),
                null,
                null,
                null
            )?.use { c ->
                if (c.moveToFirst()) {
                    val ni = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                    val si = c.getColumnIndex(OpenableColumns.SIZE)
                    if (ni >= 0 && !c.isNull(ni)) name = c.getString(ni)
                    if (si >= 0 && !c.isNull(si)) size = c.getLong(si)
                }
            }
        } catch (e: Exception) {
            // Algunas apps no responden a la consulta: usamos el nombre de la ruta.
        }
        var fileName = (name ?: uri.lastPathSegment?.substringAfterLast('/') ?: "documento")
            .replace(Regex("[\\\\/:*?\"<>|]"), "_")
            .trim()
        if (fileName.isEmpty()) fileName = "documento"
        if (!fileName.contains('.')) {
            fileName += extensionFor(mime ?: contentResolver.getType(uri))
        }

        val dir = receivedDir()
        val existing = File(dir, fileName)
        // Si ya lo habíamos recibido igual, se reutiliza (y se conserva el progreso).
        if (existing.exists() && size > 0 && existing.length() == size) {
            return existing.absolutePath
        }
        val target = uniqueFile(dir, fileName)
        val input = contentResolver.openInputStream(uri) ?: return null
        input.use { inp ->
            target.outputStream().use { out -> inp.copyTo(out) }
        }
        return target.absolutePath
    }

    private fun saveSharedText(text: String, subject: String?): String {
        val stamp = SimpleDateFormat("yyyy-MM-dd HH.mm", Locale.US).format(Date())
        val base = (subject?.take(60) ?: "Texto compartido")
            .replace(Regex("[\\\\/:*?\"<>|\\n\\r]"), "_")
            .trim()
            .ifEmpty { "Texto compartido" }
        val target = uniqueFile(receivedDir(), "$base $stamp.txt")
        target.writeText(text)
        return target.absolutePath
    }

    private fun uniqueFile(dir: File, name: String): File {
        var file = File(dir, name)
        if (!file.exists()) return file
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var n = 2
        while (file.exists()) {
            file = File(dir, "$stem ($n)$ext")
            n++
        }
        return file
    }

    private fun extensionFor(mime: String?): String = when (mime) {
        "application/pdf" -> ".pdf"
        "application/epub+zip" -> ".epub"
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" -> ".docx"
        "text/markdown" -> ".md"
        "text/plain" -> ".txt"
        else -> ""
    }
}
