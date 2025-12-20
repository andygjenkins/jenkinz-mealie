# Mealie Local Development with Tilt
# Run with: tilt up

# Render Helm chart to YAML and deploy
k8s_yaml(helm(
    './helm/mealie',
    name='mealie',
    namespace='mealie',
    values=['./helm/values/dev.yaml'],
))

# Configure resources with labels and port forwards
k8s_resource(
    'mealie',
    port_forwards=['9000:9000'],
    labels=['app'],
)

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
║  PostgreSQL:     localhost:5432                              ║
╚══════════════════════════════════════════════════════════════╝
""")
