package com.chaochuan.chaochuan

import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Bundle
import com.lx.kit.host.LXActivity

/**
 * 入口：通用逻辑（加载 Lua、生命周期、深链接、返回键、热更新……）都在 LXActivity（lxkit）里。
 * 超传额外持有 Wi‑Fi 组播锁：Android 默认丢弃发给本机的组播包，不持锁就收不到 LocalSend 的发现广播（224.0.0.167）。
 * 「分享到超传 / 用超传打开」（ACTION_SEND / SEND_MULTIPLE / VIEW content|file）：文件复制进缓存后进 chaochuanHost 的队列；
 * 这类 intent 处理完换成普通的 MAIN intent 再交给引擎，免得 lx.linking 把 content:// 当深链接；chaochuan:// 照旧交给引擎。
 */
class MainActivity : LXActivity() {
    private var multicastLock: WifiManager.MulticastLock? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // 重建（savedInstanceState）或从最近任务里重新打开时，旧的分享 intent 已经处理过，不再重复复制
        val fromHistory = ((intent?.flags ?: 0) and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0
        if (ChaochuanHost.isIncomingIntent(intent)) {
            if (savedInstanceState == null && !fromHistory) ChaochuanHost.handleIncomingIntent(this, intent)
            setIntent(neutralIntent())
        }
        super.onCreate(savedInstanceState)
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            multicastLock = wifi.createMulticastLock("chaochuan-discovery").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (e: Exception) {
            android.util.Log.w("chaochuan", "获取组播锁失败", e)
        }
    }

    override fun onNewIntent(intent: Intent) {
        if (ChaochuanHost.isIncomingIntent(intent)) {
            ChaochuanHost.handleIncomingIntent(this, intent)
            super.onNewIntent(neutralIntent())
        } else {
            super.onNewIntent(intent)
        }
    }

    private fun neutralIntent() = Intent(Intent.ACTION_MAIN).setClass(this, MainActivity::class.java)

    override fun onDestroy() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
        super.onDestroy()
    }
}
