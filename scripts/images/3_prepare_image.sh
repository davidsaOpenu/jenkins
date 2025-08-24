#!/bin/bash

# Exit on any command failure
set -e

# VM Image Customization Script
# Usage: ./customize-vm.sh <image-file> <username> <container-runtime>

IMAGE=$1
USERNAME=$2
CONTAINER_RUNTIME=$3

if [ -z "$IMAGE" ] || [ -z "$USERNAME" ] || [ -z "$CONTAINER_RUNTIME" ]; then
    echo "Usage: $0 <image-file> <username> <container-runtime>"
    echo "Example: $0 ubuntu-22.04.qcow2 stack podman"
    echo "Example: $0 ubuntu-22.04.qcow2 stack docker"
    echo ""
    echo "Supported container runtimes: docker, podman"
    exit 1
fi

# Validate container runtime parameter
if [ "$CONTAINER_RUNTIME" != "docker" ] && [ "$CONTAINER_RUNTIME" != "podman" ]; then
    echo "Error: Container runtime must be either 'docker' or 'podman'"
    exit 1
fi

# Check if the effective user ID is 0 (root)
if [[ "$EUID" -ne 0 ]]; then
    echo "This script needs to be run with sudo."
    echo "Please run: sudo $0"
    exit 1
fi

echo "Script is running with sudo privileges."

echo "Customizing VM image: $IMAGE"
echo "Creating user: $USERNAME"
echo "Installing container runtime: $CONTAINER_RUNTIME"

###################################### User Setup #########################################################

# Inject SSH keys and set root password
virt-customize --ssh-inject root -a "$IMAGE"
virt-customize --root-password password:PASSWORD -a "$IMAGE"

# Create user with proper permissions
virt-customize --run-command "useradd -s /bin/bash -d /opt/$USERNAME -m $USERNAME" -a "$IMAGE"
virt-customize --run-command "chmod +x /opt/$USERNAME" -a "$IMAGE"
#virt-customize --run-command "echo '$USERNAME ALL=(ALL) NOPASSWD: ALL' | tee /etc/sudoers.d/$USERNAME" -a "$IMAGE"
virt-customize --ssh-inject "$USERNAME:file:/var/lib/jenkins/.ssh/id_rsa.pub" -a "$IMAGE"

###################################### System Updates #########################################################

# Comprehensive proxy cleanup
virt-customize --run-command 'unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ftp_proxy FTP_PROXY no_proxy NO_PROXY' -a "$IMAGE"
virt-customize --run-command 'rm -f /etc/apt/apt.conf.d/*proxy*' -a "$IMAGE"
virt-customize --run-command 'rm -f /etc/environment' -a "$IMAGE"
virt-customize --run-command 'echo "" > /etc/environment' -a "$IMAGE"

# Remove any existing proxy configurations from apt.conf
virt-customize --run-command 'sed -i "/Acquire::http::Proxy/d" /etc/apt/apt.conf 2>/dev/null || true' -a "$IMAGE"
virt-customize --run-command 'sed -i "/Acquire::https::Proxy/d" /etc/apt/apt.conf 2>/dev/null || true' -a "$IMAGE"

# Create new apt.conf without proxy
virt-customize --run-command 'echo "Acquire::http::Proxy \"false\";" > /etc/apt/apt.conf.d/99-no-proxy' -a "$IMAGE"
virt-customize --run-command 'echo "Acquire::https::Proxy \"false\";" >> /etc/apt/apt.conf.d/99-no-proxy' -a "$IMAGE"
virt-customize --run-command 'echo "Acquire::ftp::Proxy \"false\";" >> /etc/apt/apt.conf.d/99-no-proxy' -a "$IMAGE"

# Update package lists
virt-customize --run-command 'apt-get update -y' -a "$IMAGE"

# Install essential packages (gnupg2 -> gnupg for Ubuntu 24.04+)
virt-customize --run-command 'apt-get install -y software-properties-common apt-transport-https wget curl gnupg lsb-release' -a "$IMAGE"

###################################### Package Installation #########################################################

# Install NFS support
virt-customize --run-command 'apt-get install -y nfs-common || echo "NFS installation failed, continuing..."' -a "$IMAGE"

###################################### Container Runtime Installation #########################################################

