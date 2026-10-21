# HomeLink 工程约定

## 产品与界面约定

- 最低支持 macOS 26，使用当前 macOS SDK 的原生组件适配 macOS 27 外观。优先采用 Form、Section、GroupBox、Picker、DatePicker、Menu 和原生确认框；由系统处理材质、浅深色和控件尺寸。
- 设置、添加设备和计划编辑使用统一的系统常规尺寸按钮；普通动作通过 `SecondaryActionButtonStyle` 复用原生 bordered 样式、常规圆角矩形和默认 tint，激活、失焦及禁用时的文字和外观交由原生控件处理，不手动覆盖失焦颜色；仅「完成」使用胶囊形，主要提交动作使用 borderedProminent。复制按钮不再额外强调；按钮宽度随文案适配，不手工绘制底板。保存过程中禁止交互关闭弹层。
- 设置窗口宽度限制为 520–640 点，默认 520×600 点；绿色按钮保持当前宽度，按所在屏幕 visibleFrame 纵向放大并支持还原，不进入全屏。标题栏使用系统透明标题栏，与内容背景衔接。页面内容滚动，底部操作区固定；添加设备和编辑计划等辅助窗口仍固定尺寸。
- 设置首页只保留通用设置和功能入口；登录启动只有一处，DDNS 仅在其配置页启停。设备列表保持紧凑卡片，菜单栏保留控制中心式设备状态与操作。
- 已取消的连接中断通知、设备管理总开关、大型文件夹授权窗口和独立 SSH 安全管理页不再引入。未实现的密码登录字段已移除。
- 公钥管理只在用户明确同意后读写当前账户的授权文件，同意使用小型原生确认框。它是应用内同意，不是系统文件权限或管理员授权。
- 保留系统 OpenSSH、钥匙串、主机身份验证和原生屏幕共享；不自动修改系统共享开关、SSH 策略、代理、VPN、系统 DNS 或路由器。

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

## 可选 Studio 功能

`SettingsRootView` 负责设置导航，本机访问与 DDNS 的状态分别由 `LocalAccessStore` 和 `DDNSStore` 持有，不混入现有连接控制器。`SystemDialogs` 是原生重命名、操作同意和确认弹窗的窄 AppKit 桥接。

设备菜单行、菜单按钮样式、授权设备卡片和复制控件放在 Views/Components，添加已授权设备使用独立的 AddAuthorizedDeviceView。DevicePreferencesView 的文件与主类型同名，滚动内容与固定操作区分离。DDNS 的接口编排、凭据和配置文件存储分别维护，避免一个服务文件承担多种职责。

此分发版不启用 App Sandbox，保留代码签名和原钥匙串服务。`LocalAccessStore` 保存应用内明确同意及设备显示名称，确认框不冒充系统权限授予。同意前不读取或修改 authorized_keys，同意后在文件队列中定位当前账户并执行文件操作。`SSHPublicKey` 用类型及实际内容识别公钥，不以备注判断身份。`AuthorizedKeysFile` 对文件类型、所有者和大小进行检查，使用锁、备份、并发内容复查及原子写入，保留未知行和其他授权。界面开关不会操作系统 SSH 开关或撤销公钥。

`HomeLinkStorage` 让旧安装继续使用原容器内的应用数据，避免模式切换后出现空设备列表；新安装使用普通 Application Support。只导入设备显示名称，已取消功能的偏好不再迁移；不移动、覆盖或合并设备文件，原文件保留。单实例锁、设备数据与 DDNS 使用同一个位置解析器。

