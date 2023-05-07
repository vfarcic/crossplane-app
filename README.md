## Publish To Upbound

```bash
cd package

# Replace `[...]` with the Upbound Cloud account
export UP_ACCOUNT=[...]

# Replace `[...]` with the Upbound Cloud token
export UP_TOKEN=[...]

# Create `dot-application` repository

up login

# Replace `[...]` with the version of the package (e.g., `v0.5.0`)
export VERSION=[...]

up xpkg build --name app.xpkg

up xpkg push --package app.xpkg \
    xpkg.upbound.io/$UP_ACCOUNT/dot-application:$VERSION
```
