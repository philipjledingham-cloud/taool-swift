// Copyright (c) 2026 Primetic
// SPDX-License-Identifier: MIT
// TaoolKit: https://taool.com/docs

import os

/// TaoolKit takes the account's public key (`taool_public_…`), never a server key (`taool_secret_…`), which belongs
/// only on a server.
package enum ServerKeyGuard {
    package static func check(_ key: String, log: Logger) {
        guard key.hasPrefix("taool_secret_") else { return }
        let message = "That's a server key (taool_secret_…), which never belongs in an app: anyone with the app can read it. Revoke it on the app's Server Keys in the taool app, and use the key from its TaoolKit page (taool_public_…) here."
        log.fault("\(message, privacy: .public)")
        assertionFailure(message)
    }
}
