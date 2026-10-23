//! 共享契约模块：XPC 协议、版本化 DTO、状态及错误定义。
//!
//! 契约 v1 由 T05 冻结（SourceIdentity / TargetKey / FlowObservation /
//! MeasurementSource / RouteAttribution / MihomoSnapshot / CollectorBatch /
//! CollectorControl / UsageQuery / HealthSnapshot）。
//! 当前版本常量仅用于验证模块链接与测试通路，不承载任何语义。

public enum ContractVersion {
    /// 契约尚未冻结时的占位版本，T05 发布后改为 "1"。
    public static let current = "0-dev"
}
