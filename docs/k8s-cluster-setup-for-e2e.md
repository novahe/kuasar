# Kuasar E2E 测试：Kubernetes 集群创建指南

基于 kata-containers 的实践经验，本文档详细说明如何为 Kuasar E2E 测试创建 Kubernetes 集群。

---

## 一、Kata-Containers 的 K8s 集群创建方式分析

### 1.1 支持的 K8s 部署方式

Kata-containers 支持多种 K8s 部署方式：

| 部署方式 | 使用场景 | 复杂度 | 推荐度 |
|---------|---------|--------|--------|
| **kubeadm** | CI/CD、标准测试 | 中 | ⭐⭐⭐⭐⭐ |
| **k3s** | 轻量级测试、边缘计算 | 低 | ⭐⭐⭐⭐ |
| **k0s** | 轻量级、简单部署 | 低 | ⭐⭐⭐⭐ |
| **rke2** | 生产环境、离线部署 | 高 | ⭐⭐⭐ |
| **microk8s** | 本地开发、Ubuntu | 低 | ⭐⭐⭐ |
| **AKS** | 云端测试、完整环境 | 高 | ⭐⭐ |
| **kcli** | 多节点测试、libvirt | 高 | ⭐⭐ |

### 1.1.1 kubeadm（推荐用于 CI）

**代码位置**: `tests/gha-run-k8s-common.sh:379-411`

```bash
# 1. 添加 K8s 官方源
curl -fsSL https://pkgs.k8s.io/core:/stable:/$(curl -Ls https://dl.k8s.io/release/stable.txt | cut -d. -f-2)/deb/Release.key \
    | sudo gpg --batch --yes --no-tty --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/$(curl -Ls https://dl.k8s.io/release/stable.txt | cut -d. -f-2)/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 2. Pin 包版本（避免从其他源安装）
cat <<EOF | sudo tee /etc/apt/preferences.d/kubernetes
Package: kubelet kubeadm kubectl cri-tools kubernetes-cni
Pin: origin pkgs.k8s.io
Pin-Priority: 1000
EOF

# 3. 安装 K8s 组件
sudo apt-get update
sudo apt-get -y install kubeadm kubelet kubectl --allow-downgrades
sudo apt-mark hold kubeadm kubelet kubectl

# 4. 初始化集群
sudo kubeadm init --pod-network-cidr=10.244.0.0/16

# 5. 配置 kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 6. 部署 CNI (Flannel)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 7. 去除 master taint（允许在 master 上运行 pod）
kubectl taint nodes --all node-role.kubernetes.io/control-plane-
```

**特点**:
- ✅ 官方支持，最标准
- ✅ 版本灵活，可选择任意版本
- ✅ 适合 CI/CD 自动化
- ⚠️  需要手动配置网络插件

### 1.1.2 k3s（推荐用于本地测试）

**代码位置**: `tests/gha-run-k8s-common.sh:257-281`

```bash
# 1. 一键安装
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

# 2. 等待启动
sleep 120s

# 3. 安装标准 kubectl（避免 k3s 的兼容性问题）
ARCH=$(arch_to_golang)
kubectl_version=$(/usr/local/bin/k3s kubectl version --client=true 2>/dev/null | \
    grep "Client Version" | sed -e 's/Client Version: //' -e 's/+k3s[0-9]\+//')

sudo curl -fL --progress-bar -o /usr/bin/kubectl \
    https://dl.k8s.io/release/"${kubectl_version}"/bin/linux/"${ARCH}"/kubectl
sudo chmod +x /usr/bin/kubectl
sudo rm -rf /usr/local/bin/kubectl

# 4. 配置 kubectl
mkdir -p ~/.kube
cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
```

**特点**:
- ✅ 极简安装，一条命令搞定
- ✅ 轻量级，资源占用小
- ✅ 内置 containerd 和网络插件
- ✅ 完全兼容 K8s API
- ⚠️  版本跟随最新，可能不够灵活

### 1.1.3 k0s

**代码位置**: `tests/gha-run-k8s-common.sh:208-255`

