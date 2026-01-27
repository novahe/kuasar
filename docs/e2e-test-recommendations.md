# Kuasar E2E 测试改进建议

基于对 kata-containers 项目的分析，以下是 Kuasar E2E 测试的改进建议。

## 一、现状对比分析

### Kata-Containers E2E 测试架构

```
tests/
├── integration/          # 集成测试
│   ├── kubernetes/      # 70+ 个 bats 测试
│   ├── cri-containerd/
│   ├── docker/
│   ├── nerdctl/
│   └── nydus/
├── functional/           # 功能测试
│   ├── kata-agent-apis/
│   ├── kata-monitor/
│   └── tracing/
├── stability/           # 稳定性测试
│   ├── agent_stability_test.sh
│   ├── kubernetes_soak_test.sh
│   └── stressng/
└── metrics/             # 性能测试
    ├── cpu/
    ├── density/
    ├── disk/
    ├── network/
    └── storage/
```

**测试特点：**
- **框架**: Bats (Bash Automated Testing System)
- **覆盖度**: 70+ Kubernetes 场景，涵盖核心功能
- **测试类型**: 集成、功能、稳定性、性能
- **CI 集成**: GitHub Actions 自动化运行
- **工具链**: 丰富的测试辅助工具和脚本

### Kuasar E2E 测试现状

```
tests/e2e/
├── src/
│   ├── lib.rs           # 测试框架 (700 行)
│   ├── main.rs          # 二进制入口
│   └── tests.rs         # 测试用例 (200 行)
└── configs/             # 测试配置
```

**测试特点：**
- **框架**: Rust + tokio
- **覆盖度**: 仅 runc runtime 基础生命周期测试
- **测试类型**: 只有基础的集成测试
- **测试场景**: 非常有限

---

## 二、核心差距

| 维度 | Kata-Containers | Kuasar | 差距 |
|------|----------------|--------|------|
| **测试框架** | Bats + Bash | Rust + tokio | ✅ 技术选型合理，但缺少工具链 |
| **Kubernetes 集成** | 70+ 测试用例 | 0 | ❌ 完全缺失 |
| **Runtime 覆盖** | kata-runtime | 仅 runc | ⚠️  需扩展到 vmm/wasm/quark |
| **功能测试** | 全面（网络、存储、安全） | 几乎无 | ❌ 严重不足 |
| **稳定性测试** | soak/stress 测试 | 无 | ❌ 完全缺失 |
| **性能测试** | 完整的 benchmark | 无 | ❌ 完全缺失 |
| **CI 集成** | GitHub Actions | 有 Makefile.e2e | ⚠️  需完善 |

---

## 三、改进建议

### 阶段 1: 扩展基础测试覆盖（优先级：🔴 高）

#### 1.1 完善 Runtime 生命周期测试

**目标**: 覆盖所有 Kuasar runtime 的核心功能

```rust
// tests/e2e/src/runtime_tests.rs

#[tokio::test]
#[serial]
async fn test_vmm_runtime_lifecycle() {
    // VMM (Cloud Hypervisor/QEMU/StratoVirt)
    // 1. 创建 VM
    // 2. 在 VM 内创建容器
    // 3. 验证容器运行
    // 4. 清理
}

#[tokio::test]
#[serial]
async fn test_wasm_runtime_lifecycle() {
    // Wasm (WasmEdge/Wasmtime)
}

#[tokio::test]
#[serial]
async fn test_quark_runtime_lifecycle() {
    // Quark app-kernel
}
```

**验收标准**:
- [ ] 每个 runtime 至少有 1 个 lifecycle 测试
- [ ] 测试可以在本地环境稳定运行
- [ ] 测试失败时有清晰的错误信息

#### 1.2 添加错误场景测试

**参考**: kata-containers/tests/integration/kubernetes/k8s-oom.bats

