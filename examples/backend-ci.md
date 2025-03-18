## Setup

```sh
devbox shell

kind create cluster

helm upgrade --install crossplane crossplane \
    --repo https://charts.crossplane.io/stable \
    --namespace crossplane-system --create-namespace --wait

kubectl apply --filename config.yaml

kubectl apply --filename providers/kubernetes-incluster.yaml
```

> Replace `[...]` with your GitHub token.

```sh
export GITHUB_TOKEN=[...]
```

> Replace `[...]` with your GitHub username or organization

```sh
export GITHUB_OWNER=[...]

echo "
apiVersion: v1
kind: Secret
metadata:
  name: github
  namespace: crossplane-system
type: Opaque
stringData:
  credentials: '{\"token\":\"${GITHUB_TOKEN}\",\"owner\":\"${GITHUB_OWNER}\"}'
" | kubectl --namespace crossplane-system apply --filename -

kubectl apply --filename providers/github-config.yaml

kubectl create namespace a-team

gh repo create $GITHUB_OWNER/dot-test --public

gh repo clone $GITHUB_OWNER/dot-test

cd dot-test

touch README.md

git add .

git commit -m "README"

git push

cd ..

rm -rf dot-test
```

## Example

```sh
kubectl --namespace a-team apply \
    --filename examples/backend-ci.yaml

kubectl tree --namespace a-team app silly-demo

gh repo view $GITHUB_OWNER/dot-test --web
```

## Destroy

```sh
gh repo delete $GITHUB_OWNER/dot-test

kind delete cluster

exit
```