```bash
# 1. 安装 k0s
if [[ "${CONTAINER_RUNTIME}" == "crio" ]]; then
    url=$(get_from_kata_deps ".externals.k0s.url")
    version=$(get_from_kata_deps ".externals.k0s.version")
    k0s_version_param="K0S_VERSION=${version}"
    curl -sSLf "${url}" | sudo "${k0s_version_param}" sh
else
    curl -sSLf https://get.k0s.sh | sudo sh
fi

# 2. 修改配置（修复 kube-router 端口冲突）
sudo mkdir -p /etc/k0s
k0s config create | sudo tee /etc/k0s/k0s.yaml
sudo sed -i -e "s/metricsPort: 8080/metricsPort: 9999/g" /etc/k0s/k0s.yaml

# 3. 启动单节点集群
sudo k0s install controller --single

# 4. 启动服务
sudo k0s start
sleep 120s

# 5. 配置 kubectl
ARCH=$(arch_to_golang)
kubectl_version=$(sudo k0s kubectl version 2>/dev/null | grep "Client Version" | sed -e 's/Client Version: //')
sudo curl -fL --progress-bar -o /usr/bin/kubectl \
    https://dl.k8s.io/release/"${kubectl_version}"/bin/linux/"${ARCH}"/kubectl
sudo chmod +x /usr/bin/kubectl

mkdir -p ~/.kube
sudo cp /var/lib/k0s/pki/admin.conf ~/.kube/config
sudo chown "${USER}":"${USER}" ~/.kube/config
```

**特点**:
- ✅ 纯二进制，无依赖
- ✅ 支持多种容器运行时（containerd、crio）
- ✅ 配置简单，易于管理
- ⚠️  社区相对较小

---

## 二、Kuasar E2E 测试的 K8s 集群创建方案

### 2.1 推荐方案对比

对于 Kuasar 项目，我推荐以下方案：

| 场景 | 推荐方案 | 理由 |
|------|---------|------|
| **CI/CD** | k3s | 轻量、快速、稳定 |
| **本地开发** | k3s 或 kind | 简单易用 |
| **完整测试** | kubeadm | 标准环境，灵活配置 |
| **多节点测试** | kind | 支持多节点，本地运行 |

### 2.2 方案 1: k3s（最推荐）

#### 2.2.1 完整安装脚本

```bash
#!/bin/bash
# scripts/k8s/setup-k3s.sh

set -e

echo "=== Setting up k3s cluster for Kuasar E2E tests ==="

# 1. 安装 k3s
echo "Installing k3s..."
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644

# 2. 等待 k3s 启动
echo "Waiting for k3s to be ready..."
sleep 30

# 等待 k3s 完全启动
for i in {1..30}; do
    if sudo k3s kubectl get nodes &>/dev/null; then
        echo "k3s is ready!"
        break
    fi
    echo "Waiting for k3s... ($i/30)"
    sleep 2
done

# 3. 安装标准 kubectl
echo "Installing kubectl..."
ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
K8S_VERSION=$(curl -Ls https://dl.k8s.io/release/stable.txt)

sudo curl -fL --progress-bar -o /usr/bin/kubectl \
    "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/kubectl"
sudo chmod +x /usr/bin/kubectl

# 4. 配置 kubectl
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "${USER}:${USER}" ~/.kube/config
chmod 600 ~/.kube/config

# 5. 验证集群
echo "Verifying cluster..."
kubectl version --client
kubectl version --short
kubectl get nodes
kubectl get pods -A

# 6. 等待系统 pod 就绪
echo "Waiting for system pods to be ready..."
kubectl wait --for=condition=ready --timeout=300s --all pods -n kube-system

echo "=== k3s cluster setup complete! ==="
echo "You can now run Kuasar E2E tests."
```

#### 2.2.2 卸载脚本

```bash
#!/bin/bash
# scripts/k8s/teardown-k3s.sh

echo "=== Tearing down k3s cluster ==="

# 1. 停止并卸载 k3s
sudo /usr/local/bin/k3s-uninstall.sh || true

# 2. 清理配置
sudo rm -rf /etc/rancher/k3s
sudo rm -rf /var/lib/rancher/k3s

# 3. 清理 kubectl
sudo rm -f /usr/bin/kubectl
rm -rf ~/.kube

echo "=== k3s cluster teardown complete! ==="
```

#### 2.2.3 使用方法

```bash
# 安装
make setup-k8s-cluster

# 或者直接运行
sudo bash scripts/k8s/setup-k3s.sh

# 运行测试
cd tests/e2e
bats k8s/pod-lifecycle.bats

# 清理
make teardown-k8s-cluster
```

### 2.3 方案 2: kind（适合本地开发）

#### 2.3.1 安装 kind

```bash
# 1. 安装 kind
ARCH=$(uname -m | sed 's/x86_64/amd64/' | sed 's/aarch64/arm64/')
KIND_VERSION="v0.20.0"

curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# 2. 验证
kind version
```

#### 2.3.2 创建集群

```bash
#!/bin/bash
# scripts/k8s/setup-kind.sh

set -e

echo "=== Setting up kind cluster for Kuasar E2E tests ==="

# 1. 创建集群配置
cat <<EOF > /tmp/kind-config.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    image: kindest/node:v1.29.0
  - role: worker
    image: kindest/node:v1.29.0
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF

# 2. 创建集群
kind create cluster --name kuasar-test --config=/tmp/kind-config.yaml

# 3. 加载 kuasar 镜像到 kind（如果需要）
# kind load docker-image kuasar-sandboxer:latest --name kuasar-test

# 4. 验证集群
kubectl get nodes
kubectl get pods -A

echo "=== kind cluster setup complete! ==="
```

