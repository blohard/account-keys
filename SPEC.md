# blohard account keys

This is the specification of account keys, an optional feature built on the blohard protocol. An
account's keys are memberships in that account, bought and sold on a bonding curve and backed by
the ETH paid for them. Reply gates can then limit replies to an account's key holders.

The feature is one market and two reply gates, all outside the Board:

| contract | what it does | where |
|---|---|---|
| `AccountKeys` | one shared market where every account can open its own keys to trading | §2–§4 |
| `AuthorKeyGate`, `AuthorKeyBlocklistGate` | reply gates that admit an author's key holders | §5 |

It changes nothing in the core protocol. The Board, its reply-gate rules and the right of response
are specified in the [protocol spec](https://github.com/blohard/protocol/blob/main/SPEC.md), which
this document cites as "protocol §n".

## 1. Terms

- **Creator:** the account whose keys are traded. Every account can be a creator, and each one has
  its own market inside the shared contract.
- **Key:** one whole unit of membership in a creator's market. Keys within a market are
  interchangeable.
- **Holder:** an account holding at least one of a creator's keys.
- **Supply:** a creator's outstanding keys. Buying adds to it and selling removes from it.
- **Reserve:** the ETH that backs a market's outstanding keys, paid out again when keys are sold.
- **Dev fund:** the fixed address that receives the development share of every fee.

## 2. The market

There is no owner, administrator or upgrade path. The curve, the fee rates and the dev fund are
fixed when the contract is deployed. Nobody can confiscate keys, withdraw reserves or stop
trading.

### 2.1 Activation

A creator must activate their own market with `activate(initialAmount, maxTotalCost, deadline)`
before anyone can buy keys. Only the account itself can activate its market, and only once
(`AlreadyActive`). Activation can buy the first keys in the same transaction at the normal curve
price, or buy none. There are no free keys, privileged mints or creator discounts. A creator who
never activates has no market and no holders.

### 2.2 Buying, selling and transferring

| function | what it does |
|---|---|
| `buy(creator, amount, maxTotalCost, deadline)` | buys `amount` keys for the caller and refunds any excess ETH |
| `sell(creator, amount, minNetProceeds, deadline)` | sells the caller's keys back to the market and pays the proceeds at once |
| `transfer(creator, to, amount, maxFee, deadline)` | moves the caller's keys to another account for a fee and refunds any excess ETH |

- Amounts are whole keys. Purchases, sales and transfers need a positive amount
  (`InvalidAmount`), while activation may buy none.
- Activation, purchases, sales and transfers take a deadline (`Expired` after it). Fee claims do
  not. Purchases take a maximum total cost, sales a minimum net payment and transfers a maximum
  fee (`Slippage` when the price has moved past them). Paying less than the cost or fee fails with
  `InsufficientPayment`.
- Buying and selling need an active market (`InactiveMarket`). Selling or transferring more keys
  than the caller holds fails with `InsufficientKeys`.
- A transfer cannot go to the zero address (`ZeroAddress`), the sender or the market itself
  (`InvalidRecipient`). The recipient pays nothing and receives no ETH or callback. A transfer
  leaves supply and reserves unchanged.
- There are no approvals and no holding period: buying, replying and selling in one transaction is
  allowed. There is no signed or sponsored way to trade. Smart accounts call the market directly.
- Any payment the market makes, whether a refund, sale proceeds or a fee claim, reverts the whole
  transaction if the recipient rejects it (`PaymentFailed`). It never affects other accounts.

### 2.3 The bonding curve

The curve is defined by the ETH that backs `s` outstanding keys, in wei:

```text
reserveAt(s) = 10^13 * s + floor(sqrt(1.6 * 10^23 * s^5))
```

Buying `q` keys at supply `s` costs `reserveAt(s + q) - reserveAt(s)` before fees, and selling `q`
keys pays `reserveAt(s) - reserveAt(s - q)`. Key `n` alone costs `reserveAt(n) - reserveAt(n - 1)`,
which is about `0.00001 ETH + 1 ETH * (n / 10,000)^1.5`: a flat base price plus a part that rises
as `n^1.5`.

| key | its price before fees, about |
|---:|---:|
| 1 | 0.0000104 ETH |
| 10 | 0.0000393 ETH |
| 100 | 0.0010025 ETH |
| 1,000 | 0.0316 ETH |
| 2,500 | 0.125 ETH |
| 10,000 | 1 ETH |

10,000 outstanding keys are backed by exactly 4,000.1 ETH. Because every trade is a difference of
the same function, splitting a trade never changes its curve value, a market's reserve always
equals `reserveAt(supply)`, and a trade's gas does not grow with its size. Supply is bounded by
`MAX_SUPPLY` (2^32 - 1), which keeps every intermediate value within 256 bits. Buying past it
fails with `SupplyLimit`.

Keys are interchangeable: what a seller paid for a key does not affect what selling it pays.

### 2.4 Fees

Every purchase, sale and transfer charges 5% of a curve value:

| recipient | share | basis points |
|---|---:|---:|
| the creator | 4.5% | 450 |
| the dev fund | 0.5% | 50 |

- **Purchase:** the buyer pays the curve value plus both fees. For a curve value of 1 ETH, the buyer
  pays 1.05 ETH: 1 ETH joins the reserve, 0.045 ETH accrues to the creator and 0.005 ETH to the dev
  fund.
- **Sale:** both fees come out of the curve value. Selling keys worth 1 ETH pays the seller
  0.95 ETH.
- **Transfer:** the fee is 5% of the keys' sale value at the current supply,
  `reserveAt(supply) - reserveAt(supply - amount)`. The sender pays it. With no trades in between,
  a transfer costs half the fees of selling the keys and buying them back.

Each fee is the curve value times its basis points, divided by 10,000 and rounded down to a whole
wei. A creator trading their own keys pays the same fees, and the creator share accrues back to
them.

### 2.5 Fee claims

Fees accrue to their recipient inside the market and stay there until claimed, with no expiry.
`claimFees(recipient)` pays a recipient everything owed to them. Anyone may call it, but the ETH
always goes to the recipient, so a caller can neither redirect it nor earn anything for calling. A
zero balance is a no-op. Each claim pays one recipient, so a recipient that rejects ETH cannot
block anyone else, and its fees stay claimable.

### 2.6 Quotes

| function | returns |
|---|---|
| `quoteBuy(creator, amount)` | the purchase's curve value, both fees and the total cost, for an active market |
| `quoteSell(creator, amount)` | the sale's curve value, both fees and the net payment, for an active market with enough supply |
| `quoteTransfer(creator, amount)` | the transfer's reference value, both fees and the total fee, for a market with enough supply |
| `quoteAtSupply(startSupply, amount)` | a hypothetical purchase at any supply, such as a creator's first keys before activation |
| `reserveAt(s)`, `price(n)` | the curve itself |

Quotes revert with the same errors as the trades they describe and never check the caller's
balance. A quote reserves nothing: execution checks the caller's price limit again. Integrators
decode reverts with the custom errors in the contract's ABI and never read a failed quote as a zero
price.

### 2.7 Events

```solidity
event Activated(address indexed creator);
event Trade(address indexed creator, address indexed trader, bool isBuy, uint256 amount,
            uint256 curveValue, uint256 creatorFee, uint256 devFee, uint256 newSupply);
event KeysTransferred(address indexed creator, address indexed from, address indexed to,
                      uint256 amount, uint256 referenceValue, uint256 creatorFee, uint256 devFee);
event FeesClaimed(address indexed recipient, uint256 amount);
```

Together they reconstruct every market's activation, supply, balances, accrued fees and payouts.

## 3. Solvency

The market owes, for every creator, `reserveAt(supply)`, plus every unclaimed fee. Each function
changes that debt by exactly the ETH it keeps or pays out:

- A purchase keeps the curve value and both fees, and owes all of them.
- A sale pays its net proceeds and owes that much less. Its fees move from the reserve to the fee
  balances.
- A transfer keeps its fee and owes it to the fee recipients.
- A claim pays out exactly what it removes.

The ETH balance is therefore always at least what the market owes. It can be more, since ETH can be
forced into any contract, but nothing can withdraw a surplus.

## 4. Accounts and keys

- Ordinary accounts, smart accounts and accounts with delegated code all follow the same rules.
  The market never looks at `tx.origin` or at whether an address has code.
- Keys and supply are local to one deployment on one chain. There is no cross-chain ownership.
- Holding a key is not a promise of anything: a creator may stop posting, change their gates or
  ignore holders.

## 5. Key gates

Both gates implement the protocol's `IReplyGate` (protocol §5). Each serves every author from one
deployment: it reads the parent's author from the Board and that author's market from
`AccountKeys`.

- **`AuthorKeyGate(board, keys)`** admits the parent's author and any holder of at least one of
  the author's keys.
- **`AuthorKeyBlocklistGate(board, keys, registry, listId)`** also refuses holders on the author's
  list `listId` in the `ListRegistry`. The deployed gate uses `blocked`, the list the protocol's
  `AuthorBlocklistGate` reads, so an author keeps one blocklist when switching gates. A key never
  overrides a block.

An author uses one of them as their default gate or as a single message's gate. A message has one
effective gate (protocol §4.1), so an author who wants holders only and a blocklist uses the
combined gate. An author who never activated a market has no holders, so apart from protected
responses only they can reply under either gate.

Holding is checked when a reply is posted. Selling or transferring away the last key stops future
replies but never removes accepted ones. The Board's rules still apply around the gate: a protected
response passes without calling it (protocol §5.4), deletion and removal always close replies
(protocol §5.6), and a sponsored reply is judged by its authenticated author, not the account that
paid for it. Clients may apply the gate again when showing earlier replies (protocol §5.7). The
reference client folds earlier replies from accounts that no longer hold a key, except protected
responses, which it never folds.

Both gates ignore `gateData`. Their Board, market, registry and list are fixed at deployment.

## 6. Security considerations

- **The dev fund is permanent.** It is a constructor argument and cannot be changed. If its private
  key is lost, its fees are lost with it, so it belongs in cold storage or a multisig. A dev fund
  that rejects ETH can never be paid, and its fees stay in the market.
- **Reentrancy.** Every function that sends ETH is guarded by a reentrancy lock and updates its
  balances before sending.
- **Payments forward all gas** and copy no return data, so contract wallets can receive them. A
  hostile recipient can fail, or use up the gas of, any transaction that pays it, including someone
  else's claim on its behalf. Anyone claiming fees for others should cap the gas.
- **Prices move.** Another trade can land first. The price limits and deadlines bound what a trader
  pays or receives.
- **Creators trade their own keys cheaply.** The creator share of a fee returns to the creator, so a
  creator buying and selling their own keys pays about 1% for the round trip instead of 10%. That
  makes it cheaper for a creator to trade just ahead of a buyer, so buyers should keep their price
  limits tight.

## 7. Deployments

Every contract is deployed with CREATE2 through the deterministic deployer proxy, with a fixed salt:

| contract | salt | constructor |
|---|---|---|
| `AccountKeys` | `keccak256("AccountKeys v1")` | the dev fund |
| `AuthorKeyGate` | `keccak256("AuthorKeyGate v1")` | the Board, the market |
| `AuthorKeyBlocklistGate` | `keccak256("AuthorKeyBlocklistGate v1")` | the Board, the market, the `ListRegistry`, `keccak256("blocked")` |

An address depends only on the salt, the bytecode and the constructor arguments. The market's
address therefore depends on its dev fund, and the gates' addresses on the market's. A chain whose
market has a different dev fund has different addresses for all three.
[`deployments.json`](deployments.json) lists the deployments.
