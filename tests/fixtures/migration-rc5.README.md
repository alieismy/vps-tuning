# rc.5 历史迁移器测试夹具

`migration-rc5.sh` 是公开 tag `v0.2.0-rc.5` 中 `dvt-migrate.sh` 的逐字节副本，用于保留旧 schema 1 / TCP 恢复审批回归。

SHA-256：`2ffc136221d64d8dc0ea5cf3644d747cf28883ea62002fe472617bc3e9029381`。

仅由隔离 fixture 调用，不安装、不随运行资产分发。当前 schema 2 迁移由 `test_stable_migration.py` 和三组 QEMU 真实来源测试另行覆盖，旧测试通过不能证明新迁移通过。
