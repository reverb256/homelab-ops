#!/usr/bin/env bash
# llama-cpp Setup Script for Multi-GPU (RTX 3090 + RTX 3060 Ti)
# Downloads Qwen models and verifies GPU setup

set -euo pipefail

MODEL_DIR="/var/lib/llama/models"
SERVER_URL="http://127.0.0.1:8080"

echo "🚀 llama-cpp Multi-GPU Setup"
echo ""

# Create model directory
echo "📁 Creating model directory: $MODEL_DIR"
sudo mkdir -p "$MODEL_DIR"
sudo chown j_kro:users "$MODEL_DIR"

# Check GPU visibility
echo ""
echo "🎮 Detecting GPUs..."
nvidia-smi --query-gpu=index,name,memory.total --format=csv,noheader,nounits | \
  awk -F', ' '{print "GPU " $1 ": " $2 " (" $3 " MB)"}'

echo ""
echo "📥 Available Qwen Models:"
echo ""

# Model options
cat <<'EOF'
Recommended Models for RTX 3090 (24GB) + RTX 3060 Ti (8GB):

1. Qwen2.5 7B Instruct (Q4_K_M - ~5GB)
   - Best balance of speed/quality
   - Fits entirely on RTX 3090
   - Download: huggingface-download qwen/Qwen2.5-7B-Instruct-GGUF qwen2.5-7b-instruct-q4_k_m.gguf

2. Qwen2.5 14B Instruct (Q4_K_M - ~9GB)
   - Higher quality, slower
   - Requires tensor split across GPUs
   - Download: huggingface-download qwen/Qwen2.5-14B-Instruct-GGUF qwen2.5-14b-instruct-q4_k_m.gguf

3. Qwen2.5 32B Instruct (Q4_K_M - ~19GB)
   - Best quality, requires both GPUs
   - Will split layers across 3090 + 3060 Ti
   - Download: huggingface-download qwen/Qwen2.5-32B-Instruct-GGUF qwen2.5-32b-instruct-q4_k_m.gguf
EOF

echo ""
echo "💡 Quick Download Commands:"
echo ""

# Check if huggingface-cli is available
if command -v huggingface-cli &>/dev/null; then
  echo "# Download Qwen2.5 7B (Recommended for speed)"
  echo "huggingface-cli download qwen/Qwen2.5-7B-Instruct-GGUF qwen2.5-7b-instruct-q4_k_m.gguf --local-dir $MODEL_DIR"
  echo ""
  echo "# Download Qwen2.5 14B (Balance)"
  echo "huggingface-cli download qwen/Qwen2.5-14B-Instruct-GGUF qwen2.5-14b-instruct-q4_k_m.gguf --local-dir $MODEL_DIR"
  echo ""
  echo "# Download Qwen2.5 32B (Best quality, uses both GPUs)"
  echo "huggingface-cli download qwen/Qwen2.5-32B-Instruct-GGUF qwen2.5-32b-instruct-q4_k_m.gguf --local-dir $MODEL_DIR"
else
  echo "# Install huggingface-cli first:"
  echo "pip install huggingface-hub"
  echo ""
  echo "# Then download with:"
  echo "huggingface-cli download qwen/Qwen2.5-7B-Instruct-GGUF qwen2.5-7b-instruct-q4_k_m.gguf --local-dir $MODEL_DIR"
fi

echo ""
echo "🔧 Manual download link:"
echo "https://huggingface.co/models?search=Qwen2.5+GGUF"
echo ""

# Check if llama-server is running
echo "🔍 Checking llama-server status..."
if systemctl is-active --quiet llama-server; then
  echo "✅ llama-server is running"
  echo ""
  echo "🌐 API available at: $SERVER_URL"
  echo "📊 Health check: curl $SERVER_URL/health"
  echo ""
  echo "💬 Test chat:"
  echo 'curl -X POST http://127.0.0.1:8080/completion -H "Content-Type: application/json" -d '"'"'{"prompt": "Hello!","n_predict": 50}'"'"
else
  echo "⚠️  llama-server is not running"
  echo ""
  echo "🚀 Start with: sudo systemctl start llama-server"
  echo "📊 View logs: sudo journalctl -u llama-server -f"
fi

echo ""
echo "📚 GPU Split Configuration:"
echo "  Primary:   RTX 3090 (GPU 0) - Heavier layers"
echo "  Secondary: RTX 3060 Ti (GPU 1) - Lighter layers"
echo ""
echo "🔧 To change model, edit /etc/nixos/configuration.nix:"
echo "  services.llama.modelName = \"your-model.gguf\";"
echo "  sudo nixos-rebuild switch"
