{{/*
Expand the name of the chart.
*/}}
{{- define "team-postgresql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "team-postgresql.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "team-postgresql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels.
*/}}
{{- define "team-postgresql.labels" -}}
helm.sh/chart: {{ include "team-postgresql.chart" . }}
{{ include "team-postgresql.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: primary
{{- end }}

{{/*
Selector labels.
*/}}
{{- define "team-postgresql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "team-postgresql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Selector labels of the backup job pods. They must never match the database
selector labels, or the database Service would also select the backup pod.
*/}}
{{- define "team-postgresql.backupSelectorLabels" -}}
app.kubernetes.io/name: {{ include "team-postgresql.name" . }}-backup
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels of the backup resources.
*/}}
{{- define "team-postgresql.backupLabels" -}}
helm.sh/chart: {{ include "team-postgresql.chart" . }}
{{ include "team-postgresql.backupSelectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: backup
{{- end }}
