{{/* es2-chart/templates/_helpers.tpl */}}
{{- define "es2-chart.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "es2-chart.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
    {{ default (include "es2-chart.fullname" .) .Values.serviceAccount.name }}
{{- else -}}
    {{ default "default" .Values.serviceAccount.name }}
{{- end -}}
{{- end -}}