#### 2.3.3 删除集群

```bash
#!/bin/bash
# scripts/k8s/teardown-kind.sh

kind delete cluster --name kuasar-test
```

### 2.4 方案 3: kubeadm（适合 CI）

#### 2.4.1 完整安装脚本

```bash
#!/bin/bash
# scripts/k8s/setup-kubeadm.sh

set -e

echo "=== Setting up kubeadm cluster for Kuasar E2E tests ==="

# 1. 加载内核模块
sudo modprobe overlay
sudo modprobe br_netfilter

# 2. 配置网络参数
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

# 3. 禁用 swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# 4. 安装 containerd
sudo apt-get update
sudo apt-get install -y containerd

sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# 修改 SystemdCgroup
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

sudo systemctl restart containerd
sudo systemctl enable containerd

# 5. 添加 K8s 官方源
K8S_VERSION="v1.29"
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key \
    | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" \
    | sudo tee /etc/apt/sources.list.d/kubernetes.list

# 6. 安装 K8s 组件
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# 7. 初始化集群
sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=NumCPU

# 8. 配置 kubectl
mkdir -p ~/.kube
sudo cp -i /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# 9. 安装 CNI (Flannel)
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 10. 去除 master taint
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# 11. 等待系统 pod 就绪
kubectl wait --for=condition=ready --timeout=300s --all pods -n kube-system

echo "=== kubeadm cluster setup complete! ==="
```

---

## 三、集成到 Kuasar Makefile

### 3.1 更新 Makefile.e2e

```makefile
# Makefile.e2e

K8S_PROVIDER ?= k3s  # k3s, kind, kubeadm

.PHONY: setup-k8s-cluster
setup-k8s-cluster: ## Setup Kubernetes cluster for E2E tests
	@echo "Setting up ${K8S_PROVIDER} cluster..."
	@bash scripts/k8s/setup-${K8S_PROVIDER}.sh

.PHONY: teardown-k8s-cluster
teardown-k8s-cluster: ## Teardown Kubernetes cluster
	@echo "Tearing down ${K8S_PROVIDER} cluster..."
	@bash scripts/k8s/teardown-${K8S_PROVIDER}.sh

.PHONY: test-k8s-e2e
test-k8s-e2e: setup-k8s-cluster ## Run Kubernetes E2E tests
	@echo "Running Kubernetes E2E tests..."
	@cd tests/e2e/k8s && bats *.bats
	@$(MAKE) teardown-k8s-cluster
```

### 3.2 目录结构

```
kuasar/
├── scripts/
│   └── k8s/
│       ├── setup-k3s.sh
│       ├── teardown-k3s.sh
│       ├── setup-kind.sh
│       ├── teardown-kind.sh
│       ├── setup-kubeadm.sh
│       └── teardown-kubeadm.sh
├── tests/
│   └── e2e/
│       ├── k8s/
│       │   ├── common.sh          # K8s 测试通用函数
│       │   ├── k8s-pod-lifecycle.bats
│       │   ├── k8s-network.bats
│       │   └── ...
│       └── configs/
│           └── k8s/
│               ├── nginx-pod.yaml
│               └── ...
```

---

## 四、第一个 Kubernetes 测试用例

### 4.1 测试文件

```bash
#!/usr/bin/env bats
# tests/e2e/k8s/k8s-pod-lifecycle.bats

load "${BATS_TEST_DIRNAME}/common.sh"

setup() {
    # 确保 k8s 集群可用
    kubectl get nodes &>/dev/null || die "Kubernetes cluster not available"

    # 创建测试命名空间
    kubectl create namespace kuasar-test || true
}

teardown() {
    # 清理测试资源
    kubectl delete namespace kuasar-test --ignore-not-found=true
}

@test "Pod: create and run nginx pod" {
    # 创建 pod
    kubectl run nginx \
        --image=nginx \
        --namespace=kuasar-test \
        --restart=Never

    # 等待 pod Ready
    kubectl wait --for=condition=ready --timeout=60s \
        pod/nginx -n kuasar-test

    # 验证 pod 运行中
    result=$(kubectl get pod nginx -n kuasar-test -o jsonpath='{.status.phase}')
    [ "$result" = "Running" ]

    # 删除 pod
    kubectl delete pod nginx -n kuasar-test
}

@test "Pod: execute command in running pod" {
    # 创建 pod
    kubectl run test-pod \
        --image=busybox \
        --namespace=kuasar-test \
        --restart=Never \
        --command -- sleep 300

    # 等待就绪
    kubectl wait --for=condition=ready --timeout=60s \
        pod/test-pod -n kuasar-test

    # 执行命令
    result=$(kubectl exec test-pod -n kuasar-test -- echo hello)
    [ "$result" = "hello" ]

    # 清理
    kubectl delete pod test-pod -n kuasar-test
}
```

