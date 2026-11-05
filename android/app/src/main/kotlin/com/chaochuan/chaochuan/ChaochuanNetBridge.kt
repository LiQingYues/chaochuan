package com.chaochuan.chaochuan

import com.lx.kit.bridge.LXExport
import com.lx.kit.bridge.LXMethod
import com.lx.kit.bridge.LXNativeContext
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * 局域网地址：lx.native("chaochuanNet")（Lua：core/localsend/protocol.lua refreshLanIp）
 *   lanIPv4()  Wi‑Fi / 以太网 / 热点网卡的 IPv4，跳过 VPN（tun / ppp / ipsec）、蜂窝（rmnet / ccmni）和回环；没有时返回空串
 * 开着 VPN 时 lxkit 的 device.getNetwork / wifi.getInfo 拿到的是当前默认网络（VPN 的 tun 地址），局域网发现用不了。
 */
@LXExport("chaochuanNet")
class ChaochuanNetBridge(@Suppress("unused") private val ctx: LXNativeContext) {

    @LXMethod("lanIPv4")
    fun lanIPv4(): String {
        val candidates = mutableListOf<Pair<Int, String>>()
        try {
            for (nif in NetworkInterface.getNetworkInterfaces() ?: return "") {
                if (!nif.isUp || nif.isLoopback || nif.isVirtual) continue
                val name = nif.name.lowercase()
                if (name.startsWith("tun") || name.startsWith("ppp") || name.startsWith("ipsec") ||
                    name.startsWith("rmnet") || name.startsWith("ccmni") || name.startsWith("dummy")) continue
                val rank = when {
                    name.startsWith("wlan") -> 0
                    name.startsWith("eth") -> 1
                    name.startsWith("ap") || name.startsWith("swlan") -> 2
                    else -> 3
                }
                for (addr in nif.inetAddresses) {
                    if (addr is Inet4Address && !addr.isLoopbackAddress && addr.isSiteLocalAddress) {
                        candidates.add(rank to (addr.hostAddress ?: continue))
                    }
                }
            }
        } catch (_: Exception) {
        }
        return candidates.minByOrNull { it.first }?.second ?: ""
    }
}
