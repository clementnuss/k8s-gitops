
# rke2 migration notes


## preparation

1. disable system-upgrade-controller
1. service-account-issuer
1. egress-mode-selector disabled
```shell
export ETCDCTL_ENDPOINTS='https://127.0.0.1:2379'
export ETCDCTL_CACERT='/var/lib/rancher/rke2/server/tls/etcd/server-ca.crt'
export ETCDCTL_CERT='/var/lib/rancher/rke2/server/tls/etcd/server-client.crt'
export ETCDCTL_KEY='/var/lib/rancher/rke2/server/tls/etcd/server-client.key'
export ETCDCTL_API=3
```

```bash
cd /var/lib/rancher/rke2/server/tls/etcd/
cat peer-ca.crt >> server-ca.crt
killall -s SIGTERM etcd
```


## tips:

```shell
export CONTAINER_RUNTIME_ENDPOINT="unix:///run/k3s/containerd/containerd.sock"
```
