#!/bin/bash

################################################################################
# GPU Diagnostic Script - YTCaption
# 
# Este script ajuda a diagnosticar problemas de detecção de GPU
################################################################################

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_header() {
    echo -e "${BLUE}======================================${NC}"
    echo -e "${BLUE}  GPU Diagnostic Tool${NC}"
    echo -e "${BLUE}======================================${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${BLUE}[$1]${NC}"
    echo "----------------------------------------"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
    echo -e "${RED}✗ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

print_header

# 1. Check hardware
print_section "1. Hardware Detection"

if command -v lspci &> /dev/null; then
    echo "Checking for NVIDIA hardware via lspci..."
    if lspci | grep -i nvidia &> /dev/null; then
        GPU_INFO=$(lspci | grep -i nvidia)
        print_success "NVIDIA hardware detected:"
        echo "$GPU_INFO" | while read line; do
            echo "  $line"
        done
    else
        print_warning "No NVIDIA hardware found via lspci"
        echo "  • This is a VM without GPU passthrough"
        echo "  • OR no NVIDIA GPU in the system"
    fi
else
    print_warning "lspci command not found"
    echo "  Install: sudo apt install pciutils"
fi

# 2. Check nvidia-smi
print_section "2. NVIDIA SMI Tool"

if command -v nvidia-smi &> /dev/null; then
    print_success "nvidia-smi found: $(which nvidia-smi)"
    echo ""
    echo "Running nvidia-smi..."
    if nvidia-smi &> /dev/null; then
        print_success "nvidia-smi works! GPU is accessible"
        echo ""
        nvidia-smi
    else
        print_error "nvidia-smi found but failed to run"
        echo ""
        echo "Error output:"
        nvidia-smi 2>&1 | head -5
        echo ""
        print_info "Common causes:"
        echo "  1. NVIDIA driver not loaded (run: sudo modprobe nvidia)"
        echo "  2. Driver mismatch with kernel"
        echo "  3. Permission issue (add user to 'video' group)"
    fi
else
    print_error "nvidia-smi NOT found"
    echo "  • NVIDIA driver is NOT installed"
    echo "  • Install with: sudo apt install nvidia-driver-535"
fi

# 3. Check NVIDIA kernel modules
print_section "3. NVIDIA Kernel Modules"

if command -v lsmod &> /dev/null; then
    if lsmod | grep -i nvidia &> /dev/null; then
        print_success "NVIDIA kernel modules loaded:"
        lsmod | grep -i nvidia | while read line; do
            echo "  $line"
        done
    else
        print_warning "NVIDIA kernel modules NOT loaded"
        echo ""
        print_info "To load modules:"
        echo "  sudo modprobe nvidia"
        echo "  sudo modprobe nvidia_uvm"
    fi
else
    print_warning "lsmod command not available"
fi

# 4. Check NVIDIA driver packages
print_section "4. NVIDIA Driver Packages"

if command -v dpkg &> /dev/null; then
    if dpkg -l | grep -i nvidia-driver &> /dev/null; then
        print_success "NVIDIA driver packages installed:"
        dpkg -l | grep -i nvidia-driver | awk '{print "  " $2 " (" $3 ")"}'
    else
        print_warning "No NVIDIA driver packages found"
        echo ""
        print_info "To install driver:"
        echo "  sudo apt update"
        echo "  sudo ubuntu-drivers autoinstall"
        echo "  # OR specific version:"
        echo "  sudo apt install nvidia-driver-535"
    fi
else
    print_info "dpkg not available (not Debian/Ubuntu based)"
fi

# 5. Check CUDA
print_section "5. CUDA Toolkit"

if command -v nvcc &> /dev/null; then
    CUDA_VERSION=$(nvcc --version | grep "release" | awk '{print $5}' | cut -d',' -f1)
    print_success "CUDA Toolkit installed: $CUDA_VERSION"
    echo "  Location: $(which nvcc)"
else
    print_info "CUDA Toolkit NOT installed"
    echo "  • Not required for Whisper if using NVIDIA Docker"
    echo "  • Only needed for CUDA development"
fi

# 6. Check Docker GPU support
print_section "6. Docker GPU Support"

if command -v docker &> /dev/null; then
    print_success "Docker installed: $(docker --version)"
    echo ""
    
    # Check nvidia-docker
    if dpkg -l | grep -i nvidia-docker &> /dev/null; then
        print_success "nvidia-docker2 installed"
    elif dpkg -l | grep -i nvidia-container-toolkit &> /dev/null; then
        print_success "nvidia-container-toolkit installed"
    else
        print_warning "NVIDIA Docker NOT installed"
        echo ""
        print_info "To install NVIDIA Docker:"
        echo "  distribution=\$(. /etc/os-release;echo \$ID\$VERSION_ID)"
        echo "  curl -s -L https://nvidia.github.io/nvidia-docker/gpgkey | sudo apt-key add -"
        echo "  curl -s -L https://nvidia.github.io/nvidia-docker/\$distribution/nvidia-docker.list | sudo tee /etc/apt/sources.list.d/nvidia-docker.list"
        echo "  sudo apt update"
        echo "  sudo apt install -y nvidia-docker2"
        echo "  sudo systemctl restart docker"
    fi
    
    echo ""
    echo "Testing Docker GPU access..."
    if docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi &> /dev/null; then
        print_success "Docker CAN access GPU!"
    else
        print_error "Docker CANNOT access GPU"
        echo ""
        echo "Error output:"
        docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi 2>&1 | head -10
    fi
else
    print_warning "Docker not installed"
fi

# 7. Summary and recommendations
print_section "7. Summary & Recommendations"

# Determine status
HAS_HARDWARE=false
HAS_DRIVER=false
HAS_DOCKER_GPU=false

lspci 2>/dev/null | grep -i nvidia &> /dev/null && HAS_HARDWARE=true
command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null && HAS_DRIVER=true
docker run --rm --gpus all nvidia/cuda:11.8.0-base-ubuntu22.04 nvidia-smi &> /dev/null 2>&1 && HAS_DOCKER_GPU=true

echo "Status:"
if [ "$HAS_HARDWARE" = true ]; then
    print_success "NVIDIA Hardware: Detected"
else
    print_warning "NVIDIA Hardware: Not detected"
fi

if [ "$HAS_DRIVER" = true ]; then
    print_success "NVIDIA Driver: Installed and working"
else
    print_error "NVIDIA Driver: Not working or not installed"
fi

if [ "$HAS_DOCKER_GPU" = true ]; then
    print_success "Docker GPU Access: Working"
else
    print_error "Docker GPU Access: Not working"
fi

echo ""
echo "Recommendation:"

if [ "$HAS_HARDWARE" = false ]; then
    print_info "🖥️  No NVIDIA GPU detected in this system"
    echo "  • Use CPU mode (default)"
    echo "  • Command: ./start.sh --model base --no-gpu"
    
elif [ "$HAS_DRIVER" = false ]; then
    print_info "🔧 NVIDIA GPU found but driver not installed"
    echo "  • Install driver: sudo apt install nvidia-driver-535"
    echo "  • Reboot: sudo reboot"
    echo "  • Then run: ./start.sh --model base"
    
elif [ "$HAS_DOCKER_GPU" = false ]; then
    print_info "🐳 NVIDIA driver works but Docker can't access GPU"
    echo "  • Install NVIDIA Docker (see section 6)"
    echo "  • Restart Docker: sudo systemctl restart docker"
    echo "  • Then run: ./start.sh --model base"
    
else
    print_success "🎉 Everything looks good! GPU ready to use!"
    echo "  • Run: ./start.sh --model medium"
    echo "  • Expected: GPU will be used for transcription"
fi

print_section "End of Diagnostic"
echo ""
