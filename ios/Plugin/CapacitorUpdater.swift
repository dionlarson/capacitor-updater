import Foundation
import SSZipArchive
import Alamofire

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
    var exist: Bool {
        return FileManager().fileExists(atPath: self.path)
    }
}
struct AppVersionDec: Decodable {
    let version: String?
    let url: String?
    let message: String?
    let major: Bool?
}
public class AppVersion: NSObject {
    var version: String = ""
    var url: String = ""
    var message: String?
    var major: Bool?
}
extension OperatingSystemVersion {
    func getFullVersion(separator: String = ".") -> String {
        return "\(majorVersion)\(separator)\(minorVersion)\(separator)\(patchVersion)"
    }
}
extension Bundle {
    var versionName: String? {
        return infoDictionary?["CFBundleShortVersionString"] as? String
    }
    var versionCode: String? {
        return infoDictionary?["CFBundleVersion"] as? String
    }
}

enum CustomError: Error {
    // Throw when an unzip fail
    case cannotUnzip

    // Throw in all other cases
    case unexpected(code: Int)
}

extension CustomError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .cannotUnzip:
            return NSLocalizedString(
                "The file cannot be unzip",
                comment: "Invalid zip"
            )
        case .unexpected(_):
            return NSLocalizedString(
                "An unexpected error occurred.",
                comment: "Unexpected Error"
            )
        }
    }
}

@objc public class CapacitorUpdater: NSObject {
    
    private var versionBuild = Bundle.main.versionName ?? ""
    private var versionCode = Bundle.main.versionCode ?? ""
    private var versionOs = ProcessInfo().operatingSystemVersion.getFullVersion()
    private var lastPathHot = ""
    private var lastPathPersist = ""
    private let basePathHot = "versions"
    private let basePathPersist = "NoCloud/ionic_built_snapshots"
    private let documentsUrl = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    private let libraryUrl = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
    
    public var statsUrl = ""
    public var appId = ""
    public var deviceID = UIDevice.current.identifierForVendor?.uuidString ?? ""
    public var notifyDownload: (Int) -> Void = { _ in }
    public var pluginVersion = "3.2.0"

    private func calcTotalPercent(percent: Int, min: Int, max: Int) -> Int {
        return (percent * (max - min)) / 100 + min;
    }
    
    private func randomString(length: Int) -> String {
        let letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        return String((0..<length).map{ _ in letters.randomElement()! })
    }
    
    // Persistent path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Library/NoCloud/ionic_built_snapshots/FOLDER
    // Hot Reload path /var/mobile/Containers/Data/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/Documents/FOLDER
    // Normal /private/var/containers/Bundle/Application/8C0C07BE-0FD3-4FD4-B7DF-90A88E12B8C3/App.app/public
    
