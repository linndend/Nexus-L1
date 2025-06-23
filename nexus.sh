#!/bin/bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# === Helper Functions ===
log_info() {
    echo -e "${BLUE}INFO:${NC} $1"
}

log_success() {
    echo -e "${GREEN}✅ SUCCESS:${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}⚠️ WARNING:${NC} $1"
}

log_error() {
    echo -e "${RED}❌ ERROR:${NC} $1" >&2
    exit 1
}

# Modified run_command function with better error handling and output
run_command() {
    local cmd="$1"
    local msg="$2"
    local log_file="/tmp/nexus_install.log"
    
    log_info "$msg"
    echo "Command: $cmd" >> "$log_file"
    
    # Show progress and capture both stdout and stderr
    if eval "$cmd" 2>&1 | tee -a "$log_file"; then
        log_success "${msg} completed."
        return 0
    else
        local exit_code=${PIPESTATUS[0]}
        log_error "Failed to run: ${msg} (Exit code: $exit_code)"
        echo "Check log file: $log_file"
        return $exit_code
    fi
}

# Function to check if running as root or with sudo access
check_sudo() {
    if [ "$EUID" -eq 0 ]; then
        log_info "Running as root user"
        return 0
    elif sudo -n true 2>/dev/null; then
        log_info "Sudo access available"
        return 0
    else
        log_error "This script requires sudo access. Please run with sudo or as root."
    fi
}

# Function to check internet connectivity
check_internet() {
    log_info "Checking internet connectivity..."
    if ping -c 1 google.com &> /dev/null || ping -c 1 8.8.8.8 &> /dev/null; then
        log_success "Internet connectivity confirmed"
    else
        log_error "No internet connection. Please check your network connection."
    fi
}

