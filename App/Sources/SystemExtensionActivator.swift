import Foundation
import SystemExtensions
import os

/// 系统扩展激活流程（T02）。
///
/// 首次启动即提交激活请求；所有回调写入统一 subsystem 的 os_log，
/// 供验收时用 `log show --predicate 'subsystem == "com.apptrafficmonitor.mac"'` 取证。
final class SystemExtensionActivator: NSObject, OSSystemExtensionRequestDelegate {
    static let subsystem = "com.apptrafficmonitor.mac"
    private static let logger = Logger(subsystem: subsystem, category: "activation")

    private let extensionIdentifier = "com.apptrafficmonitor.mac.TrafficFilterExtension"

    func requestActivation() {
        Self.logger.notice("提交系统扩展激活请求: \(self.extensionIdentifier, privacy: .public)")
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: extensionIdentifier,
            queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    // MARK: - OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        // 开发迭代：同 team 同 bundle ID 的新版本直接替换。
        .replace
    }

    func request(_ request: OSSystemExtensionRequest, didBeginWith error: Error) {
        Self.logger.error("激活请求开始即失败: \(String(describing: error), privacy: .public)")
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Self.logger.notice("需要用户在系统设置中批准（系统扩展已进入待批准状态）")
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            Self.logger.notice("激活请求结果: completed（已激活或已替换为当前版本）")
        case .willCompleteAfterReboot:
            Self.logger.notice("激活请求结果: willCompleteAfterReboot（重启后完成）")
        @unknown default:
            Self.logger.notice("激活请求结果: \(String(describing: result), privacy: .public)")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Self.logger.error("激活请求失败: \(String(describing: error), privacy: .public)")
    }
}
