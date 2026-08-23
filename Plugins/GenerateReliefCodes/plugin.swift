import PackagePlugin
import Foundation

@main
struct GenerateReliefCodes: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        let generator = try context.tool(named: "ReliefCodeGenerator")
        let rules = context.package.directoryURL
            .appending(path: "Sources/TaxKit/Resources/Rules")
        let output = context.package.directoryURL
            .appending(path: "Sources/TaxKit/Rules/ReliefCode+Generated.swift")

        let process = Process()
        process.executableURL = generator.url
        process.arguments = [rules.path(), output.path()]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            Diagnostics.error("ReliefCodeGenerator failed with status \(process.terminationStatus)")
            return
        }
    }
}
