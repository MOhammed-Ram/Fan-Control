import Foundation

public final class HelperClient: @unchecked Sendable {
    public static let shared = HelperClient()
    public static let socketPath = "/var/run/fancontrol_helper.sock"
    public static let fallbackSocketPath = "/tmp/fancontrol_helper.sock"

    public var isConnected: Bool {
        return ping()
    }

    public init() {}

    private func createConnection() -> Int32? {
        let paths = [HelperClient.socketPath, HelperClient.fallbackSocketPath]
        for path in paths {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            if fd < 0 { continue }

            var noSigPipe: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)

            let pathLen = path.utf8.count
            if pathLen >= MemoryLayout.size(ofValue: addr.sun_path) {
                close(fd)
                continue
            }

            _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
                path.withCString { cstr in
                    strncpy(ptr, cstr, pathLen + 1)
                }
            }

            var tv = timeval(tv_sec: 0, tv_usec: 250_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let res = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    connect(fd, saPtr, addrLen)
                }
            }

            if res == 0 {
                return fd
            }
            close(fd)
        }
        return nil
    }

    public func sendCommand(_ cmd: String) -> String? {
        guard let fd = createConnection() else { return nil }
        defer { close(fd) }

        let payload = cmd.hasSuffix("\n") ? cmd : cmd + "\n"
        let data = [UInt8](payload.utf8)
        let bytesWritten = data.withUnsafeBytes { ptr in
            write(fd, ptr.baseAddress, data.count)
        }

        if bytesWritten <= 0 { return nil }

        var buffer = [UInt8](repeating: 0, count: 256)
        let bytesRead = read(fd, &buffer, buffer.count - 1)
        if bytesRead > 0 {
            buffer[bytesRead] = 0
            let reply = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
            return reply
        }

        return nil
    }

    public func ping() -> Bool {
        return sendCommand("PING") == "PONG"
    }

    @discardableResult
    public func setFan(index: Int, rpm: Double) -> Bool {
        let cmd = String(format: "SET %d %.0f", index, rpm)
        return sendCommand(cmd) == "OK"
    }

    @discardableResult
    public func setAllFans(rpms: [Double]) -> Bool {
        guard !rpms.isEmpty else { return false }
        let args = rpms.map { String(format: "%.0f", $0) }.joined(separator: " ")
        let reply = sendCommand("SETALL \(args)")
        if reply == "OK" {
            return true
        }
        // Fallback for older running helper daemon that only supports individual SET
        var ok = true
        for (idx, rpm) in rpms.enumerated() {
            if !setFan(index: idx, rpm: rpm) {
                ok = false
            }
        }
        return ok
    }

    @discardableResult
    public func setAuto() -> Bool {
        return sendCommand("AUTO") == "OK"
    }
}
