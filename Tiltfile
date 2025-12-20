# Mealie Local Development with Tilt
# Run with: tilt up

# Use minikube's docker daemon for faster builds
# Run: eval $(minikube docker-env) before tilt up

# Load Helm chart
load('ext://helm_resource', 'helm_resource', 'helm_repo')

# Deploy Mealie stack using Helm
helm_resource(
    'mealie',
    './helm/mealie',
    namespace='mealie',
    flags=[
        '-f', './helm/values/dev.yaml',
        '--create-namespace',
    ],
    deps=['./helm/mealie', './helm/values/dev.yaml'],
)

# Port forward Mealie for local access
k8s_resource(
    'mealie',
    port_forwards=['9000:9000'],
    labels=['app'],
)

# Port forward PostgreSQL for debugging
k8s_resource(
    'mealie-postgres',
    port_forwards=['5432:5432'],
    labels=['database'],
)

# Local development notes
print("""
╔══════════════════════════════════════════════════════════════╗
║                    Mealie Local Development                   ║
╠══════════════════════════════════════════════════════════════╣
║  Mealie UI:      http://localhost:9000                       ║
║  PostgreSQL:     localhost:5432 (user: mealie)               ║
║                                                              ║
║  For ingress access, run:                                    ║
║    minikube tunnel                                           ║
║    Add to /etc/hosts: 127.0.0.1 mealie.local                 ║
║    Then visit: http://mealie.local                           ║
╚══════════════════════════════════════════════════════════════╝
""")
