---
machine:
  logging:
    destinations:
      - endpoint: tcp://192.168.63.235:5044/
        format: json_lines
        extraTags:
          node: {{ .Node.Host }}