```rust
#[tokio::test]
async fn test_container_oom() {
    // 1. 创建内存限制很小的容器
    // 2. 运行内存消耗型任务
    // 3. 验证容器被 OOMKilled
    // 4. 检查事件上报
}

#[tokio::test]
async fn test_container_crash_loop_backoff() {
    // 1. 创建启动即失败的容器
    // 2. 验证重启策略
    // 3. 验证 backoff 机制
}
```

**验收标准**:
- [ ] 至少覆盖 5 种常见错误场景
- [ ] 每个场景都有清晰的验证步骤

---

### 阶段 2: Kubernetes 集成测试（优先级：🔴 高）

#### 2.1 引入 Kubernetes 测试框架

**方案 A**: 使用 Rust 原生 Kubernetes 客户端

```toml
# tests/e2e/Cargo.toml
[dependencies]
kube = { version = "0.88", features = ["runtime", "client"] }
k8s-openapi = { version = "0.21", features = ["v1_29"] }
```

```rust
// tests/e2e/src/k8s_tests.rs
use kube::{Client, Api};
use k8s_openapi::api::core::v1::Pod;

#[tokio::test]
#[serial]
async fn test_kubernetes_pod_lifecycle() {
    let client = Client::try_default().await.unwrap();
    let pods: Api<Pod> = Api::default_namespaced(client);

    // 创建 pod
    let pod = create_test_pod("test-pod");
    let _ = pods.create(&Default::default(), &pod).await.unwrap();

    // 等待 Ready
    wait_for_pod_ready(&pods, "test-pod").await;

    // 验证
    let pod = pods.get("test-pod").await.unwrap();
    assert_eq!(pod.status.unwrap().phase.unwrap(), "Running");

    // 清理
    pods.delete("test-pod", &Default::default()).await.unwrap();
}
```

**方案 B**: 使用 Bats (与 kata-containers 一致)

```bash
#!/usr/bin/env bats
# tests/e2e/k8s/k8s-pod-lifecycle.bats

load "${BATS_TEST_DIRNAME}/../lib.sh"

setup() {
    setup_common || die "setup_common failed"
}

@test "Pod lifecycle" {
    pod_name="test-pod-${RANDOM}"

    # 创建 pod
    kubectl create -f "${pod_config_dir}/test-pod.yaml"

    # 等待 Ready
    kubectl wait --for=condition=Ready --timeout=$timeout pod "$pod_name"

    # 验证
    kubectl get pod "$pod_name" | grep "Running"

    # 清理
    kubectl delete pod "$pod_name"
}

teardown() {
    teardown_common
}
```

**推荐**: **方案 B (Bats)**，原因：
1. 与 kata-containers 生态一致
2. 可以复用 kata-containers 的测试用例
3. 脚本更容易维护和理解
4. 社区有大量现成的测试用例可以参考

#### 2.2 核心测试用例清单

参考 kata-containers/tests/integration/kubernetes/，实现以下测试：

| 类别 | 测试用例 | 优先级 |
|------|---------|--------|
| **基础功能** | Pod 生命周期 | 🔴 高 |
| | 容器生命周期 | 🔴 高 |
| | Exec/Attach | 🟡 中 |
| | Logs | 🟡 中 |
| **探针** | Liveness probe | 🔴 高 |
| | Readiness probe | 🔴 高 |
| | Startup probe | 🟡 中 |
| **存储** | EmptyDir | 🔴 高 |
| | HostPath | 🟡 中 |
| | ConfigMap/Secret | 🔴 高 |
| | Persistent Volume | 🟡 中 |
| **网络** | Pod 间通信 | 🔴 高 |
| | Service (ClusterIP) | 🔴 高 |
| | DNS | 🔴 高 |
| | Port Forward | 🟡 中 |
| **安全** | Security Context | 🟡 中 |
| | Seccomp | 🟡 中 |
| | AppArmor | 🟢 低 |
| **资源** | CPU 限制 | 🟡 中 |
| | 内存限制 | 🟡 中 |
| | OOM | 🔴 高 |
| **高级** | Init Containers | 🟡 中 |
| | Multi-Container Pod | 🟡 中 |
| | Job/CronJob | 🟢 低 |
| | DaemonSet | 🟢 低 |

