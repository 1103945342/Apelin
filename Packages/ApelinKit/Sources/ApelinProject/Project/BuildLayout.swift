import Foundation

/// Where a build and what it keeps between builds live: under the data
/// folder's `Builds/`, outside every project, so a build never writes into a
/// source tree.
public enum BuildLayout {
    /// `Builds/<projectID>/<buildID>/`: one build's own work directory, which
    /// `BuildService` wipes when the build starts.
    public static func work(inBuilds builds: URL, projectID: String, buildID: String) -> URL {
        builds.appendingPathComponent(projectID, isDirectory: true)
            .appendingPathComponent(buildID, isDirectory: true)
    }

    /// `Builds/.build-cache/<projectID>/`: the compiled code a project's
    /// builds reuse (`BuildCache` in ApelinBuild).
    public static func buildCache(inBuilds builds: URL, projectID: String) -> URL {
        builds.appendingPathComponent(buildCacheFolderName, isDirectory: true)
            .appendingPathComponent(projectID, isDirectory: true)
    }

    /// Beside the build directories: a name no build ID can be, since those
    /// are UUIDs.
    public static let buildCacheFolderName = ".build-cache"
}
