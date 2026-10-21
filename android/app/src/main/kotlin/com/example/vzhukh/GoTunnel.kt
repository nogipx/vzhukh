package dev.nogipx.vzhukh

/**
 * The tunnel itself, in Go (go/tun2socks/main.go, internal/mobile): packet
 * engine, SSH route, reconnects. Lives in the VpnService's process, so it
 * runs whether or not the app's window is open.
 */
object GoTunnel {
    init {
        System.loadLibrary("tun2socks")
    }

    /** Starts on [fd] with [config] JSON; null on success, else the error. */
    @JvmStatic external fun start(fd: Int, config: String): String?

    @JvmStatic external fun stop()

    /** The route's state as JSON: {"state": "up" | "connecting" | "down" | "stopped", ...}. */
    @JvmStatic external fun status(): String

    /** The network changed: probe or redial the route now. */
    @JvmStatic external fun nudge(reason: String)
}
