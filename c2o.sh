#!/bin/bash
# c2o - Claude-to-OpenShift CLI
# Manages cloud-based Claude development environment

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly ORANGE='\033[38;5;214m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Configuration
NAMESPACE="${NAMESPACE:-c2o-${USER:-$(whoami)}}"
DEPLOYMENT_NAME="c2o"
PVC_NAME="c2o-workspace"
SECRET_NAME="c2o-env"
IMAGE="quay.io/eformat/c2o:latest"

show_help() {
    cat <<EOF
c2o - Claude-to-OpenShift CLI

Usage: c2o <command>

Commands:
  up       Create/update c2o deployment in namespace $NAMESPACE
  down     Scale deployment to 0 (preserves PVC)
  delete   Remove namespace and all resources
  rsh      Open shell in the c2o pod
  login    Copy local gcloud credentials to the pod
  status   Show status of c2o resources
  urls     Show URLs for Grafana and Prometheus routes
  help     Show this help message

Environment:
  NAMESPACE  Override namespace (default: c2o-\$USER)

Examples:
  c2o up                          # Deploy to c2o-\$USER namespace
  c2o login                       # Copy gcloud creds (required for Claude models)
  c2o rsh                         # Shell into pod
  claude                          # Run Claude Code (after c2o rsh)

  NAMESPACE=user-mhepburn c2o up  # Deploy to a specific namespace
  NAMESPACE=user-mhepburn c2o rsh # Shell into pod in that namespace
EOF
}

check_oc() {
    if ! command -v oc &>/dev/null; then
        echo -e "${RED}Error: oc CLI not found${NC}"
        echo "Install OpenShift CLI: https://docs.openshift.com/container-platform/4.15/cli_reference/openshift_cli/getting-started-cli.html"
        exit 1
    fi

    if ! oc whoami &>/dev/null; then
        echo -e "${RED}Error: Not logged into OpenShift${NC}"
        echo "Run: oc login"
        exit 1
    fi

    echo -e "${GREEN}✓${NC} Connected to OpenShift: $(oc whoami --show-server)"
}

cmd_up() {
    echo -e "${BLUE}Deploying c2o to namespace: ${NAMESPACE}${NC}"

    # Check prerequisites
    check_oc

    if [ ! -f "${SCRIPT_DIR}/openshift/c2o/secret-env.yaml" ]; then
        if [ ! -f "${SCRIPT_DIR}/openshift/c2o/secret-env.yaml.template" ]; then
            echo -e "${RED}Error: Secret template not found${NC}"
            exit 1
        fi
        echo -e "${ORANGE}Creating secret from template...${NC}"
        cp "${SCRIPT_DIR}/openshift/c2o/secret-env.yaml.template" "${SCRIPT_DIR}/openshift/c2o/secret-env.yaml"
        echo -e "${ORANGE}Edit openshift/c2o/secret-env.yaml with your credentials, then run c2o up again${NC}"
        exit 1
    fi

    # Check if secret has placeholder values
    if grep -q "YOUR_KIMI_TOKEN_HERE\|YOUR_KIMI_HOST_HERE\|YOUR_GCP_PROJECT_ID" "${SCRIPT_DIR}/openshift/c2o/secret-env.yaml"; then
        echo -e "${RED}Error: Secret has placeholder values${NC}"
        echo "Edit openshift/c2o/secret-env.yaml with real credentials"
        exit 1
    fi

    # Create namespace if it doesn't exist
    if ! oc get namespace "${NAMESPACE}" &>/dev/null; then
        echo -e "${BLUE}Creating namespace...${NC}"
        oc create namespace "${NAMESPACE}"
        echo -e "  ${GREEN}✓${NC} Created namespace ${NAMESPACE}"
    fi

    # Apply manifests
    echo -e "${BLUE}Applying manifests...${NC}"

    # ConfigMap
    oc apply -f "${SCRIPT_DIR}/openshift/c2o/configmap.yaml" -n "${NAMESPACE}"
    echo -e "  ${GREEN}✓${NC} ConfigMap"

    # Secret
    oc apply -f "${SCRIPT_DIR}/openshift/c2o/secret-env.yaml" -n "${NAMESPACE}"
    echo -e "  ${GREEN}✓${NC} Secret"

    # PVC
    oc apply -f "${SCRIPT_DIR}/openshift/c2o/pvc.yaml" -n "${NAMESPACE}"
    echo -e "  ${GREEN}✓${NC} PVC"

    # Deployment
    oc apply -f "${SCRIPT_DIR}/openshift/c2o/deployment.yaml" -n "${NAMESPACE}"
    echo -e "  ${GREEN}✓${NC} Deployment"

    # Services
    oc apply -f "${SCRIPT_DIR}/openshift/c2o/services.yaml" -n "${NAMESPACE}"
    echo -e "  ${GREEN}✓${NC} Services"

    # Routes
    oc apply -f "${SCRIPT_DIR}/openshift/c2o/routes.yaml" -n "${NAMESPACE}"
    echo -e "  ${GREEN}✓${NC} Routes"

    echo ""
    echo -e "${BLUE}Waiting for deployment to be ready...${NC}"
    oc rollout status deployment/${DEPLOYMENT_NAME} -n "${NAMESPACE}" --timeout=300s

    echo ""
    echo -e "${GREEN}🌴 c2o is up and running!${NC}"
    echo ""
    echo -e "Run '${ORANGE}c2o rsh${NC}' to shell into the pod"
    echo -e "Run '${ORANGE}c2o login${NC}' to copy gcloud credentials"
    echo -e "Run '${ORANGE}c2o urls${NC}' to see dashboard URLs"
}

