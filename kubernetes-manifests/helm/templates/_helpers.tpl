{{/* envector-chart/templates/_helpers.tpl */}}

{{/*
Expand the name of the chart.
*/}}
{{- define "envector-chart.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "envector-chart.fullname" -}}
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
{{- define "envector-chart.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "envector-chart.labels" -}}
helm.sh/chart: {{ include "envector-chart.chart" . }}
{{ include "envector-chart.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "envector-chart.selectorLabels" -}}
app.kubernetes.io/name: {{ include "envector-chart.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "envector-chart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "envector-chart.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}

{{/*
Component names (override to avoid duplicated "envector" in fullname)
*/}}
{{- define "envector-chart.endpointName" -}}
{{- default "envector-endpoint" .Values.endpoint.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.backendName" -}}
{{- default "envector-backend" .Values.backend.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.computeName" -}}
{{- default "envector-compute" .Values.compute.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.orchestratorName" -}}
{{- default "envector-orchestrator" .Values.orchestrator.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Get DB secret name based on externalSecret/existingSecret/default
Priority: externalSecret.name > existingSecrets.dbSecret > default
*/}}
{{- define "envector-chart.dbSecretName" -}}
{{- if .Values.externalSecrets.dbSecret.enabled }}
{{- $defaultSecretName := printf "%s-db-eso" (include "envector-chart.fullname" .) }}
{{- default $defaultSecretName .Values.externalSecrets.dbSecret.name }}
{{- else if ne (.Values.existingSecrets.dbSecret | default "") "" }}
{{- .Values.existingSecrets.dbSecret }}
{{- else }}
{{- printf "%s-db-secret" (include "envector-chart.fullname" .) }}
{{- end }}
{{- end -}}

{{/*
Get Storage secret name based on externalSecret/existingSecret/default
Priority: externalSecret.name > existingSecrets.storageSecret > default
*/}}
{{- define "envector-chart.storageSecretName" -}}
{{- if .Values.externalSecrets.storageSecret.enabled }}
{{- $defaultSecretName := printf "%s-storage-eso" (include "envector-chart.fullname" .) }}
{{- default $defaultSecretName .Values.externalSecrets.storageSecret.name }}
{{- else if ne (.Values.existingSecrets.storageSecret | default "") "" }}
{{- .Values.existingSecrets.storageSecret }}
{{- else }}
{{- printf "%s-storage-secret" (include "envector-chart.fullname" .) }}
{{- end }}
{{- end -}}

{{/*
Compute storage endpoint from host/port.
Only returns "<host>:<port>" when both are provided; otherwise returns "".
*/}}
{{- define "envector-chart.storageEndpoint" -}}
{{- $host := .Values.externalServices.storage.host | default "" -}}
{{- $port := .Values.externalServices.storage.port | default "" -}}
{{- if and $host $port -}}
{{- printf "%s:%s" $host $port -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}
