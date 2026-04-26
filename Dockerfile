FROM pytorch/pytorch:latest

# Install system deps (git + pip)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install everything once at build time (not at runtime!)
# This saves ~3 minutes at instance startup on Vast.ai
RUN pip3 install --break-system-packages demucs && \
    git clone https://github.com/ysharma3501/LavaSR.git /tmp/lavasr && \
    pip3 install --break-system-packages /tmp/lavasr && \
    ln -sf /usr/local/lib/python3.12/dist-packages/LavaSR /usr/local/lib/python3.12/dist-packages/lavasr

WORKDIR /workspace
