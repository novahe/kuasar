# Kuasar vmm-sandboxer 网络机制：CNI 虚机网络虚拟化与 tc 重定向

本篇文档详细介绍了 Kuasar `vmm-sandboxer` 组件中基于 CNI 网络空间创建 TAP 设备以及挂载 `tc` 规则进行双向流量镜像重定向（Redirect）的完整流程。

---

## 1. 整体流程图 (Overall Sequence Diagram)

```mermaid
sequenceDiagram
    autonumber
    participant Sandboxer as KuasarSandboxer<br/>(vmm/sandbox/src/sandbox.rs)
    participant Sandbox as KuasarSandbox<br/>(vmm/sandbox/src/sandbox.rs)
    participant Network as Network<br/>(vmm/sandbox/src/network/mod.rs)
    participant Intf as NetworkInterface (Veth)<br/>(vmm/sandbox/src/network/link.rs)
    participant OS as Linux Kernel<br/>(netlink / tc / tuntap)
    participant VM as VM Backend (e.g. Cloud Hypervisor)<br/>(vmm/sandbox/src/vm.rs)

    Note over Sandboxer,Network: Phase 1: 获取并解析 CNI 已创建的网卡与路由
    Sandboxer->>Sandbox: prepare_network()
    Sandbox->>Network: Network::new(config)
    Network->>OS: netlink 获取 netns 内的所有链路设备 (Link)
    OS-->>Network: 返回链路列表 (例如已配置的 CNI veth 网卡 'eth0')
    Network->>Network: 过滤并保存 Veth 类型的网卡为 NetworkInterface
    Network->>OS: 获取 netns 内的路由 (Route) 列表
    OS-->>Network: 返回 IPv4/IPv6 路由表项

    Note over Network,OS: Phase 2: 为 CNI 网卡创建 Twin TAP 并配置 tc 重定向规则
    Network->>Intf: prepare_attaching(netns)
    Intf->>Intf: 格式化 TAP 名称: tap_kua_{index}
    
    Note over Intf,OS: create_tap_in_netns()
    Intf->>OS: 切换至 netns 并打开 /dev/net/tun (每个 queue 打开一次)
    Intf->>OS: ioctl(TUNSETIFF) 携带 flags: IFF_TAP | IFF_NO_PI | IFF_MULTI_QUEUE | IFF_VNET_HDR
    Intf->>OS: ioctl(TUNSETPERSIST, 1) 设置 TAP 持久化
    Intf->>OS: netlink 设置 TAP MTU 并将其设置为 UP 状态

    Intf->>OS: 命令行调用: tc qdisc add dev {tap_name} ingress
    Intf->>OS: 命令行调用: tc qdisc add dev {veth_name} ingress
    Intf->>OS: 命令行调用: tc filter add dev {tap_name} parent ffff: protocol all u32 ... redirect dev {veth_name}
    Note right of OS: 将 VM 发出 (TAP ingress) 的包重定向至 CNI 网卡发送
    Intf->>OS: 命令行调用: tc filter add dev {veth_name} parent ffff: protocol all u32 ... redirect dev {tap_name}
    Note right of OS: 将外部收到 (veth ingress) 的包重定向至 TAP 以传入 VM
    Intf->>Intf: 保存 twin = Some(tap_intf)

    Note over Network,VM: Phase 3: 将 TAP 设备及其 FDs 绑定至虚机后端
    Network->>Intf: attach_to(sandbox)
    Intf->>VM: vm.attach(DeviceInfo::Tap(TapDeviceInfo))<br/>传递 TAP FDs (从 /dev/net/tun 打开的文件描述符)
    Note right of VM: 虚机后端将其作为网卡的虚拟物理后端挂载至 Guest
```

---

## 2. TAP 创建与 tc 重定向配置详细子流程 (TAP & tc Setup Flow)

```mermaid
flowchart TD
    Start["prepare_attaching(netns)"] --> IsVeth{"接口是否为 Veth 类型？"}
    
    IsVeth -- No --> Done["不处理或执行物理设备绑定"]
    IsVeth -- Yes --> Step1["① 准备 TAP 属性<br/>名称 = 'tap_kua_' + index<br/>Queue 队列数 = vcpu 数量"]

    subgraph TapCreate["② 创建 TAP 设备 (create_tap_in_netns)"]
        A1["进入 sandbox 网络命名空间 (netns)"]
        A2["循环 queue 次:<br/>1. 打开 /dev/net/tun 设备<br/>2. ioctl(TUNSETIFF) 绑定 TAP 名称<br/>Flags: IFF_TAP | IFF_NO_PI | IFF_MULTI_QUEUE | IFF_VNET_HDR"]
        A3["ioctl(fds[0], TUNSETPERSIST, 1)<br/>设置首个 queue 持久化"]
        A4["通过 netlink 获取新创建的 TAP 设备 LinkMessage 并解析"]
        A5["通过 netlink 设定 TAP MTU 并将其 Link UP (启用)"]
        A1 --> A2 --> A3 --> A4 --> A5
    end

    subgraph TcConfig["③ 挂载 tc/ingress 队列与流控重定向规则"]
        B1["在 TAP 设备上挂载 ingress qdisc:<br/>tc qdisc add dev tap_kua_{index} ingress"]
        B2["在 CNI 网卡设备上挂载 ingress qdisc:<br/>tc qdisc add dev {veth_name} ingress"]
        B3["添加 TAP -> CNI 网卡的重定向过滤规则 (Ingress -> Egress Redirect):<br/>tc filter add dev tap_kua_{index} parent ffff: protocol all u32 match u8 0 0 action mirred egress redirect dev {veth_name}"]
        B4["添加 CNI 网卡 -> TAP 的重定向过滤规则 (Ingress -> Egress Redirect):<br/>tc filter add dev {veth_name} parent ffff: protocol all u32 match u8 0 0 action mirred egress redirect dev tap_kua_{index}"]
        B1 --> B2 --> B3 --> B4
    end

    Step1 --> TapCreate
    TapCreate --> TcConfig
    TcConfig --> Step4["④ Twin 绑定<br/>self.twin = Some(tap_intf)"]
    Step4 --> Done
    
    style TapCreate fill:#ebf5fb,stroke:#3498db,stroke-width:2px,color:#2c3e50
    style TcConfig fill:#fde8e8,stroke:#e74c3c,stroke-width:2px,color:#2c3e50
    style Done fill:#e8f8f5,stroke:#2ecc71,stroke-width:2px,color:#2c3e50
```