**实现路径**:
1. **Week 1-2**: 基础功能（Pod/Container lifecycle）
2. **Week 3**: 探针和存储
3. **Week 4**: 网络和 DNS
4. **Week 5**: 安全和资源限制

---

### 阶段 3: 功能专项测试（优先级：🟡 中）

#### 3.1 网络功能测试

**参考**: kata-containers/tests/metrics/network/

```bash
#!/usr/bin/env bats
# tests/e2e/functional/network/network-latency.bats

@test "Pod network latency" {
    # 启动测试 pod
    kubectl apply -f "${testdata}/network-test-pods.yaml"

    # 运行 ping 测试
    LATENCY=$(kubectl exec pod-a -- ping -c 10 pod-b | grep "avg" | awk '{print $4}')

    # 验证延迟 < 10ms
    (( $(echo "$LATENCY < 10" | bc -l) ))
}

@test "Pod network throughput" {
    # 使用 iperf3 测试吞吐量
    kubectl apply -f "${testdata}/iperf3-server.yaml"
    kubectl apply -f "${testdata}/iperf3-client.yaml"

    THROUGHPUT=$(kubectl exec iperf-client -- iperf3 -c iperf-server -t 10 | grep "sender" | awk '{print $7}')

    # 验证吞吐量 > 1 Gbps
    (( $(echo "$THROUGHPUT > 1.0" | bc -l) ))
}
```

#### 3.2 存储功能测试

**参考**: kata-containers/tests/metrics/storage/fio_test.sh

```bash
#!/usr/bin/env bats
# tests/e2e/functional/storage/fio-performance.bats

@test "Volume IOPS" {
    kubectl apply -f "${testdata}/fio-test.yaml"

    # 运行 FIO 测试
    IOPS=$(kubectl exec fio-test -- fio --name=randread --ioengine=libaio --iodepth=16 \
        --rw=randread --bs=4k --direct=1 --size=512M --numjobs=4 --runtime=60 \
        --group_reporting --format=json | jq '.jobs[0].read.iops')

    # 验证 IOPS > 1000
    [ "$IOPS" -gt 1000 ]
}
```

#### 3.3 VMM 特定功能测试

```bash
#!/usr/bin/env bats
# tests/e2e/functional/vmm/vm-lifecycle.bats

@test "VM hotplug device" {
    # 启动 pod
    kubectl apply -f "${testdata}/pod-with-volume.yaml"

    # 验证 VM 内可以看到新设备
    VM_PID=$(get_vm_pid_for_pod "test-pod")
    DEVICE_COUNT=$(sudo nsenter -t $VM_PID -n -- ls /sys/class/block/ | wc -l)

    # 添加 volume
    kubectl apply -f "${testdata}/extra-volume.yaml"

    # 验证设备增加
    NEW_DEVICE_COUNT=$(sudo nsenter -t $VM_PID -n -- ls /sys/class/block/ | wc -l)
    [ "$NEW_DEVICE_COUNT" -gt "$DEVICE_COUNT" ]
}

@test "VM live migration" {
    # 如果支持 live migration
    # 1. 启动 VM on node1
    # 2. 迁移到 node2
    # 3. 验证容器状态保持
    # 4. 验证网络连接不中断
}
```

---

### 阶段 4: 稳定性测试（优先级：🟡 中）

#### 4.1 Soak 测试

**参考**: kata-containers/tests/stability/kubernetes_soak_test.sh

