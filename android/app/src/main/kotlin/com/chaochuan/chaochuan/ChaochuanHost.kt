package com.chaochuan.chaochuan

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import com.lx.kit.bridge.LXCallback
import com.lx.kit.bridge.LXExport
import com.lx.kit.bridge.LXMethod
import com.lx.kit.bridge.LXNativeContext
import com.lx.kit.core.LXActivityResults
import org.json.JSONObject
import java.io.File
import java.lang.ref.WeakReference
import java.net.Inet4Address
import java.net.NetworkInterface
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * 宿主原生能力：lx.native("chaochuanHost")，四个平台同名同参（契约见 docs/native_host.md）。
 *   pickFiles({ folder, multiple }, cb)  SAF 选文件 / 文件夹，内容复制到 cacheDir/picked/<唯一目录>/ 后返回 { paths }
 *   openPath({ path, reveal }, cb)       ACTION_VIEW + FileProvider，失败退回分享面板；目录返回 { ok = false }
 *   takeIncomingFiles()                  取出并清空「分享到超传 / 用超传打开」收到的文件（MainActivity 复制到 cacheDir/incoming/）
 *   事件 incomingFiles { count }          有新的待取文件
 *   interfaces()                         本机 IPv4 { list = { { name, ip } } }，Wi‑Fi 优先，跳过 VPN / 蜂窝 / 回环
 *   桌面专用方法返回 { supported = false }
 */
@LXExport("chaochuanHost")
class ChaochuanHost(private val ctx: LXNativeContext) {

    init {
        current = WeakReference(this)
    }

