import Foundation
import PhotoFerryCore

// Command-line front end to the engine. Subcommands arrive with their milestones
// (`pf scan` in M1, `pf copy` in M2).
let args = Array(CommandLine.arguments.dropFirst())

switch args.first {
case "version", "--version", "-v":
    print("pf \(PhotoFerryCore.version)")
case "kind":
    for path in args.dropFirst() {
        let ext = (path as NSString).pathExtension
        print("\(MediaKind(fileExtension: ext).rawValue)\t\(path)")
    }
default:
    print("""
    usage: pf version
           pf kind <file>...    classify files by media kind
    """)
    exit(args.isEmpty ? 0 : 64)
}
