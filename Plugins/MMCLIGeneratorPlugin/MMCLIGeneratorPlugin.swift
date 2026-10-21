import Foundation
import PackagePlugin

/// Generates the `#schema` CLI commands into the target it is applied to.
///
/// Apply it to the command-line tool's target only:
///
/// ```swift
/// .executableTarget(
///     name: "JournalCLI",
///     dependencies: ["JournalAPI", .product(name: "MMCLI", package: "mm"), ...],
///     plugins: [.plugin(name: "MMCLIGeneratorPlugin", package: "mm")]
/// )
/// ```
///
/// It scans the target's own sources and every target of the same package it
/// depends on (directly or transitively) for `#schema` blocks with
/// `CLI(.enabled)`, and adds one generated file declaring
/// `extension Journal { struct Command ... }` — so `Journal.Command` exists
/// only in the CLI, and the shared API module (and with it the daemon)
/// never links MMCLI or swift-argument-parser.
@main
struct MMCLIGeneratorPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        let packageTargets = Set(context.package.targets.map(\.id))
        var arguments: [String] = []
        var inputs: [URL] = []
        func scan(_ module: SourceModuleTarget, role: String) {
            let files = module.sourceFiles(withSuffix: "swift").map(\.url)
            guard !files.isEmpty else { return }
            arguments += [role, module.moduleName] + files.map { $0.path(percentEncoded: false) }
            inputs += files
        }
        scan(target, role: "--own")
        for dependency in target.recursiveTargetDependencies
        where packageTargets.contains(dependency.id) {
            guard let module = dependency as? SourceModuleTarget, module.kind != .macro else {
                continue
            }
            scan(module, role: "--dependency")
        }
        let output = context.pluginWorkDirectoryURL.appending(path: "MMCLICommands.swift")
        return [
            .buildCommand(
                displayName: "Generating MM CLI commands for \(target.name)",
                executable: try context.tool(named: "MMCLIGenerator").url,
                arguments: ["--output", output.path(percentEncoded: false)] + arguments,
                inputFiles: inputs,
                outputFiles: [output]
            )
        ]
    }
}
