#!/bin/bash
# WaveCraft GPU Worker startup script (minimal - everything pre-installed in Docker image)
# ~30 second startup: just SSH fix + start worker

LOG="/workspace/startup.log"
echo "[$(date)] Startup script running..." >> $LOG

# Authorize SSH key for passwordless login
mkdir -p /root/.ssh
chmod 700 /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIH+dTJ/CMMUy8CacrGFVRbecm7T85PR5GHBAo2MmGJSa larry@hermes" > /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys

# Fix sshd_config for root login + pubkey auth
sed -i 's/^PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config

# Restart sshd to pick up new config
pkill -f sshd 2>/dev/null || true
sleep 1
/usr/sbin/sshd

# Kill any existing worker
pkill -f gpu_worker.py 2>/dev/null || true
pkill -f "python3 /workspace" 2>/dev/null || true

cd /workspace

# Write gpu_worker.py
cat > /workspace/gpu_worker.py << 'WORKER_EOF'
#!/usr/bin/env python3
"""
WaveCraft GPU Worker - Audio processing worker
Connects to B2, polls for pending jobs, processes with LavaSR, uploads results.
Auto-stops Vast.ai instance after IDLE_TIMEOUT seconds of no work.
"""
import os, sys, time, json, subprocess, signal, hashlib, base64, urllib.request, urllib.parse

BUCKET = "wavecraft-audio"
BUCKET_ID = "de4b407ae047b0e698da091f"
B2_KEY_ID = "eb0a07068a9f"
B2_APP_KEY = "005d80b8a51535c84ce8fe64288cd502265eb6a5e9"
B2_API = "https://api005.backblazeb2.com"
WORKER_URL = "https://wavecraft-api-v2.bonatznode.workers.dev"
VAST_API_KEY = os.environ.get("VAST_API_KEY", "66a404efc05ea0109d647f1f28b40e11caad60ac7f004caf212c4b71917b586f")
VAST_INSTANCE_ID = os.environ.get("VAST_INSTANCE_ID", "35638145")
IDLE_TIMEOUT = 600
POLL_INTERVAL = 60

WORKER_HEADERS = {"Content-Type": "application/json", "User-Agent": "WaveCraft-GPU-Worker/1.0"}
LOG_FILE = "/workspace/worker.log"

_lava_model = None

def get_lava_model():
    global _lava_model
    if _lava_model is None:
        from lavasr.model import LavaEnhance
        import torch
        _lava_model = LavaEnhance(device="cuda" if torch.cuda.is_available() else "cpu")
        log(f"[MODEL] LavaSR loaded on {_lava_model.device}")
    return _lava_model

