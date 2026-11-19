import Foundation

// Ignore SIGPIPE so abrupt client disconnects never crash the daemon
signal(SIGPIPE, SIG_IGN)

private var gShouldTerminate: sig_atomic_t = 0

if !smc_is_root() {
    fputs("Error: fan-control-helper must run as root.\n", stderr)
    exit(1)
}

if smc_open() != 0 {
    fputs("Error: Failed to open AppleSMC.\n", stderr)
    exit(1)
}

let primarySocketPath = "/var/run/fancontrol_helper.sock"
let fallbackSocketPath = "/tmp/fancontrol_helper.sock"
let isRootUser = (geteuid() == 0)
let activePath = isRootUser ? primarySocketPath : fallbackSocketPath

// Async-signal-safe handlers: only set the termination flag
signal(SIGINT) { _ in
    gShouldTerminate = 1
}
signal(SIGTERM) { _ in
    gShouldTerminate = 1
}
signal(SIGHUP) { _ in
    gShouldTerminate = 1
}

unlink(activePath)

let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
if serverFd < 0 {
    fputs("Error: Failed to create socket.\n", stderr)
    smc_close()
    exit(1)
}

var serverAddr = sockaddr_un()
serverAddr.sun_family = sa_family_t(AF_UNIX)

let pathLen = activePath.utf8.count
if pathLen >= MemoryLayout.size(ofValue: serverAddr.sun_path) {
    fputs("Error: Socket path too long: \(activePath)\n", stderr)
    close(serverFd)
    smc_close()
    exit(1)
}
_ = withUnsafeMutablePointer(to: &serverAddr.sun_path.0) { ptr in
    activePath.withCString { cstr in
        strncpy(ptr, cstr, pathLen + 1)
    }
}

