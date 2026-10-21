import Foundation
import MMSchemaCodeGenerator
import SwiftParser
import SwiftSyntax

/// MMCLIGenerator — the tool behind the MMCLIGeneratorPlugin build-tool plugin.
///
/// Reads the Swift sources of the CLI target and of the package targets it
/// depends on, finds every `#schema` block whose `CLI(...)` entry is
/// enabled, and writes one file into the CLI target:
/// `extension <Namespace> { ...commands... }` per block, plus the wire
/// enums' `MMCLIEnumArgument` conformances. The `#schema` macro itself never
/// emits commands, so the module holding the schema (shared with the
/// daemon) stays free of MMCLI and swift-argument-parser.
///
///     MMCLIGenerator --output <file.swift> [--own <Module> <file>... | --dependency <Module> <file>...]...
///
/// `--own` sources belong to the target receiving the output; `--dependency`
/// sources are other targets of the same package, imported by the output.
/// Errors print as `file:line:column: error: message` and exit 1.

private struct SourceGroup {
    var module: String
    var isOwn: Bool
    var files: [String] = []
}

private struct GenerationError: Error {
    var message: String
}

private func parseArguments(
    _ arguments: [String]
) throws -> (output: String, groups: [SourceGroup]) {
    var output: String?
    var groups: [SourceGroup] = []
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
        switch argument {
            case "--output":
                output = iterator.next()
            case "--own", "--dependency":
                guard let module = iterator.next() else {
                    throw GenerationError(message: "\(argument) requires a module name")
                }
                groups.append(SourceGroup(module: module, isOwn: argument == "--own"))
            default:
                guard !groups.isEmpty else {
                    throw GenerationError(message: "unexpected argument \(argument)")
                }
                groups[groups.count - 1].files.append(argument)
        }
    }
    guard let output else { throw GenerationError(message: "missing --output <file>") }
    return (output, groups)
}

/// Every `#schema` expansion at declaration level (namespace type members).
private final class SchemaFinder: SyntaxVisitor {
    var found: [MacroExpansionDeclSyntax] = []

    override func visit(_ node: MacroExpansionDeclSyntax) -> SyntaxVisitorContinueKind {
        if node.macroName.text == "schema" { found.append(node) }
        return .skipChildren
    }
}

/// The full path of the type a `#schema` expands in (`Journal`,
/// `Outer.Journal`, or an extension's extended type), or nil when it is not
/// nested in a file-scope type the generated extension can reach.
private func enclosingTypePath(_ node: some SyntaxProtocol) -> String? {
    var names: [String] = []
    var current = node.parent
    while let scope = current {
        if let declaration = scope.as(EnumDeclSyntax.self) {
            names.append(declaration.name.text)
        } else if let declaration = scope.as(StructDeclSyntax.self) {
            names.append(declaration.name.text)
        } else if let declaration = scope.as(ClassDeclSyntax.self) {
            names.append(declaration.name.text)
        } else if let declaration = scope.as(ActorDeclSyntax.self) {
            names.append(declaration.name.text)
        } else if let declaration = scope.as(ExtensionDeclSyntax.self) {
            names.append(declaration.extendedType.trimmedDescription)
            break
        } else if scope.is(FunctionDeclSyntax.self) || scope.is(ClosureExprSyntax.self)
            || scope.is(AccessorBlockSyntax.self) || scope.is(InitializerDeclSyntax.self)
        {
            return nil  // a local type: nothing outside its body can extend it
        }
        current = scope.parent
    }
    guard !names.isEmpty else { return nil }
    return names.reversed().joined(separator: ".")
}

private func indented(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "    \($0)" }
        .joined(separator: "\n")
}

private func generate(_ groups: [SourceGroup]) throws -> String {
    var extensions: [String] = []
    var conformances: [String] = []
    var importedModules: [String] = []
    var errors: [String] = []
    for group in groups {
        for file in group.files {
            let source = try String(contentsOfFile: file, encoding: .utf8)
            guard source.contains("#schema") else { continue }
            let tree = Parser.parse(source: source)
            let finder = SchemaFinder(viewMode: .sourceAccurate)
            finder.walk(tree)
            guard !finder.found.isEmpty else { continue }
            let converter = SourceLocationConverter(fileName: file, tree: tree)
            for node in finder.found {
                let location = node.startLocation(converter: converter)
                let position = "\(file):\(location.line):\(location.column)"
                do {
                    guard let path = enclosingTypePath(node) else {
                        // CLI-disabled blocks may live anywhere; an enabled one
                        // is reported (the macro also rejects a missing type).
                        if try SchemaCodeGenerator.expandSchema(node).cliEnabled {
                            errors.append(
                                "\(position): error: #schema with CLI(.enabled) must expand inside a named type declared at file scope (the generated commands extend it)"
                            )
                        }
                        continue
                    }
                    guard
                        let cli = try SchemaCodeGenerator.cliExtension(node, enclosingType: path)
                    else { continue }
                    extensions.append(
                        "extension \(path) {\n\(cli.members.map(indented).joined(separator: "\n\n"))\n}"
                    )
                    conformances.append(contentsOf: cli.topLevel)
                    if !group.isOwn, !importedModules.contains(group.module) {
                        importedModules.append(group.module)
                    }
                } catch let error as SchemaMacroError {
                    errors.append("\(position): error: \(error.description)")
                }
            }
        }
    }
    guard errors.isEmpty else {
        throw GenerationError(message: errors.joined(separator: "\n"))
    }

    var output = "// Generated by the MMCLIGeneratorPlugin build-tool plugin. Do not edit.\n"
    guard !extensions.isEmpty else { return output }
    let imports = ["ArgumentParser", "MMCLI", "MMSchema"] + importedModules
    output += "\n" + imports.map { "import \($0)" }.joined(separator: "\n") + "\n"
    output += "\n" + extensions.joined(separator: "\n\n") + "\n"
    if !conformances.isEmpty {
        output += "\n" + conformances.joined(separator: "\n") + "\n"
    }
    return output
}

do {
    let (outputPath, groups) = try parseArguments(Array(CommandLine.arguments.dropFirst()))
    try generate(groups).write(toFile: outputPath, atomically: true, encoding: .utf8)
} catch let error as GenerationError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(1)
} catch {
    FileHandle.standardError.write(Data("MMCLIGenerator: \(error)\n".utf8))
    exit(1)
}
