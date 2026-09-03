---
apiVersion: v1alpha1
kind: KubeAPIServerConfig
certExtraSANs:
    - {{ .Data.additionalControlPlaneEndpoint }}