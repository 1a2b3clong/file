#!/usr/bin/env bash
set -euo pipefail

# ================= 配置 =================
CONDA_INSTALL_PATH="/root/miniconda3"
ENV_NAME="exp"
ENV_FILE="train/environment.yml"

# 固定下载到 /root/train.zip
PROJECT_ZIP="/root/train.zip"
PROJECT_URL="https://openlist.4866666.xyz/d/tmp/train.zip?sign=UOTpuSoHP3UeHnDm2HjcsBBHbdWmWzaQW2TAjQ2HTCw=:0"

# ================= 辅助函数 =================
log_info() { echo -e "\n\x1b[32m[INFO]\x1b[0m $1"; }
log_error(){ echo -e "\n\x1b[31m[ERROR]\x1b[0m $1" >&2; }

append_if_not_exists() {
    local line="$1" file="$2"
    grep -Fxq "$line" "$file" 2>/dev/null || {
        echo "$line" >> "$file"
        log_info "已将 '$line' 添加到 $file"
    }
}

main() {
    # 1) 系统依赖
    log_info "安装系统依赖..."
    if command -v apt &>/dev/null; then
        sudo apt update
        sudo apt install -y bzip2 vim curl git wget unzip tmux
    else
        log_error "未检测到 apt，请手动安装 bzip2 vim curl git wget unzip tmux"
        exit 1
    fi

    # 2) 安装 Miniconda（全静默）
    local miniconda_installer="Miniconda3-latest-Linux-x86_64.sh"
    if [ ! -d "$CONDA_INSTALL_PATH" ]; then
        log_info "Miniconda 未安装，开始下载与静默安装..."
        [ -f "$miniconda_installer" ] || wget "https://repo.anaconda.com/miniconda/$miniconda_installer"
        bash "./$miniconda_installer" -b -p "$CONDA_INSTALL_PATH"
        rm -f "$miniconda_installer"
    else
        log_info "Miniconda 已安装在 $CONDA_INSTALL_PATH，跳过安装。"
    fi

    # 3) 初始化 conda 并开启非交互模式
    log_info "初始化 Conda 并设置非交互模式..."
    "$CONDA_INSTALL_PATH/bin/conda" init bash
    source "$CONDA_INSTALL_PATH/etc/profile.d/conda.sh"
    export CONDA_ALWAYS_YES="true"
    "$CONDA_INSTALL_PATH/bin/conda" config --set always_yes true
    "$CONDA_INSTALL_PATH/bin/conda" config --set auto_update_conda false

    # 4) 下载项目压缩包到 /root/train.zip
    log_info "下载项目压缩包到 $PROJECT_ZIP ..."
    mkdir -p /root
    rm -f "$PROJECT_ZIP"
    wget -O "$PROJECT_ZIP" "$PROJECT_URL"

    # 可选：简单校验文件非空
    if [ ! -s "$PROJECT_ZIP" ]; then
        log_error "下载失败：$PROJECT_ZIP 文件不存在或大小为 0"
        exit 1
    fi

    # 5) 解压项目
    log_info "检查并解压 $PROJECT_ZIP ..."
    if [ ! -d "/root/train" ]; then
        unzip -o "$PROJECT_ZIP" -d /root
    else
        log_info "/root/train 已存在，跳过解压。"
    fi

    # 6) 配置 channel（非交互）
    log_info "配置 conda-forge channel 与优先级..."
    "$CONDA_INSTALL_PATH/bin/conda" config --add channels conda-forge
    "$CONDA_INSTALL_PATH/bin/conda" config --set channel_priority flexible

    # 6.5) 接受 Anaconda TOS
    log_info "接受 Anaconda repo 条款..."
    "$CONDA_INSTALL_PATH/bin/conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main
    "$CONDA_INSTALL_PATH/bin/conda" tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r

    # 7) 创建环境（非交互）
    if "$CONDA_INSTALL_PATH/bin/conda" env list | awk '{print $1}' | grep -Fxq "$ENV_NAME"; then
        log_info "环境 '$ENV_NAME' 已存在，跳过创建。"
    else
        log_info "从 $ENV_FILE 创建环境 '$ENV_NAME'..."
        [ -f "/root/$ENV_FILE" ] || { log_error "缺少环境文件 /root/$ENV_FILE"; exit 1; }
        "$CONDA_INSTALL_PATH/bin/conda" env create -f "/root/$ENV_FILE" -n "$ENV_NAME"
    fi

    # 8) 持久化配置
    log_info "配置 .bashrc / .vimrc..."
    append_if_not_exists 'set mouse-=a' "$HOME/.vimrc"
    append_if_not_exists "conda activate $ENV_NAME" "$HOME/.bashrc"
    append_if_not_exists 'alias py="python"' "$HOME/.bashrc"

    log_info "✅ 环境与配置完成"
    log_info "🚀 准备启动 tmux 会话：0 (tensorboard) 与 1 (交互)"

    # 9) 路径与依赖检查
    local train_dir="/root/train"
    if [ ! -d "$train_dir" ]; then
        log_error "未找到目录 $train_dir（可能下载或解压失败）"
        exit 1
    fi
    command -v tmux >/dev/null || { log_error "未找到 tmux"; exit 1; }

    # 10) 启动两个独立 tmux 会话：0（tensorboard），1（交互）
    local conda_bin="$CONDA_INSTALL_PATH/bin/conda"

    if ! tmux has-session -t 0 2>/dev/null; then
        log_info "创建 tmux 会话 '0'（tensorboard）..."
        tmux new-session -d -s 0 -n tensorboard \
            "$conda_bin run -n $ENV_NAME --no-capture-output tensorboard --logdir=$train_dir/ray_results --bind_all"
    else
        log_info "会话 '0' 已存在，跳过创建。"
    fi

    if ! tmux has-session -t 1 2>/dev/null; then
        log_info "创建 tmux 会话 '1'（交互 shell）..."
        tmux new-session -d -s 1 -n shell \
            "bash -lc 'source $CONDA_INSTALL_PATH/etc/profile.d/conda.sh && conda activate $ENV_NAME && cd $train_dir && clear; exec bash -i'"
    else
        log_info "会话 '1' 已存在，跳过创建。"
    fi

    # 11) 附加到交互会话
    log_info "附加到会话 '1'。TensorBoard 在会话 '0' 运行。"
    echo "  提示：Ctrl-b d 可分离；tmux attach -t 1 回来；tmux attach -t 0 看 TensorBoard"
    tmux attach -t 1
}

main