cmd_down() {
    echo -e "${BLUE}Scaling down c2o in namespace: ${NAMESPACE}${NC}"
    check_oc

    oc scale deployment/${DEPLOYMENT_NAME} --replicas=0 -n "${NAMESPACE}" 2>/dev/null || true
    echo -e "${GREEN}🌴 c2o is scaled down (PVC preserved)${NC}"
}

cmd_delete() {
    echo -e "${ORANGE}Warning: This will delete namespace '${NAMESPACE}' and ALL data${NC}"
    read -p "Are you sure? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Cancelled"
        exit 0
    fi

    check_oc

    oc delete namespace "${NAMESPACE}" --ignore-not-found=true
    echo -e "${GREEN}🌴 Namespace ${NAMESPACE} deleted${NC}"
}

cmd_rsh() {
    check_oc

    local pod
    pod=$(oc get pods -n "${NAMESPACE}" -l app=c2o -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$pod" ]; then
        echo -e "${RED}Error: No c2o pod found in namespace ${NAMESPACE}${NC}"
        echo "Run 'c2o up' first"
        exit 1
    fi

    echo -e "${BLUE}Connecting to pod: ${pod}${NC}"
    oc rsh -n "${NAMESPACE}" "${pod}"
}

cmd_login() {
    check_oc

    local pod
    pod=$(oc get pods -n "${NAMESPACE}" -l app=c2o -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

    if [ -z "$pod" ]; then
        echo -e "${RED}Error: No c2o pod found. Run 'c2o up' first${NC}"
        exit 1
    fi

    local adc_path="${HOME}/.config/gcloud/application_default_credentials.json"
    if [ ! -f "$adc_path" ]; then
        echo -e "${RED}Error: GCP credentials not found${NC}"
        echo "Run: gcloud auth application-default login"
        exit 1
    fi

    echo -e "${BLUE}Copying gcloud credentials to pod...${NC}"
    oc cp -n "${NAMESPACE}" "$adc_path" "${pod}:/home/user/.config/gcloud/application_default_credentials.json"
    echo -e "  ${GREEN}✓${NC} Copied credentials"

    # Restart the pod to pick up credentials
    echo -e "${BLUE}Restarting pod to activate credentials...${NC}"
    oc delete pod -n "${NAMESPACE}" "$pod"
    sleep 2
    oc rollout status deployment/${DEPLOYMENT_NAME} -n "${NAMESPACE}" --timeout=120s

    echo -e "${GREEN}🌴 Credentials synced and pod restarted${NC}"
}

cmd_status() {
    check_oc

    echo -e "${BLUE}Pod status:${NC}"
    oc get pods -n "${NAMESPACE}" -l app=c2o 2>/dev/null || echo "  No pods found"

    echo ""
    echo -e "${BLUE}Deployment:${NC}"
    oc get deployment/${DEPLOYMENT_NAME} -n "${NAMESPACE}" 2>/dev/null || echo "  No deployment found"

    echo ""
    echo -e "${BLUE}PVC:${NC}"
    oc get pvc/${PVC_NAME} -n "${NAMESPACE}" 2>/dev/null || echo "  No PVC found"

    echo ""
    echo -e "${BLUE}Routes:${NC}"
    oc get routes -n "${NAMESPACE}" 2>/dev/null || echo "  No routes found"
}

cmd_urls() {
    check_oc

    echo -e "${BLUE}Dashboard URLs:${NC}"
    echo ""

    local grafana_url prometheus_url
    grafana_url=$(oc get route c2o-grafana -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)
    prometheus_url=$(oc get route c2o-prometheus -n "${NAMESPACE}" -o jsonpath='{.spec.host}' 2>/dev/null)

    if [ -n "$grafana_url" ]; then
        echo -e "  ${GREEN}Grafana:${NC}      https://${grafana_url}"
        echo -e "    User:     admin"
        echo -e "    Password: $(oc get secret ${SECRET_NAME} -n "${NAMESPACE}" -o jsonpath='{.data.GF_SECURITY_ADMIN_PASSWORD}' 2>/dev/null | base64 -d || echo 'admin')"
    else
        echo -e "  ${ORANGE}Grafana route not ready${NC}"
    fi

    echo ""

    if [ -n "$prometheus_url" ]; then
        echo -e "  ${GREEN}Prometheus:${NC}  https://${prometheus_url}"
    else
        echo -e "  ${ORANGE}Prometheus route not ready${NC}"
    fi

    echo ""
    echo -e "${BLUE}Port forwards (alternative to routes):${NC}"
    echo -e "  oc port-forward svc/c2o-grafana 3000:3000 -n ${NAMESPACE}"
    echo -e "  oc port-forward svc/c2o-prometheus 9090:9090 -n ${NAMESPACE}"
}

# Main command dispatcher
case "${1:-help}" in
    up)
        cmd_up
        ;;
    down)
        cmd_down
        ;;
    delete)
        cmd_delete
        ;;
    rsh)
        cmd_rsh
        ;;
    login)
        cmd_login
        ;;
    status)
        cmd_status
        ;;
    urls)
        cmd_urls
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo -e "${RED}Unknown command: $1${NC}"
        show_help
        exit 1
        ;;
esac
