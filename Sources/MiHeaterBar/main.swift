import Foundation
import HeaterKit

// Probe mode: the bare binary outside the .app bundle (no bundle id).
if Bundle.main.bundleIdentifier == nil {
    exit(await Probe.run(Array(CommandLine.arguments.dropFirst())))
}
MiHeaterBarApp.main()
