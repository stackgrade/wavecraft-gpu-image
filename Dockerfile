FROM pytorch/pytorch:latest

# Install everything once at build time (not at runtime!)
# This saves ~3 minutes at instance startup on Vast.ai
RUN pip install demucs && \
    git clone https://github.com/ysharma3501/LavaSR.git /tmp/lavasr && \
    pip install /tmp/lavasr && \
    ln -sf /usr/local/lib/python3.12/dist-packages/LavaSR /usr/local/lib/python3.12/dist-packages/lavasr

WORKDIR /workspace
