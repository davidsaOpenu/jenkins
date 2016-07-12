#!/bin/sh

set -e


###############################################
#  ansible
#sudo apt-add-repository -y ppa:ansible/ansible
#sudo apt-get update
#sudo apt-get install -y ansible

###############################################
#  editors
sudo apt-get install vim


###############################################
#  source control
sudo apt-get install git


###############################################
# qemu, kvm
sudo apt-get install qemu
sudo apt-get install qemu-kvm
sudo adduser jenkins kvm

###############################################
# SKIP qt3 (no qt3 available for ubuntu 14.04)
#sudo apt-get install qt3-dev-tools


###############################################
# osc-osd dependenceies
sudo apt-get install libsqlite3-dev


###############################################
# simulator dependencies
sudo apt-get install zlib1g-dev libsdl-image1.2-dev libgnutls-dev libvncserver-dev libpci-dev libaio-dev



###############################################
# gcc g++
sudo apt-get install gcc-4.4 g++-4.4 
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-4.4 60 --slave /usr/bin/g++ g++ /usr/bin/g++-4.4
sudo update-alternatives --config gcc



###############################################
# google-test framework
wget https://github.com/google/googletest/archive/release-1.7.0.tar.gz
tar xvf release-1.7.0.tar.gz
sudo mv googletest-release-1.7.0 /opt/gtest
sudo mkdir /opt/gtest/lib; cd /opt/gtest/lib
sudo apt-get install cmake
sudo cmake .. 
sudo make 


###############################################
#
sudo iptables -A PREROUTING -t nat -i eth0 -p tcp --dport 80 -j REDIRECT --to-port 8080



###############################################
#




###############################################
#



###############################################
#




