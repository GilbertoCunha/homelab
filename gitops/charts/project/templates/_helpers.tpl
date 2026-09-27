{{/*
The namespace an environment runs in. Prefixed so that a project can never
collide with a system namespace, and so `kubectl get ns` sorts every project
together. See docs/architecture/names.md.
*/}}
{{- define "project.namespace" -}}
{{- printf "project-%s-%s" .root.Values.name .env.name -}}
{{- end -}}

{{/*
Refuses an environment name the Gateways do not select on. Without this the
project renders, the namespace appears, and its HTTPRoutes are refused with
NotAllowedByListeners and nothing to explain why.
*/}}
{{- define "project.validateEnv" -}}
{{- $allowed := .root.Values.defaults.allowedEnvironments -}}
{{- if not (has .env.name $allowed) -}}
{{- fail (printf "project %q: environment %q is not one of %v. The Gateways in gitops/system/base/kgateway/gateways.yaml only select namespaces labelled with those, so any other name produces a namespace whose routes are silently refused." .root.Values.name .env.name $allowed) -}}
{{- end -}}
{{- if not .env.sync -}}
{{- fail (printf "project %q: environment %q has no sync block, so there is nothing to deploy." .root.Values.name .env.name) -}}
{{- end -}}
{{- end -}}

{{/*
Per-environment values fall back to .Values.defaults by hand, one field at a
time. They cannot fall back on their own: helm merges maps but REPLACES lists,
and `environments` is a list, so nothing in defaults reaches an entry that
omits a field.
*/}}
{{- define "project.podSecurity" -}}
{{- .env.podSecurity | default .root.Values.defaults.podSecurity -}}
{{- end -}}

{{- define "project.quotas" -}}
{{- $d := .root.Values.defaults.quotas -}}
{{- $q := .env.quotas | default dict -}}
cpu: {{ $q.cpu | default $d.cpu | quote }}
memory: {{ $q.memory | default $d.memory | quote }}
storage: {{ $q.storage | default $d.storage | quote }}
persistentvolumeclaims: {{ $q.persistentvolumeclaims | default $d.persistentvolumeclaims | quote }}
{{- end -}}

{{- define "project.labels" -}}
app.kubernetes.io/managed-by: {{ .root.Release.Service }}
app.kubernetes.io/part-of: {{ .root.Values.name }}
{{- end -}}
