# Failure demo patches

Each file is a `kubectl patch` payload that reproduces one documented failure.
None of them are part of the default apply; they exist so the behaviour in the
root README can be reproduced in about a minute on kind/minikube.

Apply and revert:

```bash
# A - not ready
kubectl -n delivery-lab patch deploy delivery-lab --patch-file demos/a-not-ready.yaml
kubectl -n delivery-lab patch deploy delivery-lab --patch-file demos/revert.yaml

# B - slow request
kubectl -n delivery-lab patch deploy delivery-lab --patch-file demos/b-slow.yaml

# C - bad container port
kubectl -n delivery-lab patch deploy delivery-lab --patch-file demos/c-bad-port.yaml

# D - memory pressure (drives the container past its 128Mi limit)
kubectl -n delivery-lab exec deploy/delivery-lab -- \
  python -c "b=[]
while True: b.append(bytearray(10*1024*1024))"

# E - bad rollout
kubectl -n delivery-lab patch deploy delivery-lab --patch-file demos/e-bad-rollout.yaml
kubectl -n delivery-lab rollout undo deploy/delivery-lab
```
