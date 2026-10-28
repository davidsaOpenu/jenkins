#!/usr/bin/env bash
# Prerequisites of this repo's own jobs on the machine that builds them:
# - jenkins: scripts/run.sh — vagrant-libvirt VMs (central + two student
#   nodes), rsync, git-review, Python YAML;
# - periodic-tasks: docker (the xv6 test image, stale container cleanup).
# Jenkins itself (Java, plugins, nginx) is central_deploy's job, not this.
#
#   sudo ./1_install_prereqs.sh
#
# Installs for the invoking user (SUDO_USER): vagrant plugins in their
# ~/.vagrant.d, membership in the libvirt, kvm and docker groups. Disaster
# recovery (setup_central.sh --with-repo-jobs) runs it with
# SUDO_USER=jenkins. Safe to re-run.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Please run this script as root or using sudo!"
  exit 1
fi

OS_ID=""
VERSION_ID=""

if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=${ID}
    VERSION_ID=${VERSION_ID:-}
elif [ -f /etc/lsb-release ]; then
    . /etc/lsb-release
    OS_ID=${DISTRIB_ID}
    VERSION_ID=${DISTRIB_RELEASE:-}
fi

if [ -z "$OS_ID" ]; then
    echo "Unsupported OS: Cannot determine distribution."
    exit 1
fi

# normalize OS_ID to lowercase for case-insensitive matching
OS_ID=$(echo "$OS_ID" | tr '[:upper:]' '[:lower:]')

check_success() {
    if [ $? -ne 0 ]; then
        echo "Error: $1 failed."
        exit 1
    fi
}

USERNAME="${SUDO_USER:-root}"

post_install_common() {
    systemctl enable --now libvirtd
    check_success "!!"
    systemctl enable --now docker
    check_success "!!"

    usermod -a -G libvirt,kvm,docker "$USERNAME"
    check_success "!!"

    # Same pins as swiftacular's 1_install_prereqs.sh, so the two can share
    # one user's ~/.vagrant.d: fog-libvirt 0.12.2 because vagrant-libvirt
    # 0.12.x passes libvirt_ip_command, which fog-libvirt >= 0.13 rejects;
    # fog-json 1.2.0 because newer releases need a json gem newer than the
    # one embedded in Vagrant 2.4.0. Pins go first.
    sudo -u "$USERNAME" -H vagrant plugin install fog-json --plugin-version 1.2.0
    check_success "!!"
    sudo -u "$USERNAME" -H vagrant plugin install fog-libvirt --plugin-version 0.12.2
    check_success "!!"
    sudo -u "$USERNAME" -H vagrant plugin install vagrant-libvirt
    check_success "!!"
}

install_for_fedora() {
    dnf install -y qemu-kvm \
                   libvirt \
                   libvirt-devel \
                   ruby-devel \
                   gcc \
                   make \
                   rsync \
                   curl \
                   git \
                   git-review \
                   python3-pyyaml \
                   openssh-clients \
                   vagrant \
                   moby-engine
    check_success "!!"
}

install_for_centos() {
    dnf install -y dnf-plugins-core epel-release
    check_success "!!"

    # Neither Vagrant nor Docker is packaged for the RHEL family
    dnf config-manager --add-repo https://rpm.releases.hashicorp.com/RHEL/hashicorp.repo
    check_success "!!"
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
    check_success "!!"

    dnf install -y qemu-kvm \
                   libvirt \
                   libvirt-devel \
                   ruby-devel \
                   gcc \
                   make \
                   rsync \
                   curl \
                   git \
                   git-review \
                   python3-pyyaml \
                   openssh-clients \
                   vagrant-2.4.0 \
                   docker-ce \
                   docker-ce-cli \
                   containerd.io \
                   docker-buildx-plugin
    check_success "!!"
}

install_for_ubuntu() {
    apt-get update
    check_success "!!"
    apt-get install -y \
        qemu-kvm \
        libvirt-dev \
        libvirt-daemon-system \
        libvirt-clients \
        build-essential \
        ruby-dev \
        rsync \
        curl \
        wget \
        git \
        git-review \
        python3-yaml \
        openssh-client \
        docker.io
    check_success "!!"

    # Same Vagrant as swiftacular's 1_install_prereqs.sh
    if ! dpkg -s vagrant &>/dev/null; then
        local deb
        deb=$(mktemp -d)/vagrant_2.4.0-1_amd64.deb
        wget -nv -O "$deb" https://releases.hashicorp.com/vagrant/2.4.0/vagrant_2.4.0-1_amd64.deb
        check_success "!!"
        apt-get install -y "$deb"
        check_success "!!"
        rm -rf "$(dirname "$deb")"
    fi
}

case "$OS_ID" in
  fedora)
    if [[ "$VERSION_ID" != "42" ]]; then
      echo "Only Fedora 42 is supported. Detected: Fedora $VERSION_ID"
      exit 1
    fi
    install_for_fedora
    ;;
  centos|rhel|rocky|almalinux)
    if [[ "${VERSION_ID%%.*}" != "9" ]]; then
      echo "Only version 9 of CentOS Stream / RHEL / Rocky / AlmaLinux is supported. Detected: $OS_ID $VERSION_ID"
      exit 1
    fi
    install_for_centos
    ;;
  ubuntu)
    if [[ "$VERSION_ID" != "22.04" ]]; then
      echo "Only Ubuntu 22.04 is supported. Detected: Ubuntu $VERSION_ID"
      exit 1
    fi
    install_for_ubuntu
    ;;
  *)
    echo "Unsupported OS: $OS_ID $VERSION_ID. Only Fedora 42, CentOS Stream / RHEL / Rocky / AlmaLinux 9 and Ubuntu 22.04 are supported."
    exit 1
    ;;
esac

post_install_common

echo "System preparation for $OS_ID $VERSION_ID completed successfully."
