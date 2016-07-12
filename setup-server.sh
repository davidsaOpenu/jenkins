#!/bin/sh

# based on https://www.howtoforge.com/tutorial/ubuntu-jenkins-automation-server/

set -e

##############################################################################
#  Cleanup
sudo systemctl stop docker
sudo systemctl stop jenkins
sudo apt-get -V -y remove docker | true
sudo apt-get -V -y remove docker-engine | true
sudo apt-get -V -y remove docker.io | true
sudo apt-get -V -y remove containerd | true
sudo apt-get -V -y remove runc | true
sudo apt-get -V -y remove nginx* | true
sudo apt-get -V -y remove jenkins | true
sudo sudo apt -y  autoremove

##############################################################################
# Install docker according to https://docs.docker.com/engine/install/ubuntu/
sudo apt-get -y update

sudo apt-get -y install \
    apt-transport-https \
    ca-certificates \
    curl \
    gnupg \
    lsb-release


sudo apt -y install docker.io


sudo systemctl start docker

sudo docker run hello-world

sudo systemctl status docker


##############################################################################
# Workaround  https://docs.docker.com/compose/install/#install-compose 
sudo rm -r /usr/local/bin/docker-compose
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose

docker-compose --version

##############################################################################
# add jenkins user
sudo useradd -m -d /var/lib/jenkins jenkins
# add jenkins user to the docker group
sudo usermod -aG docker jenkins

##############################################################################
# to avoid fatal: unable to access '<my_git>.git/': gnutls_handshake() failed:
#                 An unexpected TLS packet was received.
# run git config for the jenkins user
git config --global https.proxy https://proxy.cslab.openu.ac.il:80
git config --global http.proxy http://proxy.cslab.openu.ac.il:80
# https://stackoverflow.com/questions/51088635/git-clone-error-gnutls-handshake-failed-an-unexpected-tls-packet-was-receive

##############################################################################
# install Java 11
sudo apt install default-jre openjdk-11-jdk
java -version

##############################################################################
# Install jenkins - https://www.jenkins.io/doc/book/installing/
sudo apt-get -y install jenkins
# post install admin pswd /var/lib/jenkins/secrets/initialAdminPassword

#install multiple SCM, gerrit trigger plugins


# Configure Global Security
#     Security Realm
#         Unix user/group database 
#     Authorization
#         Allow anonymous read access (TODO: matrix based security)

# Uncategorized
#     gerrit-trigger
# Gerrit Connection Setting -> Name -> review.gerrithub.io
# Gerrit Connection Setting -> Hostname -> review.gerrithub.io
# Gerrit Connection Setting -> Frontend URL -> https://review.gerrithub.io
# Gerrit Connection Setting -> Port -> 29418

# linuxUserName's public key has to be registered with gerritUserName
# Gerrit Connection Setting -> SSH Keyfile -> /home/<linuxUserName>/.ssh/id_rsa
# Gerrit Connection Setting -> SSH Keyfile Password -> The password for the private
#                          key file. Set to an empty value if there is no password.
# Test the connection from the gerrit connection settings page and get a "success"
# indication. Then restart your jenkins server and make sure that the gerrit server
# verification status become green (seems there is a bug with the stutus indicatior
# that remains red untill the next restart)
# 
# To test the connecttion from the CLI 
#       ssh -p 29418 gerritUserName@review.gerrithub.io gerrit ls-projects
# other gerrit commands: https://review.gerrithub.io/Documentation/cmd-index.html

##############################################################################
# how to add jenkins scrupt to init.d (for some reason it was not created during the
# installation)

##############################################################################
# run (until init.d script is created)
# http://<server IP>/jenkins/

sudo \
/usr/bin/daemon --name=jenkins \
                --inherit \
                --env=JENKINS_HOME=/var/lib/jenkins \
                --output=/var/log/jenkins/jenkins.log \
                --pidfile=/var/run/jenkins/jenkins.pid \
                -- /usr/bin/java \
                    -Djava.awt.headless=true \
                    -jar /usr/share/jenkins/jenkins.war \
                    --webroot=/var/cache/jenkins/war \
                    --httpPort=8080 \
                    --prefix=/jenkins

# or 
sudo \
/usr/bin/java \
 -Djava.awt.headless=true \
 -jar /usr/share/jenkins/jenkins.war \
 --webroot=/var/cache/jenkins/war \
 --httpPort=8080 \
 --prefix=/jenkins


# nohup /usr/bin/java -jar /usr/share/jenkins/jenkins.war &> jenkins.log &

##############################################################################
# 
# iptables -A PREROUTING -t nat -i eth0 -p tcp --dport 80 -j REDIRECT --to-port 8080


