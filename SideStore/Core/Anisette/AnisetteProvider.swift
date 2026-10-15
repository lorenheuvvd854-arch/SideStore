//
//  AnisetteProvider.swift
//  SideStore
//
//  Created by Magesh K on 8/9/26.
//  Copyright © 2026 SideStore. All rights reserved.
//

import Foundation
import SideSign

enum AnisetteProvider {
    static func fetch(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        // Apple now rejects the identities on-device (Android) anisette can offer: Android client info gets
        // 503 from GSA and macOS client info gets -80045. Move existing installs to a Windows ADI server once,
        // dropping the adi.pb that was provisioned by the on-device libraries.
        let migrationKey = "SideStore.windowsAnisetteServerV2"  // V2: identifier now sent base64 like iloader, re-provision once more
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            debugLog("[AnisetteProvider] Switching to remote Windows ADI anisette; resetting adi.pb")
            UserDefaults.standard.useOnDeviceAnisette = false
            AnisetteConfigManager.shared.anisetteAdiBlob = nil
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        if UserDefaults.standard.useOnDeviceAnisette {
            debugLog("[AnisetteProvider] Fetching anisette via On-Device Anisette (ODA)...")
            return try await OnDeviceAnisetteManager.shared.fetchAnisetteData()
        } else {
            debugLog("[AnisetteProvider] Fetching anisette via remote server...")
            return try await fetchRemote(handler: handler)
        }
    }

    private static func fetchRemote(handler: AnisetteServerHandler? = nil) async throws -> ALTAnisetteData {
        let serverUrlStrings = await AnisetteServersManager.shared.getActiveServerURLs()
        // Windows ADI servers are the ones Apple's sign-in still accepts (iloader 2.3.8 uses jkcoxson's); try them first.
        let preferred = ["https://ani.jkcoxson.com", "https://win.ani.sidestore.io"].compactMap { URL(string: $0) }
        let preferredHosts = Set(preferred.compactMap(\.host))
        let servers = preferred + serverUrlStrings.compactMap { URL(string: $0) }.filter { !preferredHosts.contains($0.host ?? "") }
        guard !servers.isEmpty else {
            throw AnisetteError.noServersConfigured
        }

        let startIndex = 0

        let provider = SideSign.AnisetteDataManager.shared
        let existingBlob = AnisetteConfigManager.shared.anisetteAdiBlob.flatMap { Data(base64Encoded: $0) }
        let identifier = await AnisetteConfigManager.shared.resolveDeviceIdentifier()
        let headers = await AnisetteConfigManager.shared.makeRequestHeaders()

        let (anisetteData, newAdiBlob) = try await provider.fetchAnisetteDataWithFailover(
            servers: UserDefaults.standard.disableAnisetteRotation ? [servers[startIndex]] : servers,
            startIndex: startIndex,
            identifier: identifier,
            existingAdiBlob: existingBlob,
            headers: headers,
            onError: { error in
                if let anisetteError = error as? SideSign.AnisetteError,
                   case .outdatedV1Server(let serverURL, _) = anisetteError {
                    if UserDefaults.standard.defaultServerURL == serverURL.absoluteString {
                        return true
                    }
                    if let handler = handler {
                        let shouldContinue = try await handler.warnOutdatedAnisetteServer()
                        if shouldContinue {
                            UserDefaults.standard.defaultServerURL = serverURL.absoluteString
                        }
                        return shouldContinue
                    }
                }
                return false
            },
            onSuccess: { successfulServer in
                UserDefaults.standard.menuAnisetteURL = successfulServer.absoluteString
                debugLog("[AnisetteProvider] Successfully fetched Anisette data from \(successfulServer.absoluteString)")
            }
        )

        if let freshBlob = newAdiBlob {
            AnisetteConfigManager.shared.anisetteAdiBlob = freshBlob.base64EncodedString()
        }

        return anisetteData
    }
}
