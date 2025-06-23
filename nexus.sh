#!/bin/bash

set -e

# === Configuration Variables ===
IMAGE_NAME="nexus-node"
CONTAINER_NAME="nexus-node-runner" # Nama kontainer yang konsisten
VOLUME_NAME="nexus_node_data"     # Nama volume untuk data persisten
NODE_ID_PERSIST_DIR="/nexus_data" # Direktori di dalam kontainer untuk data persisten
NODE_ID_PERSIST_FILE="${NODE_ID_PERSIST_DIR}/node_id.txt" # Lokasi file Node ID di dalam kontainer

# === Color Codes ===
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
    sudo usermod -aG docker "$USER"
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

# --- 3. Preparing Docker Environment ---
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

# Declare volume for persistent data
VOLUME ${NODE_ID_PERSIST_DIR}
EOF
log_success "Dockerfile created successfully."

log_info "Creating intelligent entrypoint script (entrypoint.sh)..."
cat <<EOF > entrypoint.sh
#!/bin/bash

# Color Variables
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Persistence Configuration ---
NODE_ID_PERSIST_DIR="${NODE_ID_PERSIST_DIR}"
NODE_ID_PERSIST_FILE="${NODE_ID_PERSIST_FILE}"

# Function to handle container shutdown gracefully
cleanup() {
    echo -e "\n${YELLOW}Shutting down node gracefully...${NC}"
    exit 0
}

# Trap signals for graceful shutdown
trap cleanup SIGTERM SIGINT SIGQUIT

# Ensure we have a proper TTY for interactive input
if [ ! -t 0 ]; then
    echo -e "${RED}ERROR: This container requires interactive mode.${NC}"
    echo "Please run with: docker run -it --name <your_container_name> ${IMAGE_NAME}"
    exit 1
fi

# Check if nexus-network binary exists
if [ ! -f "/usr/local/bin/nexus-network" ]; then
    echo -e "${RED}❌ ERROR: nexus-network binary not found inside container!${NC}"
    echo "Please ensure the Docker image was built correctly."
    exit 1
fi

# Make sure binary is executable
chmod +x /usr/local/bin/nexus-network

# --- Automatic Start Logic ---
if [ -f "\$NODE_ID_PERSIST_FILE" ] && [ -s "\$NODE_ID_PERSIST_FILE" ]; then # -s checks if file is not empty
    SAVED_NODE_ID=\$(cat "\$NODE_ID_PERSIST_FILE")
    echo -e "${GREEN}===============================================${NC}"
    echo -e "${GREEN}✅ Saved Node ID found: \$SAVED_NODE_ID${NC}"
    echo -e "${GREEN}🚀 Starting node automatically with saved ID...${NC}"
    echo -e "${GREEN}===============================================${NC}"
    echo -e "${YELLOW}Node logs will be displayed below:${NC}"
    echo "----------------------------------------"
    exec /usr/local/bin/nexus-network start --node-id "\$SAVED_NODE_ID"
fi

# --- If no saved Node ID, show interactive setup ---
echo -e "${YELLOW}⚠️ No saved Node ID found. Starting interactive setup...${NC}"
sleep 2

show_menu() {
    clear
    echo -e "${BLUE}===================================${NC}"
    echo -e "${YELLOW}      🚀 Nexus Node Runner 🚀     ${NC}"
    echo -e "${BLUE}===================================${NC}"
    echo "Select mode to run the node:"
    echo "  1) Run with Wallet Address (for new registration)"
    echo "  2) Run with Node ID (if node is already registered)"
    echo -e "${BLUE}-----------------------------------${NC}"
    echo -n "Select an option (1-2): "
}

