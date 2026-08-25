# Chainlink VRF vendor provenance

- Repository: `https://github.com/smartcontractkit/chainlink-evm`
- Tag: `contracts-v1.5.0`
- Commit: `86aa5a1d34b20eda8d18fe6eb0e4882948e545ba`
- License: MIT; see `LICENSE`
- Imported: 2026-08-21

This lane contains only the source closure used by the native-payment VRF v2.5 direct-funding
reference: `VRFV2PlusWrapperConsumerBase`, `IVRFV2PlusWrapper`, `VRFV2PlusClient`, and
`LinkTokenInterface`. Preserve their upstream paths so their relative imports remain authoritative.

Update all four sources, the license, commit and tests as one dependency change. Do not mix files
from another Chainlink release.
