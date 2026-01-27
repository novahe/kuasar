# Kubernetes Pod 功能测试覆盖清单

本文档列出了 Kubernetes Pod 的所有功能，并标记了 Kuasar 测试框架的覆盖情况。

## 已测试的功能 ✅

| 功能 | 测试文件 | 测试用例 | 状态 |
|------|---------|---------|------|
| **Pod 基础生命周期** | | | |
| - Pod 创建/删除 | k8s-pod-lifecycle.bats | Basic pod lifecycle | ✅ |
| - 自定义命令 | k8s-pod-lifecycle.bats | Pod with custom command | ✅ |
| **生命周期钩子** | | | |
| - postStart (exec) | k8s-pod-lifecycle.bats | Pod lifecycle - postStart hook | ✅ |
| - preStop (exec) | k8s-pod-lifecycle.bats | Pod lifecycle - preStop hook | ✅ |
| - postStart + preStop | k8s-pod-lifecycle.bats | both lifecycle hooks | ✅ |
| - postStart (HTTP) | k8s-pod-lifecycle.bats | HTTP postStart hook | ✅ |
| **优雅关闭** | | | |
| - terminationGracePeriodSeconds | k8s-pod-lifecycle.bats | Pod graceful termination | ✅ |
| **重启策略** | | | |
| - RestartPolicy: Never | k8s-pod-lifecycle.bats | Pod restart policy - Never | ✅ |
| - RestartPolicy: OnFailure | k8s-pod-lifecycle.bats | Pod restart policy - OnFailure | ✅ |
| **健康检查** | | | |
| - Liveness probe | k8s-liveness-probes.bats | Liveness probe | ✅ |
| - Readiness probe | k8s-liveness-probes.bats | Readiness probe | ✅ |
| **资源限制** | | | |
| - CPU/内存限制 | k8s-cpu-ns.bats | CPU and resource limits | ✅ |
| - 资源请求 | k8s-cpu-ns.bats | CPU and resource limits | ✅ |
| **卷挂载** | | | |
| - emptyDir | k8s-volume.bats | Volume mounting | ✅ |
| - 多个 emptyDir | k8s-empty-dirs.bats | Multiple emptyDir volumes | ✅ |
| - 共享卷 | k8s-shared-volume.bats | Shared volumes | ✅ |
| **环境变量** | | | |
| - 直接 value | k8s-env-comprehensive.bats | direct value | ✅ |
| - ConfigMap | k8s-env-comprehensive.bats | configMapKeyRef | ✅ |
| - Secret | k8s-env-comprehensive.bats | secretKeyRef | ✅ |
| - Downward API | k8s-env-comprehensive.bats | fieldRef | ✅ |
| - 资源引用 | k8s-env-comprehensive.bats | resourceFieldRef | ✅ |
| - envFrom ConfigMap | k8s-env-comprehensive.bats | envFrom ConfigMap | ✅ |
| - envFrom Secret | k8s-env-comprehensive.bats | envFrom Secret | ✅ |
| **ConfigMap** | | | |
| - 挂载为卷 | k8s-configmap.bats | ConfigMap for a pod | ✅ |
| - 环境变量 | k8s-configmap.bats | ConfigMap for a pod | ✅ |
| **Secret** | | | |
| - 挂载为卷 | k8s-credentials-secrets.bats | Secret for a pod | ✅ |
| - 环境变量 | k8s-credentials-secrets.bats | Secret for a pod | ✅ |
| **网络** | | | |
| - Pod 网络 | k8s-nginx-connectivity.bats | Nginx pod connectivity | ✅ |
| - Service 通讯 | k8s-service-connectivity.bats | Pod to pod via Service | ✅ |
| - ClusterIP Service | k8s-service-connectivity.bats | ClusterIP service | ✅ |
| - Headless Service | k8s-service-connectivity.bats | Headless service | ✅ |
| - 负载均衡 | k8s-service-connectivity.bats | multiple endpoints | ✅ |
| **命名空间** | | | |
| - PID 命名空间 | k8s-pid-ns.bats | PID namespace isolation | ✅ |
| - CPU 命名空间 | k8s-cpu-ns.bats | CPU namespace | ✅ |
| **安全特性** | | | |
| - Seccomp 配置 | k8s-seccomp.bats | default/localhost/unconfined | ✅ |
| - 特权容器 | k8s-seccomp.bats | privileged pod handling | ✅ |
| - Linux Capabilities | k8s-seccomp.bats | dropped/added capabilities | ✅ |
| - 只读根文件系统 | k8s-seccomp.bats | readOnlyRootFilesystem | ✅ |
| **工作负载** | | | |
| - Job | k8s-job.bats | Job completion | ✅ |
| - CronJob | k8s-cron-job.bats | CronJob creation | ✅ |
| - Deployment | 需要补充 | - | ⚠️ |
| - ReplicaSet | 需要补充 | - | ⚠️ |
| **并发测试** | | | |
| - 多 Pod 并行 | k8s-parallel.bats | Multiple pods in parallel | ✅ |
| **执行命令** | | | |
| - kubectl exec | k8s-exec.bats | exec functionality | ✅ |
| - 多命令执行 | k8s-exec.bats | multiple commands | ✅ |

