FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Core utilities
RUN apt-get update && apt-get install -y --no-install-recommends \
      sudo bash-completion curl wget ca-certificates jq vim nano unzip \
      git openssh-client openssh-server \
      ansible \
      docker.io docker-compose-v2 \
      python3 python3-pip python3-yaml \
      iproute2 net-tools iptables dnsutils \
      nfs-kernel-server nfs-common \
      rsync logrotate cron sysstat procps \
      lvm2 selinux-utils policycoreutils attr \
      nginx locales tzdata \
    && locale-gen en_US.UTF-8 \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*

# Terraform 1.9.0
RUN curl -fsSL -o /tmp/tf.zip https://releases.hashicorp.com/terraform/1.9.0/terraform_1.9.0_linux_amd64.zip \
    && unzip -q /tmp/tf.zip -d /usr/local/bin/ \
    && rm /tmp/tf.zip \
    && terraform version

# kubectl (latest stable)
RUN KV=$(curl -fsSL https://dl.k8s.io/release/stable.txt) \
    && curl -fsSL -o /usr/local/bin/kubectl "https://dl.k8s.io/release/${KV}/bin/linux/amd64/kubectl" \
    && chmod +x /usr/local/bin/kubectl \
    && kubectl version --client=true

# Create runner user with sudo; docker group GID gets remapped at runtime
RUN useradd -m -s /bin/bash runner \
    && mkdir -p /etc/sudoers.d \
    && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner \
    && chmod 0440 /etc/sudoers.d/runner \
    && groupadd -f docker \
    && usermod -aG docker runner \
    && mkdir -p /home/runner/.kube \
    && chown -R runner:runner /home/runner/.kube \
    && echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/runner/.bashrc \
    && echo 'export KUBECONFIG=$HOME/.kube/config' >> /home/runner/.bashrc

WORKDIR /home/runner
CMD ["sleep", "infinity"]