`LocalSharingDetector` 只读查询 launchd 共享服务配置、Darwin membership 服务访问列表及回环地址的协议 greeting，不发送认证信息、不请求管理员权限。本机访问没有定时轮询；仅进入页面、系统设置返回时检查（包括用户自行打开系统设置）。页面任务随离开取消，通过 Workspace 应用激活及窗口恢复焦点事件识别系统设置往返，普通应用激活不触发检查；检查期间收到返回事件只保留一次待处理刷新；完成结果缓存 5 秒，共享设置返回绕过缓存，同时最多运行一批检查。协议响应通过有界的非阻塞回环 socket 读取，收到有效 greeting 立即关闭，不再等待 nc 进程超时；每个端口最多等待约 600 毫秒，取消时退出并关闭 socket。launchd 查询仍有独立超时并支持任务取消；无法读取配置且未收到协议响应时返回未知，而不推断关闭。系统服务开启、账户访问列表、公钥管理操作同意是不同状态。`LoginAtStartupRow` 复用 `DeviceStore` 的 SMAppService 注册与真实状态，返回应用时刷新，不另存一份开关值。

`DDNSStore` 持有唯一的检查任务、计时任务和生命周期观察者，关闭、断网、睡眠或退出会取消任务；代次检查阻止过期结果再次写 DNS。`DDNSConfigurationStorage` 用修订号串行保存独立的 `ddns.json`，不更改原设备文件格式。`DDNSCredentialStore` 使用独立钥匙串服务，后台读取禁止授权弹窗。

`DDNSBackend` 分离公网检测与 Cloudflare 请求，测试可注入模拟服务。`PublicIPDetector` 使用 Amazon HTTPS 与系统 dig 向 OpenDNS 进行 IPv4 查询；主来源不足时并行查询 ipify 与 ident.me 的 IPv4 HTTPS 备用接口。至少两个有效来源一致且无任何有效结果冲突才允许继续，取消、网络变化或不足两个来源都会停止写入；不采用多数投票覆盖冲突。优先来源一致时不调用备用接口。系统代理开关、utun/Fake-IP 路由不再直接判定失败；分流是否有效需首次核对实际结果。`DDNSNetworkIdentity` 仅被动读取 SystemConfiguration 的物理接口网关与系统 ARP 表，使用网关 IP/MAC 生成 external-v2 指纹，不包含会变化的公网 IP。旧指纹需要用户重新验证，不自动覆盖绑定。UPnP、SSDP、路由器 SOAP 及其权限和本地 HTTP 例外已移除。`CloudflareDNSClient` 先只读查找指定区域的一条仅 DNS 的 A 记录，明确确认后才允许修改其 content，拒绝重定向。请求错误不记录令牌或完整 API 响应。任务取消不代表已提交的服务器写入能被撤回，不确定结果必须重新查询。

`DDNSPlan` 是独立的计划计算模型，支持间隔、每日/工作日/每周多时间点和本地时区。Task.sleep 等待截止时间，网络恢复和唤醒根据补查选项执行一次；不进行高频轮询，不安装 LaunchDaemon。

## 扩展新功能

新增系统能力放在 Services，数据放在 Models，操作与状态由 Stores 协调，再接入 Views。需要用户确认的远程修改应有独立的明确动作，不能藏在查询或启动流程中。

修改后台服务后运行 `script/test_services.sh`；修改连接流程后运行 `script/test_connection_lifecycle.sh`；修改签名配置后运行 `script/test_keychain_signing.sh`。涉及新 macOS 能力时再增加相应的实机验证，避免用单元测试代替系统行为验证。

本机访问、Cloudflare 接口或计划逻辑修改后运行 `script/test_studio_features.sh`。此脚本只使用临时授权文件和模拟接口，不操作真实公钥、令牌或 DNS。

Debug 构建的 `--empty-ui-fixture` 在 Application Support 内新建独立空数据目录，可检查首次启动与添加界面；不会使用或覆盖真实设备 JSON。测试中生成的设备和 Keychain 项目需要在结束后按测试 UUID 清理，不能授权到真实远端设备。正式构建没有这个入口。

Debug 的 `--studio-ui-fixture` 使用独立目录和偏好域，展示两台模拟已授权设备，不请求文件授权，不写真实 authorized_keys，DDNS 默认关闭。`--show-settings` 打开正常数据的设置页，`--show-local-access` 打开正常数据的本机访问页。正式构建不包含这些调试入口。