## 需要补充的功能 ⚠️

### 高优先级

| 功能 | 说明 | 优先级 |
|------|------|--------|
| **Init 容器** | Pod 初始化容器 | 🔴 高 |
| **DNS 策略** | Pod DNS 策略配置 | 🔴 高 |
| **Service Account** | Pod 服务账号配置 | 🔴 高 |
| **Deployment** | 无状态应用部署 | 🟡 中 |
| **ReplicaSet** | 副本集管理 | 🟡 中 |
| **滚动更新** | 应用滚动更新 | 🟡 中 |
| **亲和性/反亲和性** | Pod 调度策略 | 🟡 中 |

### 中优先级

| 功能 | 说明 | 优先级 |
|------|------|--------|
| **容忍度 (Tolerations)** | 容忍节点污点 | 🟢 低 |
| **节点选择器** | 指定节点调度 | 🟢 低 |
| **优先级** | Pod 优先级 | 🟢 低 |
| **HostAliases** | Pod 主机别名 | 🟢 低 |
| **Overhead** | Pod 开销声明 | 🟢 低 |
| **拓扑传播约束** | 跨可用区分布 | 🟢 低 |
| **优雅期** | 不同容器的优雅期 | 🟢 低 |
| **ActiveDeadlineSeconds** | Pod 超时时间 | 🟢 低 |
| **RuntimeClass** | 运行时类使用 | ✅ 已有（默认使用） |

### 低优先级

| 功能 | 说明 | 优先级 |
|------|------|--------|
| **Pod DisruptionBudget** | 中断预算 | 🟢 低 |
| **PodSecurityPolicy** | 安全策略 | 🟢 低 |
| **Horizontal Pod Autoscaler** | 自动扩缩容 | 🟢 低 |
| **StatefulSet** | 有状态应用 | 🟢 低 |
| **DaemonSet** | 守护进程集 | 🟢 低 |
| **NetworkPolicy** | 网络策略 | 🟢 低 |

## 测试覆盖统计

- **已测试功能**: 30+ 项
- **需要补充**: 15+ 项
- **总测试文件**: 17 个
- **总测试用例**: 80+ 个

## 建议优先补充的测试

### 1. Init 容器测试（重要）
```bash
# Init 容器在主容器启动前执行
- 单个 Init 容器
- 多个 Init 容器（按顺序执行）
- Init 容器失败处理
```

### 2. DNS 策略测试（重要）
```bash
# Pod DNS 配置
- DNS 策略: ClusterFirst, Default, None
- DNS 配置: nameservers, searches, options
```

### 3. Deployment 测试（重要）
```bash
# Deployment 基础功能
- Deployment 创建/删除
- 副本管理
- 滚动更新
- 回滚
```

### 4. Service Account 测试
```bash
# 服务账号
- 自动挂载 Service Account token
- 自定义 Service Account
```
