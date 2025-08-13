#!/usr/bin/env bash
# - aks-creation-v1.sh
# このスクリプトは AKS を作成/更新し、GPU ノードプールを追加して NVIDIA GPU Operator を Helm で導入します。
# nvcr.io 用 pull secret、imagePullSecrets の型統一、各 DaemonSet のロールアウト待機、必要に応じた Azure ML 拡張の接続まで自動化します。
set -euo pipefail
IFS=$'\n\t'

# =========[ variables ]=========
REGION="japaneast"                  # NDH100/NDH200 対応リージョンに変更
RG="test02"
PPG="ppg-aks-hpc"

AKS="aks-hpc"
K8S_VERSION="1.30.7"                # サポート範囲で指定
AKS_VM_SIZE="Standard_D2as_v6"      # "Standard_D1s_v4"
GPU_VM_SIZE="Standard_NC4as_T4_v3"
VM_ZONE="2"                         # VMが対応しているゾーンを探す。1,2,3
NP_SYS="sysnp"
NP_GPU="gpunp"
SSH_KEY_LOCATION="./id_rsa.pub"     # AKSのSSHKey。設定を想定。無ければ自動生成へフォールバック

VNET_NAME="vnet-aks-hpc"
VNET_CIDR="10.0.0.0/16"
SUBNET_SYS_NAME="snet-aks-system"
SUBNET_SYS_CIDR="10.0.0.0/24"
SUBNET_GPU_NAME="snet-aks-gpu"
SUBNET_GPU_CIDR="10.0.1.0/24"

SERVICE_CIDR="10.200.0.0/24"        # AKS 管理ネットワーク（VNet とは別空間）
DNS_IP="10.200.0.10"                # 別空間で提供されるDNSアドレス

# 動作オプション
CLEAN_HOST="${CLEAN_HOST:-0}"            # 1でホスト掃除を実行（既定は0=スキップ）
DRIVER_MODE="${DRIVER_MODE:-container}"  # container|host

# NVCR 認証（Pull失敗/401対策）
NGC_API_KEY="${NGC_API_KEY:-}"           # NGC API Key を渡すと nvcr.io への pull が安定

# Helm repo（NGC 公式を既定に）
HELM_REPO_NAME="${HELM_REPO_NAME:-nvidia}"
HELM_REPO_URL="${HELM_REPO_URL:-https://helm.ngc.nvidia.com/nvidia}"
HELM_CHART_VERSION="${HELM_CHART_VERSION:-}"    # 空なら最新
GPU_NS="${GPU_NS:-gpu-operator}"

# Addon / Operator 選択
USE_STACK="${USE_STACK:-auto}"             # auto | aks-addon | operator
WAIT_ADDON_SECONDS="${WAIT_ADDON_SECONDS:-600}"
WAIT_DS_TIMEOUT="${WAIT_DS_TIMEOUT:-10m}"
WAIT_DEPLOY_TIMEOUT="${WAIT_DEPLOY_TIMEOUT:-10m}"

# taint（GPU ノードプールに付ける場合のキー/値）
GPU_TAINT_KEY="${GPU_TAINT_KEY:-sku}"
GPU_TAINT_VALUE="${GPU_TAINT_VALUE:-gpu}"
GPU_TAINT_EFFECT="${GPU_TAINT_EFFECT:-NoSchedule}"

# AML 関係 
AML_WS_RG="${AML_WS_RG:-$RG}"       # 既定は AKS RG と別なら上書き
AML_WS="aml01"                      # 空ならAML処理はスキップ
AML_MI_NAME=""                      # システム割当MIなら空のままでOK（後で自動取得）
COMPUTE_NAME="k8s01"                # Studio に出る “Azure ML Kubernetes” 名
ALLOW_INSECURE_CONNECTIONS="false"  # true=HTTP, false=HTTPS(自己署名TLS)
SSL_COMMON_NAME="aks-aml-tls.local"
SSL_SECRET_NAME="aks-aml-tls"
AML_NS="azureml"
KC_API_VER="${KC_API_VER:-2024-11-01}"  # リージョンごとに異なる。その場合には対応バージョンに修正が必要