### 4.2 通用测试库

```bash
# tests/e2e/k8s/common.sh

# 检查 K8s 集群是否可用
k8s_cluster_ready() {
    kubectl get nodes &>/dev/null && \
    kubectl get pods -n kube-system &>/dev/null
}

# 等待 pod Ready
wait_for_pod() {
    local pod_name=$1
    local namespace=${2:-default}
    local timeout=${3:-60}

    kubectl wait --for=condition=ready --timeout=${timeout}s \
        pod/${pod_name} -n ${namespace}
}

# 创建测试命名空间
create_test_namespace() {
    local ns=${1:-kuasar-test}
    kubectl create namespace ${ns} 2>/dev/null || true
}

# 清理测试命名空间
delete_test_namespace() {
    local ns=${1:-kuasar-test}
    kubectl delete namespace ${ns} --ignore-not-found=true
}

# 获取 pod IP
get_pod_ip() {
    local pod_name=$1
    local namespace=${2:-default}
    kubectl get pod ${pod_name} -n ${namespace} -o jsonpath='{.status.podIP}'
}
```

---

## 五、CI/CD 集成

### 5.1 GitHub Actions 配置

```yaml
# .github/workflows/e2e-k8s-tests.yml

name: Kubernetes E2E Tests

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

jobs:
  k8s-e2e-k3s:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Setup Go
        uses: actions/setup-go@v4
        with:
          go-version: '1.21'

      - name: Install Bats
        run: |
          sudo apt-get update
          sudo apt-get install -y bats

      - name: Setup k3s Cluster
        run: |
          make setup-k8s-cluster K8S_PROVIDER=k3s

      - name: Build Kuasar
        run: |
          make all
          make install

      - name: Run K8s E2E Tests
        run: |
          make test-k8s-e2e K8S_PROVIDER=k3s

      - name: Cleanup
        if: always()
        run: |
          make teardown-k8s-cluster K8S_PROVIDER=k3s
```

---

## 六、最佳实践

### 6.1 测试隔离

```bash
# 每个测试使用独立的命名空间
setup() {
    TEST_NS="test-$(uuidgen | cut -d'-' -f1)"
    kubectl create namespace ${TEST_NS}
    export TEST_NS
}

teardown() {
    kubectl delete namespace ${TEST_NS}
}
```

### 6.2 资源清理

```bash
# 使用 trap 确保资源被清理
trap 'kubectl delete -f test-manifest.yaml --ignore-not-found=true' EXIT
```

### 6.3 超时控制

```bash
# 为长时间操作设置超时
timeout 60s kubectl wait --for=condition=ready pod/test-pod || {
    echo "Pod not ready within timeout"
    kubectl describe pod test-pod
    return 1
}
```

### 6.4 调试信息

```bash
# 测试失败时输出调试信息
@test "Pod: should start successfully" {
    run kubectl run test-pod --image=nginx
    if [ $status -ne 0 ]; then
        echo "Failed to create pod:"
        kubectl get pods -A
        kubectl describe pod test-pod || true
        kubectl logs test-pod || true
        return 1
    fi
}
```

---

## 七、总结

### 7.1 推荐方案

| 阶段 | 推荐方案 | 理由 |
|------|---------|------|
| **当前（MVP）** | k3s | 快速上手，满足基本需求 |
| **进阶** | kind | 本地多节点测试 |
| **生产级 CI** | kubeadm | 标准环境，灵活配置 |

### 7.2 实施步骤

**Week 1**: 基础设施
- [ ] 创建 `scripts/k8s/` 目录
- [ ] 实现 k3s setup/teardown 脚本
- [ ] 更新 Makefile.e2e

**Week 2**: 测试框架
- [ ] 创建 `tests/e2e/k8s/` 目录
- [ ] 实现 `common.sh` 测试库
- [ ] 编写 3-5 个基础测试用例

**Week 3**: CI 集成
- [ ] 添加 GitHub Actions workflow
- [ ] 配置自动化测试运行
- [ ] 添加测试报告

### 7.3 预期效果

- ✅ 5 分钟内完成 K8s 集群搭建
- ✅ 测试运行时间 < 10 分钟
- ✅ CI 自动化运行 K8s E2E 测试
- ✅ 本地开发环境一键搭建

通过这套方案，Kuasar 可以快速建立起完整的 Kubernetes E2E 测试体系！
