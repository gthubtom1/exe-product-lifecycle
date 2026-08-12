# 可运行回滚手册

产品: `__PRODUCT_ID__`

回滚必须指向已保存、已验证的上一条 Release 或维护版文件。不能只写“重新安装旧版”。

## 触发条件

- 启动健康检查失败: `UNVERIFIED`
- 授权或更新合同不兼容: `UNVERIFIED`
- 自定义 UI/联系方式/功能缺失: `UNVERIFIED`
- 数据迁移失败: `UNVERIFIED`

## 回滚输入

- 目标旧 Release: `UNVERIFIED`
- 完整包路径: `UNVERIFIED`
- 完整包 SHA-256: `UNVERIFIED`
- 组件清单: `../release/COMPONENT-RELEASE-MANIFEST.yaml`
- 用户数据备份: `UNVERIFIED`

## 执行命令

```powershell
# 用产品实际脚本替换占位符，并在执行前记录当前版本和 Hash。
<ROLLBACK_COMMAND>
```

## 验证命令

```powershell
<VERIFY_ROLLBACK_COMMAND>
```

记录实际输入、字面输出和退出状态：

```text
输入:
输出:
退出状态:
证据路径:
```

## 恢复关系

```text
active(old) -> update_failed(new) -> active(old)
```

- 配置/用户数据处理: `UNVERIFIED`
- 清理失败包: `UNVERIFIED`
- 保留失败证据: `required`
- 回滚后的下一步: `UNVERIFIED`
