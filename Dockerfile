FROM pytorch/pytorch:latest

# Install SSH server + git (needed for cloning LavaSR)
RUN apt-get update && apt-get install -y --no-install-recommends \
    openssh-server \
    git \
    && rm -rf /var/lib/apt/lists/*

# SSH daemon requirements
RUN mkdir -p /run/sshd && chmod 755 /run/sshd

# Pre-authorize SSH keys at build time
RUN mkdir -p /root/.ssh && chmod 700 /root/.ssh

# Install LavaSR + Demucs + fix symlink (all in one RUN to share context)
RUN pip install demucs && \
    git clone https://github.com/ysharma3501/LavaSR.git /tmp/lavasr && \
    pip install /tmp/lavasr && \
    PIP_PATH=$(pip show lavasr 2>/dev/null | grep "Location:" | cut -d' ' -f2) && \
    echo "LavaSR installed at: $PIP_PATH" && \
    if [ -n "$PIP_PATH" ] && [ -d "$PIP_PATH/LavaSR" ]; then \
        ln -sf "$PIP_PATH/LavaSR" "$PIP_PATH/lavasr" && echo "Symlink created"; \
    else \
        find /usr /opt /root -name "LavaSR" -type d 2>/dev/null | while read d; do \
            PARENT=$(dirname "$d"); \
            ln -sf "$d" "$PARENT/lavasr" 2>/dev/null && echo "Symlink created at $PARENT/lavasr" && break; \
        done; \
    fi || echo "Symlink fix skipped"

WORKDIR /workspace

# Wrapper script: start sshd FIRST, then Jupyter
COPY start_services.sh /usr/local/bin/start_services.sh
RUN chmod +x /usr/local/bin/start_services.sh

CMD ["/usr/local/bin/start_services.sh"]
