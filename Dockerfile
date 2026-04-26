FROM pytorch/pytorch:latest

# Install system deps (git)
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install everything once at build time (not at runtime!)
# This saves ~3 minutes at instance startup on Vast.ai
# Use conda's pip (pytorch image uses conda)
RUN /opt/conda/bin/pip install demucs && \
    git clone https://github.com/ysharma3501/LavaSR.git /tmp/lavasr && \
    /opt/conda/bin/pip install /tmp/lavasr && \
    # Create case-insensitive symlink for lavasr import (Linux is case-sensitive)
    (ln -sf /opt/conda/lib/python3.12/site-packages/LavaSR /opt/conda/lib/python3.12/site-packages/lavasr 2>/dev/null || \
     ln -sf /opt/conda/lib/python3.12/site-packages/LavaSR-*/LavaSR /opt/conda/lib/python3.12/site-packages/lavasr 2>/dev/null || \
     find /opt/conda/lib -name "LavaSR" -type d 2>/dev/null | head -1 | xargs -I{} ln -sf {} /opt/conda/lib/python3.12/site-packages/lavasr)

WORKDIR /workspace
