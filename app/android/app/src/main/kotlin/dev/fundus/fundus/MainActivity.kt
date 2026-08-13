package dev.fundus.fundus

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.Settings
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.ByteArrayOutputStream
import java.io.File

class MainActivity : AudioServiceActivity() {
    private var pendingStorageResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            STORAGE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isGranted" -> result.success(hasDirectStorageAccess())
                "request" -> requestDirectStorageAccess(result)
                "storageRoot" -> result.success(
                    Environment.getExternalStorageDirectory().absolutePath,
                )
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            FILE_OPENER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "open" -> openFile(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            PDF_RENDERER_CHANNEL,
        ).setMethodCallHandler { call, result ->
            val path = call.argument<String>("path")
            when (call.method) {
                "pageCount" -> pdfPageCount(path, result)
                "renderPage" -> renderPdfPage(
                    path,
                    call.argument<Int>("page"),
                    call.argument<Int>("maxWidth") ?: 1800,
                    result,
                )
                else -> result.notImplemented()
            }
        }
    }

    private fun pdfPageCount(path: String?, result: MethodChannel.Result) {
        runPdfTask(result) {
            openPdf(path).use { descriptor ->
                PdfRenderer(descriptor).use { renderer -> renderer.pageCount }
            }
        }
    }

    private fun renderPdfPage(
        path: String?,
        pageIndex: Int?,
        requestedWidth: Int,
        result: MethodChannel.Result,
    ) {
        runPdfTask(result) {
            openPdf(path).use { descriptor ->
                PdfRenderer(descriptor).use { renderer ->
                    val index = pageIndex ?: throw IllegalArgumentException("Die Seitennummer fehlt.")
                    if (index < 0 || index >= renderer.pageCount) {
                        throw IllegalArgumentException("Die PDF-Seite existiert nicht.")
                    }
                    renderer.openPage(index).use { page ->
                        val width = requestedWidth.coerceIn(600, 2400)
                        val height = (width.toDouble() * page.height / page.width)
                            .toInt()
                            .coerceIn(1, 3600)
                        val bitmap = Bitmap.createBitmap(
                            width,
                            height,
                            Bitmap.Config.ARGB_8888,
                        )
                        try {
                            bitmap.eraseColor(Color.WHITE)
                            page.render(
                                bitmap,
                                null,
                                null,
                                PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY,
                            )
                            ByteArrayOutputStream().use { output ->
                                bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)
                                output.toByteArray()
                            }
                        } finally {
                            bitmap.recycle()
                        }
                    }
                }
            }
        }
    }

    private fun openPdf(path: String?): ParcelFileDescriptor {
        if (path.isNullOrBlank()) throw IllegalArgumentException("Der Dateipfad fehlt.")
        val file = File(path)
        if (!file.isFile) throw IllegalArgumentException("Die PDF-Datei ist nicht vorhanden.")
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    private fun runPdfTask(result: MethodChannel.Result, task: () -> Any) {
        Thread {
            try {
                val value = task()
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "pdf_error",
                        error.localizedMessage ?: "Die PDF-Datei konnte nicht gelesen werden.",
                        null,
                    )
                }
            }
        }.start()
    }

    private fun openFile(path: String?, result: MethodChannel.Result) {
        if (path.isNullOrBlank()) {
            result.error("invalid_path", "Der Dateipfad fehlt.", null)
            return
        }
        val file = File(path)
        if (!file.isFile) {
            result.error("missing_file", "Die Datei ist nicht mehr vorhanden.", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                this,
                "$packageName.fileprovider",
                file,
            )
            val extension = file.extension.lowercase()
            val mimeType = MimeTypeMap.getSingleton()
                .getMimeTypeFromExtension(extension) ?: "application/octet-stream"
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, mimeType)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_DOCUMENT)
            }
            if (intent.resolveActivity(packageManager) == null) {
                result.success(false)
                return
            }
            startActivity(intent)
            result.success(true)
        } catch (error: Exception) {
            result.error(
                "open_failed",
                error.localizedMessage ?: "Die Datei konnte nicht geöffnet werden.",
                null,
            )
        }
    }

    private fun hasDirectStorageAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            return Environment.isExternalStorageManager()
        }
        val readGranted =
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        val writeGranted =
            Build.VERSION.SDK_INT > Build.VERSION_CODES.Q ||
                checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) ==
                PackageManager.PERMISSION_GRANTED
        return readGranted && writeGranted
    }

    private fun requestDirectStorageAccess(result: MethodChannel.Result) {
        if (hasDirectStorageAccess()) {
            result.success(true)
            return
        }
        if (pendingStorageResult != null) {
            result.error(
                "request_in_progress",
                "Eine Speicherfreigabe wird bereits angefordert.",
                null,
            )
            return
        }
        pendingStorageResult = result
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val appSettings = Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            )
            try {
                startActivityForResult(appSettings, REQUEST_MANAGE_STORAGE)
            } catch (_: Exception) {
                startActivityForResult(
                    Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION),
                    REQUEST_MANAGE_STORAGE,
                )
            }
            return
        }
        requestPermissions(
            arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE,
                Manifest.permission.WRITE_EXTERNAL_STORAGE,
            ),
            REQUEST_LEGACY_STORAGE,
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_MANAGE_STORAGE) finishStorageRequest()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == REQUEST_LEGACY_STORAGE) finishStorageRequest()
    }

    private fun finishStorageRequest() {
        val result = pendingStorageResult ?: return
        pendingStorageResult = null
        result.success(hasDirectStorageAccess())
    }

    companion object {
        private const val STORAGE_CHANNEL = "dev.fundus/android_storage_access"
        private const val FILE_OPENER_CHANNEL = "dev.fundus/file_opener"
        private const val PDF_RENDERER_CHANNEL = "dev.fundus/pdf_renderer"
        private const val REQUEST_MANAGE_STORAGE = 7301
        private const val REQUEST_LEGACY_STORAGE = 7302
    }
}