# =========[ helpers ]=========
need() { command -v "$1" >/dev/null 2>&1 || { echo "need '$1'"; exit 127; }; }

disable_aks_gpu_addon_if_enabled() {
  # アドオンと GPU Operator の同時稼働は避ける
  local rg="$1" cluster="$2"
  local enabled
  enabled=$(az aks show -g "$rg" -n "$cluster" --query "addonProfiles.gpu.enabled" -o tsv 2>/dev/null || echo "")
  if [[ "$enabled" == "true" ]]; then
    echo "[CLEANUP] Disabling AKS GPU addon..."
    az aks disable-addons -g "$rg" -n "$cluster" --addons gpu || true
    kubectl -n kube-system delete ds nvidia-device-plugin-daemonset --ignore-not-found || true
    kubectl -n kube-system delete ds nvidia-driver-daemonset --ignore-not-found || true
  fi
}

uninstall_gpu_operator_if_installed() {
  echo "[CLEANUP] Uninstalling NVIDIA GPU Operator if present..."
  if helm -n "${GPU_NS}" ls 2>/dev/null | grep -q '^gpu-operator'; then
    helm -n "${GPU_NS}" uninstall gpu-operator || true
  fi
  kubectl -n "${GPU_NS}" delete pod --all --ignore-not-found || true
  kubectl delete ns "${GPU_NS}" --ignore-not-found || true
}