    private func prepareFolder(source: URL) {
        if (!FileManager.default.fileExists(atPath: source.path)) {
            do {
                try FileManager.default.createDirectory(atPath: source.path, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("✨  Capacitor-updater: Cannot createDirectory \(source.path)")
            }
        }
    }
    
    private func deleteFolder(source: URL) {
        do {
            try FileManager.default.removeItem(atPath: source.path)
        } catch {
            print("✨  Capacitor-updater: File not removed. \(source.path)")
        }
    }
    
    private func unflatFolder(source: URL, dest: URL) -> Bool {
        let index = source.appendingPathComponent("index.html")
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: source.path)
            if (files.count == 1 && source.appendingPathComponent(files[0]).isDirectory && !FileManager.default.fileExists(atPath: index.path)) {
                try FileManager.default.moveItem(at: source.appendingPathComponent(files[0]), to: dest)
                return true
            } else {
                try FileManager.default.moveItem(at: source, to: dest)
                return false
            }
        } catch {
            print("✨  Capacitor-updater: File not moved. source: \(source.path) dest: \(dest.path)")
            return true
        }
    }
    
    private func saveDownloaded(sourceZip: URL, version: String, base: URL) throws {
        prepareFolder(source: base)
        let destHot = base.appendingPathComponent(version)
        let destUnZip = documentsUrl.appendingPathComponent(randomString(length: 10))
        if (!SSZipArchive.unzipFile(atPath: sourceZip.path, toDestination: destUnZip.path)) {
            throw CustomError.cannotUnzip
        }
        if (unflatFolder(source: destUnZip, dest: destHot)) {
            deleteFolder(source: destUnZip)
        }
    }

    public func getLatest(url: URL) -> AppVersion? {
        let semaphore = DispatchSemaphore(value: 0)
        let latest = AppVersion()
        let headers: HTTPHeaders = [
            "cap_platform": "ios",
            "cap_device_id": self.deviceID,
            "cap_app_id": self.appId,
            "cap_version_build": self.versionBuild,
            "cap_version_code": self.versionCode,
            "cap_version_os": self.versionOs,
            "cap_plugin_version": self.pluginVersion,
            "cap_version_name": UserDefaults.standard.string(forKey: "versionName") ?? "builtin"
        ]
        let request = AF.request(url, headers: headers)

        request.validate().responseDecodable(of: AppVersionDec.self) { response in
            switch response.result {
                case .success:
                    if let url = response.value?.url {
                        latest.url = url
                    }
                    if let version = response.value?.version {
                        latest.version = version
                    }
                    if let major = response.value?.major {
                        latest.major = major
                    }
                    if let message = response.value?.message {
                        latest.message = message
                    }
                case let .failure(error):
                    print("✨  Capacitor-updater: Error getting Latest", error )
            }
            semaphore.signal()
        }
        semaphore.wait()
        return latest.url != "" ? latest : nil
    }
    
    public func download(url: URL) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        var version: String = ""
        var mainError: NSError? = nil
        let destination: DownloadRequest.Destination = { _, _ in
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let fileURL = documentsURL.appendingPathComponent(self.randomString(length: 10))

            return (fileURL, [.removePreviousFile, .createIntermediateDirectories])
        }
        let request = AF.download(url, to: destination)
        
        request.downloadProgress { progress in
            let percent = self.calcTotalPercent(percent: Int(progress.fractionCompleted * 100), min: 10, max: 70)
            self.notifyDownload(percent)
        }
        request.responseURL { (response) in
            if let fileURL = response.fileURL {
                switch response.result {
                case .success:
                    self.notifyDownload(71);
                    version = self.randomString(length: 10)
                    do {
                        try self.saveDownloaded(sourceZip: fileURL, version: version, base: self.documentsUrl.appendingPathComponent(self.basePathHot))
                        self.notifyDownload(85);
                        try self.saveDownloaded(sourceZip: fileURL, version: version, base: self.libraryUrl.appendingPathComponent(self.basePathPersist))
                        self.notifyDownload(100);
                        self.deleteFolder(source: fileURL)
                    } catch {
                        print("✨  Capacitor-updater: download unzip error", error)
                        mainError = error as NSError
                    }
                case let .failure(error):
                    print("✨  Capacitor-updater: download error", error)
                    mainError = error as NSError
                }
            }
            semaphore.signal()
        }
        self.notifyDownload(0);
        semaphore.wait()
        if (mainError != nil) {
            throw mainError!
        }
        return version
    }

    public func list() -> [String] {
        let dest = documentsUrl.appendingPathComponent(basePathHot)
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: dest.path)
            return files
        } catch {
            print("✨  Capacitor-updater: No version available \(dest.path)")
            return []
        }
    }
    
    public func delete(version: String, versionName: String) -> Bool {
        let destHot = documentsUrl.appendingPathComponent(basePathHot).appendingPathComponent(version)
        let destPersist = libraryUrl.appendingPathComponent(basePathPersist).appendingPathComponent(version)
        do {
            try FileManager.default.removeItem(atPath: destHot.path)
        } catch {
            print("✨  Capacitor-updater: Hot Folder \(destHot.path), not removed.")
        }
        do {
            try FileManager.default.removeItem(atPath: destPersist.path)
        } catch {
            print("✨  Capacitor-updater: Folder \(destPersist.path), not removed.")
            return false
        }
        sendStats(action: "delete", version: versionName)
        return true
    }

    public func set(version: String, versionName: String) -> Bool {
        let destHot = documentsUrl.appendingPathComponent(basePathHot).appendingPathComponent(version)
        let indexHot = destHot.appendingPathComponent("index.html")
        let destHotPersist = libraryUrl.appendingPathComponent(basePathPersist).appendingPathComponent(version)
        let indexPersist = destHotPersist.appendingPathComponent("index.html")
        if (destHot.isDirectory && destHotPersist.isDirectory && indexHot.exist && indexPersist.exist) {
            UserDefaults.standard.set(destHot.path, forKey: "lastPathHot")
            UserDefaults.standard.set(destHotPersist.path, forKey: "lastPathPersist")
            UserDefaults.standard.set(versionName, forKey: "versionName")
            sendStats(action: "set", version: versionName)
            return true
        }
        sendStats(action: "set_fail", version: versionName)
        return false
    }
    
    public func getLastPathHot() -> String {
        return UserDefaults.standard.string(forKey: "lastPathHot") ?? ""
    }
    
    public func getVersionName() -> String {
        return UserDefaults.standard.string(forKey: "versionName") ?? ""
    }
    
    public func getLastPathPersist() -> String {
        return UserDefaults.standard.string(forKey: "lastPathPersist") ?? ""
    }
    
    public func reset() {
        let version = UserDefaults.standard.string(forKey: "versionName") ?? ""
        sendStats(action: "reset", version: version)
        UserDefaults.standard.set("", forKey: "lastPathHot")
        UserDefaults.standard.set("", forKey: "lastPathPersist")
        UserDefaults.standard.set("", forKey: "versionName")
        UserDefaults.standard.synchronize()
    }

    func sendStats(action: String, version: String) {
        if (statsUrl == "") { return }
        let parameters: [String: String] = [
            "platform": "ios",
            "action": action,
            "device_id": self.deviceID,
            "version_name": version,
            "version_build": self.versionBuild,
            "version_code": self.versionCode,
            "version_os": self.versionOs,
            "plugin_version": self.pluginVersion,
            "app_id": self.appId
        ]

        DispatchQueue.global(qos: .background).async {
            let _ = AF.request(self.statsUrl, method: .post,parameters: parameters, encoder: JSONParameterEncoder.default)
            print("✨  Capacitor-updater: Stats send for \(action), version \(version)")
        }
    }
    
}
