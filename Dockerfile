FROM pytorch/pytorch:latest

# Install SSH server + git (needed for cloning LavaSR)
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    git \
    && rm -rf /var/lib/apt/lists/*

# SSH daemon requirements
RUN mkdir -p /run/sshd && chmod 755 /run/sshd

# Pre-authorize SSH keys at build time (Vast.ai injects keys via startup script too,
# but having them at build time avoids any startup timing issues)
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Install LavaSR + Demucs
RUN pip install demucs && \
    git clone https://github.com/ysharma3501/LavaSR.git /tmp/lavasr && \
    pip install /tmp/lavasr && \
    ln -sf /usr/local/lib/python3.12/dist-packages/LavaSR /usr/local/lib/python3.12/dist-packages/lavasr

WORKDIR /workspace

# Wrapper script: start sshd FIRST, then Jupyter
COPY start_services.sh /usr/local/bin/start_services.sh
RUN chmod +x /usr/local/bin/start_services.sh

CMD ["/usr/local/bin/start_services.sh"]
