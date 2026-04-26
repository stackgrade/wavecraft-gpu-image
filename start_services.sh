#!/bin/bash
set -e

# Start SSH daemon (required for Vast.ai --ssh flag)
echo "Starting sshd..."
/usr/sbin/sshd

# Start Jupyter (original behavior from pytorch/pytorch:latest)
echo "Starting Jupyter..."
exec jupyter notebook --ip=0.0.0.0 --port=8080 --NotebookApp.token='' --NotebookApp.password='' --allow-root --NotebookApp.allow_origin='*'