# --- AML helpers（bkスクリプト由来の強化） ---
ensure_provider_registered() {
  local rp="Microsoft.KubernetesConfiguration"
  local st
  st=$(az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || echo "")
  if [[ "$st" != "Registered" ]]; then
    echo "[AML] Registering resource provider: $rp"
    az provider register -n "$rp" >/dev/null
    for _ in {1..60}; do
      st=$(az provider show -n "$rp" --query registrationState -o tsv 2>/dev/null || echo "")
      [[ "$st" == "Registered" ]] && break
      sleep 5
    done
    echo "[AML] Provider state: $st"
  fi
}
kc_ext_show() {
  local sub="$1" rg="$2" aks="$3" api="$4"
  az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.ContainerService/managedClusters/${aks}/providers/Microsoft.KubernetesConfiguration/extensions/azureml-kubernetes?api-version=${api}" \
    --output json 2>/dev/null
}
kc_ext_put() {
  local sub="$1" rg="$2" aks="$3" api="$4" ns="$5"
  az rest --method put \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.ContainerService/managedClusters/${aks}/providers/Microsoft.KubernetesConfiguration/extensions/azureml-kubernetes?api-version=${api}" \
    --body "{\"properties\":{\"extensionType\":\"Microsoft.AzureML.Kubernetes\",\"releaseTrain\":\"stable\",\"releaseNamespace\":\"${ns}\",\"autoUpgradeMinorVersion\":true,\"configurationSettings\":{\"allowNamespaceCreation\":\"true\",\"enableTraining\":\"true\",\"enableInference\":\"true\"}}}" \
    -o none
}
kc_ext_wait_succeeded() {
  local sub="$1" rg="$2" aks="$3" api="$4"
  echo "[AML] Waiting extension provisioningState=Succeeded..."
  for _ in {1..60}; do
    local st
    st=$(az rest --method get --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${rg}/providers/Microsoft.ContainerService/managedClusters/${aks}/providers/Microsoft.KubernetesConfiguration/extensions/azureml-kubernetes?api-version=${api}" --query properties.provisioningState -o tsv 2>/dev/null || echo "")
    [[ "$st" == "Succeeded" ]] && { echo "[AML] extension: $st"; return 0; }
    sleep 10
  done
  echo "[WARN] Extension did not reach Succeeded (timeout)"; return 1
}
wait_crd_instancetype() {
  echo "[AML] Waiting for CRD instancetypes.amlarc.azureml.com ..."
  for _ in {1..120}; do kubectl get crd instancetypes.amlarc.azureml.com >/dev/null 2>&1 && { echo "[AML] CRD OK"; return 0; }; sleep 5; done
  echo "[WARN] CRD not found (timeout)"; return 1
}
rest_ws_show() {
  local sub="$1" ws_rg="$2" ws="$3"
  az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${ws_rg}/providers/Microsoft.MachineLearningServices/workspaces/${ws}?api-version=2024-04-01" \
    --output json 2>/dev/null
}
rest_compute_list() {
  local sub="$1" ws_rg="$2" ws="$3"
  az rest --method get \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${ws_rg}/providers/Microsoft.MachineLearningServices/workspaces/${ws}/computes?api-version=2024-04-01" \
    --output json 2>/dev/null
}
rest_compute_put_k8s() {
  local sub="$1" ws_rg="$2" ws="$3" name="$4" region="$5" aks_id="$6" ns="$7"
  az rest --method put \
    --url "https://management.azure.com/subscriptions/${sub}/resourceGroups/${ws_rg}/providers/Microsoft.MachineLearningServices/workspaces/${ws}/computes/${name}?api-version=2024-04-01" \
    --body "{\"location\":\"${region}\",\"properties\":{\"computeType\":\"Kubernetes\",\"resourceId\":\"${aks_id}\",\"properties\":{\"namespace\":\"${ns}\"}}}" \
    --output json 2>/dev/null
}
attach_compute_with_fallback() {
  local ws_rg="$1" ws="$2" comp="$3" aks_id="$4" ns="$5" region="$6" sub="$7"
  echo "[AML] Attaching AKS as AML Kubernetes compute: ${comp}"
  if az ml compute attach --type Kubernetes --name "$comp" \
       --resource-id "$aks_id" --workspace-name "$ws" \
       --resource-group "$ws_rg" --namespace "$ns" >/dev/null 2>&1; then
    echo "[AML] az ml compute attach: success"
  else
    echo "[WARN] az ml compute attach failed. Trying REST fallback..."
    rest_compute_put_k8s "$sub" "$ws_rg" "$ws" "$comp" "$region" "$aks_id" "$ns" >/dev/null \
      && echo "[AML] REST compute attach PUT: sent" \
      || echo "[ERROR] REST compute attach failed"
  fi
  # verify
  rest_compute_list "$sub" "$ws_rg" "$ws" \
    | jq -r '.value[] | "\(.name)\t\(.properties.computeType)\t\(.properties.provisioningState)"' \
    | awk 'BEGIN{print "name\ttype\tstate"}{print}' \
    || true
}

# =========[ pre-check ]=========
need az; need kubectl; need helm; need jq; need openssl

# =========[ resource group / PPG ]=========
az group show -n "$RG" >/dev/null 2>&1 || az group create -n "$RG" -l "$REGION" >/dev/null
if ! az ppg show -g "$RG" -n "$PPG" >/dev/null 2>&1; then
  az ppg create -g "$RG" -n "$PPG" -l "$REGION" --type Standard >/dev/null
fi
PPG_ID=$(az ppg show -g "$RG" -n "$PPG" --query id -o tsv)

# =========[ networking ]=========
if ! az network vnet show -g "$RG" -n "$VNET_NAME" >/dev/null 2>&1; then
  az network vnet create -g "$RG" -n "$VNET_NAME" -l "$REGION" --address-prefixes "$VNET_CIDR" >/dev/null
fi
if ! az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_SYS_NAME" >/dev/null 2>&1; then
  az network vnet subnet create -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_SYS_NAME" --address-prefixes "$SUBNET_SYS_CIDR" >/dev/null
fi
if ! az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_GPU_NAME" >/dev/null 2>&1; then
  az network vnet subnet create -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_GPU_NAME" --address-prefixes "$SUBNET_GPU_CIDR" >/dev/null
fi
SUBNET_SYS_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_SYS_NAME" --query id -o tsv)
SUBNET_GPU_ID=$(az network vnet subnet show -g "$RG" --vnet-name "$VNET_NAME" -n "$SUBNET_GPU_NAME" --query id -o tsv)

# =========[ AKS (system pool) ]=========
SSH_ARGS=()
if [[ -f "$SSH_KEY_LOCATION" ]]; then SSH_ARGS=(--ssh-key-value "$SSH_KEY_LOCATION"); else SSH_ARGS=(--generate-ssh-keys); fi

if ! az aks show -g "$RG" -n "$AKS" >/dev/null 2>&1; then
  az aks create -g "$RG" -n "$AKS" -l "$REGION" \
    --kubernetes-version "$K8S_VERSION" \
    --nodepool-name "$NP_SYS" \
    --node-count 3 \
    --node-vm-size "$AKS_VM_SIZE" \
    --os-sku Ubuntu \
    --vnet-subnet-id "$SUBNET_SYS_ID" \
    --network-plugin azure \
    --service-cidr "$SERVICE_CIDR" \
    --dns-service-ip "$DNS_IP" \
    --enable-managed-identity \
    --zones "$VM_ZONE" \
    "${SSH_ARGS[@]}"
else
  echo "[INFO] 既存 AKS クラスタを利用します: $AKS"
fi

# =========[ GPU node pool ]=========
UPGRADE_ARGS=()
if az aks nodepool add --help 2>/dev/null | grep -q "upgrade-settings"; then UPGRADE_ARGS=(--upgrade-settings maxSurge=0); fi

if ! az aks nodepool show -g "$RG" --cluster-name "$AKS" -n "$NP_GPU" >/dev/null 2>&1; then
  az aks nodepool add -g "$RG" --cluster-name "$AKS" \
    -n "$NP_GPU" \
    --node-vm-size "$GPU_VM_SIZE" \
    --node-count 2 \
    --os-sku Ubuntu \
    --vnet-subnet-id "$SUBNET_GPU_ID" \
    --ppg "$PPG_ID" \
    --labels nodepool="$NP_GPU" role=gpu \
    --node-taints ${GPU_TAINT_KEY}=${GPU_TAINT_VALUE}:${GPU_TAINT_EFFECT} \
    --max-pods 110 \
    --zones "$VM_ZONE" \
    "${UPGRADE_ARGS[@]}"
else
  echo "[INFO] 既存 GPU ノードプールを利用します: $NP_GPU"
fi

# =========[ kubeconfig / wait nodes ]=========
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
echo "[INFO] Waiting for GPU nodes to be Ready..."
kubectl wait --for=condition=Ready node -l agentpool="$NP_GPU" --timeout=900s || true
kubectl get nodes -o wide

# =========[ Try AKS GPU addon first ]=========
STACK_CHOSEN=""
if [[ "$USE_STACK" == "aks-addon" || "$USE_STACK" == "auto" ]]; then
  echo "[INFO] Trying to enable AKS NVIDIA addon..."
  if az aks enable-addons -g "$RG" -n "$AKS" --addons gpu >/dev/null 2>&1; then
    uninstall_gpu_operator_if_installed
    echo "[INFO] AKS GPU addon enabled."
    STACK_CHOSEN="aks-addon"
    # addon の DS は 'sku=gpu' taint を許容しないので外す
    echo "[INFO] Removing taint '${GPU_TAINT_KEY}=${GPU_TAINT_VALUE}:${GPU_TAINT_EFFECT}' from GPU nodes for addon..."
    kubectl taint nodes -l "agentpool=${NP_GPU}" "${GPU_TAINT_KEY}-" || true

    # allocatable GPU 出現待ち
    echo "[INFO] Waiting for allocatable GPUs to appear (addon path)..."
    end=$((SECONDS + WAIT_ADDON_SECONDS))
    while :; do
      not_ok=0
      while read -r name alloc; do
        [[ -z "$name" ]] && continue
        if [[ -z "$alloc" || "$alloc" == "<none>" ]]; then
          not_ok=$((not_ok + 1))
        fi
      done < <(kubectl get node -l "agentpool=${NP_GPU}" \
                  -o custom-columns=NAME:.metadata.name,ALLOC:.status.allocatable.nvidia\.com/gpu --no-headers)
      if [[ $not_ok -eq 0 ]]; then
        echo "[INFO] Allocatable GPU detected on all GPU nodes (addon)."
        break
      fi
      [[ $SECONDS -gt $end ]] && { echo "[ERROR] addon path: GPUs not allocatable in time"; exit 1; }
      sleep 10
    done
  else
    echo "[INFO] AKS addon unavailable. Will fallback to NVIDIA GPU Operator."
  fi
fi

# =========[ If addon failed -> install NVIDIA GPU Operator ]=========
if [[ -z "$STACK_CHOSEN" && ( "$USE_STACK" == "operator" || "$USE_STACK" == "auto" ) ]]; then
  STACK_CHOSEN="operator"
fi

if [[ "$STACK_CHOSEN" == "operator" ]]; then
  echo "[INFO] AKS addon unavailable. Falling back to NVIDIA GPU Operator (with driver)."

  # --- (optional) Clean preinstalled NVIDIA bits on GPU nodes ---
  if [[ "$CLEAN_HOST" == "1" ]]; then
    GPU_NODES=$(kubectl get nodes -l agentpool="$NP_GPU" -o name | sed 's#node/##')
    for NODE in $GPU_NODES; do
      echo "[CLEAN] $NODE"
      timeout 180s kubectl debug node/"$NODE" --profile=general --image=ubuntu -- bash -lc '
      set -eux
      [ -d /host ] || mkdir -p /host
      mount | grep -q " on /host " || mount --bind / /host
      chroot /host bash -lc "
        set -eux
        export DEBIAN_FRONTEND=noninteractive
        apt-get update || true
        apt-get -y purge \"nvidia-*\" \"cuda-*\" \"libnvidia-*\" \"xserver-xorg-video-nvidia*\" || true
        rm -rf /usr/src/nvidia* /var/lib/dkms/nvidia*
        find /lib/modules/\$(uname -r) -name \"nvidia*.ko*\" -delete || true
        rm -f /usr/bin/nvidia-smi || true
        depmod -a
      "
'
    done
  fi

  # --- egress quick check (nvcr.io) ※ 401 でも到達としてOK ---
  kubectl delete pod egress-check --ignore-not-found >/dev/null 2>&1 || true
  kubectl run egress-check --restart=Never --image=curlimages/curl:8.8.0 \
    --command -- sh -lc 'code=$(curl -sI https://nvcr.io | awk "NR==1{print \$2}"); echo HTTP:$code; [ -n "$code" ] && echo OK || echo NG' || true
  kubectl wait --for=condition=Completed pod/egress-check --timeout=60s 2>/dev/null || true
  kubectl logs egress-check || true
  kubectl delete pod egress-check --ignore-not-found >/dev/null 2>&1 || true

  # --- Namespace & nvcr.io pull secret ---
  kubectl create namespace "${GPU_NS}" --dry-run=client -o yaml | kubectl apply -f -
  if [[ -n "${NGC_API_KEY}" ]]; then
    echo "[INFO] Creating imagePull secret 'nvcr-creds' in namespace ${GPU_NS}"
    kubectl -n "${GPU_NS}" delete secret nvcr-creds --ignore-not-found
    kubectl -n "${GPU_NS}" create secret docker-registry nvcr-creds \
      --docker-server=nvcr.io --docker-username='$oauthtoken' --docker-password="${NGC_API_KEY}"
  else
    echo "[WARN] NGC_API_KEY is empty. Pull from nvcr.io may fail with 401 / rate limit."
  fi

  # --- Helm repo（NGC 公式） ---
  helm repo remove "${HELM_REPO_NAME}" >/dev/null 2>&1 || true
  helm repo add "${HELM_REPO_NAME}" "${HELM_REPO_URL}"
  helm repo update >/dev/null

  disable_aks_gpu_addon_if_enabled "$RG" "$AKS"

  # --- Values（GPU プール固定＋taint 許容） ---
  cat > /tmp/gpu-operator-values.yaml <<YAML
# --- Allow taints globally for all DS (including driver) ---
daemonsets:
  tolerations:
    - key: nvidia.com/gpu
      operator: Exists
      effect: NoSchedule
    - key: "${GPU_TAINT_KEY}"
      operator: "Equal"
      value: "${GPU_TAINT_VALUE}"
      effect: "${GPU_TAINT_EFFECT}"

# --- NFD (v25.x: node-feature-discovery ブロック) ---
node-feature-discovery:
  worker:
    nodeSelector:
      kubernetes.azure.com/agentpool: ${NP_GPU}
    tolerations:
      - key: "${GPU_TAINT_KEY}"
        operator: "Equal"
        value: "${GPU_TAINT_VALUE}"
        effect: "${GPU_TAINT_EFFECT}"
  master:
    nodeSelector:
      kubernetes.azure.com/agentpool: ${NP_GPU}
    tolerations:
      - key: "${GPU_TAINT_KEY}"
        operator: "Equal"
        value: "${GPU_TAINT_VALUE}"
        effect: "${GPU_TAINT_EFFECT}"
  gc:
    nodeSelector:
      kubernetes.azure.com/agentpool: ${NP_GPU}
    tolerations:
      - key: "${GPU_TAINT_KEY}"
        operator: "Equal"
        value: "${GPU_TAINT_VALUE}"
        effect: "${GPU_TAINT_EFFECT}"

gfd:
  enabled: false

operator:
  defaultRuntime: containerd
  nodeSelector:
    kubernetes.azure.com/agentpool: ${NP_GPU}
  tolerations:
    - key: "${GPU_TAINT_KEY}"
      operator: "Equal"
      value: "${GPU_TAINT_VALUE}"
      effect: "${GPU_TAINT_EFFECT}"

driver:
  enabled: true
  # type: host   # Secure Boot で containerized driver が失敗するなら有効化
  nodeSelector:
    kubernetes.azure.com/agentpool: ${NP_GPU}
  tolerations:
    - key: "${GPU_TAINT_KEY}"
      operator: "Equal"
      value: "${GPU_TAINT_VALUE}"
      effect: "${GPU_TAINT_EFFECT}"

devicePlugin:
  nodeSelector:
    kubernetes.azure.com/agentpool: ${NP_GPU}
  tolerations:
    - key: "${GPU_TAINT_KEY}"
      operator: "Equal"
      value: "${GPU_TAINT_VALUE}"
      effect: "${GPU_TAINT_EFFECT}"

toolkit:
  nodeSelector:
    kubernetes.azure.com/agentpool: ${NP_GPU}
  tolerations:
    - key: "${GPU_TAINT_KEY}"
      operator: "Equal"
      value: "${GPU_TAINT_VALUE}"
      effect: "${GPU_TAINT_EFFECT}"

dcgmExporter:
  enabled: true
  nodeSelector:
    kubernetes.azure.com/agentpool: ${NP_GPU}
  tolerations:
    - key: "${GPU_TAINT_KEY}"
      operator: "Equal"
      value: "${GPU_TAINT_VALUE}"
      effect: "${GPU_TAINT_EFFECT}"
YAML

  # --- overlay を条件生成（NGC_API_KEY が無い場合は imagePullSecrets を書かない） ---
  # ※ ここを単一箇所に集約。operator/devicePlugin/dcgmExporter/toolkit は「文字列配列」に統一。
  # NFD 側は PodSpec に入るため従来通り `- name: nvcr-creds` を維持。
  if [[ -n "${NGC_API_KEY}" ]]; then
    cat > /tmp/gpu-op-overlay.yaml <<'YAML'
sandboxWorkloads:
  enabled: false
sandboxDevicePlugin:
  enabled: false
operator:
  imagePullSecrets:
    - nvcr-creds
node-feature-discovery:
  imagePullSecrets:
    - name: nvcr-creds
  worker:
    imagePullSecrets:
      - name: nvcr-creds
  master:
    imagePullSecrets:
      - name: nvcr-creds
devicePlugin:
  imagePullSecrets:
    - nvcr-creds
dcgmExporter:
  imagePullSecrets:
    - nvcr-creds
toolkit:
  imagePullSecrets:
    - nvcr-creds
YAML
  else
    cat > /tmp/gpu-op-overlay.yaml <<'YAML'
sandboxWorkloads:
  enabled: false
sandboxDevicePlugin:
  enabled: false
YAML
  fi

  # DRIVER_MODE=host のとき、コメント行でも確実にヒットするように（先頭空白許容）
  if [[ "$DRIVER_MODE" == "host" ]]; then
    sed -i 's/^[[:space:]]*#[[:space:]]*type:[[:space:]]*host/  type: host/' /tmp/gpu-operator-values.yaml
  fi

  # --- Install GPU Operator ---
  set -x
  helm upgrade --install gpu-operator "${HELM_REPO_NAME}/gpu-operator" \
    ${HELM_CHART_VERSION:+--version "${HELM_CHART_VERSION}"} \
    --namespace "${GPU_NS}" \
    -f /tmp/gpu-operator-values.yaml \
    -f /tmp/gpu-op-overlay.yaml \
    --timeout 30m \
    --wait \
    --debug
  set +x

  # --- ロールアウト待ち（より堅牢：DS/Deployment のrollout） ---
  echo "[INFO] Waiting for NFD worker DS rollout..."
  kubectl -n "${GPU_NS}" rollout status ds/gpu-operator-node-feature-discovery-worker --timeout="${WAIT_DS_TIMEOUT}"

  echo "[INFO] Detecting driver deployment mode..."
  # より堅牢なホストドライバ検出（jsonpathで値を確認）
  if kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.labels.nvidia\.com/gpu\.deploy\.driver}{"\n"}{end}' \
    2>/dev/null | grep -qx 'pre-installed'; then
    echo "[INFO] Host-driver mode detected (driver DS not deployed). Skipping driver DS wait."
  else
    echo "[INFO] Waiting for NVIDIA driver DaemonSet to be Ready..."
    desired=$(kubectl -n "${GPU_NS}" get ds nvidia-driver-daemonset -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
    if [[ "$desired" -eq 0 ]]; then
      echo "[INFO] driver DS desired=0（nodeSelector によりスケジュール対象なし）。スキップします。"
    else
      END=$((SECONDS+1200))  # 20m
      while :; do
        ready=$(kubectl -n "${GPU_NS}" get ds nvidia-driver-daemonset -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)
        desired=$(kubectl -n "${GPU_NS}" get ds nvidia-driver-daemonset -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo 0)
        echo "[DRIVER] Ready ${ready}/${desired}"
        # 途中で desired が 0 になったら（=ラベルやセレクタ変更）、待ちを打ち切り
        if [[ "$desired" -eq 0 ]]; then
          echo "[INFO] driver DS desired=0 に遷移。待ちを終了します。"
          break
        fi
        if [[ "$ready" -ge "$desired" ]]; then break; fi
        [[ $SECONDS -gt $END ]] && { echo "[ERROR] driver DS not ready in time"; exit 1; }
        sleep 10
      done
    fi
  fi

  echo "[INFO] Waiting for NVIDIA device-plugin DS rollout..."
  kubectl -n "${GPU_NS}" rollout status ds/nvidia-device-plugin-daemonset --timeout="${WAIT_DS_TIMEOUT}"

  echo "[CHECK] Allocatable GPUs after plugin ready:"
  kubectl get node -l agentpool="$NP_GPU" -o custom-columns=NAME:.metadata.name,ALLOC:.status.allocatable.nvidia\.com/gpu

  echo "[INFO] Refresh device-plugin to re-advertise GPUs..."
  kubectl -n "${GPU_NS}" rollout restart ds/nvidia-device-plugin-daemonset
  kubectl -n "${GPU_NS}" rollout status ds/nvidia-device-plugin-daemonset --timeout="${WAIT_DS_TIMEOUT}"
fi

# =========[ Verify GPUs visible to kubelet ]=========
echo "[CHECK] allocatable GPUs on nodes"
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\\.com/gpu

# =========[ AML extension & attach ]=========
if [[ -n "$AML_WS" ]]; then
  az config set extension.use_dynamic_install=yes_without_prompt >/dev/null
  az config set extension.dynamic_install_allow_preview=true >/dev/null
  az config set core.only_show_errors=true >/dev/null
  az extension add -n k8s-extension -y >/dev/null || true
  az extension add -n aks-preview -y >/dev/null || true
  az extension add -n ml -y >/dev/null || true  # ★ 追加（確実に az ml を使えるように）

  kubectl create namespace "$AML_NS" 2>/dev/null || true
  ensure_provider_registered

  SUB=$(az account show --query id -o tsv)

  # Workspace 確認（RGは AML_WS_RG を使う）
  rest_ws_show "$SUB" "$AML_WS_RG" "$AML_WS" >/dev/null || { echo "[ERROR] AML workspace not found: $AML_WS_RG/$AML_WS"; exit 2; }

  CONF_SETTINGS=( "allowNamespaceCreation=true" )
  if [[ "$ALLOW_INSECURE_CONNECTIONS" == "true" ]]; then
    CONF_SETTINGS+=( "allowInsecureConnections=true" )
  else
    TMPDIR="$(mktemp -d)"
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
      -subj "/CN=${SSL_COMMON_NAME}" \
      -keyout "${TMPDIR}/tls.key" -out "${TMPDIR}/tls.crt" >/dev/null 2>&1
    kubectl -n "$AML_NS" create secret tls "$SSL_SECRET_NAME" \
      --cert="${TMPDIR}/tls.crt" --key="${TMPDIR}/tls.key" \
      --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    rm -rf "$TMPDIR"
    CONF_SETTINGS+=( "sslSecret=${SSL_SECRET_NAME}" "sslCname=${SSL_COMMON_NAME}" )
  fi

  # AzureML extension（REST; bkの安定版手順）
  if kc_ext_show "$SUB" "$RG" "$AKS" "$KC_API_VER" >/dev/null; then
    echo "[AML] azureml-kubernetes extension already exists."
  else
    echo "[AML] Creating azureml-kubernetes extension (REST)..."
    if ! kc_ext_put "$SUB" "$RG" "$AKS" "$KC_API_VER" "$AML_NS"; then
      for v in 2024-11-01 2023-05-01 2022-11-01; do
        echo "[AML] Retrying with api-version=$v ..."
        KC_API_VER="$v"
        kc_ext_put "$SUB" "$RG" "$AKS" "$KC_API_VER" "$AML_NS" && break
      done
    fi
  fi
  kc_ext_wait_succeeded "$SUB" "$RG" "$AKS" "$KC_API_VER" || true
  wait_crd_instancetype || true

  AKS_ID=$(az aks show -g "$RG" -n "$AKS" --query id -o tsv)

  # MI 取得は AML_WS_RG を用いる（修正点）
  AML_MI_ID=$(az resource show -g "$AML_WS_RG" -n "$AML_WS" \
    --resource-type Microsoft.MachineLearningServices/workspaces \
    --query identity.principalId -o tsv 2>/dev/null || echo "")

  if [[ -n "$AML_MI_ID" ]]; then
    az role assignment create \
      --assignee-object-id "$AML_MI_ID" \
      --assignee-principal-type ServicePrincipal \
      --role "Azure Kubernetes Service Cluster User Role" \
      --scope "$AKS_ID" >/dev/null 2>&1 || true
  fi

  # 既存 compute を確認し、無ければ attach（az ml → REST フォールバック）
  EXIST_CNT=$(rest_compute_list "$SUB" "$AML_WS_RG" "$AML_WS" | jq -r --arg n "$COMPUTE_NAME" '[.value[]|select(.name==$n)]|length')
  if [[ "$EXIST_CNT" =~ ^[0-9]+$ ]] && (( EXIST_CNT>0 )); then
    echo "[AML] compute already exists: $COMPUTE_NAME"
  else
    attach_compute_with_fallback "$AML_WS_RG" "$AML_WS" "$COMPUTE_NAME" "$AKS_ID" "$AML_NS" "$REGION" "$SUB"
  fi
fi

echo "[INFO] Complete. Node / GPU status:"
kubectl get nodes -o custom-columns=NAME:.metadata.name,POOL:.metadata.labels.agentpool,GPU:.status.allocatable.nvidia\\.com/gpu