validate_wallet_address() {
    local wallet="\$1"
    # Basic validation for common wallet address formats (can be improved)
    if [[ \${#wallet} -lt 10 ]]; then
        return 1
    elif [[ ! "\$wallet" =~ ^[a-zA-Z0-9] ]]; then
        return 1
    fi
    return 0
}

validate_node_id() {
    local node_id="\$1"
    # Basic validation for node ID (can be improved)
    if [[ \${#node_id} -lt 5 ]]; then
        return 1
    fi
    return 0
}

run_with_wallet() {
    local wallet_address
    echo -e "\n${BLUE}=== Running with Wallet Address ===${NC}"
    
    while true; do
        echo -n "Enter your Wallet Address: "
        read -r wallet_address
        
        if [ -z "\$wallet_address" ]; then
            echo -e "${RED}❌ Wallet Address cannot be empty. Please try again.${NC}"
            continue
        fi
        
        if ! validate_wallet_address "\$wallet_address"; then
            echo -e "${RED}❌ Invalid wallet address format. Please try again.${NC}"
            continue
        fi
        
        echo -e "${YELLOW}Wallet Address: ${GREEN}\$wallet_address${NC}"
        echo -n "Is this correct? (y/n): "
        read -r confirm
        
        if [[ "\$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
    done

    echo -e "\n${BLUE}INFO:${NC} Registering user with wallet: ${GREEN}\$wallet_address${NC}"
    if ! nexus-network register-user --wallet-address "\$wallet_address"; then
        echo -e "${RED}❌ Failed to register user. Please check your wallet address.${NC}"
        exit 1
    fi

    echo -e "\n${BLUE}INFO:${NC} Registering new node...${NC}"
    local NODE_ID
    NODE_ID=\$(nexus-network register-node 2>/dev/null)
    if [ \$? -ne 0 ] || [ -z "\$NODE_ID" ]; then
        echo -e "${RED}❌ Failed to register node.${NC}"
        exit 1
    fi

    # Simpan Node ID ke penyimpanan persisten
    mkdir -p "\$NODE_ID_PERSIST_DIR"
    echo -n "\$NODE_ID" > "\$NODE_ID_PERSIST_FILE"
    echo -e "${GREEN}✅ Node registered successfully with ID: \$NODE_ID${NC}"
    sleep 1

    echo -e "\n${BLUE}INFO:${NC} Starting node with Node ID: ${GREEN}\$NODE_ID${NC}"
    echo -e "${YELLOW}Node logs will be displayed below:${NC}"
    echo "----------------------------------------"
    
    exec /usr/local/bin/nexus-network start --node-id "\$NODE_ID"
}

run_with_node_id() {
    local node_id
    echo -e "\n${BLUE}=== Running with Node ID ===${NC}"
    
    while true; do
        echo -n "Enter your Node ID: "
        read -r node_id
        
        if [ -z "\$node_id" ]; then
            echo -e "${RED}❌ Node ID cannot be empty. Please try again.${NC}"
            continue
        fi
        
        if ! validate_node_id "\$node_id"; then
            echo -e "${RED}❌ Invalid Node ID format. Please try again.${NC}"
            continue
        fi
        
        echo -e "${YELLOW}Node ID: ${GREEN}\$node_id${NC}"
        echo -n "Is this correct? (y/n): "
        read -r confirm
        
        if [[ "\$confirm" =~ ^[Yy]$ ]]; then
            break
        fi
    done

    # Save the Node ID to persistent storage
    mkdir -p "\$NODE_ID_PERSIST_DIR"
    echo -n "\$node_id" > "\$NODE_ID_PERSIST_FILE"
    echo -e "${GREEN}✅ Node ID saved to persistent storage. Next time, the node will start automatically.${NC}"
    sleep 1

    echo -e "\n${BLUE}INFO:${NC} Starting node with ID: ${GREEN}\$node_id${NC}"
    echo -e "${YELLOW}Node logs will be displayed below:${NC}"
    echo "----------------------------------------"
    
    exec /usr/local/bin/nexus-network start --node-id "\$node_id"
}

# Main execution
main() {
    show_menu
    read -r MODE
    
    case \$MODE in
        1)
            run_with_wallet
            ;;
        2)
            run_with_node_id
            ;;
        *)
            echo -e "\n${RED}❌ Invalid option. Please select 1 or 2.${NC}"
            echo -n "Press Enter to continue..."
            read -r
            main # Restart main if invalid input
            ;;
    esac
}

# Start main execution (only if not already started automatically by saved ID)
main
EOF
chmod +x entrypoint.sh
log_success "entrypoint.sh script created successfully."

# --- 3.5: Prepare Docker Volume ---
echo -e "\n--- ${YELLOW}Step 3.5: Prepare Docker Volume${NC} ---"
log_info "Ensuring Docker volume '${VOLUME_NAME}' exists..."
if ! docker volume ls -q -f name=^/${VOLUME_NAME}$ | grep -q .; then
    run_command "docker volume create $VOLUME_NAME" "Creating Docker volume '${VOLUME_NAME}'"
else
    log_success "Docker volume '${VOLUME_NAME}' already exists."
fi

# --- 4. Build Docker Image ---
echo -e "\n--- ${YELLOW}Step 4: Build Docker Image${NC} ---"
log_info "Building '${IMAGE_NAME}' image (this may take a few minutes)..."
if docker build -t "$IMAGE_NAME" .; then
    log_success "Docker image built successfully"
else
    log_error "Failed to build Docker image"
fi

# --- 5. Run the Container ---
echo -e "\n${GREEN}======================================================${NC}"
echo -e "${GREEN}🎉 ALL INSTALLATION PROCESSES COMPLETED! 🎉${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
echo -e "${BLUE}🚀 Starting your Nexus Node container...${NC}"

# Stop and remove existing container with the same name if it's running
if docker ps -a --format '{{.Names}}' | grep -Eq "^${CONTAINER_NAME}\$"; then
    log_info "Stopping and removing existing container '${CONTAINER_NAME}'..."
    docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    log_success "Existing container removed."
fi

echo -e "\n${BLUE}Launching Nexus Node container '${CONTAINER_NAME}' with persistent volume '${VOLUME_NAME}'...${NC}"
echo -e "${YELLOW}Anda akan memasuki kontainer. Jika ini adalah jalankan pertama, Anda akan diminta memasukkan Wallet Address atau Node ID.${NC}"
echo -e "${YELLOW}Setelah input valid, node akan langsung dimulai dan menampilkan log.${NC}"
echo -e "${YELLOW}Jika Node ID sudah tersimpan, node akan otomatis dimulai tanpa meminta input lagi.${NC}"
echo "========================================================"

# Run the container with the defined volume and name, without --rm
docker run -it \
    --name "$CONTAINER_NAME" \
    -v "$VOLUME_NAME:${NODE_ID_PERSIST_DIR}" \
    "$IMAGE_NAME"

echo "========================================================"
echo -e "${GREEN}✅ Sesi kontainer Nexus Node berakhir.${NC}"
echo -e "Untuk memulai ulang node ini (jika berhenti): ${YELLOW}docker start -ai ${CONTAINER_NAME}${NC}"
echo -e "Untuk melihat log di latar belakang: ${YELLOW}docker logs -f ${CONTAINER_NAME}${NC}"
echo -e "Untuk menghentikan kontainer latar belakang: ${YELLOW}docker stop ${CONTAINER_NAME}${NC}"
echo -e "Untuk menghapus data persisten (dan memulai dari awal): ${YELLOW}docker volume rm ${VOLUME_NAME}${NC}"
echo
echo "Log instalasi ini ada di: ${YELLOW}/tmp/nexus_install.log${NC}"
