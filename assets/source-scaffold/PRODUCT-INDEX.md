# 产品索引（源码复用·二开入口）

- `product_id`: `__PRODUCT_ID__`
- 产品名称: `__PRODUCT_NAME__`
- 入口类型: `source`（源码复用二开：需求→找同类开源参考→学写法→自实现→汇入共享下游）
- 当前状态: `SOURCE_INTAKE`
- 当前模式: `bootstrap`
- 记录日期: `__DATE__`

## 读取顺序

1. 先读本文件，确认产品编号和当前状态；
2. 再读 `STATE.yaml`，选择第一个未完成阶段（源码轨道用 `assets/lifecycle-states-source.json`）；
3. 前半段读 `source/SOURCE-INTAKE.yaml`、`source/REFERENCE-INVENTORY.yaml`、`source/CAPABILITY-MAP.yaml`；
4. 汇入共享下游后，读 `CUSTOMIZATION-MANIFEST.yaml`、`auth/`、`release/`、`tooling/`、五项政策与 `reports/`。

## 当前结论

- 已确认事实: `UNVERIFIED`
- 未确认事项: `UNVERIFIED`
- 唯一下一步: 录入需求并登记同类开源参考

## 维护与交接索引

- 需求录入: `source/SOURCE-INTAKE.yaml`
- 参考登记: `source/REFERENCE-INVENTORY.yaml`
- 能力映射: `source/CAPABILITY-MAP.yaml`
- 定制规则: `CUSTOMIZATION-MANIFEST.yaml`
- 授权交接: `auth/`
- 平台发布请求: `release/RELEASE-PUBLISH-REQUEST.md`
- 真机运行证据: `reports/RUN-EVIDENCE.yaml`
- 四类交付物: `reports/CHANGES-AND-DIFF.md`、`reports/VERIFICATION-RECORD.md`、`rollback/ROLLBACK-RUNBOOK.md` 和实际构建物/差分路径

本文件只服务于 `__PRODUCT_ID__`。源码入口不需要逆向；逆向只适用于黑盒 EXE 入口。
