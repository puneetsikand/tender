import Foundation
import PhotoFerryCore
import XPC

// The copy service: an XPC service bundled at
// PhotoFerry.app/Contents/XPCServices/local.photoferry.copyservice.xpc. It is reachable only
// by processes of the app bundle it ships in (launchd scopes bundled XPC services to it).
let ledger = try? Ledger()   // ~/Library/Application Support/PhotoFerry/ledger.sqlite
let listener = try XPCListener(service: CopyService.name) { request in
    request.accept { session in CopyServicePeer(session: session, ledger: ledger) }
}
_ = listener
// XPC services park the main thread in dispatchMain(); the API requires it.
dispatchMain()
