import Foundation
import SafariServices

/// Native side of the "AdBlock YouTube" Safari Web Extension.
///
/// All the work happens in JavaScript (see Resources/); Safari still
/// requires a principal class, which simply acknowledges native messages.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    func beginRequest(with context: NSExtensionContext) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["ok": true]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