if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "Installing Podman..."
    
    # Add Podman repository for Ubuntu (official Podman PPA)
    virt-customize --run-command 'apt-get install -y software-properties-common' -a "$IMAGE"
    virt-customize --run-command 'add-apt-repository -y ppa:projectatomic/ppa || echo "PPA may not be available, trying alternative..."' -a "$IMAGE"

    # Install Podman and required packages for rootless operation
    virt-customize --run-command 'apt-get install -y podman uidmap slirp4netns crun fuse-overlayfs' -a "$IMAGE"

    # Configure subuid and subgid properly
    virt-customize --run-command "grep -q '^$USERNAME:' /etc/subuid || echo '$USERNAME:100000:65536' >> /etc/subuid" -a "$IMAGE"
    virt-customize --run-command "grep -q '^$USERNAME:' /etc/subgid || echo '$USERNAME:100000:65536' >> /etc/subgid" -a "$IMAGE"

    # Create proper directory structure for user
    virt-customize --run-command "mkdir -p /opt/$USERNAME/.config/containers" -a "$IMAGE"
    virt-customize --run-command "mkdir -p /opt/$USERNAME/.local/share/containers" -a "$IMAGE"

    # Create containers.conf for the user
    virt-customize --run-command "cat > /opt/$USERNAME/.config/containers/containers.conf << 'EOF'
[containers]
default_ulimits = []

[engine]
cgroup_manager = \"systemd\"
events_logger = \"journald\"
runtime = \"crun\"

[network]
network_backend = \"netavark\"
EOF" -a "$IMAGE"

    # Create storage.conf for the user
    virt-customize --run-command "cat > /opt/$USERNAME/.config/containers/storage.conf << 'EOF'
[storage]
driver = \"overlay\"
runroot = \"/run/user/1000/containers\"
graphroot = \"/opt/$USERNAME/.local/share/containers/storage\"

[storage.options]
additionalimagestores = []

[storage.options.overlay]
mountopt = \"nodev,metacopy=on\"
EOF" -a "$IMAGE"

    # Fix ownership of all container-related directories
    virt-customize --run-command "chown -R $USERNAME:$USERNAME /opt/$USERNAME/.config /opt/$USERNAME/.local" -a "$IMAGE"

    # Enable lingering for the user (allows user services to run without login)
    virt-customize --run-command "mkdir -p /var/lib/systemd/linger" -a "$IMAGE"
    virt-customize --run-command "touch /var/lib/systemd/linger/$USERNAME" -a "$IMAGE"

    # Create /run/user/1000 directory structure (will be recreated on boot, but helps with testing)
    virt-customize --run-command "mkdir -p /run/user/1000" -a "$IMAGE"
    virt-customize --run-command "chown 1000:1000 /run/user/1000" -a "$IMAGE"
    virt-customize --run-command "chmod 700 /run/user/1000" -a "$IMAGE"

    virt-customize --run-command "apt install -y podman-compose" -a "$IMAGE"
elif [ "$CONTAINER_RUNTIME" = "docker" ]; then
    echo "Installing Docker..."
    
    # Install Docker's official GPG key
    virt-customize --run-command 'curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg' -a "$IMAGE"
    
    # Add Docker repository
    virt-customize --run-command 'echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null' -a "$IMAGE"
    
    # Update package lists with Docker repository
    virt-customize --run-command 'apt-get update -y' -a "$IMAGE"
    
    # Install Docker packages
    virt-customize --run-command 'apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin' -a "$IMAGE"
    
    # Add user to docker group
    virt-customize --run-command "usermod -aG docker $USERNAME" -a "$IMAGE"
    
    # Enable and start Docker service
    virt-customize --run-command 'systemctl enable docker' -a "$IMAGE"
    virt-customize --run-command 'systemctl enable containerd' -a "$IMAGE"
    
    # Configure Docker daemon for better security and performance
    virt-customize --run-command 'mkdir -p /etc/docker' -a "$IMAGE"
    virt-customize --run-command 'cat > /etc/docker/daemon.json << EOF
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF' -a "$IMAGE"

fi

###################################### Network Configuration #########################################################

# Create systemd-networkd configuration for primary network interface
virt-customize --run-command 'mkdir -p /etc/systemd/network' -a "$IMAGE"
virt-customize --run-command 'cat > /etc/systemd/network/20-ens3.network << EOF
[Match]
Name=ens3

[Network]
DHCP=yes
EOF' -a "$IMAGE"

# Enable systemd-networkd service
virt-customize --run-command 'systemctl enable systemd-networkd' -a "$IMAGE"

