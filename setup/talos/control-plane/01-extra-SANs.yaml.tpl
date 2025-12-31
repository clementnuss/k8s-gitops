---
cluster:
  apiServer:
    certSANs:
      - {{ .Data.additionalControlPlaneEndpoint }}
