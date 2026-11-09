import Foundation
import PhotoFerryCore
import XPC

// The copy service: an XPC service bundled at
// PhotoFerry.app/Contents/XPCServices/local.photoferry.copyservice.xpc. It is reachable only
// by processes of the app bundle it ships in (launchd scopes bundled XPC services to it).
let ledger = try? Ledger()   // ~/Library/Application Support/PhotoFerry/ledger.sqlite
// Offsite uploads run here, in the background, for as long as the service lives. Secrets come
// from the Keychain (service local.photoferry.s3, account = key ID).
let uploads = ledger.map { UploadWorker(ledger: $0) }
if let uploads { Task { await uploads.start() } }
let listener = try XPCListener(service: CopyService.name) { request in
    request.accept { session in CopyServicePeer(session: session, ledger: ledger, uploads: uploads) }
}
_ = listener
// XPC services park the main thread in dispatchMain(); the API requires it.
dispatchMain()
