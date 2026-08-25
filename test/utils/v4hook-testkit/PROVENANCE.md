# v4hook-testkit provenance

This local-only testkit retains the embedded Permit2, PoolManager and PositionManager deployment
bytecode from [`akshatmittal/hookmate`](https://github.com/akshatmittal/hookmate) commit
`33408fbc15e083eb0bc4205fa37cb6ba0a926f44` under its MIT license. The fixtures let Foundry tests
deploy exact pinned dependencies despite Permit2's different compiler version.

The testkit deliberately excludes Hookmate's address table and custom router. Remote scripts bind
addresses supplied by a verified v4hook deployment plan. Tests swap through Uniswap v4-core's
`PoolSwapTest`; production and fork integrations must use the intended official router ABI.
