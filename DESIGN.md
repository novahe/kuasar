# Kuasar 设计文档

## 目录
1. [项目概述](#项目概述)
2. [整体架构](#整体架构)
3. [核心组件](#核心组件)
4. [Pod 创建流程](#pod-创建流程)
5. [Pod Exec 流程](#pod-exec-流程)
6. [通信机制](#通信机制)
7. [状态管理](#状态管理)
8. [错误处理与恢复](#错误处理与恢复)

---

## 项目概述

Kuasar 是一个用 Rust 编写的多云沙箱容器运行时，提供云原生解决方案并支持多种隔离技术。该项目采用了创新的 **1:N 进程管理模型**，显著降低了资源开销并提升了性能。

### 核心特性
- **1:N 架构**: 单个 sandboxer 进程管理多个容器，相比传统的 1:1 shim 模型减少了 99% 的管理资源开销
- **多云沙箱支持**: MicroVM、应用内核、WebAssembly 和 runc 等多种隔离技术
- **快速启动**: 沙箱启动速度相比传统方法提升 2 倍
- **消除 Pause 容器**: 不需要每个 pod 的静态 pause 容器

### 工作空间结构
```
kuasar/
├── vmm/sandbox/    # 主 sandboxer 实现，负责 VM 管理
├── vmm/task/       # VM 内的 task/容器运行时（init 进程）
├── shim/           # containerd shim v2 集成
├── quark/          # 应用内核沙箱
├── wasm/           # WebAssembly 沙箱
├── runc/           # runc 集成
├── kuasarctl/      # 调试 CLI 工具
└── vmm/common/     # 共享 API 和数据结构
```

---

## 整体架构

### 通信流程图

```
┌─────────────┐      ┌─────────────┐      ┌──────────────────┐      ┌─────────────┐
│  containerd │◄────►│    shim     │◄────►│   sandboxer      │◄────►│  hypervisor │
│             │ ttrpc│  (vsock)    │ vsock│  (VM manager)    │      │  (CH/QEMU)  │
└─────────────┘      └─────────────┘      └──────────────────┘      └─────────────┘
                                                         │
                                                         │ vsock
                                                         ▼
                                                ┌──────────────────┐
                                                │  task service    │
                                                │  (in-VM agent)   │
                                                └──────────────────┘
                                                         │
                                                         │ runc/youki
                                                         ▼
                                                ┌──────────────────┐
                                                │   containers     │
                                                └──────────────────┘
```

### 分层架构

1. **接口层**: containerd shim v2 协议实现
2. **传输层**: vsock 通信（VM 内外）
3. **管理层**: sandboxer（VM 生命周期管理）
4. **执行层**: task service（容器进程管理）
5. **运行时层**: runc/youki（OCI 运行时）

---

## 核心组件

### 1. Shim（容器运行时接口）
**位置**: `shim/src/bin/containerd-shim-kuasar-vmm-v2.rs`

```rust
// 入口函数
#[tokio::main]
async fn main() {
    containerd_shim::asynchronous::run::<Service<VSockTransport>>(
        "io.containerd.kuasar.vmm.v2",
        None,
    )
    .await;
}
```

**职责**:
- 实现 containerd shim v2 接口
- 作为 containerd 和 sandboxer 之间的桥梁
- 使用 vsock 与 sandboxer 通信

### 2. Sandboxer（VM 沙箱管理器）
**位置**: `vmm/sandbox/src/sandbox.rs`

核心结构:
```rust
pub struct KuasarSandboxer<V: VM, H: Hooks<V>> {
    sandboxes: Arc<RwLock<HashMap<String, SandboxPtr<V>>>>,
    factory: V::Factory,  // VM 工厂
    hooks: H,             // 生命周期钩子
    base_dir: String,
    exit_signal: Arc<ExitSignal>,
}
```

**职责**:
- 创建和管理 VM 实例
- 管理多个 pod（sandbox）
- 处理网络配置
- 生命周期管理（创建、启动、停止）

### 3. Task Service（VM 内容器运行时）
**位置**: `vmm/task/src/main.rs`

**职责**:
- 在 VM 内运行作为 init 进程
- 管理 VM 内所有容器
- 处理 exec 请求
- 管理 I/O 流

服务注册:
```rust
// ttrpc 服务注册
let task_service = create_task_service(tx).await?;
let sandbox_service = Arc::new(SandboxService::new());
let streaming_service = STREAMING_SERVICE.clone();

task_server.add_service(create_task(task_service))?;
task_server.add_service(create_sandbox_service(sandbox_service))?;
task_server.add_service(create_streaming(streaming_service))?;
```

### 4. VM 抽象层
**位置**: `vmm/sandbox/src/vm.rs`

定义了统一的 VM 接口:
```rust
#[async_trait]
pub trait VM: Send + Sync {
    async fn start(&mut self) -> Result<i32>;
    async fn stop(&mut self, force: bool) -> Result<()>;
    async fn attach(&mut self, device: DeviceInfo) -> Result<()>;
    async fn hot_attach(&mut self, device: DeviceInfo) -> Result<()>;
    async fn hot_detach(&mut self, device: DeviceInfo) -> Result<()>;
    async fn ping(&self) -> Result<bool>;
    fn wait_channel(&self) -> Receiver<i32>;
}
```

支持的虚拟化平台:
- Cloud Hypervisor
- QEMU
- StratoVirt

---

## Pod 创建流程

### 流程概览

```
containerd → shim → sandboxer → hypervisor → VM → task service → runc
```

### 详细步骤

#### 阶段 1: 请求到达
1. **containerd** 发送 `CreateSandbox` 请求到 **shim**
2. **shim** 通过 vsock 将请求转发给 **sandboxer**

#### 阶段 2: Sandbox 创建
**文件**: `vmm/sandbox/src/sandbox.rs:279-327`

```rust
async fn create(&self, id: &str, s: SandboxOption) -> Result<()> {
    // 1. 检查 sandbox 是否已存在
    if self.sandboxes.read().await.get(id).is_some() {
        return Err(Error::AlreadyExist("sandbox".to_string()));
    }

    // 2. 创建 cgroup（资源隔离）
    let mut sandbox_cgroups = SandboxCgroup::default();
    let cgroup_parent_path = get_sandbox_cgroup_parent_path(&s.sandbox)?;
    sandbox_cgroups = SandboxCgroup::create_sandbox_cgroups(&cgroup_parent_path, &s.sandbox.id)?;
    sandbox_cgroups.update_res_for_sandbox_cgroups(&s.sandbox)?;

    // 3. 创建 VM
    let vm = self.factory.create_vm(id, &s).await?;

    // 4. 初始化 sandbox
    let mut sandbox = KuasarSandbox {
        vm,
        id: id.to_string(),
        status: SandboxStatus::Created,
        base_dir: s.base_dir,
        data: s.sandbox.clone(),
        containers: Default::default(),
        storages: vec![],
        id_generator: 0,
        network: None,
        client: Arc::new(Mutex::new(None)),
        exit_signal: Arc::new(ExitSignal::default()),
        sandbox_cgroups,
    };

    // 5. 设置 sandbox 文件（hosts, hostname, resolv.conf）
    sandbox.setup_sandbox_files().await?;

    // 6. 执行 post_create 钩子
    self.hooks.post_create(&mut sandbox).await?;

    // 7. 持久化状态
    sandbox.dump().await?;

    // 8. 保存到内存
    self.sandboxes.write().await.insert(id.to_string(), Arc::new(Mutex::new(sandbox)));
    Ok(())
}
```

#### 阶段 3: Sandbox 启动
**文件**: `vmm/sandbox/src/sandbox.rs:330-358`

```rust
async fn start(&self, id: &str) -> Result<()> {
    let sandbox_mutex = self.sandbox(id).await?;
    let mut sandbox = sandbox_mutex.lock().await;

    // 1. 执行 pre_start 钩子
    self.hooks.pre_start(&mut sandbox).await?;

    // 2. 准备网络（如果有独立网络命名空间）
    if !sandbox.data.netns.is_empty() {
        sandbox.prepare_network().await?;
    }

    // 3. 启动 VM
    if let Err(e) = sandbox.start().await {
        sandbox.destroy_network().await;
        return Err(e);
    }

    // 4. 启动监控
    monitor(sandbox_clone);

    // 5. 添加到 cgroup
    if let Err(e) = sandbox.add_to_cgroup().await {
        if let Err(re) = sandbox.stop(true).await {
            return Err(e);
        }
        sandbox.destroy_network().await;
        return Err(e);
    }

    // 6. 执行 post_start 钩子
    self.hooks.post_start(&mut sandbox).await?;

    Ok(())
}
```

#### 阶段 4: VM 启动和初始化
**文件**: `vmm/sandbox/src/sandbox.rs:587-610`

```rust
async fn start(&mut self) -> Result<()> {
    // 1. 启动 VM，获取 VM PID
    let pid = self.vm.start().await?;

    // 2. 初始化与 task service 的客户端连接
    if let Err(e) = self.init_client().await {
        self.vm.stop(true).await?;
        return Err(e);
    }

    // 3. 设置 sandbox 配置到 VM
    if let Err(e) = self.setup_sandbox().await {
        self.vm.stop(true).await?;
        return Err(e);
    }

    // 4. 启动事件转发
    self.forward_events().await;

    // 5. 更新状态
    self.status = SandboxStatus::Running(pid);
    Ok(())
}
```

#### 阶段 5: 网络配置
**文件**: `vmm/sandbox/src/sandbox.rs:775-794`

```rust
async fn prepare_network(&mut self) -> Result<()> {
    // 1. 创建网络命名空间
    // 2. 配置网络接口
    // 3. 配置路由
    // 4. 附加到 sandbox
    self.network = Some(Network::new(
        &self.data.netns,
        &self.data.network,
    )?);
    Ok(())
}
```

#### 阶段 6: 在 VM 内创建容器
**文件**: `vmm/task/src/container.rs`

1. **task service** 收到创建容器请求
2. 准备根文件系统
3. 设置存储（virtio-fs 或 9p）
4. 使用 runc 创建容器
5. 启动容器 init 进程

### 时序图

```
containerd    shim        sandboxer      hypervisor       VM        task     runc
    │           │              │              │            │         │        │
    │ Create    │              │              │            │         │        │
    ├──────────►│              │              │            │         │        │
    │           │ Create       │              │            │         │        │
    │           ├─────────────►│              │            │         │        │
    │           │              │ Create VM    │            │         │        │
    │           │              ├─────────────►│            │         │        │
    │           │              │              │ Start      │         │        │
    │           │              │              ├───────────►│         │        │
    │           │              │              │            │ Boot    │        │
    │           │              │              │            │ task    │        │
    │           │              │              │            │ service │        │
    │           │              │              │            │ Ready   │        │
    │           │              │◄─────────────┼────────────┤         │        │
    │           │              │ Connect      │            │         │        │
    │           │              │─────────────►│            │         │        │
    │           │              │ Setup        │            │         │        │
    │           │              │─────────────►│───────────►│         │        │
    │           │              │              │            │ Create  │        │
    │           │              │              │            │────────►│        │
    │           │              │              │            │         │ Start  │
    │           │              │              │            │         │───────►│
    │           │              │              │            │         │ Running│
    │           │              │◄─────────────┼────────────┼─────────┤        │
    │           │◄─────────────┤              │            │         │        │
    │◄──────────┤              │              │            │         │        │
```

---

## Pod Exec 流程

### 流程概览

Exec 流程允许在运行中的容器内执行新进程。这是一个典型的跨 VM 边界操作。

### 详细步骤

#### 阶段 1: Exec 请求发起
1. 用户执行 `kubectl exec` 或类似命令
2. **containerd** 发送 `ExecProcess` 请求到 **shim**
3. **shim** 通过 vsock 转发到 **sandboxer**
4. **sandboxer** 通过 vsock 转发到 VM 内的 **task service**

#### 阶段 2: 创建 Exec 进程
**文件**: `vmm/task/src/container.rs:316-347`

```rust
impl ProcessFactory<ExecProcess> for KuasarExecFactory {
    async fn create(&self, req: &ExecProcessRequest) -> Result<ExecProcess> {
        // 1. 获取进程规范
        let p = get_spec_from_request(req)?;

        // 2. 读取 I/O 配置
        let stdio = match read_io(&self.bundle, req.id(), Some(req.exec_id())).await {
            Ok(io) => Stdio::new(&io.stdin, &io.stdout, &io.stderr, req.terminal()),
            Err(_) => Stdio::new(req.stdin(), req.stdout(), req.stderr(), req.terminal()),
        };

        // 3. 转换 stdio 为 vsock 端点
        let stdio = convert_stdio(&stdio).await?;

        // 4. 创建 ExecProcess 实例
        Ok(ExecProcess {
            state: Status::CREATED,
            id: req.exec_id.to_string(),
            stdio,
            pid: 0,
            exit_code: 0,
            exited_at: None,
            wait_chan_tx: vec![],
            console: None,
            lifecycle: Arc::from(KuasarExecLifecycle {
                runtime: self.runtime.clone(),
                bundle: self.bundle.to_string(),
                container_id: req.id.to_string(),
                io_uid: self.io_uid,
                io_gid: self.io_gid,
                spec: p,
                exit_signal: Default::default(),
            }),
            stdin: Arc::new(Mutex::new(None)),
        })
    }
}
```

#### 阶段 3: 启动 Exec 进程
**文件**: `vmm/task/src/container.rs:476-511`

```rust
async fn start(&self, p: &mut ExecProcess) -> containerd_shim::Result<()> {
    // 1. 重新扫描 PCI 总线（设备检测）
    rescan_pci_bus().await?;

    // 2. 准备 PID 文件路径
    let bundle = self.bundle.to_string();
    let pid_path = Path::new(&bundle).join(format!("{}.pid", &p.id));

    // 3. 配置 exec 选项
    let mut exec_opts = runc::options::ExecOpts {
        io: None,
        pid_file: Some(pid_path.to_owned()),
        console_socket: None,
        detach: true,
    };

    // 4. 设置终端或 I/O
    let (socket, pio) = if p.stdio.terminal {
        // 终端模式
        let s = ConsoleSocket::new().await?;
        exec_opts.console_socket = Some(s.path.to_owned());
        (Some(s), None)
    } else {
        // 标准 I/O 模式
        let pio = create_io(&p.id, self.io_uid, self.io_gid, &p.stdio)?;
        exec_opts.io = pio.io.as_ref().cloned();
        (None, Some(pio))
    };

    // 5. 执行 runc exec
    let exec_result = self
        .runtime
        .exec(&self.container_id, &self.spec, Some(&exec_opts))
        .await;

    if let Err(e) = exec_result {
        if let Some(s) = socket {
            s.clean().await;
        }
        return Err(runtime_error(&bundle, e, "OCI runtime exec failed").await);
    }

    // 6. 复制 I/O 或设置终端
    copy_io_or_console(p, socket, pio, p.lifecycle.exit_signal.clone()).await?;

    // 7. 读取 PID
    let pid = read_file_to_str(pid_path).await?.parse::<i32>()?;
    p.pid = pid;

    // 8. 更新状态
    p.state = Status::RUNNING;
    Ok(())
}
```

#### 阶段 4: I/O 处理
**文件**: `vmm/task/src/io.rs`

I/O 处理支持两种模式:

1. **非终端模式**: 使用命名管道处理 stdin/stdout/stderr
2. **终端模式**: 使用 console socket 处理交互式会话

```rust
// I/O 流复制
async fn copy_io_or_console(
    p: &mut ExecProcess,
    socket: Option<ConsoleSocket>,
    pio: Option<PipeIo>,
    exit_signal: Arc<ExitSignal>,
) -> Result<()> {
    if let Some(s) = socket {
        // 终端模式处理
        let console = s.accept().await?;
        p.console = Some(console.clone());
        // 启动双向流复制
        tokio::spawn(async move {
            // 处理终端 I/O
        });
    } else if let Some(pio) = pio {
        // 标准 I/O 模式处理
        // 启动 stdin/stdout/stderr 复制任务
    }
    Ok(())
}
```

#### 阶段 5: 进程监控
**文件**: `vmm/task/src/task.rs:67-100`

```rust
async fn process_exits(s: Subscription, task: &TaskService<Factory, RealContainer>) {
    let containers = task.containers.clone();
    let mut s = s;
    tokio::spawn(async move {
        while let Some(e) = s.rx.recv().await {
            if let Subject::Pid(pid) = e.subject {
                let exit_code = e.exit_code;
                for (_k, cont) in containers.lock().await.iter_mut() {
                    // 检查是否是 init 进程
                    if cont.init.pid == pid {
                        if should_kill_all_on_exit(&bundle).await {
                            cont.kill(None, 9, true).await?;
                        }
                        cont.init.set_exited(exit_code).await;
                        break;
                    }

                    // 检查是否是 exec 进程
                    for (_exec_id, p) in cont.processes.iter_mut() {
                        if p.pid == pid {
                            p.set_exited(exit_code).await;
                            break;
                        }
                    }
                }
            }
        }
    });
}
```

### 时序图

```
kubectl/    containerd   shim      sandboxer   VM      task    runc
client
    │            │           │           │        │       │       │
    │ exec       │           │           │        │       │       │
    ├───────────►│           │           │        │       │       │
    │            │ Exec      │           │        │       │       │
    │            ├──────────►│           │        │       │       │
    │            │           │ Exec      │        │       │       │
    │            │           ├──────────►│        │       │       │
    │            │           │           │ Exec   │       │       │
    │            │           │           ├───────►│       │       │
    │            │           │           │        │ Create│       │
    │            │           │           │        ├──────►│       │
    │            │           │           │        │       │ Exec  │
    │            │           │           │        │       ├──────►│
    │            │           │           │        │◄─────┤       │
    │            │           │           │◄───────┤       │       │
    │            │           │◄──────────┤        │       │       │
    │            │◄─────────┤           │        │       │       │
    │ Streams   │           │           │        │       │       │
    │◄──────────►│           │           │        │       │       │
    │            │<─────────►│           │        │       │       │
    │            │           │<─────────►│        │       │       │
    │            │           │           │<──────►│       │       │
    │ (stdin)   │           │           │        │       │       │
    │──────────►│           │           │        │       │       │
    │            │─────────►│           │        │       │       │
    │            │           │─────────►│        │       │       │
    │            │           │           │───────►│       │       │
    │            │           │           │        │──────►│       │
    │ (stdout)  │           │           │        │       │       │
    │◄──────────│           │           │        │       │       │
    │            │◄─────────│           │        │       │       │
    │            │           │◄─────────│        │       │       │
    │            │           │           │◄──────┤       │       │
    │            │           │           │        │◄─────┤       │
    │ Exit      │           │           │        │       │       │
    │◄──────────│           │           │        │       │       │
```

---

## 通信机制

### vsock 通信

Kuasar 使用 vsock（virtio-vsock）作为 VM 内外的主要通信机制。

#### 通信端点

1. **shim ↔ sandboxer**: vsock 动态分配端口
2. **sandboxer ↔ task service**: vsock 端口 1024（ttrpc 服务）
3. **kuasarctl ↔ task service**: vsock 端口 1025（调试接口）

#### ttrpc 协议

ttrpc 是基于 protobuf 的 RPC 协议，专为容器环境优化。

**Sandboxer 端服务**:
```rust
// vmm/sandbox/src/bin/cloud_hypervisor/main.rs
containerd_sandbox::run(
    "kuasar-vmm-sandboxer-clh",
    &args.listen,
    &args.dir,
    sandboxer,
).await
```

**Task Service 端**:
```rust
// vmm/task/src/main.rs
task_server.add_service(create_task(task_service))?;
task_server.add_service(create_sandbox_service(sandbox_service))?;
task_server.add_service(create_streaming(streaming_service))?;
```

### API 服务

#### Task Service
- `CreateContainer`: 创建新容器
- `StartContainer`: 启动容器
- `ExecProcess`: 在容器中执行进程
- `SignalProcess`: 发送信号到进程
- `DeleteProcess`: 删除进程

#### Sandbox Service
- `SandboxStatus`: 查询 sandbox 状态
- `UpdateSandbox`: 更新 sandbox 配置

#### Streaming Service
- `IOStream`: 处理 I/O 流数据传输

---

## 状态管理

### Sandbox 状态
```rust
pub enum SandboxStatus {
    Created,
    Running(i32),  // VM PID
    Stopped(i32, i32),  // VM PID, exit code
    Paused,
}
```

### 进程状态
```rust
pub enum Status {
    CREATED,
    RUNNING,
    EXITED,
    STOPPED,
    PAUSED,
}
```

### 状态持久化

Sandbox 状态持久化到磁盘：
```rust
async fn dump(&self) -> Result<()> {
    let path = Path::new(&self.base_dir)
        .join(KUASAR_STATE_DIR)
        .join(&self.id)
        .with_extension("json");

    let json = serde_json::to_string_pretty(&self)?;
    tokio::fs::write(&path, json).await?;
    Ok(())
}
```

位置: `/run/kuasar/sandboxes/<id>.json`

---

## 错误处理与恢复

### 崩溃恢复机制

**文件**: `vmm/sandbox/src/bin/cloud_hypervisor/main.rs:56-59`

```rust
// Do recovery job
if Path::new(&args.dir).exists() {
    sandboxer.recover(&args.dir).await;
}
```

### 恢复流程

1. **扫描状态目录**: 读取所有 `*.json` 状态文件
2. **重建内存结构**: 根据 JSON 数据重建 Sandbox 对象
3. **VM 状态检查**: 通过 `ping()` 检查 VM 是否仍在运行
4. **清理孤儿资源**: 删除不再存在的 VM 相关资源
5. **重新建立连接**: 重新连接到 task service

### 错误处理策略

1. **创建失败**: 回滚已创建的资源（cgroup、网络、VM）
2. **启动失败**: 清理网络配置，停止 VM
3. **执行失败**: 返回详细错误信息到上层
4. **VM 崩溃**: 监控线程检测并更新状态为 Stopped

### 资源清理

```rust
// 停止时的清理逻辑
async fn stop(&mut self, force: bool) -> Result<()> {
    // 1. 移除所有容器
    for id in container_ids {
        self.remove_container(&id).await?;
    }

    // 2. 停止 VM
    self.vm.stop(force).await?;

    // 3. 销毁网络
    self.destroy_network().await;

    Ok(())
}
```

---

## 安全特性

1. **Cgroup 隔离**: CPU、内存、I/O 资源限制
2. **命名空间隔离**: PID、IPC、UTS、Network 命名空间
3. **设备直通**: VFIO 支持直接设备分配
4. **最小权限**: 运行时以最小权限运行
5. **密钥隔离**: 每个沙箱独立的密钥和凭证

---

## 性能优化

1. **1:N 架构**: 单个 sandboxer 管理多个容器
2. **事件驱动**: 异步 I/O 和事件处理
3. **零拷贝**: 尽可能减少数据拷贝
4. **共享文件系统**: virtio-fs 实现高效文件访问
5. **连接复用**: vsock 连接池

---

## 相关文件索引

| 功能 | 文件路径 |
|------|---------|
| Shim 入口 | `shim/src/bin/containerd-shim-kuasar-vmm-v2.rs:1` |
| Sandboxer 主逻辑 | `vmm/sandbox/src/sandbox.rs:279-610` |
| Task Service 入口 | `vmm/task/src/main.rs:1` |
| 容器管理 | `vmm/task/src/container.rs:316-555` |
| 进程监控 | `vmm/task/src/task.rs:67-100` |
| VM 抽象 | `vmm/sandbox/src/vm.rs:35-110` |
| Cloud Hypervisor 集成 | `vmm/sandbox/src/bin/cloud_hypervisor/main.rs:1` |
| I/O 处理 | `vmm/task/src/io.rs:1` |
| 网络管理 | `vmm/sandbox/src/network.rs:1` |

---

## 总结

Kuasar 通过创新的 1:N 架构和高效的通信机制，提供了一个高性能、多沙箱支持的容器运行时解决方案。其核心优势在于：

1. **极低资源开销**: 相比传统架构减少 99% 管理资源
2. **快速启动**: 2 倍于传统方案的启动速度
3. **灵活隔离**: 支持多种沙箱技术
4. **云原生集成**: 完全兼容 containerd/CRI
5. **生产就绪**: 完善的错误处理和恢复机制

本文档详细描述了 Pod 创建和 Exec 流程的实现细节，可作为理解、维护和扩展 Kuasar 的技术参考。
