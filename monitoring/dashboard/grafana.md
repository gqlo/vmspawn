# Grafana dashboard provisioning (dittybopper)

This guide documents how to provision Grafana dashboards from ConfigMaps so they persist across pod restarts when using dittybopper (e.g. in the `dittybopper` namespace). Without this setup, manually imported dashboards are stored only in the pod and are lost when the Grafana pod restarts.

**Script:** [setup-grafana-dashboards.sh](setup-grafana-dashboards.sh) does provider + optional dashboard ConfigMap and deployment patch. Usage: `./setup-grafana-dashboards.sh [namespace] [dashboard1.json ...]`

## Prerequisites

- `oc` CLI logged into the cluster
- Dittybopper (Grafana) already deployed in a namespace (this doc uses `dittybopper` as the namespace; adjust if yours differs)
- A dashboard JSON file (exported from Grafana or from a file)

## Overview

Dittybopper’s deployment does not mount ConfigMaps labeled `grafana_dashboard=1` by default. To make dashboards persistent you must:

1. Create a **dashboard provider** ConfigMap so Grafana knows where to load dashboards from.
2. Create a **dashboard** ConfigMap with your dashboard JSON.
3. **Patch the dittybopper deployment** to mount both ConfigMaps into the Grafana container.

---

## Step 1: Create the dashboard provider ConfigMap

This tells Grafana to load dashboard JSON files from a specific path inside the container.

```bash
oc apply -f - << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: grafana-dashboards-provider
  namespace: dittybopper
data:
  dashboards.yaml: |
    apiVersion: 1
    providers:
      - name: 'default'
        orgId: 1
        folder: ''
        type: file
        options:
          path: /etc/grafana/provisioning/dashboards/default
EOF
```

Use your actual namespace in place of `dittybopper` if different.

---

## Step 2: Export and create the dashboard ConfigMap

### 2a. Export the dashboard from Grafana (if needed)

1. Open Grafana in the browser and go to the dashboard you want to keep.
2. Use **Share dashboard** (or the ⋮ menu) → **Export**.
3. Choose **Export for sharing externally** (or “Save to file”).
4. Save the file locally (e.g. `my-dashboard.json`).

### 2b. Create a ConfigMap from the JSON file

From the directory where the JSON file is:

```bash
# Replace my-dashboard and my-dashboard.json with your names.
# The key (filename) will appear as the file name inside the container.
oc create configmap my-dashboard \
  --from-file=my-dashboard.json \
  -n dittybopper
```

To force the key to be `dashboard.json` (some setups expect this name):

```bash
oc create configmap my-dashboard \
  --from-file=dashboard.json=my-dashboard.json \
  -n dittybopper
```

Optional: add the label `grafana_dashboard=1` for consistency with other setups (dittybopper does not use it for mounting; the mount is done in Step 3):

```bash
oc label configmap my-dashboard grafana_dashboard=1 -n dittybopper
```

---

## Step 3: Mount the ConfigMaps in the dittybopper deployment

Add two volumes to the Grafana container so it sees the provider config and the dashboard JSON.

**Provider config** (so Grafana reads `dashboards.yaml`):

```bash
oc set volume deployment/dittybopper -n dittybopper \
  --add \
  --name=grafana-dashboards-provider \
  --type=configmap \
  --configmap-name=grafana-dashboards-provider \
  --mount-path=/etc/grafana/provisioning/dashboards \
  -c dittybopper
```

**Dashboard ConfigMap** (so Grafana sees your JSON under the path configured in the provider):

```bash
oc set volume deployment/dittybopper -n dittybopper \
  --add \
  --name=my-dashboard \
  --type=configmap \
  --configmap-name=my-dashboard \
  --mount-path=/etc/grafana/provisioning/dashboards/default \
  -c dittybopper
```

Replace `my-dashboard` with the name of the ConfigMap you created in Step 2.

Wait for the rollout to finish:

```bash
oc rollout status deployment/dittybopper -n dittybopper --timeout=120s
```

---

## Step 4: Verify

1. Open Grafana and go to **Dashboards** (or **Explore**).
2. The provisioned dashboard should appear (title comes from the dashboard JSON).
3. Restart the pod and confirm the dashboard is still there:

   ```bash
   oc rollout restart deployment/dittybopper -n dittybopper
   oc rollout status deployment/dittybopper -n dittybopper --timeout=120s
   ```

Optional: confirm files inside the container:

```bash
oc exec -n dittybopper deployment/dittybopper -c dittybopper -- \
  ls -la /etc/grafana/provisioning/dashboards/
oc exec -n dittybopper deployment/dittybopper -c dittybopper -- \
  ls -la /etc/grafana/provisioning/dashboards/default/
```

You should see `dashboards.yaml` and, under `default/`, your JSON file(s).

---

## Adding more dashboards

- **Option A (same ConfigMap):** Add another key to the same ConfigMap and re-apply (e.g. another JSON file). Then restart the deployment so the new file is mounted.
- **Option B (new ConfigMap):** Create a new ConfigMap with a different dashboard JSON. Add a second volume mounting it into a **new** folder under provisioning, and extend `dashboards.yaml` with another provider for that path. Alternatively, mount under `default` (e.g. `.../default/extra`) only if your Grafana supports nested paths for the same provider; otherwise add a second provider and path.

---

## Troubleshooting

- **Dashboard does not appear after Step 3**  
  - Check that the JSON is valid and is the format Grafana expects (e.g. export from Grafana and use that file).  
  - Check Grafana logs: `oc logs -n dittybopper deployment/dittybopper -c dittybopper --tail=100` for provisioning or parsing errors.

- **Dashboard disappears after a few minutes**  
  - Without the mounts in Step 3, dashboards live only in the pod. Ensure both volumes are present:  
    `oc get deployment dittybopper -n dittybopper -o jsonpath='{.spec.template.spec.volumes[*].name}'`

- **Wrong namespace**  
  - Replace `dittybopper` in all commands with your Grafana/dittybopper namespace.
