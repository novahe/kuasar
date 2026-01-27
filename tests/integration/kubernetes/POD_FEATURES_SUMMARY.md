# Kubernetes Pod 功能测试 - 快速参考

## 已完整测试的 Pod 功能 ✅

### 生命周期管理 (k8s-pod-lifecycle.bats)
- ✅ postStart 钩子（exec 命令）
- ✅ preStop 钩子（exec 命令）
- ✅ postStart 钩子（HTTP 请求）
- ✅ 优雅关闭（terminationGracePeriodSeconds）
- ✅ 重启策略

### 安全配置 (k8s-seccomp.bats)
- ✅ Seccomp 配置（RuntimeDefault/localhost/unconfined）
- ✅ 特权容器处理
- ✅ Linux Capabilities（添加/删除）
- ✅ 只读根文件系统

### 网络通讯 (k8s-service-connectivity.bats)
- ✅ ClusterIP Service
- ✅ Headless Service
- ✅ Service DNS 解析
- ✅ 负载均衡
- ✅ 服务环境变量

### 健康检查 (k8s-liveness-probes.bats)
- ✅ Liveness probe
- ✅ Readiness probe

### 资源管理 (k8s-cpu-ns.bats)
- ✅ CPU/内存限制
- ✅ 资源请求

### 存储卷
- ✅ emptyDir (k8s-volume.bats)
- ✅ 多个 emptyDir (k8s-empty-dirs.bats)
- ✅ 共享卷 (k8s-shared-volume.bats)

### 配置注入
- ✅ ConfigMap 卷/环境变量 (k8s-configmap.bats)
- ✅ Secret 卷/环境变量 (k8s-credentials-secrets.bats)
- ✅ 所有环境变量类型 (k8s-env-comprehensive.bats)

### 工作负载
- ✅ Job (k8s-job.bats)
- ✅ CronJob (k8s-cron-job.bats)

### 命名空间隔离
- ✅ PID namespace (k8s-pid-ns.bats)
- ✅ CPU namespace (k8s-cpu-ns.bats)

### 其他功能
- ✅ kubectl exec (k8s-exec.bats)
- ✅ 并行 Pod (k8s-parallel.bats)
- ✅ 网络连通性 (k8s-nginx-connectivity.bats)

## 建议优先补充的功能

### 🔴 高优先级

1. **Init 容器** - Pod 初始化容器
2. **DNS 策略** - Pod DNS 配置
3. **Service Account** - 服务账号和权限
4. **Deployment** - 无状态应用部署和滚动更新

### 🟡 中优先级

5. **亲和性/反亲和性** - Pod 调度策略
6. **容忍度** - 节点污点容忍
7. **节点选择器** - 指定节点调度
8. **ReplicaSet** - 副本集管理

### 🟢 低优先级

9. **优先级类** - Pod 优先级和 QoS
10. **HostAliases** - Pod 主机别名
11. **Overhead** - Pod 资源开销
12. **拓扑传播约束** - 跨可用区分布

## 测试统计

- 总测试文件：17 个
- 总测试用例：45 个
- 测试覆盖功能：30+ 项

## 运行所有测试

```bash
# 运行所有 Pod 生命周期测试
make test-k8s

# 只运行 Pod 生命周期测试
cd tests/integration/kubernetes
bats k8s-pod-lifecycle.bats
```
