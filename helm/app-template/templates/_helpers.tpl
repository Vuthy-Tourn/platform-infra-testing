{{- define "tenant-app.serviceName" -}}
{{- .service.name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "tenant-app.serviceAccountName" -}}
{{- $defaultName := include "tenant-app.serviceName" . -}}
{{- if .service.serviceAccount }}
{{- if .service.serviceAccount.create }}
{{- default $defaultName .service.serviceAccount.name -}}
{{- else -}}
default
{{- end -}}
{{- else -}}
{{- $defaultName -}}
{{- end -}}
{{- end -}}

{{- define "tenant-app.labels" -}}
{{- $root := .root -}}
{{- $service := .service -}}
app.kubernetes.io/name: {{ include "tenant-app.serviceName" . }}
app.kubernetes.io/instance: {{ $root.Release.Name }}
app.kubernetes.io/version: {{ $root.Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ $root.Release.Service }}
platform.devops/workspace-id: {{ $root.Values.workspace.id | quote }}
platform.devops/user-id: {{ $root.Values.workspace.userId | quote }}
platform.devops/project-name: {{ $service.name | quote }}
platform.devops/framework: {{ $service.framework | quote }}
platform.devops/service-type: {{ default "internal" $service.serviceType | quote }}
{{- end -}}

{{- define "tenant-app.syncWave" -}}
{{- default 0 .service.syncWave | toString -}}
{{- end -}}
