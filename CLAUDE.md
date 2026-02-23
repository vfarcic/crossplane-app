# CLAUDE.md

## GitHub API

- When using `gh api`, always use read-only syntax: `gh api --paginate <endpoint>`, `gh api -X GET <endpoint>`, or `gh api --method GET <endpoint>`. These are pre-approved in settings. Write operations (POST/PUT/DELETE) require explicit user approval.

## Testing

- Always redirect test output to a file in the `./tmp` directory using `> ./tmp/test-output.log 2>&1` (not `tee`). Create the directory if it doesn't exist.
- To run tests, use `task test` which handles cluster setup, test execution, and teardown.
- For iterating on tests with an existing cluster, use `task test-once`.

## Composition Development

- KCL source files live in `kcl/`. The Crossplane Composition YAML in `package/` is generated from KCL — never edit `package/backend.yaml` directly.
- After modifying KCL files, run `task package-generate` to regenerate the composition YAML, then `task package-apply` to apply it to the cluster.
- Use `KUBECONFIG=kubeconfig-dot-app.yaml` when running kubectl commands against the KinD test cluster.
