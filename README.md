# k8s-kubeadm-lab

Config-driven scripts to bootstrap a local, multi-node Kubernetes cluster
with `kubeadm`, CRI-O, Flannel, and NFS-backed persistent storage.

Built for Ubuntu 24.04.x LTS on arm64 (Apple Silicon VMs via VMware
Fusion/UTM/Parallels), but works on amd64 too — apt picks the matching
architecture automatically.

## Topology (default — edit `config.env` to change)

| Role | Hostname | IP |
|---|---|---|
| Control plane | master | 192.168.247.131 |
| Worker | worker1 | 192.168.247.132 |
| Worker | worker2 | 192.168.247.133 |
| NFS storage | nfs | 192.168.247.135 |

Kubernetes version: **v1.35.0** (also set in `config.env` — CRI-O's
version is derived from it automatically, you don't set that separately).

## Repo layout

```
k8s-kubeadm-lab/
├── config.env                        # <- edit THIS to change IPs/versions
└── scripts/
    ├── lib/common.sh                 # shared functions (not run directly)
    ├── 01-init-master.sh             # run once, on the master
    ├── 02-join-worker.sh             # run on each worker
    ├── 03-nfs-server-setup.sh        # run on the NFS node
    ├── 04-nfs-provisioner-install.sh # run on the master, after 03
    └── 99-reset-node.sh              # run on any node to clean-slate it
```

## Before you start

1. Provision 4 VMs (or however many workers you want — see "Changing the
   topology" below) with fresh Ubuntu 24.04.x LTS.
2. Set each VM's hostname to match `config.env` (`hostnamectl set-hostname master`, etc.)
   and give each a static IP matching the table above.
3. Confirm all 4 VMs can reach each other on the network.
4. Confirm architecture with `uname -m` — expect `aarch64` (arm64) or `x86_64` (amd64).

## Configure once

Edit **`config.env`** at the repo root — this is the only file you should
need to touch for a different environment (different IPs, different
Kubernetes version, more/fewer workers):

```bash
K8S_VERSION="1.35.0"
POD_CIDR="10.244.0.0/16"

MASTER_HOSTNAME="master01"
MASTER_IP="172.17.0.232"

WORKER_HOSTNAMES=("worker01" "worker2")
WORKER_IPS=("172.17.0.233" "192.168.247.133")

NFS_HOSTNAME="nfs"
NFS_IP="172.17.0.2"
NFS_EXPORT_PATH="/srv/nfs/kubedata"
```

**Copy the whole repo (including your edited `config.env`) to every
node** — master, every worker, and the NFS node — before running
anything. All scripts read topology from this one file, so it must be
identical everywhere:

```bash
scp -r deploy-k8s-cluster/ root@172.17.0.233:~/
scp -r deploy-k8s-cluster/ dglab@172.17.0.2:~/
#scp -r k8s-kubeadm-lab/ user@192.168.247.133:~/
#scp -r k8s-kubeadm-lab/ user@192.168.247.135:~/
```

### Changing the topology (more/fewer workers)

`WORKER_HOSTNAMES` and `WORKER_IPS` are parallel arrays — add or remove
entries in both (keeping the same order) to resize the cluster:

```bash
WORKER_HOSTNAMES=("worker1" "worker2" "worker3")
WORKER_IPS=("172.17.0.233" "192.168.247.133" "192.168.247.134")
```

### Changing the Kubernetes version

Just change `K8S_VERSION` in `config.env`. `K8S_MINOR` and `CRIO_VERSION`
are computed automatically from it — you never set those directly.

```bash
K8S_VERSION="1.34.2"   # CRIO_VERSION becomes v1.34 automatically
```

## Deployment order

1. **On `master`**: `sudo ./scripts/01-init-master.sh`
   Installs CRI-O + kubeadm/kubelet/kubectl, runs `kubeadm init`, installs
   Flannel, and prints a `kubeadm join ...` command (also saved at
   `/root/kubeadm-join-command.sh`).

2. **On each worker**: `sudo ./scripts/02-join-worker.sh <TOKEN> <CA_CERT_HASH>`
   Take `<TOKEN>` and `<CA_CERT_HASH>` from step 1's output. `MASTER_IP`
   itself comes from `config.env`, so you don't pass it here.

3. **Verify from `master`**:
   ```bash
   kubectl get nodes -o wide
   ```
   All nodes should show `Ready` with `VERSION` matching `K8S_VERSION`.

4. **On `nfs`**: `sudo ./scripts/03-nfs-server-setup.sh`
   Exports `NFS_EXPORT_PATH` to the master and every worker.

5. **On `master`**: `./scripts/04-nfs-provisioner-install.sh`
   Installs the NFS subdir provisioner via Helm and creates a default
   `nfs-client` StorageClass.

6. **Smoke-test storage**:
   ```yaml
   # test-pvc.yaml
   apiVersion: v1
   kind: PersistentVolumeClaim
   metadata:
     name: test-claim
   spec:
     accessModes: ["ReadWriteOnce"]
     resources:
       requests:
         storage: 1Gi
   ```
   ```bash
   kubectl apply -f test-pvc.yaml
   kubectl get pvc test-claim   # should reach Bound
   ```

## Resetting a node

If a `kubeadm init`/`join` fails partway through and you want to retry
cleanly, use `99-reset-node.sh` rather than re-running init blindly on
top of half-created state:

```bash
sudo ./scripts/99-reset-node.sh            # wipe state, keep packages installed (fast retry)
sudo ./scripts/99-reset-node.sh --purge    # also uninstall kubeadm/kubelet/kubectl/cri-o entirely
```

This script exists because of a real issue we hit: `kubeadm reset`
alone does **not** clean up CRI-O's image storage. If CRI-O's store
gets into a bad state (see Troubleshooting below), kubelet can keep
retrying `CreateContainer` forever with `image not known` errors even
though `kubeadm reset` reported success. `99-reset-node.sh` stops CRI-O,
unmounts its overlay filesystem, and wipes storage — then restarts it
clean.

## Troubleshooting

### `kubeadm init` fails: "control plane component may have crashed"

kubeadm's own message here is generic and doesn't tell you *what*
crashed. Find out with `crictl`:

```bash
crictl --runtime-endpoint unix:///var/run/crio/crio.sock ps -a
crictl --runtime-endpoint unix:///var/run/crio/crio.sock logs <CONTAINER_ID> 2>&1 | tail -80
journalctl -u kubelet --no-pager -n 200 | grep -iE "error|apiserver"
```

Things we've actually hit and fixed while building this repo:

| Symptom | Cause | Fix |
|---|---|---|
| etcd log shows repeated election-timeout / clock-related warnings | Guest clock drift — very common on VMware Fusion without `open-vm-tools` | `01-init-master.sh` now auto-installs `open-vm-tools` when it detects a VMware VM; confirm with `timedatectl status` |
| kubelet log: `CreateContainerError: ... image not known` for `kube-apiserver`, while `etcd`'s own log is clean and healthy | CRI-O's image store got into an inconsistent state (leftover from a prior failed attempt) | `sudo ./scripts/99-reset-node.sh` then re-run `01-init-master.sh` |
| etcd container restarting many times (`ATTEMPT` column high in `crictl ps -a`) but its own log shows no errors when it does run | Usually resolves once the *actual* root cause (clock or image store) is fixed — etcd restarts are a symptom of apiserver/kubelet churn, not the root cause itself | Check etcd's own log content, not just the restart count |
| `dial tcp <IP>:6443: connect: connection refused` | kube-apiserver isn't listening yet/at all — always a downstream symptom | Find out *why* apiserver isn't up via `crictl` + `journalctl`, don't just retry blindly |

### General minimums

- **2 vCPU / 2GB RAM absolute minimum** on the control-plane node;
  4GB+ recommended. Below this, etcd and kube-apiserver are prone to
  crash-looping or being OOM-killed. `01-init-master.sh` /
  `02-join-worker.sh` print a warning (not a hard stop) if you're under
  this.
- **Time sync matters more than it seems** — etcd's Raft protocol is
  sensitive to clock skew. If you're on VMware Fusion, this is handled
  automatically; on other hypervisors, confirm `timedatectl status`
  shows `synchronized: yes`.
- **Tokens expire after 24h.** If you come back to this later and the
  worker join fails with an auth/token error, regenerate on master:
  ```bash
  kubeadm token create --print-join-command
  ```

## CNI note

This repo uses **Flannel** (single manifest, reliably multi-arch,
simplest for a lab). CRI-O ships its own default bridge CNI config,
which `01-init-master.sh` removes automatically to avoid conflicts —
if pods get stuck in `ContainerCreating` with networking errors, check
`ls /etc/cni/net.d/` for leftover CRI-O configs first.

If you'd rather use Calico for NetworkPolicy support, swap the Flannel
`kubectl apply` line in `01-init-master.sh` for the Tigera Operator
install — the old single-manifest `calico.yaml` URL is no longer
maintained.

## Security note for this repo

`config.env` only contains topology and version info (private LAN
IPs, hostnames, a Kubernetes version string) — no secrets. The actual
cluster join token/CA hash are generated at runtime on the master and
saved to `/root/kubeadm-join-command.sh` **on the node**, never
written into this repo. It's safe to commit `config.env` as-is, but
treat the real IPs as environment-specific and expect to change them
per deployment.