```bash
#!/bin/bash
# tests/e2e/stability/soak-test.sh

set -e

DURATION=${1:-1h}  # 默认 1 小时
POD_COUNT=${2:-100}  # 默认 100 个 pod

echo "Starting soak test: ${POD_COUNT} pods for ${DURATION}"

# 创建大量 pod
kubectl apply -f "${testdata}/soak-pods-deployment.yaml"
kubectl scale deployment soak-test --replicas=${POD_COUNT}

# 持续监控
START_TIME=$(date +%s)
END_TIME=$((START_TIME + $(duration_to_seconds $DURATION)))

while [ $(date +%s) -lt $END_TIME ]; do
    # 检查 pod 状态
    READY_COUNT=$(kubectl get pods -l app=soak-test | grep Running | wc -l)

    if [ "$READY_COUNT" -lt "$POD_COUNT" ]; then
        echo "ERROR: Only ${READY_COUNT}/${POD_COUNT} pods are running"
        kubectl get pods -l app=soak-test
        exit 1
    fi

    # 检查资源使用
    MEMORY_USAGE=$(free -m | grep Mem | awk '{print $3}')
    echo "Memory usage: ${MEMORY_USAGE}MB, Ready pods: ${READY_COUNT}/${POD_COUNT}"

    sleep 60
done

echo "Soak test passed!"
```

#### 4.2 Stress 测试

**参考**: kata-containers/tests/stability/stressng/

```bash
#!/bin/bash
# tests/e2e/stability/stress-test.sh

# CPU 压力测试
@test "CPU stress" {
    kubectl apply -f "${testdata}/stress-cpu.yaml"

    # 运行 10 分钟
    sleep 600

    # 验证系统没有崩溃
    kubectl get pods | grep stress-cpu | grep Running
}

# 内存压力测试
@test "Memory stress" {
    kubectl apply -f "${testdata}/stress-memory.yaml"

    # 运行 10 分钟
    sleep 600

    # 验证系统没有 OOM（除了预期的容器 OOM）
    kubectl get pods | grep stress-memory
}

# IO 压力测试
@test "IO stress" {
    kubectl apply -f "${testdata}/stress-io.yaml"

    # 运行 10 分钟
    sleep 600

    # 验证系统响应正常
    kubectl get nodes
}
```

---

### 阶段 5: 性能测试（优先级：🟢 低）

#### 5.1 启动时间测试

**参考**: kata-containers/tests/metrics/time/launch_times.sh

```bash
#!/bin/bash
# tests/e2e/metrics/startup-time.sh

ITERATIONS=100

echo "Measuring container startup time (${ITERATIONS} iterations)"

TOTAL_TIME=0
for i in $(seq 1 $ITERATIONS); do
    START=$(date +%s%N)

    kubectl run test-pod-${i} --image=nginx --restart=Never

    kubectl wait --for=condition=Ready pod/test-pod-${i} --timeout=30s

    END=$(date +%s%N)

    DURATION=$(( (END - START) / 1000000 ))
    TOTAL_TIME=$((TOTAL_TIME + DURATION))

    kubectl delete pod test-pod-${i}
done

AVG_TIME=$((TOTAL_TIME / ITERATIONS))
echo "Average startup time: ${AVG_TIME}ms"

# 与 baseline 对比
if [ $AVG_TIME -gt 5000 ]; then
    echo "ERROR: Startup time too high: ${AVG_TIME}ms"
    exit 1
fi
```

#### 5.2 资源开销测试

**参考**: kata-containers/tests/metrics/density/memory_usage.sh

```bash
#!/bin/bash
# tests/e2e/metrics/memory-footprint.sh

BASELINE_MEMORY=$(free -m | grep Mem | awk '{print $3}')

# 启动 100 个 pod
kubectl apply -f "${testdata}/nginx-deployment.yaml"
kubectl scale deployment nginx --replicas=100

# 等待所有 pod Ready
kubectl wait --for=condition=available deployment/nginx --timeout=5m

# 测量内存使用
PEAK_MEMORY=$(free -m | grep Mem | awk '{print $3}')

PER_POD_MEMORY=$(( (PEAK_MEMORY - BASELINE_MEMORY) / 100 ))

echo "Memory per pod: ${PER_POD_MEMORY}MB"

# 验证内存开销合理
if [ $PER_POD_MEMORY -gt 50 ]; then
    echo "ERROR: Memory per pod too high: ${PER_POD_MEMORY}MB"
    exit 1
fi
```

