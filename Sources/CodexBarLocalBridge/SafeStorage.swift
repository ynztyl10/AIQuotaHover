import CommonCrypto
import Foundation
import Security

enum KeychainReadResult {
    case password(Data)
    case needsAuthorization
    case missing
}

final class SafeStorageReader {
    static let shared = SafeStorageReader()

    private let lock = NSLock()
    private var cachedKeys: [String: Data] = [:]

    private init() {}

    /// Reads an Electron `safeStorage` ("v10"...) encrypted file using macOS Login Keychain.
    /// When `interactive == false`, sets `kSecUseAuthenticationUISkip` so background refreshes
    /// NEVER trigger unexpected macOS Keychain popups.
    func decryptFile(
        candidateFiles: [URL],
        candidateServices: [String],
        interactive: Bool
    ) -> (state: String, plaintext: Data?, matchedService: String?) {
        guard let cipherData = candidateFiles
            .compactMap({ try? Data(contentsOf: $0) })
            .first(where: { $0.starts(with: Data("v10".utf8)) })
        else {
            // Check fallback plaintext .json if degraded mode was ever used
            for file in candidateFiles {
                let jsonURL = URL(fileURLWithPath: file.path + ".json")
                if let plain = try? Data(contentsOf: jsonURL), !plain.isEmpty {
                    return ("available", plain, "plaintext-fallback")
                }
            }
            return ("missing", nil, nil)
        }

        var sawAuthRequired = false

        for service in candidateServices {
            if let cachedKey = getCachedKey(for: service),
               let plain = Self.decryptV10(cipherData, symmetricKey: cachedKey)
            {
                return ("available", plain, service)
            }

            switch Self.readKeychainPassword(service: service, interactive: interactive) {
            case .password(let passwordData):
                if let key = Self.derivePBKDF2Key(password: passwordData),
                   let plain = Self.decryptV10(cipherData, symmetricKey: key)
                {
                    setCachedKey(key, for: service)
                    return ("available", plain, service)
                }
            case .needsAuthorization:
                sawAuthRequired = true
            case .missing:
                continue
            }
        }

        if sawAuthRequired {
            return ("needs_authorization", nil, nil)
        }
        return ("missing", nil, nil)
    }

    private func getCachedKey(for service: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return cachedKeys[service]
    }

    private func setCachedKey(_ key: Data, for service: String) {
        lock.lock()
        defer { lock.unlock() }
        cachedKeys[service] = key
    }

    private static let uiLock = NSLock()
    private typealias SetInteractionFn = @convention(c) (UInt8) -> OSStatus
    private typealias GetInteractionFn = @convention(c) (UnsafeMutablePointer<UInt8>) -> OSStatus
    private static let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
    private static let setInteraction: SetInteractionFn? = dlsym(rtldDefault, "SecKeychainSetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: SetInteractionFn.self) }
    private static let getInteraction: GetInteractionFn? = dlsym(rtldDefault, "SecKeychainGetUserInteractionAllowed")
        .map { unsafeBitCast($0, to: GetInteractionFn.self) }

    static func withKeychainUI<T>(allowed: Bool, _ body: () -> T) -> T {
        uiLock.lock()
        defer { uiLock.unlock() }
        guard let setInteraction, let getInteraction else { return body() }
        var prev: UInt8 = 1
        _ = getInteraction(&prev)
        _ = setInteraction(allowed ? 1 : 0)
        defer { _ = setInteraction(prev) }
        return body()
    }

    static func readKeychainPassword(service: String, interactive: Bool) -> KeychainReadResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !interactive {
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        }

        var result: AnyObject?
        let status = withKeychainUI(allowed: interactive) {
            SecItemCopyMatching(query as CFDictionary, &result)
        }
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else {
                return .missing
            }
            // Strip trailing newline if present when stored as UTF-8 string
            return .password(data)
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .needsAuthorization
        case errSecItemNotFound:
            return .missing
        default:
            return .missing
        }
    }

    /// Chromium / Electron macOS `safeStorage`:
    /// PBKDF2-HMAC-SHA1(password, salt: "saltysalt", rounds: 1003, keyLength: 16)
    static func derivePBKDF2Key(password: Data) -> Data? {
        var key = Data(count: kCCKeySizeAES128)
        let salt = Array("saltysalt".utf8)
        let keyLen = key.count
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { pwBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                    password.count,
                    salt,
                    salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    1003,
                    keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLen
                )
            }
        }
        return status == kCCSuccess ? key : nil
    }

    /// Decrypts "v10" + AES-128-CBC(iv = 16 spaces 0x20, PKCS#7 padding)
    static func decryptV10(_ cipherData: Data, symmetricKey: Data) -> Data? {
        let prefix = Data("v10".utf8)
        guard cipherData.starts(with: prefix) else { return nil }
        let body = Data(cipherData.dropFirst(prefix.count))
        guard !body.isEmpty, body.count % kCCBlockSizeAES128 == 0 else { return nil }

        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var out = Data(count: body.count + kCCBlockSizeAES128)
        let outCapacity = out.count
        var moved = 0

        let status = out.withUnsafeMutableBytes { outBytes in
            body.withUnsafeBytes { inBytes in
                symmetricKey.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress,
                        symmetricKey.count,
                        iv,
                        inBytes.baseAddress,
                        body.count,
                        outBytes.baseAddress,
                        outCapacity,
                        &moved
                    )
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        let plain = out.prefix(moved)
        // Verify valid UTF-8 JSON object
        guard (try? JSONSerialization.jsonObject(with: plain)) != nil else {
            return nil
        }
        return Data(plain)
    }
}
