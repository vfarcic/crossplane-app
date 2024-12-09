oxr = option("params").oxr
_id = oxr.spec.id
_params = oxr.spec.parameters
dxr = {
    **oxr
    status.host = _params.host
}

_metadata = lambda suffix: str, kind: str -> any {
    {
        if suffix == "":
            name = _id
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _id + "-" + kind
            }
        else:
            name = _id + "-" + kind + "-" + suffix
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _id + "-" + kind + "-" + suffix
            }
    }
}

_devboxRun = "devbox run --config devbox-ci.json -- ./dot.nu run ci $TAG"

if not _params.ci?.runTests:
    _devboxRun = _devboxRun + " --run_tests false"
if not _params.ci?.buildImages:
    _devboxRun = _devboxRun + " --build_images false"
        
_items = []

if _params.ci?.enabled and _params.repository?.enabled and _params.repository?.name:
    _items += [{
        apiVersion = "repo.github.upbound.io/v1alpha1"
        kind = "Branch"
        metadata = _metadata("ci", "branch")
        spec.forProvider = {
            branch = "ci"
            repository = _params.repository.name
        }
    }, {
        apiVersion = "repo.github.upbound.io/v1alpha1"
        kind = "RepositoryFile"
        metadata = _metadata("gha", "file")
        spec.forProvider = {
            branch = "ci"
            commitAuthor = "Crossplane"
            commitEmail = "github-provider@crossplane.io"
            commitMessage = "GitHub Actions [skip ci]"
            file = ".github/workflows/ci.yaml"
            repository = _params.repository.name
            content = """\
name: ci
run-name: ci
on:
  push:
    branches:
      - main
jobs:
  all:
    runs-on: ubuntu-latest
    env:
      TAG: 0.0.$[[ github.run_number ]]
      FORCE_COLOR: 1
    steps:
      - name: Checkout
        uses: actions/checkout@v4
      - name: Set up QEMU
        uses: docker/setup-qemu-action@v3
      - name: Login to ghcr
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: vfarcic
          password: $[[ secrets.REGISTRY_PASSWORD ]]
      - name: Install devbox
        uses: jetify-com/devbox-install-action@v0.11.0
        with:
          project-path: devbox-ci.json
      - name: All
        run: |
          REPLACE_DEVBOX_RUN
        env:
          REGISTRY_PASSWORD: $[[ secrets.REGISTRY_PASSWORD ]]
      - name: Commit changes
        run: |
          git config --local user.email "41898282+github-actions[bot]@users.noreply.github.com"
          git config --local user.name "github-actions[bot]"
          git add .
          git commit -m "Release $[[ env.TAG ]] [skip ci]"
      - name: Push changes
        uses: ad-m/github-push-action@master
        with:
          github_token: $[[ secrets.GITHUB_TOKEN ]]
          branch: $[[ github.ref ]]
""".replace("[[", "{{").replace("]]", "}}").replace("REPLACE_DEVBOX_RUN", _devboxRun)
        }
    }, {
        apiVersion = "repo.github.upbound.io/v1alpha1"
        kind = "RepositoryFile"
        metadata = _metadata("dot-nu", "file")
        spec.forProvider = {
            branch = "ci"
            commitAuthor = "Crossplane"
            commitEmail = "github-provider@crossplane.io"
            commitMessage = "dot.nu [skip ci]"
            file = "dot.nu"
            repository = _params.repository.name
            content = """\
#!/usr/bin/env nu

def main [] {}

# Runs all CI tasks
def "main run ci" [
    tag: string # The tag of the image (e.g., 0.0.1)
    manifest = "REPLACE_MANIFEST" # The path to the manifest file
    --run_tests = true # Whether to run tests
    --build_images = true # Whether to build images
] {

    if $run_tests {
        main run tests --language go
    }

    if $build_images {
        main build image $tag
    }

    main update claim $tag $manifest

}

# Runs tests
def "main run tests" [
    --language = "go" # The language of the project (e.g., go)
] {

    if $language == "go" {
        go test -v $"(pwd)/..."
    }

}

# Builds and (optionally) pushes container images
def "main build image" [
    tag: string   # The tag of the image (e.g., 0.0.1)
    --push = true # Whether to push the image to the registry
] {

    docker image build --tag $"REPLACE_IMAGE:latest" .

    docker image tag $"REPLACE_IMAGE:latest" $"REPLACE_IMAGE:($tag)"

    if $push {

        docker image push $"REPLACE_IMAGE:latest"

        docker image push $"REPLACE_IMAGE:($tag)"
    }

}

# Updates the claim
def "main update claim" [
    tag: string # The tag of the image (e.g., 0.0.1)
    path = "REPLACE_MANIFEST" # The path to the claim file
] {

    open $path | upsert spec.parameters.tag $tag | save $path --force

}
""".replace("REPLACE_IMAGE", _params.image).replace("REPLACE_MANIFEST", "apps/" + _id + ".yaml")
        }
    }, {
        apiVersion = "repo.github.upbound.io/v1alpha1"
        kind = "RepositoryFile"
        metadata = _metadata("devbox", "file")
        spec.forProvider = {
            branch = "ci"
            commitAuthor = "Crossplane"
            commitEmail = "github-provider@crossplane.io"
            commitMessage = "devbox-ci.json [skip ci]"
            file = "devbox-ci.json"
            repository = _params.repository.name
            content = """\
{
  "packages": [
    "nushell@0.100.0",
    "go@1.22.3"
  ],
  "shell": {
    "init_hook": [
      "chmod +x dot.nu"
    ],
    "scripts":   {}
  }
}
"""
        }
    }, {
        apiVersion = "repo.github.upbound.io/v1alpha1"
        kind = "RepositoryFile"
        metadata = _metadata("dockerfile", "file")
        spec.forProvider = {
            branch = "ci"
            commitAuthor = "Crossplane"
            commitEmail = "github-provider@crossplane.io"
            commitMessage = "Dockerfile [skip ci]"
            file = "Dockerfile"
            repository = _params.repository.name
            content = """\
FROM golang:1.23.3-alpine AS build
RUN mkdir /src
WORKDIR /src
ADD ./go.mod .
ADD ./go.sum .
ADD ./vendor .
ADD ./*.go ./
RUN GOOS=linux GOARCH=amd64 go build -o app
RUN chmod +x app

FROM scratch
ARG VERSION
ENV VERSION=$VERSION
ENV DB_PORT=5432 DB_USERNAME=postgres DB_NAME=my-db
COPY --from=build /src/app /usr/local/bin/app
EXPOSE 8080
CMD ["app"]
"""
        }
    }]

items = _items