---

## 3. 网络拓扑与双向数据转发路径 (Data Plane Topology)

在 Kuasar 虚机网络模型中，TAP 设备与 CNI 虚拟网卡（Veth）通过 `tc mirred` 机制完成了内核二层的回环流控转发。外部网络与 VM Guest 内部的通讯路径如下：

```mermaid
flowchart LR
    subgraph Host["宿主机内的 Sandbox/Pod NetNS"]
        CNI["CNI Veth 网卡<br/>(例如 eth0 / vethX)"]
        
        subgraph tc["TC 镜像重定向 (内核数据面)"]
            VethIngress["veth ingress qdisc"]
            TapIngress["tap ingress qdisc"]
        end
        
        TAP["TAP 设备<br/>(tap_kua_{index})"]
    end

    subgraph VM["虚机内 (Guest VM)"]
        Virtio["Virtio-Net 网卡后端"]
        GuestEth["Guest 内网卡 (eth0)"]
    end

    %% 入站出站路径描绘
    External["外部网络 / 宿主机 CNI 桥接"] <--> CNI
    
    %% CNI 进来的流量 -> 重定向到 TAP
    CNI -.->|"进入网卡"| VethIngress
    VethIngress -->|"tc redirect"| TAP
    
    %% TAP 进来的流量 -> 重定向到 CNI 发出
    TAP -.->|"发出 VM"| TapIngress
    TapIngress -->|"tc redirect"| CNI
    
    %% TAP 与 虚机交互
    TAP <-->|"共享内存/队列 (FD 读写)"| Virtio
    Virtio <--> GuestEth

    style CNI fill:#fef5e7,stroke:#f39c12,stroke-width:2px,color:#2c3e50
    style TAP fill:#ebf5fb,stroke:#3498db,stroke-width:2px,color:#2c3e50
    style tc fill:#fdf2e9,stroke:#d35400,stroke-width:2px,color:#2c3e50
    style Virtio fill:#f5eef8,stroke:#9b59b6,stroke-width:2px,color:#2c3e50
```

---

## 4. 关键组件与代码映射 (Key Components & Code Mapping)

| 阶段 / 动作 | 核心类与方法 | 关联源文件 | 关键职责描述 |
| :--- | :--- | :--- | :--- |
| **准备网络** | `KuasarSandboxer::start` | [sandbox.rs:L260-268](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/sandbox.rs#L260-L268) | 若 `netns` 不为空，则触发 `prepare_network` |
| **配置网络** | `KuasarSandbox::prepare_network` | [sandbox.rs:L789-808](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/sandbox.rs#L789-L808) | 收集网卡 Queue 数（对应 vcpu 数量），实例化 `Network` 并执行网卡及路由的挂载绑定 |
| **CNI 解析** | `Network::new_in_netns` | [mod.rs:L88-126](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/mod.rs#L88-L126) | 用 netlink 扫描 netns，调用 `NetworkInterface::parse_from_message` 并解析已由 CNI 创建好的 Veth / IP 地址 / 路由表 |
| **触发附加** | `Network::attach_to` | [mod.rs:L128-137](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/mod.rs#L128-L137) | 对遍历到的每个网卡，依次执行 `prepare_attaching` 和 `attach_to` |
| **流控规则设置** | `NetworkInterface::prepare_attaching` | [link.rs:L312-331](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/link.rs#L312-L331) | 入口函数：对 Veth 驱动网卡，调用 `create_tap_in_netns` 生成 TAP 设备并调用 `tc` 命令行工具配置双向 `ingress redirect` 规则 |
| **TAP 创建器** | `create_tap_in_netns` | [link.rs:L483-516](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/link.rs#L483-L516) | 封装在 netns 内新建 TAP、设置 MTU 并开启接口的动作 |
| **系统底层绑定** | `create_tap_device` | [link.rs:L526-565](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/link.rs#L526-L565) | 底层系统调用：多次打开 `/dev/net/tun` 并通过 `ioctl(TUNSETIFF)` 与 `ioctl(TUNSETPERSIST)` 持久化 TAP 描述符并获取 FDs 向量 |
| **tc ingress 挂载** | `add_qdisc_ingress` | [link.rs:L397-403](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/link.rs#L397-L403) | 执行 `tc qdisc add dev {name} ingress` |
| **tc 重定向过滤** | `add_redirect_tc_filter` | [link.rs:L405-432](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/link.rs#L405-L432) | 执行 `tc filter add ... action mirred egress redirect` 进行网卡到 TAP 设备的对流映射 |
| **绑定至 VM 后端** | `NetworkInterface::attach_to` | [link.rs:L333-388](https://github.com/kuasar-io/kuasar/blob/main/vmm/sandbox/src/network/link.rs#L333-L388) | 获取 TAP 设备的 Twin 对象，并调用 `sandbox.vm.attach` 把包含该 TAP 所有 FDs 的 `TapDeviceInfo` 移交给 VM 后端驱动。 |
