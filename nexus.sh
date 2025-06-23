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

# Function display 
spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='|/-\'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_with_spinner() {
    local cmd="$1"
    local msg="$2"
    log_info "$msg"
    ($cmd) &> /dev/null &
    spinner $!
    wait $!
    if [ $? -eq 0 ]; then
        log_success "${msg} completed."
    else
        log_error "Failed to run: ${msg}"
    fi
}

clear
echo -e "${BLUE}==============================================${NC}"
echo -e "${YELLOW}    🚀 Nexus Node Automatic Installer 🚀    ${NC}"
echo -e "${BLUE}==============================================${NC}"
echo

# --- 1. Dependency Installation ---
echo -e "\n--- ${YELLOW}Step 1: System Dependency Installation${NC} ---"
run_with_spinner "sudo apt-get update -y && sudo apt-get upgrade -y" "Updating package list"
run_with_spinner "sudo apt-get install -y curl ca-certificates docker.io libssl-dev build-essential" "Installing curl, docker, and build-essential"

# --- 2. Nexus CLI Installation ---
echo -e "\n--- ${YELLOW}Step 2: Nexus CLI Installation${NC} ---"
CLI_DIR="$HOME/.nexus"
CLI_PATH="$CLI_DIR/bin/nexus-network"

if [ -f "$CLI_PATH" ]; then
    log_warn "Nexus CLI is already installed. Skipping installation."
else
    log_info "Downloading and installing Nexus CLI..."

    if curl -sSfL https://cli.nexus.xyz/ | sh; then
        log_success "Nexus CLI installed successfully."
    else
        log_error "Failed to download or install Nexus CLI."
    fi
fi

# Verify CLI
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
run_with_spinner "docker build -t nexus-node ." "Building 'nexus-node' image"


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
