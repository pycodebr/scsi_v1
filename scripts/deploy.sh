#!/bin/bash
set -euo pipefail

# SCSI — Deploy script for Docker Swarm
# Usage: ./scripts/deploy.sh [build]

DOMAIN="${DOMAIN:-scsi.digital}"
REGISTRY="${REGISTRY:-ghcr.io/pycodebr/scsi_v1:latest}"
STACK_NAME="scsi_v1"

echo "=== SCSI Deploy ==="

if [ "${1:-}" = "build" ]; then
    echo ">>> Building image..."
    docker build -t "$REGISTRY" .
    echo ">>> Pushing image..."
    docker push "$REGISTRY"
fi

echo ">>> Deploying stack..."
docker stack deploy -c docker-stack.yml "$STACK_NAME"

echo ">>> Waiting for services to stabilize..."
sleep 10

echo ">>> Service status:"
docker service ls

echo ""
echo "=== Post-deploy commands ==="
echo "Run migrations and collectstatic:"
echo "  APP=\$(docker ps --filter name=${STACK_NAME}_app -q | head -n1)"
echo "  docker exec -it \$APP python manage.py migrate"
echo "  docker exec -it \$APP python manage.py collectstatic --noinput"
echo "  docker exec -it \$APP python manage.py createsuperuser"
echo ""
echo "Check SSL:"
echo "  docker service logs -f ${STACK_NAME}_traefik"
echo ""
echo "Check app:"
echo "  docker service logs -f ${STACK_NAME}_app"