#### 5.3 密度测试

**参考**: kata-containers/tests/metrics/density/fast_footprint.sh

```bash
#!/bin/bash
# tests/e2e/metrics/pod-density.sh

MAX_PODS=500

echo "Testing maximum pod density"

# 逐步增加 pod 数量
for COUNT in 100 200 300 400 500; do
    echo "Scaling to ${COUNT} pods"
    kubectl scale deployment test-pods --replicas=${COUNT}

    # 等待稳定
    sleep 30

    # 检查所有 pod Ready
    READY_COUNT=$(kubectl get pods -l app=test | grep Running | wc -l)

    if [ "$READY_COUNT" -lt "$COUNT" ]; then
        echo "ERROR: Failed to reach ${COUNT} pods. Maximum: ${READY_COUNT}"
        exit 1
    fi

    echo "Successfully running ${READY_COUNT} pods"
done

echo "Pod density test passed: ${MAX_PODS} pods"
```

---

## 四、测试工具链建设

### 4.1 通用测试库

**参考**: kata-containers/tests/common.bash

```bash
# tests/e2e/lib/common.sh

# 重试机制
kubernetes_retry() {
    local retries=5
    local interval=10
    local count=0

    while [ $count -lt $retries ]; do
        kubectl "$@" && return 0
        count=$((count + 1))
        sleep $interval
    done

    return 1
}

# 等待 pod Ready
wait_for_pod() {
    local pod_name=$1
    local timeout=${2:-60}

    kubectl wait --for=condition=Ready --timeout=${timeout}s pod/$pod_name
}

# 获取 pod IP
get_pod_ip() {
    local pod_name=$1
    kubectl get pod $pod_name -o jsonpath='{.status.podIP}'
}

# 获取 VM PID (VMM 专用)
get_vm_pid() {
    local pod_name=$1

    # 查找对应的 hypervisor 进程
    ps aux | grep "pod-name=${pod_name}" | grep -v grep | awk '{print $2}'
}

# 执行命令到 VM 内部
exec_in_vm() {
    local pod_name=$1
    shift

    local vm_pid=$(get_vm_pid $pod_name)
    sudo nsenter -t $vm_pid -n -- "$@"
}
```

### 4.2 测试数据管理

```
tests/e2e/testdata/
├── pods/
│   ├── nginx-pod.yaml
│   ├── busybox-pod.yaml
│   └── stress-pod.yaml
├── deployments/
│   ├── nginx-deployment.yaml
│   └── stress-deployment.yaml
├── volumes/
│   ├── emptydir.yaml
│   ├── configmap.yaml
│   └── pvc.yaml
├── network/
│   ├── pod-to-pod.yaml
│   └── service.yaml
└── security/
    ├── privileged-pod.yaml
    └── seccomp-pod.yaml
```

### 4.3 CI/CD 集成

```yaml
# .github/workflows/e2e-tests.yml
name: E2E Tests

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  runc-e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup Rust
        uses: actions-rs/toolchain@v1
        with:
          toolchain: stable
      - name: Setup dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y containerd cri-tools
      - name: Run E2E tests
        run: |
          make setup-e2e-env
          make test-e2e-runc

  vmm-e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup VMM
        run: |
          sudo apt-get install -y cloud-hypervisor virtiofsd
          make bin/vmm-sandboxer
          make bin/vmm-task
      - name: Run VMM E2E tests
        run: |
          make test-e2e-vmm

  kubernetes-integration:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Setup Kubernetes
        uses: helm/kind-action@v1
        with:
          version: v0.20.0
      - name: Install containerd
        run: |
          sudo apt-get install -y containerd
      - name: Install Kuasar
        run: |
          make all
          make install
      - name: Run K8s E2E tests
        run: |
          cd tests/e2e/k8s
          ./run_kubernetes_tests.sh
```

