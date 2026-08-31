## Description

Please describe the changes this PR makes and why it should be merged.

## Type of Change

- [ ] Bug fix (non-breaking change that fixes an issue)
- [ ] New feature (non-breaking change that adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Refactoring (no functional changes)
- [ ] Documentation update

## Checklist

- [ ] I have read the [Contributing Guidelines](../CONTRIBUTE.md)
- [ ] My code follows the code style of this project
- [ ] I have run `zig fmt --check build.zig src examples tests`
- [ ] I have run `sh scripts/check_conventions.sh`
- [ ] I have run the relevant Debug, ReleaseSafe, and compliance tests
- [ ] I have run ASan/UBSan and bounded fuzzing for memory or parser changes
- [ ] I have run Autobahn without exclusions for WebSocket/RFC 7692 changes
- [ ] I have compiled and interoperability-tested relevant HTTP/3 changes
- [ ] I documented API, limit, dependency, and compatibility changes
