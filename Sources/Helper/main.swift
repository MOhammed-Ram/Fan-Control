import Foundation

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

func cleanup() {
    _ = smc_set_all_auto()
    smc_close()
    unlink(primarySocketPath)
    unlink(fallbackSocketPath)
}

signal(SIGINT) { _ in
    cleanup()
    exit(0)
}
signal(SIGTERM) { _ in
    cleanup()
    exit(0)
}
signal(SIGHUP) { _ in
    cleanup()
    exit(0)
}

unlink(primarySocketPath)
unlink(fallbackSocketPath)

let serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
if serverFd < 0 {
    fputs("Error: Failed to create socket.\n", stderr)
    exit(1)
}

var serverAddr = sockaddr_un()
serverAddr.sun_family = sa_family_t(AF_UNIX)

var activePath = primarySocketPath
let pathLen = activePath.utf8.count
_ = withUnsafeMutablePointer(to: &serverAddr.sun_path.0) { ptr in
    activePath.withCString { cstr in
        strncpy(ptr, cstr, pathLen + 1)
    }
}

var bindRes = withUnsafePointer(to: &serverAddr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
        bind(serverFd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}

if bindRes != 0 {
    // Try fallback to /tmp
    activePath = fallbackSocketPath
    _ = withUnsafeMutablePointer(to: &serverAddr.sun_path.0) { ptr in
        activePath.withCString { cstr in
            strncpy(ptr, cstr, activePath.utf8.count + 1)
        }
    }
    bindRes = withUnsafePointer(to: &serverAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            bind(serverFd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if bindRes != 0 {
        fputs("Error: Failed to bind socket to \(primarySocketPath) or \(fallbackSocketPath).\n", stderr)
        exit(1)
    }
}

// Allow read/write access to all local users
chmod(activePath, 0o666)

if listen(serverFd, 16) < 0 {
    fputs("Error: Failed to listen on socket.\n", stderr)
    exit(1)
}

// Set non-blocking on server socket so we can run the watchdog
var flags = fcntl(serverFd, F_GETFL, 0)
_ = fcntl(serverFd, F_SETFL, flags | O_NONBLOCK)

print("✅ Fan Control Privileged Helper running on \(activePath)")

var lastCommandTime: Date = Date()
var isAutoMode: Bool = true

while true {
    var clientAddr = sockaddr_un()
    var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

    let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
            accept(serverFd, saPtr, &clientLen)
        }
    }

    if clientFd >= 0 {
        // Clear inherited O_NONBLOCK on accepted client socket and set 500ms timeout
        let clientFlags = fcntl(clientFd, F_GETFL, 0)
        if clientFlags >= 0 {
            _ = fcntl(clientFd, F_SETFL, clientFlags & ~O_NONBLOCK)
        }
        var tv = timeval(tv_sec: 0, tv_usec: 500_000)
        setsockopt(clientFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(clientFd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

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
                            lastCommandTime = Date()
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
                            lastCommandTime = Date()
                            response = "OK\n"
                        } else {
                            response = "FAIL\n"
                        }
                    }

                default:
                    response = "UNKNOWN\n"
                }
            }

            let respData = [UInt8](response.utf8)
            _ = respData.withUnsafeBytes { ptr in
                write(clientFd, ptr.baseAddress, respData.count)
            }
        }
        close(clientFd)
    } else {
        // Immediately restore macOS auto mode if lid closed for sleep, or if watchdog > 4s
        if !isAutoMode && smc_is_lid_closed() && smc_clamshell_causes_sleep() {
            print("⚠️ Lid closed for sleep: Restoring fans to macOS auto mode.")
            _ = smc_set_all_auto()
            isAutoMode = true
        } else if !isAutoMode && Date().timeIntervalSince(lastCommandTime) > 4.0 {
            print("⚠️ Watchdog timeout: Restoring fans to macOS auto mode.")
            _ = smc_set_all_auto()
            isAutoMode = true
        }

        // Sleep 50ms before checking for new connections
        usleep(50000)
    }
}
