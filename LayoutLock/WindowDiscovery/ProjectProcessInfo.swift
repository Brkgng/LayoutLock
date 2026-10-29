import Foundation
import Darwin

/// Reads project context without retaining environment values or logging process arguments.
enum ProjectProcessInfo {
    static func currentDirectoryURL(_ pid: pid_t) -> URL? {
        var info = proc_vnodepathinfo()
        let size = MemoryLayout<proc_vnodepathinfo>.size
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(size)) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
            String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    static func projectPaths(_ pid: pid_t, selecting: ([String]) -> [String]) -> [String] {
        var query = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&query, UInt32(query.count), nil, &size, nil, 0) == 0,
              size >= MemoryLayout<Int32>.size, size <= 2 * 1024 * 1024 else { return [] }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&query, UInt32(query.count), &bytes, &size, nil, 0) == 0 else { return [] }
        let count = bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard count > 0, count <= 4096 else { return [] }
        var offset = MemoryLayout<Int32>.size
        while offset < size, bytes[offset] != 0 { offset += 1 } // executable path
        while offset < size, bytes[offset] == 0 { offset += 1 }
        var arguments: [String] = []
        // KERN_PROCARGS2 also contains the environment. Stop after argc arguments.
        for _ in 0..<count {
            guard offset < size else { return [] }
            let start = offset
            while offset < size, bytes[offset] != 0 { offset += 1 }
            guard offset < size else { return [] }
            arguments.append(String(decoding: bytes[start..<offset], as: UTF8.self))
            offset += 1
        }
        return selecting(arguments)
    }
}
