# LIST02 队列回归

在项目根目录执行：

```sh
bash scripts/test_queue.sh
# 可传入独立报告目录，不覆盖默认目录：
bash scripts/test_queue.sh Tests/Integration/Reports/queue-list02-rerun
```

需要 Apple Silicon macOS 14+、Command Line Tools 和可连接 WindowServer 的图形登录会话。脚本使用独立 `/private/tmp` 临时目录，结束后清理，不启动 SiliconPlayer、不展示测试窗口、不访问屏幕或摄像头。

`run_queue_checks.py` 编译真实 PlayerCore；从当次生产 PlayerView 提取队列表格类型，从 PlayerModelAdvanced 提取队列批量方法，再与 `QueueInteractionChecks.swift` 合并测试。测试文件只提供回调计数、构造拖动输入与断言，不保存生产实现副本。完整源文件及精确编译区域 SHA256、命令、退出码、通过组数存入 `summary.json`。

核心回归含 9 组 LIST02 检查：2048 组删除/当前项组合、非连续选择保持相对顺序、插入位置补偿、过滤后的 UUID 锚点、隐藏行保留、原子拒绝非法 ID/位置、连续组拖回自身不移动、包含最后一项的非连续选择拖到末尾正确合并，以及私有拖动格式的会话/版本/重复 ID/大小/过期 ID/一万项边界。脚本同时重跑现有核心测试。

10 组原生和模型检查覆盖：真实表格工厂及 260pt 布局、多行选中后的 UUID、真实 pasteboard 私有类型、正常/过滤后的 drop 回调、Delete/Return、全选筛选结果、单项/批量菜单、原始行编号、非法/跨来源/过期/session/越界 drop。真实生产模型方法在回调计数边界确认：当前项存活时零重载、移除当前及邻居时仅一次后继加载、全移除时一次停止、无效请求不持久化。

这不等于真实鼠标/键盘手势和播放验收：Command/Shift 点击、鼠标拖动生成的 NSDraggingSession、自动滚动、插入线显示、深浅主题/VoiceOver 仍需桌面交互验收；真实 libmpv 播放项和进度保持由 app verifier 的 queue-batch 场景单独验证。模型计数测试使用真实队列方法，但 save/load/stop/persist 是仪器化边界，不实际执行 libmpv 或用户数据写入。