let oldUmask = umask(0o177)
let bindRes = withUnsafePointer(to: &serverAddr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        bind(serverFd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
_ = umask(oldUmask)

if bindRes != 0 {
    fputs("Error: Failed to bind socket to \(activePath) (errno=\(errno)).\n", stderr)
    close(serverFd)
    smc_close()
    exit(1)
}

// Restrict socket access to root:staff (0660); peer UID is also verified on every connection
if isRootUser {
    _ = chown(activePath, 0, 20)
}
chmod(activePath, 0o660)

if listen(serverFd, 16) < 0 {
    fputs("Error: Failed to listen on socket.\n", stderr)
    close(serverFd)
    unlink(activePath)
    smc_close()
    exit(1)
}

// Set non-blocking on server socket
var flags = fcntl(serverFd, F_GETFL, 0)
if flags >= 0 {
    _ = fcntl(serverFd, F_SETFL, flags | O_NONBLOCK)
}

func cleanup() {
    _ = smc_set_all_auto()
    smc_close()
    close(serverFd)
    unlink(activePath)
}

func isPeerAuthorized(_ clientFd: Int32) -> Bool {
    var peerUid: uid_t = 0
    var peerGid: gid_t = 0
    guard getpeereid(clientFd, &peerUid, &peerGid) == 0 else {
        return false
    }
    if peerUid == 0 || peerUid == geteuid() {
        return true
    }
    var st = stat()
    if stat("/dev/console", &st) == 0 && peerUid == st.st_uid {
        return true
    }
    return false
}

func writeResponse(_ clientFd: Int32, _ response: String) {
    let respData = [UInt8](response.utf8)
    _ = respData.withUnsafeBytes { ptr in
        write(clientFd, ptr.baseAddress, respData.count)
    }
}

print("✅ Fan Control Privileged Helper running on \(activePath)")

var lastCommandNs: UInt64 = DispatchTime.now().uptimeNanoseconds
var isAutoMode: Bool = true
let watchdogTimeoutNs: UInt64 = 4_000_000_000

while gShouldTerminate == 0 {
    var pfd = pollfd(fd: serverFd, events: Int16(POLLIN), revents: 0)
    let pollRes = poll(&pfd, 1, 50)
    if pollRes < 0 {
        if errno == EINTR {
            continue
        }
        break
    }

    if gShouldTerminate != 0 {
        break
    }

    if pollRes > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                accept(serverFd, saPtr, &clientLen)
            }
        }

        if clientFd >= 0 {
            // Clear inherited O_NONBLOCK, disable SIGPIPE, and set 500ms timeouts
            let clientFlags = fcntl(clientFd, F_GETFL, 0)
            if clientFlags >= 0 {
                _ = fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK)
            }
            var noSigPipe: Int32 = 1
            setsockopt(clientFd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            var tv = timeval(tv_sec: 0, tv_usec: 500_000)
            setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            if !isPeerAuthorized(clientFd) {
                writeResponse(clientFd, "ERR Unauthorized\n")
                close(clientFd)
            } else {
                var buffer = [UInt8](repeating: 0, count: 512)
                let bytesRead = read(clientFd, &buffer, buffer.count - 1)
                if bytesRead > 0 {
                    buffer[bytesRead] = 0
                    let command = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
                    let parts = command.split(separator: " ").map(String.init)

                    var response = "ERR\n"
                    if !parts.isEmpty {
                        let verb = parts[0].uppercased()
                        switch verb {
                        case "PING":
                            response = "PONG\n"

                        case "AUTO":
                            _ = smc_set_all_auto()
                            isAutoMode = true
                            response = "OK\n"

                        case "SET":
                            if smc_is_lid_closed() && smc_clamshell_causes_sleep() {
                                _ = smc_set_all_auto()
                                isAutoMode = true
                                response = "OK\n"
                                break
                            }
                            let fanCount = smc_get_fan_count()
                            if parts.count >= 3,
                               let fanIdx = Int32(parts[1]),
                               fanIdx >= 0 && fanIdx < fanCount,
                               let rawRpm = Float(parts[2]),
                               rawRpm.isFinite {
                                let minRpm = smc_get_fan_min_rpm(fanIdx)
                                let maxRpm = smc_get_fan_max_rpm(fanIdx)
                                let clampedRpm = max(minRpm, min(maxRpm, rawRpm))
                                let res = smc_set_fan_target(fanIdx, clampedRpm)
                                if res == 0 {
                                    isAutoMode = false
                                    lastCommandNs = DispatchTime.now().uptimeNanoseconds
                                    response = "OK\n"
                                } else {
                                    response = "FAIL\n"
                                }
                            }

                        case "SETALL":
                            if smc_is_lid_closed() && smc_clamshell_causes_sleep() {
                                _ = smc_set_all_auto()
                                isAutoMode = true
                                response = "OK\n"
                                break
                            }
                            let fanCount = Int(smc_get_fan_count())
                            if parts.count >= 2 && fanCount > 0 {
                                var allSucceeded = true
                                for i in 0..<min(fanCount, parts.count - 1) {
                                    if let rawRpm = Float(parts[i + 1]), rawRpm.isFinite {
                                        let fanIdx = Int32(i)
                                        let minRpm = smc_get_fan_min_rpm(fanIdx)
                                        let maxRpm = smc_get_fan_max_rpm(fanIdx)
                                        let clampedRpm = max(minRpm, min(maxRpm, rawRpm))
                                        if smc_set_fan_target(fanIdx, clampedRpm) != 0 {
                                            allSucceeded = false
                                        }
                                    } else {
                                        allSucceeded = false
                                    }
                                }
                                if allSucceeded {
                                    isAutoMode = false
                                    lastCommandNs = DispatchTime.now().uptimeNanoseconds
                                    response = "OK\n"
                                } else {
                                    response = "FAIL\n"
                                }
                            }

                        default:
                            response = "UNKNOWN\n"
                        }
                    }

                    writeResponse(clientFd, response)
                }
                close(clientFd)
            }
        }
    }

    // Immediately restore macOS auto mode if lid closed for sleep, or if monotonic watchdog > 4s
    if !isAutoMode && smc_is_lid_closed() && smc_clamshell_causes_sleep() {
        print("⚠️ Lid closed for sleep: Restoring fans to macOS auto mode.")
        _ = smc_set_all_auto()
        isAutoMode = true
    } else if !isAutoMode {
        let nowNs = DispatchTime.now().uptimeNanoseconds
        if nowNs >= lastCommandNs && (nowNs - lastCommandNs) > watchdogTimeoutNs {
            print("⚠️ Watchdog timeout: Restoring fans to macOS auto mode.")
            _ = smc_set_all_auto()
            isAutoMode = true
        }
    }
}

cleanup()