def log(msg):
    ts = time.strftime("%H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line)
    with open(LOG_FILE, "a") as f:
        f.write(line + "\n")

def b2_auth():
    creds = base64.b64encode(f"{B2_KEY_ID}:{B2_APP_KEY}".encode()).decode()
    req = urllib.request.Request(
        f"{B2_API}/b2api/v4/b2_authorize_account",
        data=b"{}",
        headers={"Authorization": f"Basic {creds}", "Content-Type": "application/json"},
        method="POST"
    )
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    return {
        "token": data["authorizationToken"],
        "apiUrl": data["apiInfo"]["storageApi"]["apiUrl"],
        "downloadUrl": data["apiInfo"]["storageApi"]["downloadUrl"]
    }

def b2_list(auth, prefix):
    url = f"{auth['apiUrl']}/b2api/v4/b2_list_file_names"
    data = json.dumps({"bucketId": BUCKET_ID, "prefix": prefix, "maxFileCount": 10}).encode()
    req = urllib.request.Request(url, data=data, headers={"Authorization": auth["token"], "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as resp:
        result = json.loads(resp.read())
    return result.get("files", [])

def b2_download_file_by_id(auth, file_id, dest_path):
    url = f"{auth['apiUrl']}/b2api/v4/b2_download_file_by_id"
    data = json.dumps({"fileId": file_id}).encode()
    req = urllib.request.Request(url, data=data, headers={"Authorization": auth["token"], "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as resp:
        with open(dest_path, "wb") as f:
            f.write(resp.read())

def b2_upload(auth, file_path, key, content_type="audio/wav"):
    url = f"{auth['apiUrl']}/b2api/v4/b2_get_upload_url"
    data = json.dumps({"bucketId": BUCKET_ID}).encode()
    req = urllib.request.Request(url, data=data, headers={"Authorization": auth["token"], "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as resp:
        upload_data = json.loads(resp.read())
    upload_url = upload_data["uploadUrl"]
    upload_token = upload_data["authorizationToken"]
    sha1_hash = hashlib.sha1()
    with open(file_path, "rb") as f:
        for chunk in iter(lambda: f.read(8192), b""):
            sha1_hash.update(chunk)
    sha1 = sha1_hash.hexdigest()
    with open(file_path, "rb") as f:
        file_data = f.read()
    headers = {
        "Authorization": upload_token,
        "Content-Type": content_type,
        "X-Bz-File-Name": key,
        "X-Bz-Content-Sha1": sha1,
        "Content-Length": str(len(file_data))
    }
    req = urllib.request.Request(upload_url, data=file_data, headers=headers, method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def b2_delete_file_version(auth, file_id, file_name):
    url = f"{auth['apiUrl']}/b2api/v4/b2_delete_file_version"
    data = json.dumps({"fileId": file_id, "fileName": file_name}).encode()
    req = urllib.request.Request(url, data=data, headers={"Authorization": auth["token"], "Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def vast_stop_instance():
    api_key = os.environ.get("VAST_API_KEY")
    instance_id = os.environ.get("VAST_INSTANCE_ID", VAST_INSTANCE_ID)
    if not api_key:
        log("[VAST] No API key, skipping stop")
        return
    url = f"https://console.vast.ai/api/v0/instances/{instance_id}/stop/"
    req = urllib.request.Request(url, data=b"{}", headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"}, method="PUT")
    try:
        with urllib.request.urlopen(req) as resp:
            log(f"[VAST] Stop API response: {resp.read().decode()}")
    except Exception as e:
        log(f"[VAST] Stop failed: {e}")

def complete_job_in_worker(job_id, output_key):
    url = f"{WORKER_URL}/api/jobs/{job_id}/complete"
    data = json.dumps({"output_key": output_key}).encode()
    req = urllib.request.Request(url, data=data, headers=WORKER_HEADERS, method="POST")
    with urllib.request.urlopen(req) as resp:
        return json.loads(resp.read())

def fail_job_in_worker(job_id, error_msg):
    url = f"{WORKER_URL}/api/jobs/{job_id}/fail"
    data = json.dumps({"error": error_msg}).encode()
    req = urllib.request.Request(url, data=data, headers=WORKER_HEADERS, method="POST")
    try:
        with urllib.request.urlopen(req) as resp:
            return json.loads(resp.read())
    except:
        return None

def process_job(job):
    job_id = job.get("id")
    job_type = job.get("jobType", "restore")
    input_key = job.get("inputKey")
    output_key = job.get("outputKey")
    log(f"=== JOB: {job_id} ({job_type}) ===")
    log(f"Input:  {input_key}")
    log(f"Output: {output_key}")
    local_input = f"/workspace/input_{job_id}.wav"
    local_output = f"/workspace/output_{job_id}.wav"
    try:
        log(f"Downloading: {input_key}")
        auth = b2_auth()
        files = b2_list(auth, input_key)
        if not files:
            raise FileNotFoundError(f"Input file not found in B2: {input_key}")
        input_file = files[0]
        b2_download_file_by_id(auth, input_file["fileId"], local_input)
        log(f"Downloaded to {local_input} ({os.path.getsize(local_input)} bytes)")
        if job_type == "restore":
            log(f"Processing restore: {job_id}")
            import torch, torchaudio
            le = get_lava_model()
            wav, sr = le.load_audio(local_input)
            enhanced = le.enhance(wav)
            torchaudio.save(local_output, enhanced.cpu(), 48000)
            log(f"LavaSR enhance complete")
        elif job_type == "split":
            log(f"Processing split: {job_id}")
            result = subprocess.run([
                "python3", "-m", "demucs",
                "--out", "/workspace/demucs_out",
                local_input
            ], capture_output=True, text=True, timeout=600)
            if result.returncode != 0:
                raise RuntimeError(f"Demucs failed: {result.stderr[:500]}")
            import glob, shutil
            stem_files = glob.glob(f"/workspace/demucs_out/**/*", recursive=True)
            if not stem_files:
                raise RuntimeError("Demucs produced no output files")
            main_output = [f for f in stem_files if f.endswith(".wav")][0]
            shutil.copy(main_output, local_output)
        elif job_type == "master":
            log(f"Processing master: {job_id}")
            import shutil
            shutil.copy(local_input, local_output)
        else:
            raise ValueError(f"Unknown job type: {job_type}")
        log(f"Processing complete, output size: {os.path.getsize(local_output)} bytes")
        log(f"Uploading result: {output_key}")
        auth2 = b2_auth()
        b2_upload(auth2, local_output, output_key, "audio/wav")
        log(f"Upload complete")
        complete_job_in_worker(job_id, output_key)
        log(f"Job COMPLETED: {job_id}")
    except Exception as e:
        log(f"Job FAILED: {e}")
        fail_job_in_worker(job_id, str(e))
    finally:
        for f in [local_input, local_output]:
            if os.path.exists(f):
                os.remove(f)
        subprocess.run(["rm", "-rf", "/workspace/demucs_out"], capture_output=True)

def get_next_job():
    url = f"{WORKER_URL}/api/jobs/pending"
    req = urllib.request.Request(url, method="GET", headers={"User-Agent": "WaveCraft-GPU-Worker/1.0"})
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read())
    return data

def main():
    log("=" * 40)
    log("WaveCraft GPU Worker starting...")
    gpu_name = subprocess.run(['nvidia-smi', '--query-gpu=name', '--format=csv,noheader'], capture_output=True, text=True).stdout.strip()
    log(f"GPU: {gpu_name}")
    log(f"Worker URL: {WORKER_URL}")
    log(f"Idle timeout: {IDLE_TIMEOUT}s")
    log("=" * 40)
    last_job_time = time.time()
    while True:
        try:
            response = get_next_job()
            job_data = response.get("job")
            if job_data:
                last_job_time = time.time()
                process_job(job_data)
            else:
                idle_time = time.time() - last_job_time
                log(f"No job. Idle {idle_time:.0f}s / {IDLE_TIMEOUT}s")
                if idle_time >= IDLE_TIMEOUT:
                    log(f"Idle timeout reached. Stopping Vast.ai instance...")
                    vast_stop_instance()
                    log("Worker exiting.")
                    break
                time.sleep(POLL_INTERVAL)
        except Exception as e:
            log(f"Error in main loop: {e}")
            time.sleep(POLL_INTERVAL)

if __name__ == "__main__":
    main()
WORKER_EOF

chmod +x /workspace/gpu_worker.py
echo "[$(date)] gpu_worker.py written" >> $LOG

# Start worker in tmux
echo "[$(date)] Starting GPU worker..." >> $LOG
tmux kill-session -t worker 2>/dev/null || true
tmux new-session -d -s worker "cd /workspace && python3 /workspace/gpu_worker.py 2>&1 | tee -a /workspace/worker.log"
echo "[$(date)] GPU worker started in tmux session 'worker'" >> $LOG
echo "[$(date)] Startup complete!" >> $LOG
