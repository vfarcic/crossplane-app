## Create App With PostgreSQL In Google Cloud

```bash
cat examples/backend-db-google.yaml

kubectl create namespace a-team

kubectl --namespace a-team apply \
    --filename examples/backend-db-google.yaml

kubectl --namespace a-team get appclaims

kubectl get sqls,managed

curl silly-demo.127.0.0.1.nip.io/videos
```

## Destroy

```bash
gcloud projects delete $PROJECT_ID
```