    companion object {
        private const val TAG = "chaochuan"
        private val io = Executors.newCachedThreadPool()

        /** 进程级待取队列：Activity 收到的文件先排在这里，等 Lua 来取（启动时 Lua 还没起来也不丢） */
        private val incoming = ArrayList<String>()

        @Volatile
        private var current: WeakReference<ChaochuanHost>? = null

        private val SUPPORTED_FALSE = mapOf("supported" to false)

        // ------------------------------------------------------------ 收到的文件（MainActivity 调用）

        /** 是不是「分享 / 打开方式」送来的文件或文字（chaochuan:// 深链接不算） */
        fun isIncomingIntent(intent: Intent?): Boolean {
            intent ?: return false
            return when (intent.action) {
                Intent.ACTION_SEND, Intent.ACTION_SEND_MULTIPLE -> true
                Intent.ACTION_VIEW -> intent.data?.scheme?.lowercase().let { it == "content" || it == "file" }
                else -> false
            }
        }

        /** 把 intent 里的 URI（EXTRA_STREAM / ClipData / data）或纯文字复制进 cacheDir/incoming/ 后排队，并通知 Lua */
        fun handleIncomingIntent(context: Context, intent: Intent) {
            val app = context.applicationContext
            val uris = LinkedHashSet<Uri>()
            when (intent.action) {
                Intent.ACTION_SEND -> streamExtra(intent)?.let { uris.add(it) }
                Intent.ACTION_SEND_MULTIPLE -> streamListExtra(intent)?.let { uris.addAll(it) }
            }
            intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let { uris.add(it) } }
            if (intent.action == Intent.ACTION_VIEW) intent.data?.let { uris.add(it) }
            val text = if (uris.isEmpty() && intent.action == Intent.ACTION_SEND)
                (intent.getCharSequenceExtra(Intent.EXTRA_TEXT) ?: intent.clipData?.takeIf { it.itemCount > 0 }
                    ?.getItemAt(0)?.text)?.toString()
            else null
            if (uris.isEmpty() && text.isNullOrEmpty()) return
            io.execute {
                val dir = uniqueDir(File(app.cacheDir, "incoming"))
                val paths = ArrayList<String>()
                for (u in uris) {
                    try {
                        copyUri(app, u, dir)?.let { paths.add(it.absolutePath) }
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "复制收到的文件失败：$u", e)
                    }
                }
                if (!text.isNullOrEmpty()) {
                    try {
                        val stamp = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US).format(Date())
                        val f = uniqueFile(dir, "shared_text_$stamp.txt")
                        f.writeText(text, Charsets.UTF_8)
                        paths.add(f.absolutePath)
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "保存分享的文字失败", e)
                    }
                }
                if (paths.isEmpty()) return@execute
                synchronized(incoming) { incoming.addAll(paths) }
                current?.get()?.ctx?.emit("incomingFiles", mapOf("count" to paths.size))
            }
        }

        @Suppress("DEPRECATION")
        private fun streamExtra(intent: Intent): Uri? =
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableExtra(Intent.EXTRA_STREAM) as? Uri

        @Suppress("DEPRECATION")
        private fun streamListExtra(intent: Intent): List<Uri>? =
            if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)

        // ------------------------------------------------------------ 复制工具

        /** base/<时间戳-序号>/：每批文件一个目录，保留原文件名 */
        private fun uniqueDir(base: File): File {
            var i = 0
            while (true) {
                val d = File(base, "${System.currentTimeMillis()}-$i")
                if (!d.exists() && d.mkdirs()) return d
                i++
            }
        }

        private fun safeName(name: String?, fallback: String): String {
            val n = name?.replace('/', '_')?.replace('\u0000', '_')?.trim().orEmpty()
            return if (n.isEmpty() || n == "." || n == "..") fallback else n
        }

        /** 重名加序号：a.txt → a (1).txt */
        private fun uniqueFile(dir: File, name: String): File {
            var f = File(dir, name)
            if (!f.exists()) return f
            val dot = name.lastIndexOf('.').takeIf { it > 0 } ?: name.length
            val stem = name.substring(0, dot)
            val ext = name.substring(dot)
            var i = 1
            while (f.exists()) f = File(dir, "$stem ($i)$ext").also { i++ }
            return f
        }

        private fun displayName(context: Context, uri: Uri): String? {
            if (uri.scheme == "file") return uri.lastPathSegment
            return try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null
                }
            } catch (_: Exception) {
                null
            } ?: uri.lastPathSegment?.substringAfterLast('/')
        }

        /** 把一个 URI 的内容复制到 dir 下（保留显示名，重名加序号） */
        private fun copyUri(context: Context, uri: Uri, dir: File, name: String? = null): File? {
            val target = uniqueFile(dir, safeName(name ?: displayName(context, uri), "file"))
            val input = context.contentResolver.openInputStream(uri) ?: return null
            input.use { inp -> target.outputStream().use { inp.copyTo(it) } }
            return target
        }

        /** SAF 文件夹：按原目录结构复制到 dest（DocumentsContract 遍历） */
        private fun copyTree(context: Context, treeUri: Uri, docId: String, dest: File) {
            dest.mkdirs()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, docId)
            val cols = arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
            )
            val entries = ArrayList<Triple<String, String, String?>>()
            context.contentResolver.query(children, cols, null, null, null)?.use { c ->
                while (c.moveToNext()) entries.add(Triple(c.getString(0), c.getString(1) ?: c.getString(0), c.getString(2)))
            }
            for ((id, name, mime) in entries) {
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    copyTree(context, treeUri, id, uniqueFile(dest, safeName(name, "folder")))
                } else {
                    try {
                        copyUri(context, DocumentsContract.buildDocumentUriUsingTree(treeUri, id), dest, name)
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "复制 $name 失败", e)
                    }
                }
            }
        }
    }

    private val context: Context get() = ctx.activity

    // ================================================================ 所有平台

    @LXMethod("pickFiles")
    fun pickFiles(args: JSONObject?, cb: LXCallback) {
        val folder = args?.optBoolean("folder", false) == true
        val multiple = args?.optBoolean("multiple", true) != false
        val app = context.applicationContext
        val empty = mapOf("paths" to emptyList<String>())
        val ok = if (folder) {
            LXActivityResults.launch(ctx.engine, ActivityResultContracts.OpenDocumentTree(), null) { tree ->
                if (tree == null) return@launch cb.resolve(empty)
                io.execute {
                    try {
                        val rootId = DocumentsContract.getTreeDocumentId(tree)
                        val rootDoc = DocumentsContract.buildDocumentUriUsingTree(tree, rootId)
                        val name = safeName(displayName(app, rootDoc), "folder")
                        val dest = File(uniqueDir(File(app.cacheDir, "picked")), name)
                        copyTree(app, tree, rootId, dest)
                        cb.resolve(mapOf("paths" to listOf(dest.absolutePath)))
                    } catch (e: Exception) {
                        android.util.Log.w(TAG, "复制文件夹失败", e)
                        cb.resolve(empty)
                    }
                }
            }
        } else if (multiple) {
            LXActivityResults.launch(ctx.engine, ActivityResultContracts.OpenMultipleDocuments(), arrayOf("*/*")) { uris ->
                copyPicked(app, uris, cb)
            }
        } else {
            LXActivityResults.launch(ctx.engine, ActivityResultContracts.OpenDocument(), arrayOf("*/*")) { uri ->
                copyPicked(app, listOfNotNull(uri), cb)
            }
        }
        if (!ok) cb.resolve(empty)
    }

    private fun copyPicked(app: Context, uris: List<Uri>, cb: LXCallback) {
        if (uris.isEmpty()) return cb.resolve(mapOf("paths" to emptyList<String>()))
        io.execute {
            val dir = uniqueDir(File(app.cacheDir, "picked"))
            val paths = ArrayList<String>()
            for (u in uris) {
                try {
                    copyUri(app, u, dir)?.let { paths.add(it.absolutePath) }
                } catch (e: Exception) {
                    android.util.Log.w(TAG, "复制选中的文件失败：$u", e)
                }
            }
            cb.resolve(mapOf("paths" to paths))
        }
    }

    @LXMethod("openPath")
    fun openPath(args: JSONObject?, cb: LXCallback) {
        val path = args?.optString("path").orEmpty()
        val file = File(path)
        if (path.isEmpty() || !file.isFile) return cb.resolve(mapOf("ok" to false))
        val activity = ctx.activity
        val uri = try {
            FileProvider.getUriForFile(activity, "${activity.packageName}.chaochuan.fileprovider", file)
        } catch (e: Exception) {
            android.util.Log.w(TAG, "FileProvider 不覆盖 $path", e)
            return cb.resolve(mapOf("ok" to false))
        }
        val ext = file.extension.lowercase(Locale.ROOT)
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext) ?: "application/octet-stream"
        val view = Intent(Intent.ACTION_VIEW).setDataAndType(uri, mime)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        val opened = try {
            activity.startActivity(view)
            true
        } catch (_: ActivityNotFoundException) {
            false
        } catch (e: Exception) {
            android.util.Log.w(TAG, "打开 $path 失败", e)
            false
        }
        if (opened) return cb.resolve(mapOf("ok" to true))
        // 没有能预览的 App：退回系统分享面板
        val send = Intent(Intent.ACTION_SEND).setType(mime)
            .putExtra(Intent.EXTRA_STREAM, uri)
            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        send.clipData = ClipData.newRawUri(file.name, uri)
        val shared = try {
            activity.startActivity(Intent.createChooser(send, file.name).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION))
            true
        } catch (e: Exception) {
            android.util.Log.w(TAG, "分享 $path 失败", e)
            false
        }
        cb.resolve(mapOf("ok" to shared))
    }

    @LXMethod("takeIncomingFiles")
    fun takeIncomingFiles(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> {
        val list = synchronized(incoming) { ArrayList(incoming).also { incoming.clear() } }
        return mapOf("paths" to list)
    }

    @LXMethod("interfaces")
    fun interfaces(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> {
        val found = mutableListOf<Triple<Int, String, String>>()
        try {
            for (nif in NetworkInterface.getNetworkInterfaces() ?: return mapOf("list" to emptyList<Any>())) {
                if (!nif.isUp || nif.isLoopback || nif.isVirtual) continue
                val name = nif.name
                val lower = name.lowercase(Locale.ROOT)
                if (listOf("tun", "ppp", "ipsec", "rmnet", "ccmni", "dummy", "lo").any { lower.startsWith(it) }) continue
                val rank = when {
                    lower.startsWith("wlan") -> 0
                    lower.startsWith("eth") -> 1
                    lower.startsWith("ap") || lower.startsWith("swlan") -> 2
                    else -> 3
                }
                for (addr in nif.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress && !addr.isLinkLocalAddress) {
                        found.add(Triple(rank, name, addr.hostAddress ?: continue))
                    }
                }
            }
        } catch (_: Exception) {
        }
        val list = found.sortedBy { it.first }.map { mapOf("name" to it.second, "ip" to it.third) }
        return mapOf("list" to list)
    }

    // ================================================================ 只有桌面：移动端 { supported = false }

    @LXMethod("pickDirectory")
    fun pickDirectory(@Suppress("UNUSED_PARAMETER") args: JSONObject?, cb: LXCallback) = cb.resolve(SUPPORTED_FALSE)

    @LXMethod("setCloseToTray")
    fun setCloseToTray(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> = SUPPORTED_FALSE

    @LXMethod("showWindow")
    fun showWindow(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> = SUPPORTED_FALSE

    @LXMethod("hideWindow")
    fun hideWindow(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> = SUPPORTED_FALSE

    @LXMethod("setLaunchAtLogin")
    fun setLaunchAtLogin(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> = SUPPORTED_FALSE

    @LXMethod("getLaunchAtLogin")
    fun getLaunchAtLogin(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> = SUPPORTED_FALSE

    @LXMethod("setContextMenu")
    fun setContextMenu(@Suppress("UNUSED_PARAMETER") args: JSONObject?): Map<String, Any?> = SUPPORTED_FALSE
}

/** openPath 用的 FileProvider（子类：避免和 lxkit 自带的 androidx FileProvider 在合并 Manifest 时冲突） */
class ChaochuanFileProvider : FileProvider()
