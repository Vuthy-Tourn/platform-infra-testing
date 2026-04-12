{{- define "tenant-app.name" -}}
{{- default .Chart.Name .Values.app.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tenant-app.fullname" -}}
{{- if .Values.app.name -}}
{{- .Values.app.name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- include "tenant-app.name" . -}}
{{- end -}}
{{- end -}}

{{- define "tenant-app.labels" -}}
app.kubernetes.io/name: {{ include "tenant-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
platform.devops/user-id: {{ .Values.app.userId | quote }}
platform.devops/project-name: {{ .Values.app.projectName | quote }}
platform.devops/framework: {{ .Values.app.framework | quote }}
platform.devops/service-type: {{ default "internal" .Values.app.serviceType | quote }}
{{- end -}}