---

## 五、实施路径

### Phase 1: 基础完善（1-2 周）

**目标**: 建立可运行的测试基础

- [ ] 完善所有 runtime 的 lifecycle 测试
- [ ] 添加错误场景测试（OOM、crash loop）
- [ ] 建立测试数据目录结构
- [ ] 编写通用测试库

**验收**: 所有 runtime 至少有 1 个可运行的测试

### Phase 2: Kubernetes 集成（3-4 周）

**目标**: 实现核心 Kubernetes 功能测试

- [ ] 引入 Bats 测试框架
- [ ] 实现 20 个核心测试用例
- [ ] 搭建本地测试环境
- [ ] 集成到 CI

**验收**: CI 中可以自动运行 K8s 测试

### Phase 3: 功能扩展（2-3 周）

**目标**: 覆盖网络、存储、安全功能

- [ ] 网络功能测试（延迟、吞吐、DNS）
- [ ] 存储功能测试（各种 volume 类型）
- [ ] 安全功能测试（security context、seccomp）

**验收**: 功能测试覆盖率达到 60%

### Phase 4: 稳定性和性能（2-3 周）

**目标**: 建立非功能性测试体系

- [ ] Soak 测试（长时间运行）
- [ ] Stress 测试（压力测试）
- [ ] 性能基准测试（启动时间、资源开销）

**验收**: 可以定期运行稳定性测试

### Phase 5: 持续优化（持续）

**目标**: 不断提升测试质量和效率

- [ ] 测试覆盖率分析
- [ ] 测试执行时间优化
- [ ] 测试结果可视化
- [ ] 自动化回归测试

---

## 六、关键指标

### 测试覆盖率目标

| 维度 | 当前 | 目标 | 时间 |
|------|------|------|------|
| Runtime 类型 | 1/4 | 4/4 | Phase 1 |
| K8s 核心功能 | 0% | 80% | Phase 2 |
| 功能专项 | 0% | 60% | Phase 3 |
| 稳定性测试 | 0 | ✅ | Phase 4 |
| 性能基准 | 0 | ✅ | Phase 4 |

### 质量指标

- **测试通过率**: > 95%
- **测试执行时间**: < 30 分钟
- **Flaky 测试率**: < 5%
- **测试覆盖率**: > 70%

---

## 七、资源需求

### 人力

- **测试开发**: 1-2 人
- **测试基础设施**: 0.5 人（兼职）
- **CI 维护**: 0.5 人（兼职）

### 环境

- **CI 环境**: GitHub Actions (免费)
- **测试集群**: 3-5 个节点（可选，本地也可）
- **性能测试**: 需要物理机或高性能 VM

---

## 八、总结

Kuasar 的 E2E 测试还处于早期阶段，相比 kata-containers 有很大的提升空间。建议按照上述 5 个阶段逐步推进：

1. **Phase 1**: 建立基础（1-2 周）
2. **Phase 2**: Kubernetes 集成（3-4 周）- **最重要**
3. **Phase 3**: 功能扩展（2-3 周）
4. **Phase 4**: 稳定性和性能（2-3 周）
5. **Phase 5**: 持续优化（持续）

**关键成功因素**:
- 使用 Bats 框架（与 kata-containers 对齐）
- 优先实现 Kubernetes 集成测试
- 建立自动化 CI
- 持续维护和更新测试用例

**预期收益**:
- 提升代码质量和稳定性
- 加快版本发布速度
- 减少生产环境问题
- 增强用户信心
