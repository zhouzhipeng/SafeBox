package com.zhouzhipeng.safebox

import android.app.Activity
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.provider.DocumentsContract
import android.system.Os
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.ArrayDeque
import java.util.Locale
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private companion object {
        const val CHANNEL = "com.zhouzhipeng.safebox/authorized_directory"
        const val PICK_DIRECTORY_REQUEST = 0x5342
        const val EXPORT_FILE_REQUEST = 0x5343
    }

    private data class PendingExport(
        val result: MethodChannel.Result,
        val source: File,
    )

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var pendingDirectoryResult: MethodChannel.Result? = null
    private var pendingExport: PendingExport? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleAuthorizedDirectoryCall)
    }

    private fun handleAuthorizedDirectoryCall(
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "chooseDirectory" -> chooseDirectory(result)
            "mirrorCiphertext" -> mirrorCiphertext(call, result)
            "releaseDirectory" -> releaseDirectory(call, result)
            "protectTemporaryPlaintext" -> protectTemporaryPlaintext(call, result)
            "exportFile" -> exportFile(call, result)
            else -> result.notImplemented()
        }
    }

    private fun chooseDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null || pendingExport != null) {
            result.error("busy", "A directory picker is already active", null)
            return
        }
        pendingDirectoryResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        try {
            startActivityForResult(intent, PICK_DIRECTORY_REQUEST)
        } catch (error: Exception) {
            pendingDirectoryResult = null
            result.error("picker", "Unable to open the system directory picker", null)
        }
    }

    @Deprecated("Required by the FlutterActivity activity-result bridge")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == EXPORT_FILE_REQUEST) {
            val pending = pendingExport ?: return
            pendingExport = null
            val destination = data?.data
            if (resultCode != Activity.RESULT_OK || destination == null) {
                pending.result.success(false)
                return
            }
            ioExecutor.execute {
                try {
                    val output = contentResolver.openOutputStream(destination, "w")
                        ?: error("Unable to open the selected export destination")
                    FileInputStream(pending.source).use { input ->
                        output.use { sink -> input.copyTo(sink, 1024 * 1024) }
                    }
                    runOnUiThread { pending.result.success(true) }
                } catch (error: Exception) {
                    runOnUiThread {
                        pending.result.error(
                            "export",
                            error.message ?: "Unable to export the selected file",
                            null,
                        )
                    }
                }
            }
            return
        }
        if (requestCode != PICK_DIRECTORY_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val result = pendingDirectoryResult ?: return
        pendingDirectoryResult = null
        if (resultCode != Activity.RESULT_OK || data?.data == null) {
            result.success(null)
            return
        }
        val uri = data.data!!
        try {
            val granted = data.flags and
                (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            contentResolver.takePersistableUriPermission(uri, granted)
            val displayName = queryDisplayName(uri) ?: "Android 系统目录"
            result.success(
                mapOf(
                    "reference" to uri.toString(),
                    "platform" to "android",
                    "display_name" to displayName,
                ),
            )
        } catch (error: Exception) {
            result.error("permission", "Unable to persist directory access", null)
        }
    }

    private fun exportFile(call: MethodCall, result: MethodChannel.Result) {
        if (pendingDirectoryResult != null || pendingExport != null) {
            result.error("busy", "A system file picker is already active", null)
            return
        }
        val sourcePath = call.argument<String>("source_path")
        val suggestedName = call.argument<String>("suggested_name")
        val mimeType = call.argument<String>("mime_type")
        if (sourcePath == null || suggestedName == null || mimeType == null) {
            result.error("arguments", "Missing export arguments", null)
            return
        }
        try {
            validateSegment(suggestedName)
            require(mimeType.isNotBlank() && mimeType.length <= 255 && !mimeType.contains('\u0000'))
            val source = File(sourcePath).canonicalFile
            val privateRoot = File(applicationInfo.dataDir).canonicalFile
            check(source.path.startsWith(privateRoot.path + File.separator)) {
                "Export source is outside the application container"
            }
            check(source.isFile) { "Export source is not a regular file" }
            pendingExport = PendingExport(result, source)
            val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = mimeType
                putExtra(Intent.EXTRA_TITLE, suggestedName)
                addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or
                        Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                )
            }
            startActivityForResult(intent, EXPORT_FILE_REQUEST)
        } catch (error: Exception) {
            pendingExport = null
            result.error("export", error.message ?: "Unable to open the export picker", null)
        }
    }

    private fun mirrorCiphertext(call: MethodCall, result: MethodChannel.Result) {
        val reference = call.argument<String>("reference")
        val destinationRoot = call.argument<String>("destination_root")
        val maximumDepth = call.argument<Number>("maximum_depth")?.toInt()
        val maximumFiles = call.argument<Number>("maximum_files")?.toInt()
        val maximumFileBytes = call.argument<Number>("maximum_file_bytes")?.toLong()
        if (reference == null ||
            destinationRoot == null ||
            maximumDepth == null ||
            maximumFiles == null ||
            maximumFileBytes == null
        ) {
            result.error("arguments", "Missing mirror arguments", null)
            return
        }
        ioExecutor.execute {
            try {
                val value = mirrorTree(
                    Uri.parse(reference),
                    File(destinationRoot),
                    maximumDepth,
                    maximumFiles,
                    maximumFileBytes,
                )
                runOnUiThread { result.success(value) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error(
                        "mirror",
                        error.message ?: "Unable to mirror the authorized directory",
                        null,
                    )
                }
            }
        }
    }

    private fun mirrorTree(
        treeUri: Uri,
        destinationRoot: File,
        maximumDepth: Int,
        maximumFiles: Int,
        maximumFileBytes: Long,
    ): Map<String, Any> {
        require(DocumentsContract.isTreeUri(treeUri)) { "Reference is not a tree URI" }
        require(maximumDepth in 1..64 && maximumFiles in 1..200_000)
        require(maximumFileBytes > 0)
        val hasPermission = contentResolver.persistedUriPermissions.any {
            it.uri == treeUri && it.isReadPermission
        }
        check(hasPermission) { "Persisted directory permission was revoked" }

        val root = destinationRoot.canonicalFile
        val filesRoot = filesDir.canonicalFile
        check(root.path.startsWith(filesRoot.path + File.separator)) {
            "Mirror destination is outside the application support directory"
        }
        root.mkdirs()
        check(root.isDirectory) { "Unable to create mirror destination" }

        data class PendingDocument(
            val documentId: String,
            val relativeSegments: List<String>,
            val depth: Int,
        )

        val rootId = DocumentsContract.getTreeDocumentId(treeUri)
        val pending = ArrayDeque<PendingDocument>()
        pending.add(PendingDocument(rootId, emptyList(), 0))
        val visited = mutableSetOf<String>()
        var fileCount = 0
        var totalBytes = 0L
        var catalogPresent = false

        while (pending.isNotEmpty()) {
            val current = pending.removeFirst()
            check(current.depth <= maximumDepth) { "Directory nesting is too deep" }
            if (!visited.add(current.documentId)) continue
            val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri,
                current.documentId,
            )
            contentResolver.query(
                childrenUri,
                arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                ),
                null,
                null,
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) {
                    val documentId = cursor.requiredString(
                        DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    )
                    val name = cursor.requiredString(
                        DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    )
                    validateSegment(name)
                    val mimeType = cursor.requiredString(
                        DocumentsContract.Document.COLUMN_MIME_TYPE,
                    )
                    val relative = current.relativeSegments + name
                    if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                        if (name != ".sbox-staging" && name != ".sbox-sync") {
                            pending.add(
                                PendingDocument(documentId, relative, current.depth + 1),
                            )
                        }
                        continue
                    }
                    val isCatalog = relative.size == 1 && name == "catalog.sbox"
                    if (!name.lowercase(Locale.ROOT).endsWith(".sbox")) continue
                    fileCount++
                    check(fileCount <= maximumFiles) { "Too many SBOX files" }
                    val declaredSize = cursor.optionalLong(
                        DocumentsContract.Document.COLUMN_SIZE,
                    )
                    if (declaredSize != null) {
                        check(declaredSize in 1..maximumFileBytes) {
                            "SBOX file exceeds the configured limit"
                        }
                    }
                    val documentUri = DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        documentId,
                    )
                    val copied = copyDocument(
                        documentUri,
                        root,
                        relative,
                        maximumFileBytes,
                        isCatalog,
                    )
                    totalBytes = Math.addExact(totalBytes, copied)
                    if (isCatalog) catalogPresent = true
                }
            } ?: error("Unable to enumerate the authorized directory")
        }
        return mapOf(
            "file_count" to fileCount,
            "total_bytes" to totalBytes,
            "catalog_present" to catalogPresent,
        )
    }

    private fun copyDocument(
        documentUri: Uri,
        destinationRoot: File,
        relativeSegments: List<String>,
        maximumFileBytes: Long,
        replaceCatalog: Boolean,
    ): Long {
        var target = destinationRoot
        for (segment in relativeSegments) target = File(target, segment)
        val canonicalTarget = target.canonicalFile
        check(canonicalTarget.path.startsWith(destinationRoot.path + File.separator)) {
            "Document path escaped the mirror root"
        }
        canonicalTarget.parentFile?.mkdirs()
        val temporary = File(
            canonicalTarget.parentFile,
            ".${canonicalTarget.name}.${UUID.randomUUID()}.part",
        )
        var copied = 0L
        try {
            val input = contentResolver.openInputStream(documentUri)
                ?: error("Unable to open a selected SBOX document")
            input.use { source ->
                FileOutputStream(temporary).use { output ->
                    val buffer = ByteArray(1024 * 1024)
                    while (true) {
                        val count = source.read(buffer)
                        if (count < 0) break
                        copied = Math.addExact(copied, count.toLong())
                        check(copied <= maximumFileBytes) {
                            "SBOX file exceeds the configured limit"
                        }
                        output.write(buffer, 0, count)
                    }
                    output.fd.sync()
                }
            }
            check(copied > 0) { "Empty SBOX file is invalid" }
            if (canonicalTarget.exists() && !replaceCatalog) {
                check(sha256(temporary).contentEquals(sha256(canonicalTarget))) {
                    "An immutable mirrored SBOX path changed content"
                }
                temporary.delete()
            } else {
                Os.rename(temporary.absolutePath, canonicalTarget.absolutePath)
            }
            return copied
        } finally {
            if (temporary.exists()) temporary.delete()
        }
    }

    private fun releaseDirectory(call: MethodCall, result: MethodChannel.Result) {
        val reference = call.argument<String>("reference")
        if (reference == null) {
            result.error("arguments", "Missing directory reference", null)
            return
        }
        try {
            val uri = Uri.parse(reference)
            val permission = contentResolver.persistedUriPermissions.firstOrNull {
                it.uri == uri
            }
            if (permission != null) {
                var flags = 0
                if (permission.isReadPermission) {
                    flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
                }
                if (permission.isWritePermission) {
                    flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                }
                contentResolver.releasePersistableUriPermission(uri, flags)
            }
            result.success(null)
        } catch (error: Exception) {
            result.error("permission", "Unable to release directory access", null)
        }
    }

    private fun protectTemporaryPlaintext(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path == null) {
            result.error("arguments", "Missing temporary plaintext path", null)
            return
        }
        ioExecutor.execute {
            try {
                val root = File(path).canonicalFile
                val cache = cacheDir.canonicalFile
                check(root.path.startsWith(cache.path + File.separator)) {
                    "Temporary plaintext root is outside the application cache"
                }
                root.mkdirs()
                check(root.isDirectory) { "Unable to create temporary plaintext root" }
                Os.chmod(root.absolutePath, 0x1c0) // 0700
                File(root, ".nomedia").apply {
                    if (!exists()) createNewFile()
                }
                runOnUiThread { result.success(null) }
            } catch (error: Exception) {
                runOnUiThread {
                    result.error("protection", "Unable to protect temporary plaintext", null)
                }
            }
        }
    }

    private fun queryDisplayName(uri: Uri): String? = contentResolver.query(
        DocumentsContract.buildDocumentUriUsingTree(
            uri,
            DocumentsContract.getTreeDocumentId(uri),
        ),
        arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
        null,
        null,
        null,
    )?.use { cursor ->
        if (cursor.moveToFirst()) {
            cursor.getString(0)?.takeIf { it.isNotBlank() }
        } else {
            null
        }
    }

    private fun validateSegment(value: String) {
        val encodedLength = value.toByteArray(Charsets.UTF_8).size
        require(
            value.isNotEmpty() &&
                value != "." &&
                value != ".." &&
                encodedLength <= 255 &&
                !value.contains('/') &&
                !value.contains('\\') &&
                value.none { it.code == 0 || it.code < 0x20 || it.code == 0x7f },
        ) { "Document provider returned an unsafe name" }
    }

    private fun Cursor.requiredString(column: String): String {
        val index = getColumnIndex(column)
        check(index >= 0 && !isNull(index)) { "Document provider omitted $column" }
        return getString(index)
    }

    private fun Cursor.optionalLong(column: String): Long? {
        val index = getColumnIndex(column)
        return if (index < 0 || isNull(index)) null else getLong(index)
    }

    private fun sha256(file: File): ByteArray {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(1024 * 1024)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest()
    }

    override fun onDestroy() {
        pendingDirectoryResult?.error("cancelled", "Activity was destroyed", null)
        pendingDirectoryResult = null
        pendingExport?.result?.error("cancelled", "Activity was destroyed", null)
        pendingExport = null
        ioExecutor.shutdownNow()
        super.onDestroy()
    }
}
