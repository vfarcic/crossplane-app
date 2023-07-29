## Create App With PostgreSQL In Google Cloud

```bash
cat examples/backend-db-google.yaml

kubectl create namespace a-team

kubectl --namespace a-team apply \
    --filename examples/backend-db-google.yaml

kubectl --namespace a-team get appclaims,sqlclaims

kubectl get apps,sqls,managed

kubectl --namespace a-team get all,ingresses

curl silly-demo.$INGRESS_HOST.nip.io/videos
```

## Destroy

```bash
gcloud projects delete $PROJECT_ID
```
