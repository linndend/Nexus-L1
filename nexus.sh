#!/bin/bash

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}🔧 Nexus Container Fix Script${NC}"
echo "====================================="

# 1. Check current container status
echo -e "\n${YELLOW}1. Checking current setup...${NC}"
if docker images | grep -q "nexus-node"; then
    echo -e "${GREEN}✅ nexus-node image found${NC}"
else
    echo -e "${RED}❌ nexus-node image not found. Please run installer first.${NC}"
    exit 1
fi

# 2. Create a new fixed entrypoint
echo -e "\n${YELLOW}2. Creating fixed entrypoint...${NC}"
cat > /tmp/entrypoint.sh << 'EOF'
#!/bin/bash

# Color Variables
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to cleanup debug logs
cleanup_debug_logs() {
    rm -f /var/log/nexus/debug.log 2>/dev/null
    rm -f /tmp/nexus-debug-*.log 2>/dev/null
}

# Function to handle container shutdown gracefully
cleanup() {
    echo -e "\n${YELLOW}Shutting down node gracefully...${NC}"
    cleanup_debug_logs
    exit 0
}

trap cleanup SIGTERM SIGINT SIGQUIT

# Auto-run if wallet is provided via env var, regardless of TTY
if [ -n "$AUTO_RUN" ] || [ -n "$WALLET_ADDRESS" ]; then
    if [ -n "$WALLET_ADDRESS" ]; then
        echo "Auto-running with wallet address: $WALLET_ADDRESS"
        if nexus-network register-user --wallet-address "$WALLET_ADDRESS"; then
            nexus-network register-node && nexus-network start
        else
            echo "Failed to register user"
            exit 1
        fi
    else
        echo -e "${RED}ERROR: AUTO_RUN set but no wallet address provided.${NC}"
        exit 1
    fi
    exit 0
fi

# Original interactive menu code follows
show_menu() {
    clear
    echo -e "${BLUE}===================================${NC}"
    echo -e "${YELLOW}      🚀 Nexus Node Runner 🚀     ${NC}"
    echo -e "${BLUE}===================================${NC}"
    echo "Select mode to run the node:"
    echo "  1) Run with Wallet Address"
    echo "  2) Run with Node ID"
    echo "  3) Test nexus binary"
    echo "  4) Exit"
    echo -e "${BLUE}-----------------------------------${NC}"
}

run_with_wallet() {
    echo -e "\n${BLUE}=== Running with Wallet Address ===${NC}"
    echo -n "Enter your Wallet Address: "
    read -r wallet_address

    if [ -z "$wallet_address" ]; then
        echo -e "${RED}❌ Wallet Address cannot be empty${NC}"
        return 1
    fi

    echo -e "${BLUE}Wallet: ${GREEN}$wallet_address${NC}"
    echo -e "${BLUE}Registering user...${NC}"

    if nexus-network register-user --wallet-address "$wallet_address"; then
        echo -e "${GREEN}✅ User registered${NC}"
        echo -e "${BLUE}Registering node...${NC}"

        if nexus-network register-node; then
            echo -e "${GREEN}✅ Node registered${NC}"
            echo -e "${BLUE}Starting node...${NC}"
            nexus-network start
        else
            echo -e "${RED}❌ Failed to register node${NC}"
        fi
    else
        echo -e "${RED}❌ Failed to register user${NC}"
    fi
}

run_with_node_id() {
    echo -e "\n${BLUE}=== Running with Node ID ===${NC}"
    echo -n "Enter your Node ID: "
    read -r node_id

    if [ -z "$node_id" ]; then
        echo -e "${RED}❌ Node ID cannot be empty${NC}"
        return 1
    fi

    echo -e "${BLUE}Node ID: ${GREEN}$node_id${NC}"
    echo -e "${BLUE}Starting node...${NC}"
    nexus-network start --node-id "$node_id"
}

test_binary() {
    echo -e "\n${BLUE}=== Testing Nexus Binary ===${NC}"
    echo "Binary location: $(which nexus-network)"
    echo "Binary permissions: $(ls -la /usr/local/bin/nexus-network)"

    echo -e "\n${YELLOW}Testing binary execution:${NC}"
    /usr/local/bin/nexus-network --help 2>/dev/null || \
    /usr/local/bin/nexus-network version 2>/dev/null || \
    echo "Binary executed (no help/version available)"

    echo -e "\n${YELLOW}Press Enter to continue...${NC}"
    read -r
}

while true; do
    show_menu
    echo -n "Select option (1-4): "
    read -r choice

    case $choice in
        1) run_with_wallet ;;
        2) run_with_node_id ;;
        3) test_binary ;;
        4) echo "Goodbye!"; exit 0 ;;
        *) echo -e "${RED}Invalid option${NC}"; sleep 2 ;;
    esac
done
EOF

chmod +x /tmp/entrypoint.sh

# 3. Rebuild container with fixed entrypoint
echo -e "\n${YELLOW}3. Rebuilding container with fixed entrypoint...${NC}"

# Go to nexus directory
cd ~/.nexus/bin || { echo "Cannot find nexus directory"; exit 1; }

# Copy fixed entrypoint
cp /tmp/entrypoint.sh ./entrypoint.sh

# Rebuild
echo -e "${BLUE}Rebuilding Docker image...${NC}"
docker build -t nexus-node . --no-cache

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ Container rebuilt successfully${NC}"
    echo -e "\n${YELLOW}Now testing the fixed container:${NC}"
    echo "======================================="
    # Updated command to pass auto-run environment variables if desired
    # For exact original command format but with features inside entrypoint:
    docker run -it --rm nexus-node
else
    echo -e "${RED}❌ Failed to rebuild container${NC}"
fi
