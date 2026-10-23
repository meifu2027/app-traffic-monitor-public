//! 存储模块：系统 SQLite3 轻量封装、迁移、事务、压缩及区间查询（T09–T11 实现）。
//! 主 app 是数据库唯一写入者；扩展不直接访问数据库。

public enum StorageModule {
    public static let scope = "SQLite 唯一写入者：迁移/预编译语句/事务/WAL/30 天压缩/区间查询（T09–T11）"
}