# Function to check available disk space
check_disk_space() {
    local required_space=2000000  # 2GB in KB
    local available_space=$(df / | tail -1 | awk '{print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        log_warn "Low disk space detected. Available: $(($available_space/1024))MB, Recommended: $(($required_space/1024))MB"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_error "Installation cancelled due to insufficient disk space."
        fi
    fi
}

clear
echo -e "${BLUE}==============================================${NC}"
echo -e "${YELLOW}    🚀 Nexus Node Automatic Installer 🚀    ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo

# Pre-installation checks
log_info "Performing pre-installation checks..."
check_sudo
check_internet
check_disk_space

# --- 1. Dependency Installation ---
echo -e "\n--- ${YELLOW}Step 1: System Dependency Installation${NC} ---"

# Fix package cache and handle potential lock issues
log_info "Checking for package manager locks..."
if sudo lsof /var/lib/dpkg/lock-frontend &> /dev/null; then
    log_warn "Package manager is locked. Waiting for other package operations to complete..."
    while sudo lsof /var/lib/dpkg/lock-frontend &> /dev/null; do
        sleep 2
        echo -n "."
    done
    echo
fi

# Update with more verbose output and better error handling
log_info "Updating package repositories..."
if ! sudo apt-get update -y; then
    log_warn "Initial update failed, trying to fix broken packages..."
    sudo dpkg --configure -a
    sudo apt-get -f install -y
    sudo apt-get update -y
fi

log_info "Upgrading existing packages..."
sudo apt-get upgrade -y

# Fix Docker installation conflicts
fix_docker_conflicts() {
    log_info "Checking for Docker-related package conflicts..."
    
    # Remove conflicting packages if they exist
    local conflicting_packages=("containerd" "containerd.io" "docker" "docker-engine" "docker.io" "docker-ce" "docker-ce-cli")
    
    for pkg in "${conflicting_packages[@]}"; do
        if dpkg -l | grep -q "^ii.*$pkg "; then
            log_warn "Removing conflicting package: $pkg"
            sudo apt-get remove -y "$pkg" || true
        fi
    done
    
    # Clean up any remaining configuration files
    sudo apt-get autoremove -y
    sudo apt-get autoclean
}

install_docker_official() {
    log_info "Installing Docker from official repository..."
    
    # Add Docker's official GPG key
    sudo apt-get update
    sudo apt-get install -y ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    
    if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null; then
        log_warn "Failed to add Docker GPG key, trying alternative method..."
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo tee /etc/apt/keyrings/docker.asc > /dev/null
        sudo chmod a+r /etc/apt/keyrings/docker.asc
    fi
    
    # Add Docker repository
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    
    # Update package index
    sudo apt-get update
    
    # Install Docker Engine
    if sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        log_success "Docker CE installed successfully"
    else
        log_error "Failed to install Docker CE"
    fi
}

install_docker_snap() {
    log_info "Installing Docker via Snap as fallback..."
    if command -v snap >/dev/null 2>&1; then
        sudo snap install docker
        log_success "Docker installed via Snap"
    else
        log_error "Snap is not available, cannot install Docker"
    fi
}

install_docker_ubuntu_repo() {
    log_info "Trying to install Docker from Ubuntu repository with conflict resolution..."
    
    # First try to install without docker.io if there are conflicts
    sudo apt-get install -y curl ca-certificates libssl-dev build-essential
    
    # Try different Docker installation methods
    if sudo apt-get install -y docker.io; then
        log_success "docker.io installed successfully"
    else
        log_warn "docker.io installation failed, trying conflict resolution..."
        
        # Try to resolve conflicts
        fix_docker_conflicts
        
        # Try again
        if sudo apt-get install -y docker.io; then
            log_success "docker.io installed after conflict resolution"
        else
            log_warn "docker.io still failing, trying official Docker repository..."
            install_docker_official
        fi
    fi
}

log_info "Installing required dependencies..."

# Install non-Docker packages first
BASIC_PACKAGES=("curl" "ca-certificates" "libssl-dev" "build-essential")

for package in "${BASIC_PACKAGES[@]}"; do
    log_info "Installing $package..."
    if sudo apt-get install -y "$package"; then
        log_success "$package installation completed"
    else
        log_error "Failed to install $package"
    fi
done

# Handle Docker installation separately due to potential conflicts
log_info "Installing Docker..."
if command -v docker >/dev/null 2>&1; then
    log_warn "Docker is already installed, skipping Docker installation"
else
    # Try Ubuntu repository first, then official repo as fallback
    install_docker_ubuntu_repo
fi

# Verify Docker installation and start service
log_info "Starting and enabling Docker service..."
if sudo systemctl start docker && sudo systemctl enable docker; then
    log_success "Docker service started and enabled"
else
    log_warn "Failed to start Docker service, trying alternative method..."
    
    # If systemctl fails, try with snap docker
    if command -v snap >/dev/null 2>&1 && snap list | grep -q docker; then
        log_info "Using Snap Docker, no systemctl needed"
    else
        log_error "Cannot start Docker service"
    fi
fi

# Add current user to docker group (if not root)
if [ "$EUID" -ne 0 ]; then
    sudo usermod -aG docker $USER
    log_warn "Added user to docker group. You may need to log out and back in for changes to take effect."
fi

# --- 2. Nexus CLI Installation ---
echo -e "\n--- ${YELLOW}Step 2: Nexus CLI Installation${NC} ---"
CLI_DIR="$HOME/.nexus"
CLI_PATH="$CLI_DIR/bin/nexus-network"

if [ -f "$CLI_PATH" ]; then
    log_warn "Nexus CLI is already installed. Skipping installation."
else
    log_info "Creating Nexus directory..."
    mkdir -p "$CLI_DIR"
    
    log_info "Downloading and installing Nexus CLI..."
    
    # Use more robust download with timeout and retry
    for attempt in {1..3}; do
        log_info "Download attempt $attempt/3..."
        if timeout 300 curl -sSfL --connect-timeout 30 --max-time 300 https://cli.nexus.xyz/ | sh; then
            log_success "Nexus CLI installed successfully."
            break
        else
            if [ $attempt -eq 3 ]; then
                log_error "Failed to download Nexus CLI after 3 attempts."
            else
                log_warn "Download attempt $attempt failed, retrying in 5 seconds..."
                sleep 5
            fi
        fi
    done
fi

# Verify CLI installation
if [ ! -f "$CLI_PATH" ]; then
    log_error "Nexus CLI installation not found at $CLI_PATH"
fi

chmod +x "$CLI_PATH"
cd "$(dirname "$CLI_PATH")" # Change to ~/.nexus/bin for build context

# --- 3. Docker Setup ---
echo -e "\n--- ${YELLOW}Step 3: Preparing Docker Environment${NC} ---"

log_info "Creating Dockerfile..."
cat <<EOF > Dockerfile
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && \\
    apt-get install -y --no-install-recommends curl ca-certificates libssl-dev && \\
    apt-get clean && \\
    rm -rf /var/lib/apt/lists/*

COPY nexus-network /usr/local/bin/nexus-network
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /usr/local/bin/nexus-network /entrypoint.sh

# Working directory
WORKDIR /root

ENTRYPOINT ["/entrypoint.sh"]
EOF
log_success "Dockerfile created successfully."

log_info "Creating interactive entrypoint script..."
cat <<'EOF' > entrypoint.sh
#!/bin/bash

# Color Variables
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

show_menu() {
    clear
    echo -e "${BLUE}===================================${NC}"
    echo -e "${YELLOW}      🚀 Nexus Node Runner 🚀     ${NC}"
    echo -e "${BLUE}===================================${NC}"
    echo "Select mode to run the node:"
    echo "  1) Run with Wallet Address (for new registration)"
    echo "  2) Run with Node ID (if node is already registered)"
    echo "  3) Exit"
    echo -e "${BLUE}-----------------------------------${NC}"
}

run_with_wallet() {
    local wallet_address
    while true; do
        read -p "Enter your Wallet Address: " wallet_address
        if [ -n "$wallet_address" ]; then
            break
        else
            echo -e "${RED}Wallet Address cannot be empty. Please try again.${NC}"
        fi
    done

    echo -e "\n${BLUE}INFO:${NC} Registering user with wallet: ${GREEN}$wallet_address${NC}"
    nexus-network register-user --wallet-address "$wallet_address"

    echo -e "\n${BLUE}INFO:${NC} Registering new node..."
    nexus-network register-node

    echo -e "\n${BLUE}INFO:${NC} Starting node... Logs will be displayed below."
    nexus-network start
}

run_with_node_id() {
    local node_id
    while true; do
        read -p "Enter your Node ID: " node_id
        if [ -n "$node_id" ]; then
            break
        else
            echo -e "${RED}Node ID cannot be empty. Please try again.${NC}"
        fi
    done

    echo -e "\n${BLUE}INFO:${NC} Starting node with ID: ${GREEN}$node_id${NC}... Logs will be displayed below."
    nexus-network start --node-id "$node_id"
}

while true; do
    show_menu
    read -p "Select an option (1-3): " MODE
    case $MODE in
        1)
            run_with_wallet
            break
            ;;
        2)
            run_with_node_id
            break
            ;;
        3)
            echo "Exiting script."
            exit 0
            ;;
        *)
            echo -e "\n${RED}Invalid option. Press [Enter] to try again.${NC}"
            read -n 1
            ;;
    esac
done
EOF
chmod +x entrypoint.sh
log_success "entrypoint.sh script created successfully."

# --- 4. Build Docker Image ---
echo -e "\n--- ${YELLOW}Step 4: Build Docker Image${NC} ---"
log_info "Building 'nexus-node' image (this may take a few minutes)..."
if docker build -t nexus-node .; then
    log_success "Docker image built successfully"
else
    log_error "Failed to build Docker image"
fi

# --- 5. Done ---
echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 ALL PROCESSES COMPLETED! 🎉${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
echo "Docker image ${YELLOW}nexus-node${NC} has been successfully created."
echo "To run your node, use the following command:"
echo
echo -e "    ${YELLOW}docker run -it --rm nexus-node${NC}"
echo
echo "Note:"
echo " - The ${BLUE}-it${NC} option will open an interactive terminal to choose the mode."
echo " - The ${BLUE}--rm${NC} option will automatically remove the container after it stops."
echo "   (If you wish to persist node data, consider using Docker Volumes)."
echo
echo "Log file location: ${YELLOW}/tmp/nexus_install.log${NC}"
