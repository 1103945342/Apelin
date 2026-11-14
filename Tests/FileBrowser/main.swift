import ApelinCore
import Foundation

/// The file browser's own checks: where it stands, the path trail it draws,
/// what a place allows, what one folder holds, what an operation does and
/// where the Locations menu leads.
///
/// They run against a temporary folder and the paths this device already has;
/// nothing here writes anywhere else, and nothing outside the folder it made
/// is changed. `Scripts/test-file-browser.sh` compiles them with the app's
/// model files, and a device runs them the same way with `swiftc`.

func temporaryFolder(_ tag: String) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("apelin-file-browser-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// The path as `realpath` answers it: `/var` and `/private/var` are one place,
/// and a comparison is made on what the kernel will use.
func canonical(_ path: String) -> String {
    CanonicalPath.resolve(path) ?? path
}

func canonicalURL(_ path: String) -> URL {
    URL(fileURLWithPath: canonical(path), isDirectory: true)
}

try checkFileBrowserLocation()
try checkFileBrowserBreadcrumb()
try checkFileBrowserPolicy()
try checkFileBrowserListing()
try checkFileBrowserOperations()
try checkFileBrowserWriteGuard()
try checkFileBrowserLocations()
print("ok: the file browser's places, path trail, refusals, listings and operations")
