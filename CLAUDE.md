# CLAUDE.md

## Testing

- Always redirect test output to a file in the `./tmp` directory using `> ./tmp/test-output.log 2>&1` (not `tee`). Create the directory if it doesn't exist.
- To run tests, use `task test` which handles cluster setup, test execution, and teardown.
- For iterating on tests with an existing cluster, use `task test-once`.
