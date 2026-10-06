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
                    if parts.count >= 3, let fanIdx = Int32(parts[1]), let rpm = Float(parts[2]) {
                        let res = smc_set_fan_target(fanIdx, rpm)
                        if res == 0 {
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
        // Watchdog: If fans are in manual mode and no command received for > 12 seconds, restore auto!
        if !isAutoMode && Date().timeIntervalSince(lastCommandTime) > 12.0 {
            print("⚠️ Watchdog timeout: Restoring fans to macOS auto mode.")
            _ = smc_set_all_auto()
            isAutoMode = true
        }

        // Sleep 50ms before checking for new connections
        usleep(50000)
    }
}
