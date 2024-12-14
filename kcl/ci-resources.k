import template

oxrMock = {
  spec = {
    id = "123"
    parameters = {
      image = "IMAGE"
      repository = {
        enabled = True
        name = "REPO"
      }
      ci = {
        enabled = True
      }
    }
  }
}
oxr = option("params").oxr
_id = oxr.spec.id
_params = oxr.spec.parameters
dxr = {
  **oxr
  status.host = _params.host
}

schema RepositoryFile:
  apiVersion = "repo.github.upbound.io/v1alpha1"
  kind = "RepositoryFile"
  metadata: any
  spec: RepositoryFileSpec

schema RepositoryFileSpec:
  forProvider: RepositoryFileForProvider

schema RepositoryFileForProvider:
  branch = "${_id}-ci"
  commitAuthor = "Crossplane"
  commitEmail = "github-provider@crossplane.io"
  commitMessage = "${file} [skip ci]"
  file: str
  overwriteOnCreate = True
  repository = _params.repository.name
  content: str

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
    _items += [
    {
      apiVersion = "repo.github.upbound.io/v1alpha1"
      kind = "Branch"
      metadata = _metadata("ci", "branch")
      spec.forProvider = {
        branch = "${_id}-ci"
        repository = _params.repository.name
      }
    },
    RepositoryFile{
      metadata = _metadata("gha", "file")
      spec: RepositoryFileSpec{
        forProvider: RepositoryFileForProvider{
          file = ".github/workflows/ci.yaml"
          content = template.execute("""\
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
          {{devboxRun}}
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
""", {
  devboxRun: _devboxRun
}).replace("[[", "{{").replace("]]", "}}")
        }
      }
    },
    RepositoryFile{
      metadata = _metadata("dot-nu", "file")
      spec: RepositoryFileSpec{
        forProvider: RepositoryFileForProvider{
          file = "dot.nu"
          content = template.execute("""\
#!/usr/bin/env nu

def main [] {}

# Runs all CI tasks
def "main run ci" [
    tag: string # The tag of the image (e.g., 0.0.1)
    manifest = "apps/{{id}}.yaml" # The path to the manifest file
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

    docker image build --tag $"{{image}}:latest" .

    docker image tag $"{{image}}:latest" $"{{image}}:($tag)"

    if $push {

        docker image push $"{{image}}:latest"

        docker image push $"{{image}}:($tag)"
    }

}

# Updates the claim
def "main update claim" [
    tag: string # The tag of the image (e.g., 0.0.1)
    path = "apps/{{id}}.yaml" # The path to the claim file
] {

    open $path | upsert spec.parameters.tag $tag | save $path --force

}
""", {
  image: _params.image,
  id: _id
})
        }
      }
    },
    RepositoryFile{
      metadata = _metadata("devbox", "file")
      spec: RepositoryFileSpec{
        forProvider: RepositoryFileForProvider{
          file = "devbox-ci.json"
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
      }
    },
    RepositoryFile{
      metadata = _metadata("dockerfile", "file")
      spec: RepositoryFileSpec{
        forProvider: RepositoryFileForProvider{
          file = "Dockerfile"
          content = """\
FROM golang:1.23.3-alpine AS build
RUN mkdir /src
WORKDIR /src
ADD ./go.mod .
ADD ./go.sum .
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
      }
    }, {
        apiVersion = "repo.github.upbound.io/v1alpha1"
        kind = "PullRequest"
        metadata = _metadata("", "pull-request")
        spec.forProvider = {
            baseRef = "main"
            headRef = "${_id}-ci"
            body = "Review, merge, enjoy."
            title = "CI"
            baseRepositorySelector.matchControllerRef = True
        }
    }
  ]

items = _items
