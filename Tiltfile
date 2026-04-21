# Mealie Local Development with Tilt
# Run with: tilt up

# Ensure namespace exists
load('ext://namespace', 'namespace_create')
namespace_create('mealie')

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

# Seed job - runs after Mealie is ready
# Creates admin@test.com / test credentials
local_resource(
    'seed',
    cmd='./scripts/seed.sh http://localhost:9000/api',
    resource_deps=['mealie'],
    labels=['setup'],
    allow_parallel=True,
)

# Local development notes
print("""
╔══════════════════════════════════════════════════════════════╗
║                    Mealie Local Development                   ║
╠══════════════════════════════════════════════════════════════╣
║  Mealie UI:      http://localhost:9000                       ║
║  PostgreSQL:     localhost:5432                              ║
║  Admin login:    changeme@example.com / testtest             ║
╚══════════════════════════════════════════════════════════════╝
""")
