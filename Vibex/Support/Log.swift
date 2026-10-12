import os

/// One logger per subsystem area. `nonisolated` so background work can log too.
nonisolated enum Log {
    private static let subsystem = "com.yusuf.vibex"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let layout = Logger(subsystem: subsystem, category: "layout")
    static let terminal = Logger(subsystem: subsystem, category: "terminal")
    static let simulator = Logger(subsystem: subsystem, category: "simulator")
    static let dock = Logger(subsystem: subsystem, category: "dock")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let mcp = Logger(subsystem: subsystem, category: "mcp")
}
