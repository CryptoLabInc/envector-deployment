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
Component names — short defaults to keep total resource names under 63 chars.
fullname (up to 40 chars) + "-" + component (up to 12 chars) + suffix room.
Override via .Values.<component>.name if needed.
*/}}
{{- define "envector-chart.endpointName" -}}
{{- default "endpoint" .Values.endpoint.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.backendName" -}}
{{- default "backend" .Values.backend.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.computeName" -}}
{{- default "compute" .Values.compute.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.orchestratorName" -}}
{{- default "orch" .Values.orchestrator.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.shaperName" -}}
{{- default "shaper" .Values.shaper.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.auditName" -}}
{{- default "audit" .Values.audit.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "envector-chart.auditLogmqName" -}}
{{- default "audit-logmq" .Values.audit.logmq.name | trunc 63 | trimSuffix "-" -}}
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
Construct Cloud SQL DB URL via auth proxy.
IAM user derived from SA name + project (from instanceConnectionName).
*/}}
{{- define "envector-chart.cloudSQLDbURL" -}}
{{- $proxyHost := printf "%s-cloud-sql-proxy" (include "envector-chart.fullname" .) -}}
{{- $parts := splitList ":" .Values.cloudSQL.instanceConnectionName -}}
{{- $project := index $parts 0 -}}
{{- $saName := include "envector-chart.serviceAccountName" . -}}
{{- printf "host=%s port=5432 dbname=%s user=%s@%s.iam sslmode=disable" $proxyHost .Values.cloudSQL.database $saName $project -}}
{{- end -}}

{{/*
Compute storage endpoint from host/port.
Only returns "<host>:<port>" when both are provided; otherwise returns "".
*/}}
{{- define "envector-chart.storageEndpoint" -}}
{{- $host := .Values.externalServices.storage.host | default "" -}}
{{- $port := .Values.externalServices.storage.port | default "" | toString -}}
{{- if and $host $port -}}
{{- printf "%s:%s" $host $port -}}
{{- else -}}
{{- "" -}}
{{- end -}}
{{- end -}}
