# blohard account keys

Account keys for [blohard](https://github.com/blohard/protocol): memberships in an account, bought
and sold on a bonding curve, and reply gates that admit only the account and its key holders.

Every account can open its own keys to trading. A key's price rises with the number of keys
outstanding, and the ETH paid for keys stays in the market to pay sellers back. Every purchase,
sale and transfer pays a 5% fee, 4.5% to the account and 0.5% to a development fund.

**The contracts are immutable and have no owner.** Once deployed, nobody, blohard included, can
change the curve or the fees, redirect the development fund, take keys or reserves, or stop
trading.

**[SPEC.md](SPEC.md)** is the specification: the curve, the fees, trading and the key gates. The
Board and its reply-gate rules are in the
[protocol spec](https://github.com/blohard/protocol/blob/main/SPEC.md).

blohard.social has [a guide to account keys](https://blohard.social/keys/8453/about), and you can
buy and sell keys there.

## Contracts

| contract | what it does |
|---|---|
| [`AccountKeys`](src/AccountKeys.sol) | the shared market: activation, buying, selling, transfers and fee claims. Immutable and ownerless |
| [`AuthorKeyGate`](src/KeyGates.sol) | a reply gate that admits the parent's author and their key holders |
| [`AuthorKeyBlocklistGate`](src/KeyGates.sol) | the same, refusing holders on the author's `blocked` list |

## Deployments

[`deployments.json`](deployments.json) has the live addresses, and a test checks them against the
CREATE2 addresses of this code.

| | Base (8453) | Base Sepolia (84532) |
|---|---|---|
| `AccountKeys` | `0x6E6674Cd2Df37812C5c729a68CA881FFC22A49E4` | same |
| `AuthorKeyGate` | `0x62653E324dE74404493eDcB3E1375f572B6e8292` | same |
| `AuthorKeyBlocklistGate` | `0x48AeE1fee1b227eE1E34A58ac313E95e623C7e2C` | same |

The market's address depends on its development fund, which is a constructor argument, and the
gates' addresses depend on the market's. Both chains use the same fund, so they share all three
addresses.

## Build and test

You need [Foundry](https://getfoundry.sh). The blohard protocol comes in as a submodule.

```sh
git clone --recurse-submodules https://github.com/blohard/account-keys.git
cd account-keys
forge build
forge test
```

The build treats compiler and lint warnings as errors. `forge fmt` keeps the formatting.

## Deploy

The scripts deploy through the deterministic deployer proxy. Each one finds its CREATE2 address
first and reports an existing deployment instead of repeating it. Without `--broadcast` nothing is
sent: a script simulates the deployment and prints the addresses.

```sh
ACCOUNT_KEYS_DEV_FUND=0x… forge script script/DeployAccountKeys.s.sol \
    --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
BOARD=0x… REGISTRY=0x… ACCOUNT_KEYS=0x… forge script script/DeployKeyGates.s.sol \
    --rpc-url $RPC --broadcast --private-key $DEPLOYER_KEY
```

Run each script without `--broadcast` first and check the printed addresses against
`deployments.json`: a wrong development fund or input gives other addresses, and the development
fund can never be changed after deployment.
`DeployKeyGates` takes the Board, `ListRegistry` and market addresses from the environment. The
first two are in the protocol's
[`deployments.json`](https://github.com/blohard/protocol/blob/main/deployments.json). `LIST_NAME`
names the blocklist the combined gate reads, `blocked` by default.

## License

[MIT](LICENSE)
