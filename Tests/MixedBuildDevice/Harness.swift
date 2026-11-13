// Standalone device adapter for test-mixed-build-device.py. The script inserts
// BuildPipeline's actual source planning, compile, link and Swift module methods
// at the marker below. This checks the real argument construction and runs its
// compilers; it does NOT exercise BuildService, packaging or Mach-O verification.
import Foundation

struct BuildFailure: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

struct DeviceToolchain {
    var id = "device-test"
    var version = "15.3"
    func tool(_ name: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["APELIN_TOOLCHAIN_BIN"]!)
            .appendingPathComponent(name)
    }
}
struct DeviceSDK {
    var id = "device-test"
    var path: String { ProcessInfo.processInfo.environment["SDKROOT"]! }
}
struct DeviceInputs {
    var projectRoot: URL
    var project: ProjectDocument
    var workDirectory: URL
    var bootstrap: Bootstrap
    var configuration = ConfigurationName.debug
    var buildID = "mixed-device-check"
    var toolchain = DeviceToolchain()
    var sdk = DeviceSDK()
}

final class DevicePipelineCheck {
    let inputs: DeviceInputs
    var objects: [String: [Architecture: [String]]] = [:]
    var sourcePlans: [String: ProductSourcePlan] = [:]
    var slices: [String: [Architecture: String]] = [:]
    private var moduleCache: [Architecture: [String: BuiltModule]] = [:]
    var project: ProjectDocument { inputs.project }
    var configuration: ProjectDocument.Configuration { project.configuration(inputs.configuration) }
    var architectures: [Architecture] { project.architectures[inputs.bootstrap] ?? [] }
    var root: String { inputs.projectRoot.path }
    var work: URL { inputs.workDirectory }
    var bootstrapDefine: String { "APELIN_BOOTSTRAP_" + inputs.bootstrap.rawValue.uppercased() }
    var configurationDefine: String { "APELIN_CONFIGURATION_DEBUG" }
    var defines: [(String, String)] {
        [(bootstrapDefine, "1"), (configurationDefine, "1")]
            + (configuration.defines ?? [:]).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    struct Support {
        var includes: [String] = []
        var libraryDirectories: [String] = []
        var rpaths: [String] = []
    }
    init(inputs: DeviceInputs) { self.inputs = inputs }
    func support(for product: ProjectDocument.Product) throws -> Support {
        precondition((product.extensionSupport ?? []).isEmpty)
        return Support()
    }
    func tool(_ name: String) throws -> String { inputs.toolchain.tool(name).path }
    func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }
    func log(_ line: String) { print(line) }
    func execute(_ executable: String, _ arguments: [String], label: String) throws {
        let invocation = ToolInvocation(executable: executable, arguments: arguments,
                                        workingDirectory: root, environment: ProcessInfo.processInfo.environment)
        print("$ " + invocation.displayLine)
        let result = try ToolRunner.run(invocation, cancellation: BuildCancellation())
        print(result.output)
        guard result.succeeded else { throw BuildFailure("\(label): \(result.status)") }
    }
    // Intentionally outside this standalone test's coverage. MacPipelineTests
    // and the real BuildPipeline validate pointer authentication and packages.
    func requirePointerSignatures(_ binary: String, product: ProjectDocument.Product) throws {}
    func fileName(of product: ProjectDocument.Product) -> String {
        product.type == .dylib ? product.name + ".dylib" : product.name
    }
    var extensionEntryPoint: [String] {
        ["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain", "-framework", "Foundation"]
    }

    // INSERT_PIPELINE_METHODS

    func run() throws {
        for product in project.products {
            try compile(product, flags: [])
            try link(product, flags: [])
        }
    }
}

@main struct DeviceMixedBuildMain {
    static func main() throws {
        let env = ProcessInfo.processInfo.environment
        let repo = URL(fileURLWithPath: env["APELIN_PROJECT_ROOT"]!)
        let relative = CommandLine.arguments[1]
        let root = repo.appendingPathComponent(relative)
        let project = try JSONDecoder().decode(ProjectDocument.self, from: Data(contentsOf: root.appendingPathComponent("project.json")))
        let bootstrap = Bootstrap(rawValue: CommandLine.arguments[2])!
        let inputs = DeviceInputs(projectRoot: root, project: project,
                                  workDirectory: root.appendingPathComponent("out-" + bootstrap.rawValue), bootstrap: bootstrap)
        try DevicePipelineCheck(inputs: inputs).run()
        print("PIPELINE COMPILE/LINK PASSED")
    }
}
