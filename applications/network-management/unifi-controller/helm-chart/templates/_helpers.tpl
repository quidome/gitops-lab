{{- define "unifi-controller.fullname" -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "unifi-controller.labels" -}}
app.kubernetes.io/name: unifi-controller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "unifi-controller.selectorLabels" -}}
app.kubernetes.io/name: unifi-controller
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
