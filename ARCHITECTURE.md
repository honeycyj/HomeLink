# HomeLink 工程约定

## 层次与职责

| 位置 | 职责 |
| --- | --- |
| App | 原生场景、单实例入口、正常退出协调 |
| Views | 展示与交互；Components 中共用公钥、复制反馈等控件 |
| Stores | MainActor 上的可观察状态和操作协调 |
| Services | 钥匙串、设备文件、系统进程、OpenSSH 与诊断日志 |
| Models | 可传递的数据值、连接状态和存储变更类型 |
| Support | 后台执行器、授权命令、客户端进程守护 |
| Configuration | 可提交的基础构建配置，以及忽略提交的本机签名配置 |
| Tests / script | 可重复的本机服务、连接生命周期与签名验证 |

## 并发边界

界面和 Stores 保持 MainActor；可能等待系统交互的钥匙串操作、文件操作与通用子进程交给后台执行器。后台服务不直接修改 SwiftUI 状态。

DeviceFileStorage 的私有数组与修订号只允许在其串行队列中使用。添加、移除、编辑、记录连接时间通过 DeviceMutation 操作；避免在调用方先复制整个数组、等待后再覆盖存储。DeviceRepository 忽略过期修订，防止后台结果返回顺序影响界面。

设备数据继续使用原来的 JSON 数组；设备 UUID、公钥、连接参数和 Keychain 项目标识均保持兼容。

## 连接与密钥

ConnectionController 串行协调请求；SSHConnection 负责实际会话；SSHSessionResources 持有单次尝试的资源。后台钥匙串读取返回后必须检查取消状态，不能启动已经取消的连接。

临时私钥始终处于仅本人可访问的专用目录中，认证结束或失败后清理。KeyStore 不缓存设备私钥到长期文件，不将私钥写入日志。复用密钥为不同设备保留独立 Keychain 项目，删除设备不会撤销远端授权。

ProcessRunner 只执行明确的程序和参数，提供超时、取消与有限大小的错误输出。SSH 的协议与加密继续由系统 OpenSSH 实现。

## 日志

读取 SSH stderr 时只做有界内存缓冲，写盘在独立队列批量完成。退出与失败路径等待 stderr 排空并显式 flush；排错代码需要立即可用的文件时也应先 flush。日志不得包含私钥或账户密码。

## 扩展新功能

新增系统能力放在 Services，数据放在 Models，操作与状态由 Stores 协调，再接入 Views。需要用户确认的远程修改应有独立的明确动作，不能藏在查询或启动流程中。

修改后台服务后运行 `script/test_services.sh`；修改连接流程后运行 `script/test_connection_lifecycle.sh`；修改签名配置后运行 `script/test_keychain_signing.sh`。涉及新 macOS 能力时再增加相应的实机验证，避免用单元测试代替系统行为验证。

Debug 构建的 `--empty-ui-fixture` 在应用容器内新建独立空数据目录，可检查首次启动与添加界面；不会使用或覆盖真实设备 JSON。测试中生成的设备和 Keychain 项目需要在结束后按测试 UUID 清理，不能授权到真实远端设备。正式构建没有这个入口。