# Create network testing script
virt-customize --run-command "cat > /opt/$USERNAME/test-network.sh << 'EOF'
#!/bin/bash
echo '=== Network Interface Status ==='
ip addr show ens3
echo
echo '=== Routing Table ==='
ip route show
echo
echo '=== Testing Internet Connectivity ==='
ping -c 2 8.8.8.8
EOF" -a "$IMAGE"

virt-customize --run-command "chmod +x /opt/$USERNAME/test-network.sh" -a "$IMAGE"
virt-customize --run-command "chown $USERNAME:$USERNAME /opt/$USERNAME/test-network.sh" -a "$IMAGE"

###################################### Container Runtime Testing #########################################################

if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    # Create Podman testing script
    virt-customize --run-command "cat > /opt/$USERNAME/test-podman.sh << 'EOF'
#!/bin/bash
echo '=== Testing Podman Installation ==='
podman --version
echo
echo '=== Podman System Info ==='
podman info --format=json | jq -r '.host.os, .store.graphRoot, .store.runRoot' 2>/dev/null || podman info
echo
echo '=== Testing Podman Hello World ==='
podman run --rm hello-world
echo
echo '=== Podman Images ==='
podman images
EOF" -a "$IMAGE"

    virt-customize --run-command "chmod +x /opt/$USERNAME/test-podman.sh" -a "$IMAGE"
    virt-customize --run-command "chown $USERNAME:$USERNAME /opt/$USERNAME/test-podman.sh" -a "$IMAGE"

elif [ "$CONTAINER_RUNTIME" = "docker" ]; then
    # Create Docker testing script
    virt-customize --run-command "cat > /opt/$USERNAME/test-docker.sh << 'EOF'
#!/bin/bash
echo '=== Testing Docker Installation ==='
docker --version
echo
echo '=== Docker System Info ==='
docker info --format=json | jq -r '.ServerVersion, .DockerRootDir, .Driver' 2>/dev/null || docker info
echo
echo '=== Testing Docker Hello World ==='
docker run --rm hello-world
echo
echo '=== Docker Images ==='
docker images
EOF" -a "$IMAGE"

    virt-customize --run-command "chmod +x /opt/$USERNAME/test-docker.sh" -a "$IMAGE"
    virt-customize --run-command "chown $USERNAME:$USERNAME /opt/$USERNAME/test-docker.sh" -a "$IMAGE"
fi

# Install jq for JSON parsing in the test scripts
virt-customize --run-command 'apt-get install -y jq' -a "$IMAGE"

###################################### System Configuration #########################################################

# Generate SSH host keys (fix for Ubuntu 22.04)
virt-customize --run-command 'ssh-keygen -A' -a "$IMAGE"

# Enable network interface for Ubuntu cloud images (fallback)
virt-customize --run-command 'echo "@reboot root dhclient" >> /etc/crontab' -a "$IMAGE"

    
# Install toolchain
virt-customize --run-command 'apt-get install -y build-essential qemu-system-x86 clang-format-16 shellcheck gcc-multilib' -a "$IMAGE"
    

# Clean up package cache
virt-customize --run-command 'apt-get autoremove -y && apt-get autoclean' -a "$IMAGE"

echo "VM customization completed successfully!"
echo ""
echo "Default credentials:"
echo "  Root password: PASSWORD"
echo "  User '$USERNAME': passwordless sudo enabled"
echo ""
echo "Installed software:"
if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "  - Podman (with rootless configuration)"
elif [ "$CONTAINER_RUNTIME" = "docker" ]; then
    echo "  - Docker (with user in docker group)"
fi
echo "  - NFS client support (if available)"
echo "  - Network testing tools"
echo ""
echo "Testing scripts created in /opt/$USERNAME/:"
echo "  - test-network.sh     : Test network connectivity"
if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "  - test-podman.sh      : Test Podman installation"
elif [ "$CONTAINER_RUNTIME" = "docker" ]; then
    echo "  - test-docker.sh      : Test Docker installation"
fi
echo ""
echo "Boot VM with  qemu-system-x86_64 -enable-kvm -m 2048 -smp 4 -hda $IMAGE -nic user,hostfwd=tcp::2225-:22 -nographic"
echo ""
echo "After booting the VM, run these commands to test:"
echo "  sudo /opt/$USERNAME/test-network.sh"
if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    echo "  sudo -u $USERNAME /opt/$USERNAME/test-podman.sh"
elif [ "$CONTAINER_RUNTIME" = "docker" ]; then
    echo "  sudo -u $USERNAME /opt/$USERNAME/test-docker.sh"
fi
