import Darwin
import Foundation

/// Private local files; callers pass only directories owned by Subvox.
enum PrivateStorage {
    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Subvox", directoryHint: .isDirectory)
    }

    static func createDirectory(at url: URL, exclusive: Bool = false) throws {
        if exclusive {
            guard mkdir(url.path, 0o700) == 0 else { throw posixError() }
        } else {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        defer { close(fd) }
        guard fchmod(fd, 0o700) == 0 else { throw posixError() }
    }

    static func createFile(at url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw posixError() }
        guard fchmod(fd, 0o600) == 0 else {
            let error = posixError()
            close(fd)
            unlink(url.path)
            throw error
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    static func read(from url: URL) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw posixError() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw posixError() }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        guard fchmod(fd, 0o600) == 0 else { throw posixError() }
        return try handle.readToEnd() ?? Data()
    }

    /// Write private bytes before atomically replacing the destination.
    static func write(_ data: Data, to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try createDirectory(at: parent)
        try checkDestination(url)
        let temporary = parent.appending(path: ".\(UUID().uuidString).tmp")
        let handle = try createFile(at: temporary)
        defer {
            try? handle.close()
            try? FileManager.default.removeItem(at: temporary)
        }
        try handle.write(contentsOf: data)
        try handle.close()
        try checkDestination(url)
        guard rename(temporary.path, url.path) == 0 else { throw posixError() }
    }

    private static func checkDestination(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
        } else if errno != ENOENT {
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}
