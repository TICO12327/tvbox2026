import Foundation

@main
struct BootstrapGenerator {
    static func main() throws {
        print(try NodeBootstrap.make(bundlePath: CommandLine.arguments[1], failurePath: CommandLine.arguments[2]))
    }
}
